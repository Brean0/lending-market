// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LendingMarketTest} from "./LendingMarket.t.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {LendingMarket} from "../src/LendingMarket.sol";

// Interface keeps the new-selector regressions compilable against the pre-feedback implementation.
interface OracleAgeConfiguration {
    function maxPriceAge() external view returns (uint256);
    function setOracle(address feed, uint256 maxAge) external;
}

/// @dev Full round metadata is configurable because MockOracle always reports a complete, 18-decimal round.
contract ConfigurableOracle is IPriceOracle {
    uint8 public immutable decimals;
    uint80 internal immutable round;
    int256 internal immutable price;
    uint256 internal immutable updated;
    uint80 internal immutable answeredRound;

    constructor(uint80 round_, int256 price_, uint256 updated_, uint80 answeredRound_, uint8 decimals_) {
        round = round_;
        price = price_;
        updated = updated_;
        answeredRound = answeredRound_;
        decimals = decimals_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, price, updated, updated, answeredRound);
    }
}

contract OracleValidationTest is LendingMarketTest {
    uint256 internal constant NOW = 100_000;

    function _useRound(int256 price, uint256 updatedAt, uint80 round, uint80 answeredRound, uint8 decimals)
        internal
    {
        // Move time before installing the round so freshness boundaries are deterministic.
        vm.warp(NOW);
        ConfigurableOracle feed = new ConfigurableOracle(round, price, updatedAt, answeredRound, decimals);
        vm.prank(admin);
        market.setOracle(address(feed), 1 hours);
    }

    function _expectBorrowRevert(bytes memory reason, uint256 collateral) internal {
        _postCollateral(borrower, collateral);
        vm.prank(borrower);
        vm.expectRevert(reason);
        market.borrow(5_000e18);
        assertEq(market.borrowBalanceOf(borrower), 0);
        assertEq(base.balanceOf(borrower), 0);
    }

    function test_oracleZeroAnswerRejectsBorrow() public {
        _useRound(0, NOW, 2, 2, 18);
        _expectBorrowRevert("invalid oracle answer", 10e18);
    }

    function test_oracleNegativeAnswerRejectsBorrow() public {
        _useRound(-1, NOW, 2, 2, 18);
        _expectBorrowRevert("invalid oracle answer", 10e18);
    }

    function test_oracleNegativeAnswerWithOneWeiCollateralRejectsBorrow() public {
        _useRound(-1, NOW, 2, 2, 18);
        _expectBorrowRevert("invalid oracle answer", 1);
    }

    function test_oracleStaleRoundRejectsBorrow() public {
        _useRound(2_000e18, NOW - 1 hours - 1, 2, 2, 18);
        _expectBorrowRevert("stale oracle price", 10e18);
    }

    function test_oracleFutureTimestampRejectsBorrow() public {
        _useRound(2_000e18, NOW + 1, 2, 2, 18);
        _expectBorrowRevert("invalid oracle timestamp", 10e18);
    }

    function test_oracleZeroTimestampRejectsBorrow() public {
        _useRound(2_000e18, 0, 2, 2, 18);
        _expectBorrowRevert("invalid oracle timestamp", 10e18);
    }

    function test_oracleZeroRoundRejectsBorrow() public {
        _useRound(2_000e18, NOW, 0, 0, 18);
        _expectBorrowRevert("invalid oracle round", 10e18);
    }

    function test_oracleIncompleteRoundRejectsBorrow() public {
        _useRound(2_000e18, NOW, 2, 1, 18);
        _expectBorrowRevert("incomplete oracle round", 10e18);
    }

    function test_oracleUnansweredRoundRejectsBorrow() public {
        _useRound(2_000e18, NOW, 2, 0, 18);
        _expectBorrowRevert("incomplete oracle round", 10e18);
    }

    function test_oracleEightDecimalsRejectsBorrow() public {
        _useRound(2_000e18, NOW, 2, 2, 8);
        _expectBorrowRevert("unsupported oracle decimals", 10e18);
    }

    function test_oracleNineteenDecimalsRejectsBorrow() public {
        _useRound(2_000e18, NOW, 2, 2, 19);
        _expectBorrowRevert("unsupported oracle decimals", 10e18);
    }

    function test_oracleFreshPositiveRoundAllowsBorrow() public {
        _useRound(2_000e18, NOW, 2, 2, 18);
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(5_000e18);
        assertEq(market.getPrice(), 2_000e18);
        assertEq(base.balanceOf(borrower), 5_000e18);
        assertTrue(market.isHealthy(borrower));
    }

    function test_oracleExactlyOneHourOldAllowsBorrow() public {
        _useRound(2_000e18, NOW - 1 hours, 2, 2, 18);
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(5_000e18);
        assertEq(base.balanceOf(borrower), 5_000e18);
        assertTrue(market.isHealthy(borrower));
    }

    function test_oracleValidRoundAllowsHealthEquality() public {
        // Use the original setup timestamp so no interest accrues before the exact-limit borrow.
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(16_000e18);
        assertEq(market.borrowBalanceOf(borrower), 16_000e18);
        assertTrue(market.isHealthy(borrower));
    }

    function test_oracleLaterAnsweredRoundAllowsBorrow() public {
        _useRound(2_000e18, NOW, 2, 3, 18);
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(5_000e18);
        assertEq(base.balanceOf(borrower), 5_000e18);
    }

    function test_debtFreeHealthSkipsOracleQueries() public {
        // An address with no aggregator implementation reverts if either oracle method is queried.
        vm.prank(admin);
        market.setOracle(address(0xdead), 1 hours);
        assertTrue(market.isHealthy(borrower));
    }

    function _configuration() internal view returns (OracleAgeConfiguration) {
        return OracleAgeConfiguration(address(market));
    }

    function _setAge(uint256 age) internal {
        // Read before prank: evaluating the getter in a setter argument would consume the prank.
        address feed = address(market.oracle());
        vm.prank(admin);
        _configuration().setOracle(feed, age);
    }

    function _initializeWithAge(LendingMarket target, uint256 age) internal returns (bool, bytes memory) {
        return address(target)
            .call(
                abi.encodeWithSignature(
                    "initialize(address,address,address,address,address,uint256,uint256,uint256,uint256)",
                    admin,
                    guardian,
                    address(wethOracle),
                    address(base),
                    address(weth),
                    uint256(0.8e18),
                    uint256(1.1e18),
                    RATE_PER_SECOND,
                    age
                )
            );
    }

    function test_initializerStoresConfiguredAge() public {
        LendingMarket target = new LendingMarket();
        (bool ok,) = _initializeWithAge(target, 2 hours);
        assertTrue(ok, "new initializer selector must succeed");
        assertEq(OracleAgeConfiguration(address(target)).maxPriceAge(), 2 hours);
    }

    function test_initializerRejectsZeroAgeAndRollsBack() public {
        LendingMarket target = new LendingMarket();
        (bool ok, bytes memory reason) = _initializeWithAge(target, 0);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSignature("Error(string)", "invalid max price age"));
        assertEq(target.admin(), address(0));
        (ok,) = _initializeWithAge(target, 15 minutes);
        assertTrue(ok, "failed initialization must permit retry");
        assertEq(OracleAgeConfiguration(address(target)).maxPriceAge(), 15 minutes);
    }

    function test_setOracleChangesFeedAndAgeTogether() public {
        ConfigurableOracle feed = new ConfigurableOracle(2, 1_900e18, block.timestamp, 2, 18);
        vm.prank(admin);
        _configuration().setOracle(address(feed), 15 minutes);
        assertEq(address(market.oracle()), address(feed));
        assertEq(_configuration().maxPriceAge(), 15 minutes);
        assertEq(market.getPrice(), 1_900e18);
    }

    function test_setOracleRejectsZeroAgeAndPreservesConfiguration() public {
        address originalFeed = address(market.oracle());
        ConfigurableOracle feed = new ConfigurableOracle(2, 1_900e18, block.timestamp, 2, 18);
        vm.prank(admin);
        vm.expectRevert("invalid max price age");
        _configuration().setOracle(address(feed), 0);
        assertEq(address(market.oracle()), originalFeed);
        assertEq(_configuration().maxPriceAge(), 1 hours);
    }

    function test_setOracleRejectsZeroFeedAndPreservesAge() public {
        address originalFeed = address(market.oracle());
        vm.prank(admin);
        vm.expectRevert("zero oracle");
        _configuration().setOracle(address(0), 2 hours);
        assertEq(address(market.oracle()), originalFeed);
        assertEq(_configuration().maxPriceAge(), 1 hours);
    }

    function test_configuredDistinctAgesChangeStaleDecision() public {
        _useRound(2_000e18, NOW - 90 minutes, 2, 2, 18);
        _setAge(2 hours);
        assertEq(market.getPrice(), 2_000e18);
        _setAge(1 hours);
        vm.expectRevert("stale oracle price");
        market.getPrice();
    }

    function test_configuredFifteenMinuteBoundaryAllowsBorrow() public {
        _useRound(2_000e18, NOW - 15 minutes, 2, 2, 18);
        _setAge(15 minutes);
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(5_000e18);
        assertEq(base.balanceOf(borrower), 5_000e18);
    }

    function test_configuredFifteenMinutesPlusOneRejectsBorrow() public {
        _useRound(2_000e18, NOW - 15 minutes - 1, 2, 2, 18);
        _setAge(15 minutes);
        _expectBorrowRevert("stale oracle price", 10e18);
    }

    function test_unconfiguredUpgradeFailsClosedUntilAdminConfiguresAge() public {
        // An upgraded old proxy has zero in the newly appended slot 18.
        vm.store(address(market), bytes32(uint256(18)), bytes32(0));
        vm.expectRevert("invalid max price age");
        market.getPrice();
        vm.prank(admin);
        _configuration().setOracle(address(wethOracle), 2 hours);
        assertEq(market.getPrice(), 2_000e18);
        assertEq(_configuration().maxPriceAge(), 2 hours);
    }

    function _prepareLiquidation() internal {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);
        base.mint(liquidator, 1_000e18);
        vm.prank(liquidator);
        base.approve(address(market), type(uint256).max);
    }

    function _liquidationState() internal view returns (bytes32) {
        bytes32 accounting = keccak256(
            abi.encode(
                market.borrowBalanceOf(borrower),
                market.borrowPrincipal(borrower),
                market.collateralBalance(borrower),
                market.totalBorrowPrincipal(),
                market.totalCollateral(),
                market.totalSupplyPrincipal(),
                market.baseBorrowIndex(),
                market.baseSupplyIndex(),
                market.lastAccrualTime()
            )
        );
        bytes32 tokens = keccak256(
            abi.encode(
                base.balanceOf(borrower),
                base.balanceOf(liquidator),
                base.balanceOf(address(market)),
                weth.balanceOf(borrower),
                weth.balanceOf(liquidator),
                weth.balanceOf(address(market))
            )
        );
        return keccak256(abi.encode(accounting, tokens));
    }

    function _expectLiquidationRevert(bytes memory reason) internal {
        bytes32 beforeState = _liquidationState();
        vm.prank(liquidator);
        vm.expectRevert(reason);
        market.liquidate(borrower, 1_000e18);
        assertEq(_liquidationState(), beforeState, "failed liquidation changed accounting or tokens");
    }

    function test_liquidationRejectsZeroPriceWithoutStateChange() public {
        _prepareLiquidation();
        _useRound(0, NOW, 2, 2, 18);
        _expectLiquidationRevert("invalid oracle answer");
    }

    function test_liquidationRejectsNegativePriceWithoutStateChange() public {
        _prepareLiquidation();
        _useRound(-1, NOW, 2, 2, 18);
        _expectLiquidationRevert("invalid oracle answer");
    }

    function test_liquidationRejectsZeroRoundWithoutStateChange() public {
        _prepareLiquidation();
        _useRound(1_800e18, NOW, 0, 0, 18);
        _expectLiquidationRevert("invalid oracle round");
    }

    function test_liquidationRejectsIncompleteRoundWithoutStateChange() public {
        _prepareLiquidation();
        _useRound(1_800e18, NOW, 2, 1, 18);
        _expectLiquidationRevert("incomplete oracle round");
    }

    function test_liquidationRejectsUnansweredRoundWithoutStateChange() public {
        _prepareLiquidation();
        _useRound(1_800e18, NOW, 2, 0, 18);
        _expectLiquidationRevert("incomplete oracle round");
    }

    function test_liquidationRejectsWrongDecimalsWithoutStateChange() public {
        _prepareLiquidation();
        _useRound(1_800e18, NOW, 2, 2, 8);
        _expectLiquidationRevert("unsupported oracle decimals");
    }

    function test_liquidationRejectsZeroTimestampWithoutStateChange() public {
        _prepareLiquidation();
        _useRound(1_800e18, 0, 2, 2, 18);
        _expectLiquidationRevert("invalid oracle timestamp");
    }

    function test_liquidationRejectsFutureTimestampWithoutStateChange() public {
        _prepareLiquidation();
        _useRound(1_800e18, NOW + 1, 2, 2, 18);
        _expectLiquidationRevert("invalid oracle timestamp");
    }

    function test_liquidationRejectsStaleRoundWithoutStateChange() public {
        _prepareLiquidation();
        _useRound(1_800e18, NOW - 1 hours - 1, 2, 2, 18);
        _expectLiquidationRevert("stale oracle price");
    }

    function test_liquidationAcceptsValidPrice() public {
        _prepareLiquidation();
        _useRound(1_800e18, NOW, 2, 2, 18);
        vm.prank(liquidator);
        market.liquidate(borrower, 1_000e18);
        assertGt(weth.balanceOf(liquidator), 0);
        assertEq(base.balanceOf(liquidator), 0);
        assertLt(market.borrowBalanceOf(borrower), 15_000e18);
    }

    function test_liquidationAcceptsConfiguredAgeInclusiveBoundary() public {
        _prepareLiquidation();
        _useRound(1_800e18, NOW - 2 hours, 2, 2, 18);
        _setAge(2 hours);
        vm.prank(liquidator);
        market.liquidate(borrower, 1_000e18);
        assertGt(weth.balanceOf(liquidator), 0);
        assertEq(base.balanceOf(liquidator), 0);
        assertLt(market.borrowBalanceOf(borrower), 15_000e18);
    }
}
