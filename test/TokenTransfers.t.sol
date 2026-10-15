// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";
import {LendingMarket} from "../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @dev Adversarial behavior is confined to tests; the production mock stays unchanged.
contract TransferTestToken {
    enum Mode {
        Normal,
        NoReturn,
        False,
        FalseAfterMove,
        ShortReturn,
        LongReturn,
        LongFalseReturn,
        InvalidBool,
        Revert
    }
    Mode public mode;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setMode(Mode next) external {
        mode = next;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(mode != Mode.Revert, "token reverted");
        if (mode == Mode.False) return false;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (mode == Mode.FalseAfterMove) return false;
        if (mode == Mode.NoReturn) assembly { return(0, 0) }
        if (mode == Mode.ShortReturn) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == Mode.LongReturn) {
            assembly {
                mstore(0, 1)
                mstore(32, 0)
                return(0, 64)
            }
        }
        if (mode == Mode.LongFalseReturn) {
            assembly {
                mstore(0, 0)
                mstore(32, 1)
                return(0, 64)
            }
        }
        if (mode == Mode.InvalidBool) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return true;
    }
}

contract TokenTransfersTest is Test {
    TransferTestToken internal base;
    TransferTestToken internal collateral;
    MockOracle internal oracle;
    LendingMarket internal market;
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        base = new TransferTestToken();
        collateral = new TransferTestToken();
        oracle = new MockOracle(1e18);
        address admin = makeAddr("admin");
        bytes memory init = abi.encodeCall(
            LendingMarket.initialize,
            (
                admin,
                admin,
                address(oracle),
                address(base),
                address(collateral),
                0.8e18,
                1.1e18,
                uint256(0.05e18) / 365 days,
                1 hours
            )
        );
        market = LendingMarket(
            address(new TransparentUpgradeableProxy(address(new LendingMarket()), admin, init))
        );
        base.mint(supplier, 20_000e18);
        base.mint(borrower, 1_000e18);
        base.mint(liquidator, 1_000e18);
        collateral.mint(borrower, 2_000e18);
        vm.startPrank(supplier);
        base.approve(address(market), type(uint256).max);
        market.supply(10_000e18);
        vm.stopPrank();
        vm.startPrank(borrower);
        base.approve(address(market), type(uint256).max);
        collateral.approve(address(market), type(uint256).max);
        market.supplyCollateral(1_000e18);
        market.borrow(500e18);
        vm.stopPrank();
        vm.prank(liquidator);
        base.approve(address(market), type(uint256).max);
    }

    // Paths: supply, withdraw, supplyCollateral, withdrawCollateral, borrow,
    // repay, liquidate with failed base payment, liquidate with failed collateral delivery.
    function _action(uint256 path) internal {
        if (path == 0) {
            vm.prank(supplier);
            market.supply(100e18);
        } else if (path == 1) {
            vm.prank(supplier);
            market.withdraw(100e18);
        } else if (path == 2) {
            vm.prank(borrower);
            market.supplyCollateral(100e18);
        } else if (path == 3) {
            vm.prank(borrower);
            market.withdrawCollateral(100e18);
        } else if (path == 4) {
            vm.prank(borrower);
            market.borrow(100e18);
        } else if (path == 5) {
            vm.prank(borrower);
            market.repay(type(uint256).max);
        } else {
            vm.prank(liquidator);
            market.liquidate(borrower, 100e18);
        }
    }

    function _prepare(uint256 path) internal {
        vm.warp(block.timestamp + 2 days);
        // Refresh after the warp so the transfer tests also work with stale-price protection.
        oracle.setPrice(path >= 6 ? int256(0.5e18) : int256(1e18));
    }

    function _token(uint256 path) internal view returns (TransferTestToken) {
        return path == 2 || path == 3 || path == 7 ? collateral : base;
    }

    function _state() internal view returns (bytes32) {
        bytes32 accounting = keccak256(
            abi.encode(
                market.totalSupplyPrincipal(),
                market.totalBorrowPrincipal(),
                market.totalCollateral(),
                market.supplyPrincipal(supplier),
                market.borrowPrincipal(borrower),
                market.collateralBalance(borrower),
                market.baseSupplyIndex(),
                market.baseBorrowIndex(),
                market.lastAccrualTime()
            )
        );
        return keccak256(abi.encode(accounting, _tokenState(base), _tokenState(collateral)));
    }

    function _tokenState(TransferTestToken token) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.balanceOf(address(market)),
                token.balanceOf(supplier),
                token.balanceOf(borrower),
                token.balanceOf(liquidator),
                token.allowance(supplier, address(market)),
                token.allowance(borrower, address(market)),
                token.allowance(liquidator, address(market))
            )
        );
    }

    function _rejectEveryPath(TransferTestToken.Mode mode) internal {
        for (uint256 path; path < 8; ++path) {
            uint256 snapshot = vm.snapshotState();
            _prepare(path);
            _token(path).setMode(mode);
            bytes32 beforeState = _state();
            if (mode == TransferTestToken.Mode.Revert) {
                // SafeERC20 preserves the token's own reason for failed calls.
                vm.expectRevert(bytes("token reverted"));
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(_token(path)))
                );
            }
            _action(path);
            assertEq(_state(), beforeState, "failed transfer changed accounting, balances or allowances");
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_falseReturnRollsBackEveryPath() public {
        _rejectEveryPath(TransferTestToken.Mode.False);
    }

    function test_falseAfterMovingFundsRollsBackEveryPath() public {
        _rejectEveryPath(TransferTestToken.Mode.FalseAfterMove);
    }

    function test_shortReturnRollsBackEveryPath() public {
        _rejectEveryPath(TransferTestToken.Mode.ShortReturn);
    }

    function test_longFalseReturnRollsBackEveryPath() public {
        _rejectEveryPath(TransferTestToken.Mode.LongFalseReturn);
    }

    function test_trueWithTrailingDataSucceedsEveryPath() public {
        // Match standard ABI/SafeERC20 behavior; still assert the complete settlement effects.
        _acceptEveryPath(TransferTestToken.Mode.LongReturn);
    }

    function test_invalidBoolRollsBackEveryPath() public {
        _rejectEveryPath(TransferTestToken.Mode.InvalidBool);
    }

    function test_revertingTokenRollsBackEveryPath() public {
        _rejectEveryPath(TransferTestToken.Mode.Revert);
    }

    function _acceptEveryPath(TransferTestToken.Mode mode) internal {
        for (uint256 path; path < 8; ++path) {
            uint256 snapshot = vm.snapshotState();
            _prepare(path);
            market.accrueInterest();
            base.setMode(mode);
            collateral.setMode(mode);
            uint256 baseBefore = base.balanceOf(address(market));
            uint256 collateralBefore = collateral.balanceOf(address(market));
            uint256 debtBefore = market.borrowBalanceOf(borrower);
            _action(path);
            if (path == 0) {
                assertEq(base.balanceOf(address(market)), baseBefore + 100e18);
                assertEq(base.balanceOf(supplier), 9_900e18);
                assertGt(market.supplyBalanceOf(supplier), 10_100e18);
            } else if (path == 1) {
                assertEq(base.balanceOf(address(market)), baseBefore - 100e18);
                assertEq(base.balanceOf(supplier), 10_100e18);
                assertLt(market.supplyBalanceOf(supplier), 10_000e18);
            } else if (path == 2) {
                assertEq(collateral.balanceOf(address(market)), collateralBefore + 100e18);
                assertEq(market.collateralBalance(borrower), 1_100e18);
            } else if (path == 3) {
                assertEq(collateral.balanceOf(address(market)), collateralBefore - 100e18);
                assertEq(collateral.balanceOf(borrower), 1_100e18);
                assertEq(market.collateralBalance(borrower), 900e18);
            } else if (path == 4) {
                assertEq(base.balanceOf(address(market)), baseBefore - 100e18);
                assertEq(base.balanceOf(borrower), 1_600e18);
                assertApproxEqAbs(market.borrowBalanceOf(borrower), debtBefore + 100e18, 2);
            } else if (path == 5) {
                assertEq(base.balanceOf(address(market)), baseBefore + debtBefore);
                assertApproxEqAbs(market.borrowBalanceOf(borrower), 0, 2);
            } else {
                assertEq(base.balanceOf(address(market)), baseBefore + 100e18);
                assertEq(base.balanceOf(liquidator), 900e18);
                assertGt(collateral.balanceOf(liquidator), 0);
                assertEq(
                    collateral.balanceOf(address(market)) + collateral.balanceOf(liquidator), collateralBefore
                );
                assertApproxEqAbs(market.borrowBalanceOf(borrower), debtBefore - 100e18, 2);
            }
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_standardTrueReturnSucceedsEveryPath() public {
        _acceptEveryPath(TransferTestToken.Mode.Normal);
    }

    function test_optionalNoReturnSucceedsEveryPath() public {
        _acceptEveryPath(TransferTestToken.Mode.NoReturn);
    }

    function test_tokenWithoutCodeCannotCreditSupply() public {
        vm.etch(address(base), hex"");
        uint256 beforePrincipal = market.totalSupplyPrincipal();
        vm.prank(supplier);
        vm.expectRevert();
        market.supply(100e18);
        assertEq(market.totalSupplyPrincipal(), beforePrincipal);
    }
}
