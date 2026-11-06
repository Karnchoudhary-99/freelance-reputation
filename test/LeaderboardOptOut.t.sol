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

    function testOptedOutSubjectHiddenFromLeaderboards() public {
        _attest(makeAddr("a1"), alice, 90);
        _attest(makeAddr("a2"), bob, 80);
        _attest(makeAddr("a3"), carol, 70);
        assertEq(registry.getLeaderboard(10).length, 3);

        vm.prank(alice);
        registry.setLeaderboardOptOut(true);
        ReputationRegistry.LeaderboardEntry[] memory board = registry.getLeaderboard(10);
        assertEq(board.length, 2);
        assertEq(board[0].subject, bob);
        assertEq(board[1].subject, carol);

        // Category boards hide them too.
        assertEq(registry.getLeaderboardByCategory(ReputationRegistry.Category.Overall, 10).length, 2);

        // Opting back in restores the listing, rank included.
        vm.prank(alice);
        registry.setLeaderboardOptOut(false);
        board = registry.getLeaderboard(10);
        assertEq(board.length, 3);
        assertEq(board[0].subject, alice);
    }

    function testOptedOutSubjectHiddenFromTierDirectory() public {
        // Alice: 3 attestations at 90 -> Established.
        _attest(makeAddr("a1"), alice, 90);
        _attest(makeAddr("a2"), alice, 90);
        _attest(makeAddr("a3"), alice, 90);
        _attest(makeAddr("a4"), bob, 70);

        address[] memory established = registry.getSubjectsByTier(
            ReputationRegistry.Tier.Established,
            10
        );
        assertEq(established.length, 1);
        assertEq(established[0], alice);

        vm.prank(alice);
        registry.setLeaderboardOptOut(true);
        assertEq(
            registry.getSubjectsByTier(ReputationRegistry.Tier.Established, 10).length,
            0
        );
    }

    function testOptOutLeavesScoresTiersAndAttestationsReadable() public {
        _attest(makeAddr("a1"), alice, 90);
        _attest(makeAddr("a2"), alice, 90);
        _attest(makeAddr("a3"), alice, 90);
        vm.prank(alice);
        registry.setLeaderboardOptOut(true);

        // Direct reads are unaffected by the listing choice.
        assertEq(registry.getScore(alice).average, 9000);
        assertEq(registry.getScore(alice).count, 3);
        assertEq(uint256(registry.tierOf(alice)), uint256(ReputationRegistry.Tier.Established));
        assertEq(registry.getProfile(alice).overall.average, 9000);
        assertEq(registry.getAttestations(alice).length, 3);
        assertEq(registry.subjectCount(), 1);

        // New attestations still land while opted out.
        _attest(makeAddr("a4"), alice, 100);
        assertEq(registry.getScore(alice).count, 4);
        assertEq(registry.getLeaderboard(10).length, 0);
    }
}
