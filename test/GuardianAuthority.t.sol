// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LendingMarketTest} from "./LendingMarket.t.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract GuardianAuthorityTest is LendingMarketTest {
    event OracleUpdated(address indexed newOracle);
    event PausedSet(bool paused);

    function test_guardianCannotChangeOracle() public {
        MockOracle replacement = new MockOracle(1e18);

        vm.prank(guardian);
        vm.expectRevert("not admin");
        market.setOracle(address(replacement), 1 hours);

        assertEq(address(market.oracle()), address(wethOracle));
    }

    function test_adminCanChangeOracleAndEmitsEvent() public {
        MockOracle replacement = new MockOracle(1_900e18);

        vm.expectEmit(true, false, false, true, address(market));
        emit OracleUpdated(address(replacement));
        vm.prank(admin);
        market.setOracle(address(replacement), 1 hours);

        assertEq(address(market.oracle()), address(replacement));
    }

    function test_guardianCanPauseAndEmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(market));
        emit PausedSet(true);
        vm.prank(guardian);
        market.setPaused(true);

        assertTrue(market.paused());
    }

    function test_guardianCanUnpauseAndEmitsEvent() public {
        vm.startPrank(guardian);
        market.setPaused(true);
        vm.expectEmit(false, false, false, true, address(market));
        emit PausedSet(false);
        market.setPaused(false);
        vm.stopPrank();

        assertFalse(market.paused());
    }

    function test_adminCanPauseAndUnpauseAndEmitsEvents() public {
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, true, address(market));
        emit PausedSet(true);
        market.setPaused(true);
        assertTrue(market.paused());

        vm.expectEmit(false, false, false, true, address(market));
        emit PausedSet(false);
        market.setPaused(false);
        vm.stopPrank();

        assertFalse(market.paused());
    }

    function test_adminCanUnpauseAfterGuardianPause() public {
        vm.prank(guardian);
        market.setPaused(true);

        vm.prank(admin);
        market.setPaused(false);

        assertFalse(market.paused());
    }

    function test_unrelatedAccountCannotChangeOracle() public {
        MockOracle replacement = new MockOracle(1e18);

        vm.prank(borrower);
        vm.expectRevert();
        market.setOracle(address(replacement), 1 hours);

        assertEq(address(market.oracle()), address(wethOracle));
    }

    function test_unrelatedAccountCannotPauseOrUnpause() public {
        vm.prank(borrower);
        vm.expectRevert("not guardian");
        market.setPaused(true);
        assertFalse(market.paused());

        vm.prank(guardian);
        market.setPaused(true);

        vm.prank(borrower);
        vm.expectRevert("not guardian");
        market.setPaused(false);
        assertTrue(market.paused());
    }
}
