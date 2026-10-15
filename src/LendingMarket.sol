// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
// TODO: add reentrancy guard

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
 */
contract LendingMarket {
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
    address public pendingAdmin;

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
    event PrincipalUpdated(address indexed account, uint256 principal);
    event CollateralUpdated(address indexed account, uint256 collateral);
    event BaseSupplyIndexUpdated(uint256 baseSupplyIndex);
    event BaseBorrowIndexUpdated(uint256 baseBorrowIndex);
    event PendingAdminSet(address indexed pendingAdmin);
    event AdminUpdated(address indexed admin);

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
        emit BaseBorrowIndexUpdated(baseBorrowIndex);

        if (suppliesBefore > 0) {
            uint256 accruedToSuppliers = (borrowsBefore * interest) / FACTOR;
            baseSupplyIndex += (baseSupplyIndex * accruedToSuppliers) / suppliesBefore;
            emit BaseSupplyIndexUpdated(baseSupplyIndex);
        }

        lastAccrualTime = block.timestamp;
    }

    // -------------------------------------------------------------------------------------------
    // Supplier actions
    // -------------------------------------------------------------------------------------------

    function supply(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        baseToken.transferFrom(msg.sender, address(this), amount);

        uint256 principal = _principalForSupply(amount);
        supplyPrincipal[msg.sender] += principal;
        totalSupplyPrincipal += principal;

        emit Supply(msg.sender, amount);
    }

    function withdraw(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 principal = _principalForSupply(amount);
        require(supplyPrincipal[msg.sender] >= principal, "insufficient balance");

        decrementPrincipal(msg.sender, principal);

        baseToken.transfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------------
    // Borrower actions
    // -------------------------------------------------------------------------------------------

    function supplyCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");

        collateralToken.transferFrom(msg.sender, address(this), amount);

        incrementCollateral(msg.sender, amount);

        emit SupplyCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        require(collateralBalance[msg.sender] >= amount, "insufficient collateral");

        decrementCollateral(msg.sender, amount);

        require(isHealthy(msg.sender), "would be undercollateralized");

        collateralToken.transfer(msg.sender, amount);

        emit WithdrawCollateral(msg.sender, amount);
    }

    function borrow(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 principal = _principalForBorrow(amount);
        incrementPrincipal(msg.sender, principal);

        require(isHealthy(msg.sender), "would be undercollateralized");

        baseToken.transfer(msg.sender, amount);

        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 owed = borrowBalanceOf(msg.sender);
        if (amount > owed) amount = owed;

        uint256 principal = _principalForBorrow(amount);

        baseToken.transferFrom(msg.sender, address(this), amount);

        decrementPrincipal(msg.sender, principal);

        emit Repay(msg.sender, amount);
    }

    // TODO: FUTURE FEATURE Add the ability for someone to transfer their position (collateral/debts) to another user.

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

        uint256 seizeAmount = (repayAmount * liquidationIncentive) / FACTOR;

        if (seizeAmount > collateralBalance[borrower]) seizeAmount = collateralBalance[borrower];

        uint256 principal = _principalForBorrow(repayAmount);
        decrementPrincipal(borrower, principal);
        decrementCollateral(borrower, seizeAmount);

        baseToken.transferFrom(msg.sender, address(this), repayAmount);
        collateralToken.transfer(msg.sender, seizeAmount);

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

        uint256 collateralValue = (collateralBalance[account] * getManipulationResistantPrice()) / FACTOR;
        uint256 borrowingPower = (collateralValue * collateralFactor) / FACTOR;

        return borrowingPower >= debt;
    }

    function getManipulationResistantPrice() public view returns (uint256) {
        // go back to the lead engineer - determine how to make price manipulation resistant.
        return getPrice();
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

    // both of these round down.
    function _principalForBorrow(uint256 amount) internal view returns (uint256) {
        return (amount * FACTOR) / baseBorrowIndex;
    }

    // both of these round down.
    function _principalForSupply(uint256 amount) internal view returns (uint256) {
        return (amount * FACTOR) / baseSupplyIndex;
    }

    function incrementPrincipal(address account, uint256 amount) internal {
        supplyPrincipal[account] += amount;
        totalSupplyPrincipal += amount;
        emit PrincipalUpdated(account, supplyPrincipal[account]);
    }

    function decrementPrincipal(address account, uint256 amount) internal {
        supplyPrincipal[account] -= amount;
        totalSupplyPrincipal -= amount;
        emit PrincipalUpdated(account, supplyPrincipal[account]);
    }

    function incrementCollateral(address account, uint256 amount) internal {
        collateralBalance[account] += amount;
        totalCollateral += amount;
        emit CollateralUpdated(account, collateralBalance[account]);
    }

    function decrementCollateral(address account, uint256 amount) internal {
        collateralBalance[account] -= amount;
        totalCollateral -= amount;
        emit CollateralUpdated(account, collateralBalance[account]);
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

    function setParameters(uint256 collateralFactor_, uint256 liquidationIncentive_, uint256 borrowRatePerSecond_)
        external
        onlyAdmin
    {
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

    // TODO: add functionality where newAdmin has to claim the admin role by calling a function on the contract.
    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        pendingAdmin = newAdmin;
        emit PendingAdminSet(newAdmin);
    }

    function claimAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminUpdated(msg.sender);
    }
}
