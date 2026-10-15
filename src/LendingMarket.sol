// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title LendingMarket
 * @notice Single-collateral money market. Suppliers deposit the base asset and earn interest;
 *         borrowers post collateral and draw the base asset against it. Balances are tracked as
 *         principal and scaled by a pair of global indices that advance with accrued interest.
 *
 * @dev This contract is deployed behind a TransparentUpgradeableProxy. Live markets hold real
 *      user balances in the storage layout below.
 *
 *      Scaling: all values are 1e18-fixed-point unless stated otherwise. Collateral prices are
 *      quoted by the oracle in base-asset terms, also 1e18.
 *      Listed assets must be standard 18-decimal ERC20 contracts without transfer fees or rebasing.
 *      SafeERC20 validates transfer call results; accounting assumes the requested amount moves.
 */
contract LendingMarket {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------------------------

    uint8 internal constant DECIMALS = 18;
    uint256 internal constant FACTOR = 10 ** DECIMALS;

    // -------------------------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------------------------

    // --- roles and wiring ---
    address public admin;
    address public pauseGuardian;
    IPriceOracle public oracle;
    IERC20 public baseToken;
    IERC20 public collateralToken;

    // --- accrual state ---
    uint256 public baseBorrowIndex;
    uint256 public baseSupplyIndex;
    uint256 public lastAccrualTime;

    // --- market totals (principal terms) ---
    uint256 public totalSupplyPrincipal;
    uint256 public totalBorrowPrincipal;
    uint256 public totalCollateral;

    // --- risk parameters ---
    uint256 public collateralFactor;
    uint256 public liquidationIncentive;
    uint256 public borrowRatePerSecond;

    // --- per-account state ---
    mapping(address => uint256) public supplyPrincipal;
    mapping(address => uint256) public borrowPrincipal;
    mapping(address => uint256) public collateralBalance;

    // --- circuit breaker ---
    bool public paused;

    bool private _initialized;

    // Appended for proxy compatibility; configure to match the listed feed's heartbeat.
    uint256 public maxPriceAge;

    // -------------------------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------------------------

    event Supply(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);
    event SupplyCollateral(address indexed account, uint256 amount);
    event WithdrawCollateral(address indexed account, uint256 amount);
    event Borrow(address indexed account, uint256 amount);
    event Repay(address indexed account, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed borrower, uint256 repaid, uint256 seized);
    event OracleUpdated(address indexed newOracle);
    event ParametersUpdated(uint256 collateralFactor, uint256 liquidationIncentive, uint256 borrowRate);
    event PausedSet(bool paused);

    // -------------------------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == pauseGuardian || msg.sender == admin, "not guardian");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    // -------------------------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------------------------

    function initialize(
        address admin_,
        address pauseGuardian_,
        address oracle_,
        address baseToken_,
        address collateralToken_,
        uint256 collateralFactor_,
        uint256 liquidationIncentive_,
        uint256 borrowRatePerSecond_,
        uint256 maxPriceAge_
    ) external {
        require(!_initialized, "already initialized");
        require(maxPriceAge_ > 0, "invalid max price age");
        _initialized = true;

        admin = admin_;
        pauseGuardian = pauseGuardian_;
        oracle = IPriceOracle(oracle_);
        baseToken = IERC20(baseToken_);
        collateralToken = IERC20(collateralToken_);

        collateralFactor = collateralFactor_;
        liquidationIncentive = liquidationIncentive_;
        borrowRatePerSecond = borrowRatePerSecond_;
        maxPriceAge = maxPriceAge_;

        baseBorrowIndex = FACTOR;
        baseSupplyIndex = FACTOR;
        lastAccrualTime = block.timestamp;
    }

    // -------------------------------------------------------------------------------------------
    // Interest accrual
    // -------------------------------------------------------------------------------------------

    /// @notice Advances both indices to the current block timestamp.
    function accrueInterest() public {
        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0) return;

        uint256 interest = borrowRatePerSecond * elapsed;

        uint256 borrowsBefore = presentValueBorrow(totalBorrowPrincipal);
        uint256 suppliesBefore = presentValueSupply(totalSupplyPrincipal);

        baseBorrowIndex += (baseBorrowIndex * interest) / FACTOR;

        if (suppliesBefore > 0) {
            uint256 accruedToSuppliers = (borrowsBefore * interest) / FACTOR;
            baseSupplyIndex += (baseSupplyIndex * accruedToSuppliers) / suppliesBefore;
        }

        lastAccrualTime = block.timestamp;
    }

    // -------------------------------------------------------------------------------------------
    // Supplier actions
    // -------------------------------------------------------------------------------------------

    function supply(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        baseToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 principal = _principalForSupply(amount);
        supplyPrincipal[msg.sender] += principal;
        totalSupplyPrincipal += principal;

        emit Supply(msg.sender, amount);
    }

    function withdraw(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        // Base leaving the market must debit enough principal to cover the transfer.
        uint256 principal = _principalForSupplyUp(amount);
        require(supplyPrincipal[msg.sender] >= principal, "insufficient balance");

        supplyPrincipal[msg.sender] -= principal;
        totalSupplyPrincipal -= principal;

        baseToken.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------------
    // Borrower actions
    // -------------------------------------------------------------------------------------------

    function supplyCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        collateralBalance[msg.sender] += amount;
        totalCollateral += amount;

        emit SupplyCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        require(collateralBalance[msg.sender] >= amount, "insufficient collateral");

        // Withdrawal health must include elapsed interest so collateral cannot leave against stale debt.
        accrueInterest();

        collateralBalance[msg.sender] -= amount;
        totalCollateral -= amount;

        require(isHealthy(msg.sender), "would be undercollateralized");

        collateralToken.safeTransfer(msg.sender, amount);

        emit WithdrawCollateral(msg.sender, amount);
    }

    function borrow(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        // Base leaving the market must create debt for the entire transfer, even for one wei.
        uint256 principal = _principalForBorrowUp(amount);
        borrowPrincipal[msg.sender] += principal;
        totalBorrowPrincipal += principal;

        require(isHealthy(msg.sender), "would be undercollateralized");

        baseToken.safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 owed = borrowBalanceOf(msg.sender);
        if (amount > owed) amount = owed;

        // Paying the displayed full debt clears all principal; reconversion can leave dust.
        uint256 principal = amount == owed ? borrowPrincipal[msg.sender] : _principalForBorrow(amount);

        baseToken.safeTransferFrom(msg.sender, address(this), amount);

        borrowPrincipal[msg.sender] -= principal;
        totalBorrowPrincipal -= principal;

        emit Repay(msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------------
    // Liquidation
    // -------------------------------------------------------------------------------------------

    /**
     * @notice Repays part of an unhealthy borrower's debt in exchange for their collateral,
     *         plus the liquidation incentive.
     * @param borrower the account being liquidated
     * @param repayAmount how much of the borrower's debt the liquidator is repaying
     */
    function liquidate(address borrower, uint256 repayAmount) external whenNotPaused {
        require(repayAmount > 0, "zero amount");
        accrueInterest();

        require(!isHealthy(borrower), "borrower is healthy");

        uint256 owed = borrowBalanceOf(borrower);
        if (repayAmount > owed) repayAmount = owed;

        uint256 price = getPrice();

        // Convert base repayment to collateral using the incentive and base-per-collateral price.
        // Their FACTOR scales cancel: checked multiplication, then one final floor in collateral wei.
        uint256 seizeAmount = (repayAmount * liquidationIncentive) / price;
        if (seizeAmount > collateralBalance[borrower]) {
            seizeAmount = collateralBalance[borrower];
        }

        // Full liquidation clears principal dust just like full repayment.
        uint256 principal = repayAmount == owed ? borrowPrincipal[borrower] : _principalForBorrow(repayAmount);
        borrowPrincipal[borrower] -= principal;
        totalBorrowPrincipal -= principal;

        collateralBalance[borrower] -= seizeAmount;
        totalCollateral -= seizeAmount;

        baseToken.safeTransferFrom(msg.sender, address(this), repayAmount);
        collateralToken.safeTransfer(msg.sender, seizeAmount);

        emit Liquidate(msg.sender, borrower, repayAmount, seizeAmount);
    }

    // -------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------

    function borrowBalanceOf(address account) public view returns (uint256) {
        return presentValueBorrow(borrowPrincipal[account]);
    }

    function supplyBalanceOf(address account) public view returns (uint256) {
        return presentValueSupply(supplyPrincipal[account]);
    }

    function presentValueBorrow(uint256 principal) public view returns (uint256) {
        return (principal * baseBorrowIndex) / FACTOR;
    }

    function presentValueSupply(uint256 principal) public view returns (uint256) {
        return (principal * baseSupplyIndex) / FACTOR;
    }

    /// @notice Fraction of supplied base currently borrowed, 1e18 scaled.
    /// @dev Multiplication is applied before the division so the 1e18 scale survives; the
    ///      intermediate cannot realistically overflow at supported market sizes.
    function utilization() public view returns (uint256) {
        uint256 supplied = presentValueSupply(totalSupplyPrincipal);
        if (supplied == 0) return 0;
        return (presentValueBorrow(totalBorrowPrincipal) * FACTOR) / supplied;
    }

    /// @notice True when the account's borrowing power covers its debt.
    function isHealthy(address account) public view returns (bool) {
        uint256 debt = borrowBalanceOf(account);
        if (debt == 0) return true;

        uint256 collateralValue = (collateralBalance[account] * getPrice()) / FACTOR;
        uint256 borrowingPower = (collateralValue * collateralFactor) / FACTOR;

        return borrowingPower >= debt;
    }

    /// @notice Collateral price in base-asset terms, 1e18 scaled.
    function getPrice() public view returns (uint256) {
        // Old proxies have zero in the appended slot: fail closed until explicitly configured.
        require(maxPriceAge > 0, "invalid max price age");
        // Valuation assumes 1e18 prices; reject incompatible scales rather than misprice collateral.
        require(oracle.decimals() == DECIMALS, "unsupported oracle decimals");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();
        // Validate before casting: negative answers would become enormous unsigned prices.
        require(answer > 0, "invalid oracle answer");
        require(roundId != 0, "invalid oracle round");
        require(answeredInRound >= roundId, "incomplete oracle round");
        // Reject missing/future timestamps before subtraction, then require a current valuation.
        require(updatedAt <= block.timestamp && updatedAt > 0, "invalid oracle timestamp");
        require(block.timestamp - updatedAt <= maxPriceAge, "stale oracle price");
        return uint256(answer);
    }

    // -------------------------------------------------------------------------------------------
    // Internal accounting helpers
    // -------------------------------------------------------------------------------------------

    // Incoming partial repayments round down so debt relief never exceeds the amount paid.
    function _principalForBorrow(uint256 amount) internal view returns (uint256) {
        return (amount * FACTOR) / baseBorrowIndex;
    }

    // Incoming deposits round down so supplier credit never exceeds the amount received.
    function _principalForSupply(uint256 amount) internal view returns (uint256) {
        return (amount * FACTOR) / baseSupplyIndex;
    }

    // Round outgoing transfers up without adding index - 1 to the scaled amount.
    function _principalForBorrowUp(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        return ((amount * FACTOR - 1) / baseBorrowIndex) + 1;
    }

    function _principalForSupplyUp(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        return ((amount * FACTOR - 1) / baseSupplyIndex) + 1;
    }

    // -------------------------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------------------------

    function setOracle(address newOracle, uint256 maxPriceAge_) external onlyGuardian {
        require(newOracle != address(0), "zero oracle");
        require(maxPriceAge_ > 0, "invalid max price age");
        // Change feed and heartbeat policy atomically so a new feed never inherits the old policy.
        oracle = IPriceOracle(newOracle);
        maxPriceAge = maxPriceAge_;
        emit OracleUpdated(newOracle);
    }

    function setParameters(
        uint256 collateralFactor_,
        uint256 liquidationIncentive_,
        uint256 borrowRatePerSecond_
    ) external onlyAdmin {
        require(collateralFactor_ <= FACTOR, "cf too high");
        require(liquidationIncentive_ >= FACTOR, "incentive below par");

        accrueInterest();

        collateralFactor = collateralFactor_;
        liquidationIncentive = liquidationIncentive_;
        borrowRatePerSecond = borrowRatePerSecond_;

        emit ParametersUpdated(collateralFactor_, liquidationIncentive_, borrowRatePerSecond_);
    }

    function setPaused(bool paused_) external onlyGuardian {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        admin = newAdmin;
    }
}
