// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LendingMarketTest} from "./LendingMarket.t.sol";

contract CollateralWithdrawalAccrualTest is LendingMarketTest {
    function _openPosition() internal {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);
    }

    function _advanceYear() internal {
        vm.warp(block.timestamp + 365 days);
        // Keep collateral value fixed and the feed fresh: only elapsed interest changes health.
        wethOracle.setPrice(2_000e18);
    }

    function _stateHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                market.baseBorrowIndex(),
                market.baseSupplyIndex(),
                market.lastAccrualTime(),
                market.totalSupplyPrincipal(),
                market.totalBorrowPrincipal(),
                market.totalCollateral(),
                market.borrowPrincipal(borrower),
                market.collateralBalance(borrower),
                weth.balanceOf(borrower),
                weth.balanceOf(address(market)),
                base.balanceOf(borrower),
                base.balanceOf(address(market))
            )
        );
    }

    function test_withdrawCollateralRejectsPendingInterestAndRollsBack() public {
        _openPosition();
        _advanceYear();
        bytes32 beforeState = _stateHash();

        // Remaining borrowing power is 15,200; debt including elapsed interest is about 15,750.
        vm.prank(borrower);
        vm.expectRevert("would be undercollateralized");
        market.withdrawCollateral(0.5e18);

        assertEq(_stateHash(), beforeState, "failed withdrawal must roll back accounting and tokens");
    }

    function test_safeWithdrawalAccruesInterestAndUpdatesClockAndIndices() public {
        _openPosition();
        _advanceYear();

        vm.prank(borrower);
        market.withdrawCollateral(0.1e18);

        assertEq(market.lastAccrualTime(), block.timestamp);
        assertGt(market.baseBorrowIndex(), FACTOR);
        assertGt(market.baseSupplyIndex(), FACTOR);
        assertApproxEqAbs(market.borrowBalanceOf(borrower), 15_750e18, 1e12);
        assertEq(market.borrowPrincipal(borrower), 15_000e18);
        assertEq(market.totalBorrowPrincipal(), 15_000e18);
        assertEq(market.collateralBalance(borrower), 9.9e18);
        assertEq(market.totalCollateral(), 9.9e18);
        assertEq(weth.balanceOf(borrower), 0.1e18);
        assertEq(weth.balanceOf(address(market)), 9.9e18);
        assertTrue(market.isHealthy(borrower));
    }

    function test_zeroDebtWithdrawalReturnsAllCollateralAndUpdatesClock() public {
        _postCollateral(borrower, 10e18);
        _advanceYear();

        vm.prank(borrower);
        market.withdrawCollateral(10e18);

        assertEq(market.lastAccrualTime(), block.timestamp);
        assertGt(market.baseBorrowIndex(), FACTOR);
        assertEq(market.baseSupplyIndex(), FACTOR);
        assertEq(market.borrowBalanceOf(borrower), 0);
        assertEq(market.collateralBalance(borrower), 0);
        assertEq(market.totalCollateral(), 0);
        assertEq(weth.balanceOf(borrower), 10e18);
        assertEq(weth.balanceOf(address(market)), 0);
    }

    function test_insufficientCollateralWithdrawalRevertsWithoutStateChange() public {
        _openPosition();
        _advanceYear();
        bytes32 beforeState = _stateHash();

        vm.prank(borrower);
        vm.expectRevert("insufficient collateral");
        market.withdrawCollateral(11e18);

        assertEq(_stateHash(), beforeState);
    }

    function test_pausedCollateralWithdrawalRevertsWithoutStateChange() public {
        _openPosition();
        _advanceYear();
        vm.prank(guardian);
        market.setPaused(true);
        bytes32 beforeState = _stateHash();

        vm.prank(borrower);
        vm.expectRevert("paused");
        market.withdrawCollateral(0.1e18);

        assertEq(_stateHash(), beforeState);
        assertTrue(market.paused());
    }

    function test_alreadyAccruedWithdrawalDoesNotAccrueTwice() public {
        _openPosition();
        _advanceYear();
        market.accrueInterest();
        uint256 borrowIndex = market.baseBorrowIndex();
        uint256 supplyIndex = market.baseSupplyIndex();
        uint256 debt = market.borrowBalanceOf(borrower);

        vm.prank(borrower);
        market.withdrawCollateral(0.1e18);

        assertEq(market.baseBorrowIndex(), borrowIndex);
        assertEq(market.baseSupplyIndex(), supplyIndex);
        assertEq(market.lastAccrualTime(), block.timestamp);
        assertEq(market.borrowBalanceOf(borrower), debt);
        assertEq(market.collateralBalance(borrower), 9.9e18);
        assertEq(weth.balanceOf(borrower), 0.1e18);
    }

    function test_zeroCollateralWithdrawalRevertsWithoutStateChange() public {
        _openPosition();
        _advanceYear();
        bytes32 beforeState = _stateHash();

        vm.prank(borrower);
        vm.expectRevert("zero amount");
        market.withdrawCollateral(0);

        assertEq(_stateHash(), beforeState);
    }
}
