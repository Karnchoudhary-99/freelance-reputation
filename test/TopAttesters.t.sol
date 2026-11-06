// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract TopAttestersTest is Test {
    ReputationRegistry registry;

    address a1 = makeAddr("a1");
    address a2 = makeAddr("a2");
    address a3 = makeAddr("a3");
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

    function testEmptyRegistryTopAttesters() public view {
        assertEq(registry.attesterCount(), 0);
        assertEq(registry.getTopAttesters(10).length, 0);
        assertEq(registry.getTopAttesters(0).length, 0);
    }

    function testAttesterCountTracksFirstSeenOnly() public {
        _attest(a1, alice, 90);
        _attest(a1, bob, 80);
        // Re-attest updates the record; it is not a second attester.
        _attest(a1, alice, 95);
        _attest(a2, carol, 70);
        assertEq(registry.attesterCount(), 2);
    }

    function testRankingByActiveCountAndLimit() public {
        _attest(a1, alice, 90);
        _attest(a1, bob, 80);
        _attest(a1, carol, 70);
        _attest(a2, alice, 85);
        _attest(a2, bob, 75);
        _attest(a3, alice, 60);

        ReputationRegistry.AttesterLeaderboardEntry[] memory top = registry.getTopAttesters(2);
        assertEq(top.length, 2);
        assertEq(top[0].attester, a1);
        assertEq(top[0].count, 3);
        assertEq(top[1].attester, a2);
        assertEq(top[1].count, 2);

        // Limit larger than the ranked set returns the whole set.
        assertEq(registry.getTopAttesters(100).length, 3);
        assertEq(registry.getTopAttesters(100)[2].attester, a3);
        // Limit 0 returns an empty array, not the whole board.
        assertEq(registry.getTopAttesters(0).length, 0);
    }

    function testTieBreakByOwnAverageThenFirstSeen() public {
        // a1 and a2 both give 2 attestations; a1 is itself rated 100,
        // a2 is rated 50, so a1 wins the tie on own average.
        _attest(makeAddr("x"), a1, 100);
        _attest(makeAddr("y"), a2, 50);
        _attest(a1, alice, 90);
        _attest(a1, bob, 80);
        _attest(a2, alice, 85);
        _attest(a2, bob, 75);

        ReputationRegistry.AttesterLeaderboardEntry[] memory top = registry.getTopAttesters(10);
        assertEq(top.length, 4);
        assertEq(top[0].attester, a1);
        assertEq(top[0].average, 10000);
        assertEq(top[0].weight, 3);
        assertEq(top[1].attester, a2);
        assertEq(top[1].average, 5000);
        assertEq(top[1].weight, 2);

        // The two one-attestation attesters (x, y) tie on count 1 and
        // on own average 0, so first-seen order breaks the tie.
        assertEq(top[2].attester, makeAddr("x"));
        assertEq(top[3].attester, makeAddr("y"));
    }

    function testRevokedOnlyAttesterExcludedButCounted() public {
        _attest(a1, alice, 100);
        _attest(a2, bob, 80);
        vm.prank(a1);
        registry.revokeAttestation(0);
        // a1 stays in the attester registry but drops off the board.
        assertEq(registry.attesterCount(), 2);
        ReputationRegistry.AttesterLeaderboardEntry[] memory top = registry.getTopAttesters(10);
        assertEq(top.length, 1);
        assertEq(top[0].attester, a2);
        assertEq(top[0].count, 1);
    }

    function testDisputedAttestationDoesNotCount() public {
        _attest(a1, alice, 100);
        _attest(a1, bob, 90);
        _attest(a2, carol, 80);
        vm.prank(alice);
        registry.disputeAttestation(0, bytes32("unfair"));
        ReputationRegistry.AttesterLeaderboardEntry[] memory top = registry.getTopAttesters(10);
        assertEq(top.length, 2);
        // a1 drops to count 1 (bob only); a2 keeps count 1; tie on
        // count breaks on own average — both 0, so first-seen: a1.
        assertEq(top[0].attester, a1);
        assertEq(top[0].count, 1);
        assertEq(top[1].attester, a2);
    }

    function testExpiredAttestationDoesNotCount() public {
        // The test contract deployed the registry, so it is the owner.
        registry.setExpiryDuration(1 days);
        _attest(a1, alice, 100);
        _attest(a2, bob, 80);
        vm.warp(block.timestamp + 2 days);
        ReputationRegistry.AttesterLeaderboardEntry[] memory top = registry.getTopAttesters(10);
        assertEq(top.length, 0);
        assertEq(registry.attesterCount(), 2);
    }

    function testSuspendedAttesterStaysRankedWithWeightZero() public {
        _attest(a1, alice, 100);
        _attest(a1, bob, 90);
        _attest(a2, carol, 80);
        // The test contract is the owner: three strikes suspend a1.
        registry.strikeAttester(a1);
        registry.strikeAttester(a1);
        registry.strikeAttester(a1);
        assertTrue(registry.isSuspended(a1));

        // Past records still count — suspension blocks new attestations
        // only — but the weight shown is the current one: 0.
        ReputationRegistry.AttesterLeaderboardEntry[] memory top = registry.getTopAttesters(10);
        assertEq(top.length, 2);
        assertEq(top[0].attester, a1);
        assertEq(top[0].count, 2);
        assertEq(top[0].weight, 0);
        assertEq(top[1].attester, a2);
        assertEq(top[1].count, 1);
    }
}
