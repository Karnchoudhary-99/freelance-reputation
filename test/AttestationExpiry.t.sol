// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract AttestationExpiryTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function testExpiryDefaultsTo730Days() public view {
        assertEq(registry.expiryDuration(), 730 days);
    }

    function testExpiredAttestationExcludedFromScore() public {
        registry.setExpiryDuration(10 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        assertEq(registry.getScore(alice).count, 1);

        vm.warp(block.timestamp + 10 days);
        assertTrue(registry.isExpired(0));
        ReputationRegistry.Score memory s = registry.getScore(alice);
        assertEq(s.count, 0);
        assertEq(s.average, 0);
        assertEq(s.effectiveWeight, 0);
        assertEq(s.totalWeight, 0);
    }

    function testExpiryBoundaryIsInclusive() public {
        registry.setExpiryDuration(10 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));

        // One second before the deadline it still counts.
        vm.warp(block.timestamp + 10 days - 1);
        assertFalse(registry.isExpired(0));
        assertEq(registry.getScore(alice).count, 1);

        // At the deadline it has faded out.
        vm.warp(block.timestamp + 1);
        assertTrue(registry.isExpired(0));
        assertEq(registry.getScore(alice).count, 0);
    }

    function testExpiresAtView() public {
        registry.setExpiryDuration(30 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        assertEq(registry.expiresAt(0), uint64(block.timestamp) + 30 days);

        registry.setExpiryDuration(0);
        assertEq(registry.expiresAt(0), 0);
        assertFalse(registry.isExpired(0));
    }

    function testExpiresAtRejectsUnknownId() public {
        vm.expectRevert(ReputationRegistry.UnknownAttestation.selector);
        registry.expiresAt(99);
        vm.expectRevert(ReputationRegistry.UnknownAttestation.selector);
        registry.isExpired(99);
    }

    function testPreviewShowsExpiry() public {
        registry.setExpiryDuration(10 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));

        // Preview before the deadline: still counts.
        ReputationRegistry.Score memory before = registry.getScoreAt(
            alice,
            uint64(block.timestamp) + 9 days
        );
        assertEq(before.count, 1);
        assertEq(before.average, 9000);

        // Preview at/past the deadline: faded out.
        ReputationRegistry.Score memory past = registry.getScoreAt(
            alice,
            uint64(block.timestamp) + 10 days
        );
        assertEq(past.count, 0);
        assertEq(past.average, 0);
    }

    function testTierFallsAfterExpiry() public {
        registry.setExpiryDuration(10 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        vm.prank(dave);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        assertEq(uint256(registry.tierOf(alice)), uint256(ReputationRegistry.Tier.Established));

        vm.warp(block.timestamp + 10 days);
        assertEq(uint256(registry.tierOf(alice)), uint256(ReputationRegistry.Tier.Unranked));
        assertEq(registry.getLeaderboard(10).length, 0);
    }

    function testDisablingExpiryRevivesRecords() public {
        registry.setExpiryDuration(10 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        vm.warp(block.timestamp + 10 days);
        assertEq(registry.getScore(alice).count, 0);

        // Turning expiry off revives every expired record at once.
        registry.setExpiryDuration(0);
        assertFalse(registry.isExpired(0));
        ReputationRegistry.Score memory s = registry.getScore(alice);
        assertEq(s.count, 1);
        assertEq(s.average, 9000);
    }
}
