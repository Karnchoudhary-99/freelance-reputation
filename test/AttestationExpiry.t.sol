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

    function testReAttestRevivesExpiredRecord() public {
        registry.setExpiryDuration(10 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 60, bytes32("c1"));
        vm.warp(block.timestamp + 10 days);
        assertTrue(registry.isExpired(0));
        assertEq(registry.getScore(alice).count, 0);

        // Re-attesting updates the same record in place and refreshes
        // the expiry clock: the endorsement is live again.
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("c2"));
        assertEq(id, 0);
        assertFalse(registry.isExpired(0));
        ReputationRegistry.Score memory s = registry.getScore(alice);
        assertEq(s.count, 1);
        assertEq(s.average, 8000);
        assertEq(registry.expiresAt(0), uint64(block.timestamp) + 10 days);
    }

    function testOnlyOwnerCanSetExpiryDuration() public {
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.setExpiryDuration(10 days);
        assertEq(registry.expiryDuration(), 730 days);
    }

    function testExpiryDurationUpdatedEvent() public {
        vm.expectEmit(false, false, false, true, address(registry));
        emit ReputationRegistry.ExpiryDurationUpdated(30 days);
        registry.setExpiryDuration(30 days);
        assertEq(registry.expiryDuration(), 30 days);
    }

    function testDisputeExpiredAttestationReverts() public {
        registry.setExpiryDuration(10 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AttestationExpired.selector);
        registry.disputeAttestation(0, bytes32("unfair"));
    }

    function testShorteningDurationExpiresOldRecordsImmediately() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        vm.warp(block.timestamp + 5 days);
        assertFalse(registry.isExpired(0));

        // The record is 5 days old; a 1-day duration expires it at once.
        registry.setExpiryDuration(1 days);
        assertTrue(registry.isExpired(0));
        assertEq(registry.getScore(alice).count, 0);
    }

    function testRevokingExpiredRecordStaysAllowed() public {
        registry.setExpiryDuration(10 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        vm.warp(block.timestamp + 10 days);

        vm.prank(bob);
        registry.revokeAttestation(0);
        assertTrue(registry.attestation(0).revoked);

        // And a fresh attestation afterwards creates a new record.
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 70, bytes32("c2"));
        assertEq(id, 1);
        assertEq(registry.getScore(alice).count, 1);
    }

    function testDisputeThatExpiresMidFlightCanStillResolve() public {
        registry.setExpiryDuration(10 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        vm.prank(alice);
        registry.disputeAttestation(0, bytes32("unfair"));

        // The dispute window (30 days) outlasts the expiry (10 days):
        // the record is both disputed and expired now.
        vm.warp(block.timestamp + 11 days);
        assertTrue(registry.isExpired(0));

        // Upholding re-confirms it: the clock refreshes and it counts again.
        vm.prank(bob);
        registry.resolveDispute(0, true);
        assertFalse(registry.isExpired(0));
        assertFalse(registry.attestation(0).disputed);
        assertEq(registry.getScore(alice).count, 1);
    }
}
