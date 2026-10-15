// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LendingMarketTest} from "./LendingMarket.t.sol";
import {LendingMarket} from "../src/LendingMarket.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract InterestAccrualModifierTest is LendingMarketTest {
    event OracleUpdated(address indexed newOracle);
    event ParametersUpdated(uint256 collateralFactor, uint256 liquidationIncentive, uint256 borrowRate);
    event PausedSet(bool paused);

    struct Accrual {
        uint256 borrowIndex;
        uint256 supplyIndex;
        uint256 timestamp;
    }

    function _openDebt() internal {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(5_000e18);
    }

    function _storedAccrual() internal view returns (Accrual memory) {
        return Accrual(market.baseBorrowIndex(), market.baseSupplyIndex(), market.lastAccrualTime());
    }

    function _advanceTime() internal returns (Accrual memory expected) {
        uint256 oldBorrowIndex = market.baseBorrowIndex();
        uint256 oldSupplyIndex = market.baseSupplyIndex();
        uint256 borrows = market.presentValueBorrow(market.totalBorrowPrincipal());
        uint256 supplies = market.presentValueSupply(market.totalSupplyPrincipal());
        vm.warp(block.timestamp + 30 days);
        // Refresh freshness only; these tests do not change collateral valuation.
        wethOracle.setPrice(2_000e18);
        uint256 interest = market.borrowRatePerSecond() * (block.timestamp - market.lastAccrualTime());
        expected = Accrual(
            oldBorrowIndex + oldBorrowIndex * interest / FACTOR,
            oldSupplyIndex + oldSupplyIndex * (borrows * interest / FACTOR) / supplies,
            block.timestamp
        );
    }

    function _assertAccrual(Accrual memory expected) internal view {
        assertEq(market.lastAccrualTime(), expected.timestamp, "timestamp");
        assertEq(market.baseBorrowIndex(), expected.borrowIndex, "borrow index");
        assertEq(market.baseSupplyIndex(), expected.supplyIndex, "supply index");
    }

    function test_collateralDepositAccrues() public {
        _openDebt();
        Accrual memory expected = _advanceTime();
        _postCollateral(borrower, 1e18);
        _assertAccrual(expected);
    }

    function test_collateralWithdrawalAccrues() public {
        _openDebt();
        Accrual memory expected = _advanceTime();
        vm.prank(borrower);
        market.withdrawCollateral(1e18);
        _assertAccrual(expected);
    }

    function test_setOracleLeavesAccrualPendingAndEmitsEvent() public {
        _openDebt();
        MockOracle replacement = new MockOracle(2_000e18);
        Accrual memory before = _storedAccrual();
        _advanceTime();

        vm.expectEmit(true, false, false, true, address(market));
        emit OracleUpdated(address(replacement));
        vm.prank(admin);
        market.setOracle(address(replacement), 2 hours);

        assertEq(address(market.oracle()), address(replacement));
        assertEq(market.maxPriceAge(), 2 hours);
        _assertAccrual(before);
    }

    function test_setAdminLeavesAccrualPending() public {
        _openDebt();
        Accrual memory before = _storedAccrual();
        _advanceTime();
        vm.prank(admin);
        market.setAdmin(supplier);
        assertEq(market.admin(), supplier);
        _assertAccrual(before);
    }

    function test_guardianPauseLeavesAccrualPendingAndEmitsEvent() public {
        _openDebt();
        Accrual memory before = _storedAccrual();
        _advanceTime();

        vm.expectEmit(false, false, false, true, address(market));
        emit PausedSet(true);
        vm.prank(guardian);
        market.setPaused(true);

        assertTrue(market.paused());
        _assertAccrual(before);
    }

    function test_guardianUnpauseLeavesAccrualPendingAndEmitsEvent() public {
        _openDebt();
        vm.prank(guardian);
        market.setPaused(true);
        Accrual memory before = _storedAccrual();
        _advanceTime();

        vm.expectEmit(false, false, false, true, address(market));
        emit PausedSet(false);
        vm.prank(guardian);
        market.setPaused(false);

        assertFalse(market.paused());
        _assertAccrual(before);
    }

    function test_setParametersSettlesOldRateBeforeInstallingNewRateAndEmitsEvent() public {
        _openDebt();
        vm.prank(admin);
        market.setParameters(0.8e18, 1.1e18, 1e10);
        vm.warp(block.timestamp + 1_000_000);

        vm.expectEmit(false, false, false, true, address(market));
        emit ParametersUpdated(0.75e18, 1.12e18, 2e10);
        vm.prank(admin);
        market.setParameters(0.75e18, 1.12e18, 2e10);

        // The setter settles the pending interval at the old rate: 1% on 5,000 debt.
        _assertAccrual(Accrual(1.01e18, 1.00005e18, block.timestamp));
        assertEq(market.borrowBalanceOf(borrower), 5_050e18);
        assertEq(market.supplyBalanceOf(supplier), 1_000_050e18);
        assertEq(market.collateralFactor(), 0.75e18);
        assertEq(market.liquidationIncentive(), 1.12e18);
        assertEq(market.borrowRatePerSecond(), 2e10);

        // A later interval uses the new rate: 2% on the now-settled 5,050 debt.
        vm.warp(block.timestamp + 1_000_000);
        market.accrueInterest();
        _assertAccrual(Accrual(1.0302e18, 1.000151e18, block.timestamp));
        assertEq(market.borrowBalanceOf(borrower), 5_151e18);
        assertEq(market.supplyBalanceOf(supplier), 1_000_151e18);
    }

    function test_explicitAccrualBeforeRateChangeDoesNotAccrueTwice() public {
        _openDebt();
        Accrual memory expected = _advanceTime();
        market.accrueInterest();
        _assertAccrual(expected);
        vm.prank(admin);
        market.setParameters(0.75e18, 1.12e18, RATE_PER_SECOND * 2);
        _assertAccrual(expected);
        assertEq(market.borrowRatePerSecond(), RATE_PER_SECOND * 2);
        expected = _advanceTime();
        market.accrueInterest();
        _assertAccrual(expected);
    }

    function test_supplyStillAccrues() public {
        _openDebt();
        base.mint(supplier, 1_000e18);
        Accrual memory expected = _advanceTime();
        vm.prank(supplier);
        market.supply(1_000e18);
        _assertAccrual(expected);
    }

    function test_withdrawStillAccrues() public {
        _openDebt();
        Accrual memory expected = _advanceTime();
        vm.prank(supplier);
        market.withdraw(1_000e18);
        _assertAccrual(expected);
    }

    function test_borrowStillAccrues() public {
        _openDebt();
        Accrual memory expected = _advanceTime();
        vm.prank(borrower);
        market.borrow(1_000e18);
        _assertAccrual(expected);
    }

    function test_repayStillAccrues() public {
        _openDebt();
        Accrual memory expected = _advanceTime();
        vm.startPrank(borrower);
        base.approve(address(market), type(uint256).max);
        market.repay(1_000e18);
        vm.stopPrank();
        _assertAccrual(expected);
    }

    function test_liquidateStillAccrues() public {
        _openDebt();
        Accrual memory expected = _advanceTime();
        wethOracle.setPrice(500e18);
        base.mint(liquidator, 100e18);
        vm.startPrank(liquidator);
        base.approve(address(market), type(uint256).max);
        market.liquidate(borrower, 100e18);
        vm.stopPrank();
        _assertAccrual(expected);
    }

    function test_publicAccrualRunsOnceAndIsIdempotentAtSameTimestamp() public {
        _openDebt();
        Accrual memory expected = _advanceTime();
        market.accrueInterest();
        _assertAccrual(expected);
        market.accrueInterest();
        _assertAccrual(expected);
        _postCollateral(borrower, 1e18);
        _assertAccrual(expected);
    }

    function test_uninitializedAccrualDoesNotWriteIndicesOrTimestamp() public {
        LendingMarket fresh = new LendingMarket();
        vm.warp(block.timestamp + 30 days);
        fresh.accrueInterest();
        assertEq(fresh.baseBorrowIndex(), 0);
        assertEq(fresh.baseSupplyIndex(), 0);
        assertEq(fresh.lastAccrualTime(), 0);
        fresh.initialize(
            admin,
            guardian,
            address(wethOracle),
            address(base),
            address(weth),
            0.8e18,
            1.1e18,
            RATE_PER_SECOND,
            1 hours
        );
        assertEq(fresh.baseBorrowIndex(), FACTOR);
        assertEq(fresh.baseSupplyIndex(), FACTOR);
        assertEq(fresh.lastAccrualTime(), block.timestamp);
    }

    function test_repeatInitializationRevertsWithoutAccrualChanges() public {
        _openDebt();
        Accrual memory before = _storedAccrual();
        _advanceTime();
        vm.expectRevert("already initialized");
        market.initialize(supplier, borrower, address(0), address(0), address(0), 0, 0, 0, 1 hours);
        _assertAccrual(before);
        assertEq(market.admin(), admin);
        assertEq(address(market.oracle()), address(wethOracle));
        assertEq(market.borrowRatePerSecond(), RATE_PER_SECOND);
    }

    function test_viewsKeepStoredValuesWithoutProjection() public {
        _openDebt();
        Accrual memory before = _storedAccrual();
        _advanceTime();
        assertEq(market.borrowBalanceOf(borrower), 5_000e18);
        assertEq(market.supplyBalanceOf(supplier), 1_000_000e18);
        assertEq(market.presentValueBorrow(1e18), 1e18);
        assertEq(market.presentValueSupply(1e18), 1e18);
        assertEq(market.utilization(), 0.005e18);
        assertTrue(market.isHealthy(borrower));
        assertEq(market.getPrice(), 2_000e18);
        _assertAccrual(before);
    }

    function test_pausedRepayAndRateUpdateAccrueWhileOtherAdminControlsLeaveInterestPending() public {
        _openDebt();
        vm.prank(guardian);
        market.setPaused(true);
        Accrual memory expected = _advanceTime();
        vm.startPrank(borrower);
        base.approve(address(market), type(uint256).max);
        market.repay(100e18);
        vm.stopPrank();
        _assertAccrual(expected);
        expected = _advanceTime();
        market.accrueInterest();
        _assertAccrual(expected);

        expected = _advanceTime();
        vm.prank(admin);
        market.setParameters(0.75e18, 1.12e18, RATE_PER_SECOND * 2);
        assertEq(market.collateralFactor(), 0.75e18);
        assertEq(market.liquidationIncentive(), 1.12e18);
        assertEq(market.borrowRatePerSecond(), RATE_PER_SECOND * 2);
        _assertAccrual(expected);
        Accrual memory before = _storedAccrual();

        _advanceTime();
        MockOracle replacement = new MockOracle(2_000e18);
        vm.prank(admin);
        market.setOracle(address(replacement), 2 hours);
        assertEq(address(market.oracle()), address(replacement));
        assertEq(market.maxPriceAge(), 2 hours);
        _assertAccrual(before);

        _advanceTime();
        vm.prank(admin);
        market.setAdmin(supplier);
        assertEq(market.admin(), supplier);
        _assertAccrual(before);

        _advanceTime();
        vm.prank(supplier);
        market.setPaused(false);
        _assertAccrual(before);
        assertFalse(market.paused());
    }

    function test_overflowingAccrualBlocksParameterRepairButAllowsGuardianPauseAndUnpause() public {
        _openDebt();
        vm.prank(admin);
        market.setParameters(0.8e18, 1.1e18, type(uint256).max);
        Accrual memory before = _storedAccrual();
        vm.warp(block.timestamp + 2);

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        market.accrueInterest();
        _assertAccrual(before);

        vm.prank(guardian);
        market.setPaused(true);
        assertTrue(market.paused());
        _assertAccrual(before);
        vm.prank(guardian);
        market.setPaused(false);
        assertFalse(market.paused());
        _assertAccrual(before);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        market.setParameters(0.75e18, 1.12e18, RATE_PER_SECOND);
        assertEq(market.collateralFactor(), 0.8e18);
        assertEq(market.liquidationIncentive(), 1.1e18);
        assertEq(market.borrowRatePerSecond(), type(uint256).max);
        _assertAccrual(before);
    }

    function test_rejectedActionsPreserveAccrualState() public {
        _openDebt();
        vm.prank(guardian);
        market.setPaused(true);
        Accrual memory before = _storedAccrual();
        _advanceTime();
        bytes[5] memory pausedCalls = [
            abi.encodeCall(market.supply, (1e18)),
            abi.encodeCall(market.withdraw, (1e18)),
            abi.encodeCall(market.supplyCollateral, (1e18)),
            abi.encodeCall(market.withdrawCollateral, (1e18)),
            abi.encodeCall(market.borrow, (1e18))
        ];
        for (uint256 i; i < pausedCalls.length; i++) {
            (bool ok, bytes memory reason) = address(market).call(pausedCalls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSignature("Error(string)", "paused"));
            _assertAccrual(before);
        }
        vm.expectRevert("paused");
        market.liquidate(borrower, 1e18);
        vm.expectRevert("not admin");
        market.setOracle(address(wethOracle), 1 hours);
        vm.expectRevert("not guardian");
        market.setPaused(false);
        vm.expectRevert("not admin");
        market.setAdmin(supplier);
        vm.expectRevert("not admin");
        market.setParameters(0.8e18, 1.1e18, RATE_PER_SECOND);
        _assertAccrual(before);
    }

    function test_guardsPreserveRejectionsWhenAccrualWouldOverflow() public {
        vm.prank(admin);
        market.setParameters(0.8e18, 1.1e18, type(uint256).max);
        vm.prank(guardian);
        market.setPaused(true);
        Accrual memory before = _storedAccrual();
        vm.warp(block.timestamp + 2);
        // Any attempted accrual would overflow; the original rejection must win.
        vm.expectRevert("paused");
        market.supplyCollateral(1e18);
        vm.expectRevert("not guardian");
        market.setPaused(false);
        vm.expectRevert("not guardian");
        market.setPaused(true);
        vm.prank(guardian);
        vm.expectRevert("not admin");
        market.setOracle(address(wethOracle), 1 hours);
        vm.expectRevert("not admin");
        market.setOracle(address(wethOracle), 1 hours);
        vm.expectRevert("not admin");
        market.setAdmin(supplier);
        vm.expectRevert("not admin");
        market.setParameters(0.8e18, 1.1e18, RATE_PER_SECOND);
        _assertAccrual(before);
        assertTrue(market.paused());
        assertEq(address(market.oracle()), address(wethOracle));
    }
}
