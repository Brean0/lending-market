// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LendingMarketTest} from "./LendingMarket.t.sol";

contract LiquidationPricingTest is LendingMarketTest {
    function test_liquidationConvertsBaseRepaymentToWeth() public {
        _prepareLiquidation(15_000e18, 1_800e18);

        // 1,100 base buys 0.611111111111111111 WETH at 1,800 base per WETH.
        _liquidateAndAssert(15_000e18, 1_000e18, 611_111_111_111_111_111);
    }

    function test_liquidationConvertsAtPriceAboveOne() public {
        _prepareLiquidation(20e18, 2e18);

        _liquidateAndAssert(20e18, 1e18, 0.55e18);
    }

    function test_liquidationConvertsAtPriceBelowOne() public {
        _prepareLiquidation(5e18, 0.5e18);

        _liquidateAndAssert(5e18, 1e18, 2.2e18);
    }

    function test_liquidationRoundsIncentiveBeforeConvertingUnits() public {
        _prepareLiquidation(5e18, 0.5e18);

        // floor(19 * 1.1) = 20 base wei, which buys 40 collateral wei at 0.5.
        _liquidateAndAssert(5e18, 19, 40);
    }

    function test_liquidationCapsConvertedSeizureAtPostedCollateral() public {
        _prepareLiquidation(30e18, 2e18);

        // 27.5 base would buy 13.75 WETH, but only 10 WETH is posted.
        _liquidateAndAssert(30e18, 25e18, 10e18);
    }

    function test_liquidationRejectsZeroPriceWithoutChangingBalances() public {
        _prepareLiquidation(15_000e18, 0);
        base.mint(liquidator, 1_000e18);
        vm.startPrank(liquidator);
        base.approve(address(market), type(uint256).max);
        vm.expectRevert("invalid oracle answer");
        market.liquidate(borrower, 1_000e18);
        vm.stopPrank();

        assertEq(base.balanceOf(liquidator), 1_000e18);
        assertEq(base.balanceOf(address(market)), 985_000e18);
        assertEq(market.borrowBalanceOf(borrower), 15_000e18);
        assertEq(market.totalBorrowPrincipal(), 15_000e18);
        assertEq(market.collateralBalance(borrower), 10e18);
        assertEq(market.totalCollateral(), 10e18);
        assertEq(weth.balanceOf(address(market)), 10e18);
        assertEq(weth.balanceOf(liquidator), 0);
    }

    function testFuzz_liquidationConvertsRepaymentAtNonzeroPrices(uint256 price, uint256 repayment) public {
        price = bound(price, 0.001e18, 1_800e18);
        repayment = bound(repayment, 1, 15_000e18);
        // This position is unhealthy throughout the price range, so eligibility cannot hide conversion bugs.
        _prepareLiquidation(15_000e18, price);

        uint256 expectedSeizure = ((repayment * 11 / 10) * 1e18) / price;
        if (expectedSeizure > 10e18) expectedSeizure = 10e18;
        _liquidateAndAssert(15_000e18, repayment, expectedSeizure);
    }

    function _prepareLiquidation(uint256 debt, uint256 price) internal {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(debt);
        wethOracle.setPrice(int256(price));
        assertFalse(market.isHealthy(borrower));
    }

    function _liquidateAndAssert(uint256 debt, uint256 repayment, uint256 expectedSeizure) internal {
        base.mint(liquidator, repayment);
        vm.startPrank(liquidator);
        base.approve(address(market), type(uint256).max);
        market.liquidate(borrower, repayment);
        vm.stopPrank();

        assertEq(base.balanceOf(liquidator), 0, "liquidator base spent");
        assertEq(base.balanceOf(address(market)), 1_000_000e18 - debt + repayment, "market base received");
        assertEq(base.balanceOf(borrower), debt, "borrower base unchanged");
        assertEq(market.borrowBalanceOf(borrower), debt - repayment, "borrower debt reduced");
        assertEq(market.borrowPrincipal(borrower), debt - repayment, "borrower principal reduced");
        assertEq(market.totalBorrowPrincipal(), debt - repayment, "global debt reduced");
        assertEq(weth.balanceOf(liquidator), expectedSeizure, "liquidator collateral received");
        assertEq(weth.balanceOf(borrower), 0, "borrower wallet collateral unchanged");
        assertEq(weth.balanceOf(address(market)), 10e18 - expectedSeizure, "market collateral remaining");
        assertEq(market.collateralBalance(borrower), 10e18 - expectedSeizure, "borrower collateral reduced");
        assertEq(market.totalCollateral(), 10e18 - expectedSeizure, "global collateral reduced");
        assertEq(market.totalSupplyPrincipal(), 1_000_000e18, "supplier principal unchanged");
    }
}
