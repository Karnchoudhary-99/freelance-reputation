// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract LeaderboardOptOutTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function _attest(address attester, address subject, uint8 score) internal {
        vm.prank(attester);
        registry.attest(subject, ReputationRegistry.Category.Overall, score, bytes32(0));
    }

    function testOptOutDefaultsToFalse() public view {
        assertFalse(registry.isLeaderboardOptedOut(alice));
        assertFalse(registry.isLeaderboardOptedOut(bob));
    }

    function testOptOutAndBackIn() public {
        vm.prank(alice);
        registry.setLeaderboardOptOut(true);
        assertTrue(registry.isLeaderboardOptedOut(alice));
        assertFalse(registry.isLeaderboardOptedOut(bob));

        vm.prank(alice);
        registry.setLeaderboardOptOut(false);
        assertFalse(registry.isLeaderboardOptedOut(alice));
    }

    function testOptOutEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ReputationRegistry.LeaderboardOptOut(alice, true);
        vm.prank(alice);
        registry.setLeaderboardOptOut(true);

        vm.expectEmit(true, false, false, true);
        emit ReputationRegistry.LeaderboardOptOut(alice, false);
        vm.prank(alice);
        registry.setLeaderboardOptOut(false);
    }

    function testOptOutBeforeAnyAttestationAppliesWhenListed() public {
        // Alice opts out before anyone attests her; the choice sticks
        // once she lands on the board.
        vm.prank(alice);
        registry.setLeaderboardOptOut(true);
        _attest(makeAddr("a1"), alice, 90);
        _attest(makeAddr("a2"), bob, 80);
        assertEq(registry.getLeaderboard(10).length, 1);
        assertEq(registry.getLeaderboard(10)[0].subject, bob);
    }
}
