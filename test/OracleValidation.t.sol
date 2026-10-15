// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LendingMarketTest} from "./LendingMarket.t.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

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
        vm.prank(guardian);
        market.setOracle(address(feed));
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
        vm.prank(guardian);
        market.setOracle(address(0xdead));
        assertTrue(market.isHealthy(borrower));
    }
}
