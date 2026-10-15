// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LendingMarketTest} from "./LendingMarket.t.sol";

contract PrincipalRoundingTest is LendingMarketTest {
    function _accrue(uint256 elapsed) internal {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(5_000e18 + 7);
        vm.warp(block.timestamp + elapsed);
        // Keep the unchanged collateral price fresh while testing interest-driven rounding.
        wethOracle.setPrice(2_000e18);
        market.accrueInterest();
        assertGt(market.baseBorrowIndex(), FACTOR);
        assertGt(market.baseSupplyIndex(), FACTOR);
    }

    function test_freshAccountCannotWithdrawOneWeiAfterAccrual() public {
        _accrue(1 days);
        address fresh = makeAddr("fresh");
        uint256 cash = base.balanceOf(address(market));
        uint256 total = market.totalSupplyPrincipal();
        vm.prank(fresh);
        vm.expectRevert("insufficient balance");
        market.withdraw(1);
        assertEq(base.balanceOf(fresh), 0);
        assertEq(base.balanceOf(address(market)), cash);
        assertEq(market.totalSupplyPrincipal(), total);
    }

    function test_noCollateralCannotBorrowOneWeiAfterAccrual() public {
        _accrue(1 days);
        address fresh = makeAddr("fresh");
        uint256 cash = base.balanceOf(address(market));
        uint256 total = market.totalBorrowPrincipal();
        vm.prank(fresh);
        vm.expectRevert("would be undercollateralized");
        market.borrow(1);
        assertEq(base.balanceOf(fresh), 0);
        assertEq(market.borrowPrincipal(fresh), 0);
        assertEq(base.balanceOf(address(market)), cash);
        assertEq(market.totalBorrowPrincipal(), total);
    }

    function test_supplierOneWeiWithdrawalChargesPrincipal() public {
        _accrue(1 days);
        _checkWithdrawal(1);
    }

    function test_collateralizedOneWeiBorrowCreatesDebt() public {
        _accrue(1 days);
        _checkBorrow(1);
    }

    function testFuzz_supplierDebitCoversTransferredAmount(uint256 amount, uint256 elapsed) public {
        _accrue(bound(elapsed, 1, 365 days));
        _checkWithdrawal(bound(amount, 1, 1_000e18));
    }

    function testFuzz_newDebtCoversTransferredAmount(uint256 amount, uint256 elapsed) public {
        _accrue(bound(elapsed, 1, 365 days));
        _checkBorrow(bound(amount, 1, 1_000e18));
    }

    function _checkWithdrawal(uint256 amount) internal {
        uint256 principalBefore = market.supplyPrincipal(supplier);
        uint256 totalBefore = market.totalSupplyPrincipal();
        uint256 cashBefore = base.balanceOf(address(market));
        uint256 tokensBefore = base.balanceOf(supplier);
        vm.prank(supplier);
        market.withdraw(amount);
        uint256 debit = principalBefore - market.supplyPrincipal(supplier);
        assertGt(debit, 0);
        assertGe(debit * market.baseSupplyIndex(), amount * FACTOR);
        assertLt((debit - 1) * market.baseSupplyIndex(), amount * FACTOR);
        assertEq(market.totalSupplyPrincipal(), totalBefore - debit);
        assertEq(base.balanceOf(address(market)), cashBefore - amount);
        assertEq(base.balanceOf(supplier), tokensBefore + amount);
    }

    function _checkBorrow(uint256 amount) internal {
        address fresh = makeAddr("fresh borrower");
        _postCollateral(fresh, 10e18);
        uint256 totalBefore = market.totalBorrowPrincipal();
        uint256 cashBefore = base.balanceOf(address(market));
        vm.prank(fresh);
        market.borrow(amount);
        uint256 debt = market.borrowPrincipal(fresh);
        assertGt(debt, 0);
        assertGe(debt * market.baseBorrowIndex(), amount * FACTOR);
        assertLt((debt - 1) * market.baseBorrowIndex(), amount * FACTOR);
        assertGe(market.borrowBalanceOf(fresh), amount);
        assertEq(market.totalBorrowPrincipal(), totalBefore + debt);
        assertEq(base.balanceOf(address(market)), cashBefore - amount);
        assertEq(base.balanceOf(fresh), amount);
    }

    function test_fullDisplayedRepaymentClearsDust() public {
        _checkFullRepayment(false);
    }

    function test_cappedRepaymentClearsDust() public {
        _checkFullRepayment(true);
    }

    function _checkFullRepayment(bool capped) internal {
        _accrue(1 days);
        uint256 owed = market.borrowBalanceOf(borrower);
        uint256 principal = market.borrowPrincipal(borrower);
        // This fixture must exercise a lossy round trip, not an exactly divisible balance.
        assertLt(owed * FACTOR / market.baseBorrowIndex(), principal);
        base.mint(borrower, owed);
        uint256 cashBefore = base.balanceOf(address(market));
        uint256 tokensBefore = base.balanceOf(borrower);
        vm.startPrank(borrower);
        base.approve(address(market), type(uint256).max);
        market.repay(capped ? type(uint256).max : owed);
        vm.stopPrank();
        assertEq(market.borrowPrincipal(borrower), 0);
        assertEq(market.borrowBalanceOf(borrower), 0);
        assertEq(market.totalBorrowPrincipal(), 0);
        assertEq(base.balanceOf(borrower), tokensBefore - owed);
        assertEq(base.balanceOf(address(market)), cashBefore + owed);
    }

    function testFuzz_partialRepaymentNeverOvercredits(uint256 amount) public {
        _accrue(1 days);
        amount = bound(amount, 1, market.borrowBalanceOf(borrower) - 1);
        uint256 principalBefore = market.borrowPrincipal(borrower);
        uint256 totalBefore = market.totalBorrowPrincipal();
        uint256 cashBefore = base.balanceOf(address(market));
        base.mint(borrower, amount);
        uint256 tokensBefore = base.balanceOf(borrower);
        vm.startPrank(borrower);
        base.approve(address(market), type(uint256).max);
        market.repay(amount);
        vm.stopPrank();
        uint256 credit = principalBefore - market.borrowPrincipal(borrower);
        assertLe(credit * market.baseBorrowIndex(), amount * FACTOR);
        assertGt((credit + 1) * market.baseBorrowIndex(), amount * FACTOR);
        assertEq(market.totalBorrowPrincipal(), totalBefore - credit);
        assertEq(base.balanceOf(borrower), tokensBefore - amount);
        assertEq(base.balanceOf(address(market)), cashBefore + amount);
    }

    function testFuzz_supplyCreditNeverExceedsDeposit(uint256 amount) public {
        _accrue(1 days);
        amount = bound(amount, 1, 1_000e18);
        address fresh = makeAddr("fresh supplier");
        uint256 totalBefore = market.totalSupplyPrincipal();
        uint256 cashBefore = base.balanceOf(address(market));
        base.mint(fresh, amount);
        vm.startPrank(fresh);
        base.approve(address(market), amount);
        market.supply(amount);
        vm.stopPrank();
        uint256 credit = market.supplyPrincipal(fresh);
        assertLe(credit * market.baseSupplyIndex(), amount * FACTOR);
        assertGt((credit + 1) * market.baseSupplyIndex(), amount * FACTOR);
        assertEq(market.totalSupplyPrincipal(), totalBefore + credit);
        assertEq(base.balanceOf(fresh), 0);
        assertEq(base.balanceOf(address(market)), cashBefore + amount);
    }

    function test_fullLiquidationClearsDust() public {
        _checkFullLiquidation(false);
    }

    function test_cappedLiquidationClearsDust() public {
        _checkFullLiquidation(true);
    }

    function _checkFullLiquidation(bool capped) internal {
        _accrue(1 days);
        wethOracle.setPrice(1e18);
        uint256 owed = market.borrowBalanceOf(borrower);
        assertLt(owed * FACTOR / market.baseBorrowIndex(), market.borrowPrincipal(borrower));
        uint256 cashBefore = base.balanceOf(address(market));
        uint256 collateralBefore = market.collateralBalance(borrower);
        base.mint(liquidator, owed);
        vm.startPrank(liquidator);
        base.approve(address(market), owed);
        market.liquidate(borrower, capped ? type(uint256).max : owed);
        vm.stopPrank();
        assertEq(market.borrowPrincipal(borrower), 0);
        assertEq(market.borrowBalanceOf(borrower), 0);
        assertEq(market.totalBorrowPrincipal(), 0);
        assertEq(base.balanceOf(liquidator), 0);
        assertEq(base.balanceOf(address(market)), cashBefore + owed);
        assertEq(market.collateralBalance(borrower), 0);
        assertEq(market.totalCollateral(), 0);
        assertEq(weth.balanceOf(liquidator), collateralBefore);
    }
}
