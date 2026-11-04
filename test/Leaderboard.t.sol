// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract LeaderboardTest is Test {
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

    function testEmptyRegistryLeaderboard() public view {
        assertEq(registry.subjectCount(), 0);
        assertEq(registry.getLeaderboard(10).length, 0);
        assertEq(registry.getLeaderboard(0).length, 0);
    }

    function testLeaderboardOrderAndLimit() public {
        _attest(makeAddr("a1"), alice, 90);
        _attest(makeAddr("a2"), bob, 70);
        _attest(makeAddr("a3"), carol, 90);
        _attest(makeAddr("a4"), carol, 90); // carol: avg 90, count 2
        assertEq(registry.subjectCount(), 3);

        ReputationRegistry.LeaderboardEntry[] memory top = registry.getLeaderboard(2);
        assertEq(top.length, 2);
        // Carol outranks alice on the count tie-break at equal average.
        assertEq(top[0].subject, carol);
        assertEq(top[0].average, 9000);
        assertEq(top[0].count, 2);
        assertEq(uint256(top[0].tier), uint256(ReputationRegistry.Tier.Emerging));
        assertEq(top[1].subject, alice);
        assertEq(top[1].average, 9000);
        assertEq(top[1].count, 1);

        // Limit larger than the ranked set returns the whole set.
        assertEq(registry.getLeaderboard(100).length, 3);
        assertEq(registry.getLeaderboard(100)[2].subject, bob);
        // Limit 0 returns an empty array, not the whole board.
        assertEq(registry.getLeaderboard(0).length, 0);
    }

    function testRevokedOnlySubjectExcludedButCounted() public {
        _attest(makeAddr("a1"), alice, 100);
        _attest(makeAddr("a2"), bob, 80);
        vm.prank(makeAddr("a1"));
        registry.revokeAttestation(0);
        // Alice stays in the subject registry but drops off the board.
        assertEq(registry.subjectCount(), 2);
        ReputationRegistry.LeaderboardEntry[] memory board = registry.getLeaderboard(10);
        assertEq(board.length, 1);
        assertEq(board[0].subject, bob);
    }

    function testReattestAfterRevokeDoesNotDuplicateSubject() public {
        _attest(makeAddr("a1"), alice, 100);
        vm.prank(makeAddr("a1"));
        registry.revokeAttestation(0);
        _attest(makeAddr("a1"), alice, 60);
        assertEq(registry.subjectCount(), 1);
        ReputationRegistry.LeaderboardEntry[] memory board = registry.getLeaderboard(10);
        assertEq(board.length, 1);
        assertEq(board[0].average, 6000);
    }

    function testDisputedSubjectExcludedUntilResolved() public {
        _attest(makeAddr("a1"), alice, 100);
        _attest(makeAddr("a2"), bob, 80);
        vm.prank(alice);
        registry.disputeAttestation(0, bytes32("unfair"));
        ReputationRegistry.LeaderboardEntry[] memory board = registry.getLeaderboard(10);
        assertEq(board.length, 1);
        assertEq(board[0].subject, bob);
        vm.prank(makeAddr("a1"));
        registry.resolveDispute(0, true);
        board = registry.getLeaderboard(10);
        assertEq(board.length, 2);
        assertEq(board[0].subject, alice);
    }
}
