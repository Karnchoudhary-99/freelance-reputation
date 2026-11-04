// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract ReputationRegistryTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function testAttestCreatesRecordAndScore() public {
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        assertEq(id, 0);

        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.attester, bob);
        assertEq(a.subject, alice);
        assertEq(a.score, 90);
        assertEq(a.weight, 1); // bob has no reputation yet
        assertFalse(a.revoked);

        ReputationRegistry.Score memory s = registry.getScore(alice);
        assertEq(s.average, 9000);
        assertEq(s.count, 1);
        assertEq(s.totalWeight, 1);
    }

    function testEmptyScoreIsZero() public view {
        ReputationRegistry.Score memory s = registry.getScore(alice);
        assertEq(s.average, 0);
        assertEq(s.count, 0);
        assertEq(s.totalWeight, 0);
    }

    function testAttestRejectsBadInputs() public {
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.InvalidScore.selector);
        registry.attest(alice, ReputationRegistry.Category.Overall, 101, bytes32(0));

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.SelfAttestation.selector);
        registry.attest(bob, ReputationRegistry.Category.Overall, 50, bytes32(0));

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.ZeroAddress.selector);
        registry.attest(address(0), ReputationRegistry.Category.Overall, 50, bytes32(0));
    }

    function testReAttestUpdatesInsteadOfStacking() public {
        vm.prank(bob);
        uint256 first = registry.attest(alice, ReputationRegistry.Category.Overall, 60, bytes32("v1"));
        vm.warp(block.timestamp + 100);
        vm.prank(bob);
        uint256 second = registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("v2"));
        assertEq(first, second);
        assertEq(registry.attestationCount(), 1);

        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.score, 80);
        assertEq(a.commentHash, bytes32("v2"));
        assertEq(a.updatedAt, block.timestamp);
        assertEq(registry.getScore(alice).average, 8000);

        // A different category is a separate attestation.
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 100, bytes32(0));
        assertEq(registry.attestationCount(), 2);
    }

    function testRevokeExcludesFromScoreAndAllowsReAttest() public {
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32(0));
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 70, bytes32(0));
        assertEq(registry.getScore(alice).average, 8000);

        vm.prank(bob);
        registry.revokeAttestation(id);
        ReputationRegistry.Score memory s = registry.getScore(alice);
        assertEq(s.average, 7000);
        assertEq(s.count, 1);
        assertTrue(registry.attestation(id).revoked);

        // Revoked record stays readable via getAttestations.
        assertEq(registry.getAttestations(alice).length, 2);

        // After revocation the same key can attest again, as a fresh record.
        vm.prank(bob);
        uint256 fresh = registry.attest(alice, ReputationRegistry.Category.Overall, 100, bytes32(0));
        assertEq(fresh, 2);
        assertEq(registry.getScore(alice).average, 8500);
    }

    function testRevokeGuards() public {
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32(0));

        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.NotAttester.selector);
        registry.revokeAttestation(id);

        vm.prank(bob);
        registry.revokeAttestation(id);

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AlreadyRevoked.selector);
        registry.revokeAttestation(id);

        vm.expectRevert(ReputationRegistry.UnknownAttestation.selector);
        registry.revokeAttestation(99);
    }

    function testWeightedScoreUsesAttesterReputation() public {
        // Give bob a strong reputation: 90 from carol and dave.
        vm.prank(carol);
        registry.attest(bob, ReputationRegistry.Category.Overall, 90, bytes32(0));
        vm.prank(dave);
        registry.attest(bob, ReputationRegistry.Category.Overall, 90, bytes32(0));
        assertEq(registry.attesterWeight(bob), 3);
        assertEq(registry.attesterWeight(carol), 1);

        // bob (weight 3) scores alice 60, carol (weight 1) scores 90.
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 60, bytes32(0));
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32(0));
        // (60*3 + 90*1) / 4 = 67.50
        ReputationRegistry.Score memory s = registry.getScore(alice);
        assertEq(s.average, 6750);
        assertEq(s.totalWeight, 4);
    }

    function testWeightTiers() public {
        // 50-79 average -> weight 2.
        vm.prank(carol);
        registry.attest(dave, ReputationRegistry.Category.Overall, 60, bytes32(0));
        assertEq(registry.attesterWeight(dave), 2);
        // Below 50 -> weight 1.
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 40, bytes32(0));
        assertEq(registry.attesterWeight(alice), 1);
    }

    function testDecayFactorTiers() public {
        vm.warp(20 * 365 days); // far enough back that tier math never underflows
        uint64 now_ = uint64(block.timestamp);
        assertEq(registry.decayFactorBps(now_), 10000);
        assertEq(registry.decayFactorBps(now_ - 89 days), 10000);
        assertEq(registry.decayFactorBps(now_ - 90 days), 5000);
        assertEq(registry.decayFactorBps(now_ - 364 days), 5000);
        assertEq(registry.decayFactorBps(now_ - 365 days), 2500);
        assertEq(registry.decayFactorBps(now_ - 10 * 365 days), 2500);
    }

    function testDecayedAverageHalvesOldAttestation() public {
        // bob scores alice 100 (fresh, full weight), carol scores 0, then a
        // year passes for carol's attestation only if it ages... warp moves
        // both, so attest bob's record second, after the warp.
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 0, bytes32(0));
        vm.warp(block.timestamp + 200 days);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 100, bytes32(0));
        // carol at half weight (5000 bps), bob at full (10000 bps):
        // (0*5000 + 100*10000) / 15000 = 66.66
        ReputationRegistry.Score memory s = registry.getScore(alice);
        assertEq(s.average, 6666);
        assertEq(s.count, 2);
        assertEq(s.totalWeight, 2); // raw weights unchanged by decay
        assertEq(s.effectiveWeight, 15000);
    }

    function testQuarterWeightAfterOneYear() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 100, bytes32(0));
        vm.warp(block.timestamp + 400 days);
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 0, bytes32(0));
        // bob at quarter weight (2500), carol full (10000): 100*2500/12500 = 20.00
        assertEq(registry.getScore(alice).average, 2000);
        assertEq(registry.getScore(alice).effectiveWeight, 12500);
    }

    function testReAttestRefreshesDecayClock() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 0, bytes32(0));
        vm.warp(block.timestamp + 200 days);
        // bob re-attests: same record, fresh clock, still score 0.
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 0, bytes32(0));
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 100, bytes32(0));
        // Both full weight now: (0 + 100) / 2 = 50.00, not 33.33.
        assertEq(registry.getScore(alice).average, 5000);
    }

    function testDisputeExcludesFromScoreUntilUpheld() public {
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 20, bytes32(0));
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 100, bytes32(0));
        assertEq(registry.getScore(alice).average, 6000);

        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("unfair"));
        ReputationRegistry.Attestation memory a = registry.attestation(id);
        assertTrue(a.disputed);
        assertEq(a.disputeReason, bytes32("unfair"));
        // Only carol's 100 counts while disputed.
        assertEq(registry.getScore(alice).average, 10000);
        assertEq(registry.getScore(alice).count, 1);

        vm.prank(bob);
        registry.resolveDispute(id, true);
        assertFalse(registry.attestation(id).disputed);
        assertEq(registry.getScore(alice).average, 6000);
    }

    function testDisputeConcedeRevokes() public {
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 20, bytes32(0));
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32(0));
        vm.prank(bob);
        registry.resolveDispute(id, false);
        ReputationRegistry.Attestation memory a = registry.attestation(id);
        assertTrue(a.revoked);
        assertFalse(a.disputed);
        assertEq(registry.getScore(alice).count, 0);
        // After conceding, bob may attest alice again as a fresh record.
        vm.prank(bob);
        uint256 fresh = registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32(0));
        assertEq(fresh, 1);
    }

    function testDisputeGuards() public {
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 20, bytes32(0));

        // Only the subject may dispute.
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.NotSubject.selector);
        registry.disputeAttestation(id, bytes32(0));

        // Only the attester may resolve.
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotAttester.selector);
        registry.resolveDispute(id, true);

        // No double dispute, no re-attest while disputed.
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AlreadyDisputed.selector);
        registry.disputeAttestation(id, bytes32(0));
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AlreadyDisputed.selector);
        registry.attest(alice, ReputationRegistry.Category.Overall, 50, bytes32(0));

        // Expiry too early, and resolve on a non-disputed record.
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.DisputeNotExpired.selector);
        registry.expireDispute(id);
        vm.prank(bob);
        registry.resolveDispute(id, true);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotDisputed.selector);
        registry.resolveDispute(id, true);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotDisputed.selector);
        registry.expireDispute(id);

        // Revoking a disputed record settles the dispute.
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32(0));
        vm.prank(bob);
        registry.revokeAttestation(id);
        assertTrue(registry.attestation(id).revoked);
        assertFalse(registry.attestation(id).disputed);
    }

    function testDisputeExpiryReinstatesAfterWindow() public {
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 20, bytes32(0));
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32(0));
        assertEq(registry.getScore(alice).count, 0);

        vm.warp(block.timestamp + 29 days);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.DisputeNotExpired.selector);
        registry.expireDispute(id);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        registry.expireDispute(id);
        assertFalse(registry.attestation(id).disputed);
        assertEq(registry.getScore(alice).average, 2000);
    }

    function testUpholdRefreshesDecayClock() public {
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 0, bytes32(0));
        vm.warp(block.timestamp + 200 days); // bob's record now half-weight
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32(0));
        vm.prank(bob);
        registry.resolveDispute(id, true); // re-confirmation: fresh clock
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 100, bytes32(0));
        // Both full weight after uphold: (0 + 100) / 2 = 50.00.
        assertEq(registry.getScore(alice).average, 5000);
    }

    function testDecayAppliesToCategoryScores() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 100, bytes32(0));
        vm.warp(block.timestamp + 200 days);
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Quality, 0, bytes32(0));
        // Quality: bob half-weight, carol full -> 100*5000/15000 = 33.33.
        assertEq(registry.getScoreByCategory(alice, ReputationRegistry.Category.Quality).average, 3333);
        // Overall matches the category here (only Quality attestations exist).
        assertEq(registry.getScore(alice).average, 3333);
    }

    function testAttesterWeightUsesDecayedAverage() public {
        vm.prank(carol);
        registry.attest(bob, ReputationRegistry.Category.Overall, 90, bytes32(0));
        vm.prank(dave);
        registry.attest(bob, ReputationRegistry.Category.Overall, 90, bytes32(0));
        assertEq(registry.attesterWeight(bob), 3);
        // A year later bob's endorsements are quarter-weight, but the
        // average is still 90 — weight must stay 3 (decay shrinks weight,
        // not the average itself). What DOES drop the weight is a disputed
        // attestation being excluded: dispute both, and bob has no score.
        vm.warp(block.timestamp + 400 days);
        assertEq(registry.attesterWeight(bob), 3);
        vm.prank(bob);
        registry.disputeAttestation(0, bytes32(0));
        vm.prank(bob);
        registry.disputeAttestation(1, bytes32(0));
        assertEq(registry.attesterWeight(bob), 1);
    }

    function testDisputeOfRevokedRecordReverts() public {
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 20, bytes32(0));
        vm.prank(bob);
        registry.revokeAttestation(id);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AlreadyRevoked.selector);
        registry.disputeAttestation(id, bytes32(0));
    }

    function testExpireDisputeOnlySubject() public {
        vm.prank(bob);
        uint256 id = registry.attest(alice, ReputationRegistry.Category.Overall, 20, bytes32(0));
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32(0));
        vm.warp(block.timestamp + 31 days);
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.NotSubject.selector);
        registry.expireDispute(id);
    }

    function testCategoryScoreFilters() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 100, bytes32(0));
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Timeliness, 50, bytes32(0));

        assertEq(registry.getScore(alice).average, 7500);
        assertEq(registry.getScoreByCategory(alice, ReputationRegistry.Category.Quality).average, 10000);
        assertEq(registry.getScoreByCategory(alice, ReputationRegistry.Category.Timeliness).average, 5000);
        assertEq(registry.getScoreByCategory(alice, ReputationRegistry.Category.Reliability).count, 0);
    }

    function testBatchAttestsManyAndUpdatesInPlace() public {
        ReputationRegistry.AttestInput[] memory inputs = new ReputationRegistry.AttestInput[](3);
        inputs[0] = ReputationRegistry.AttestInput(alice, ReputationRegistry.Category.Quality, 90, bytes32("b1"));
        inputs[1] = ReputationRegistry.AttestInput(alice, ReputationRegistry.Category.Timeliness, 70, bytes32("b2"));
        inputs[2] = ReputationRegistry.AttestInput(carol, ReputationRegistry.Category.Quality, 80, bytes32("b3"));

        vm.prank(bob);
        uint256[] memory ids = registry.attestBatch(inputs);
        assertEq(ids.length, 3);
        assertEq(ids[0], 0);
        assertEq(ids[1], 1);
        assertEq(ids[2], 2);
        assertEq(registry.getScore(alice).average, 8000);
        assertEq(registry.getScore(carol).average, 8000);

        // A batch entry for an existing active record updates it, no new id.
        ReputationRegistry.AttestInput[] memory update = new ReputationRegistry.AttestInput[](1);
        update[0] = ReputationRegistry.AttestInput(alice, ReputationRegistry.Category.Quality, 100, bytes32("b4"));
        vm.prank(bob);
        uint256[] memory updated = registry.attestBatch(update);
        assertEq(updated[0], 0);
        assertEq(registry.attestationCount(), 3);
        assertEq(registry.getScore(alice).average, 8500);
    }

    function testBatchIsAtomicOnBadEntry() public {
        ReputationRegistry.AttestInput[] memory inputs = new ReputationRegistry.AttestInput[](2);
        inputs[0] = ReputationRegistry.AttestInput(alice, ReputationRegistry.Category.Quality, 90, bytes32(0));
        inputs[1] = ReputationRegistry.AttestInput(alice, ReputationRegistry.Category.Timeliness, 101, bytes32(0));

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.InvalidScore.selector);
        registry.attestBatch(inputs);
        // Nothing from the batch landed: no partial state.
        assertEq(registry.attestationCount(), 0);
        assertEq(registry.getScore(alice).count, 0);
    }

    function testBatchEmptyIsNoop() public {
        ReputationRegistry.AttestInput[] memory inputs = new ReputationRegistry.AttestInput[](0);
        vm.prank(bob);
        uint256[] memory ids = registry.attestBatch(inputs);
        assertEq(ids.length, 0);
        assertEq(registry.attestationCount(), 0);
    }

    function testPaginatedReads() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("p1"));
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Timeliness, 70, bytes32("p2"));
        vm.prank(dave);
        registry.attest(alice, ReputationRegistry.Category.Reliability, 50, bytes32("p3"));

        ReputationRegistry.Attestation[] memory page = registry.getAttestationsPaginated(alice, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0].score, 70);
        assertEq(page[1].score, 50);

        // Limit clamps to the remainder instead of reverting.
        page = registry.getAttestationsPaginated(alice, 2, 99);
        assertEq(page.length, 1);
        assertEq(page[0].score, 50);

        // Offset past the end is an empty page, not a revert.
        page = registry.getAttestationsPaginated(alice, 3, 10);
        assertEq(page.length, 0);
        page = registry.getAttestationsPaginated(alice, 99, 10);
        assertEq(page.length, 0);
    }

    function testProfileMatchesIndividualScores() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 100, bytes32(0));
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Timeliness, 50, bytes32(0));

        ReputationRegistry.Profile memory p = registry.getProfile(alice);
        assertEq(p.overall.average, 7500);
        assertEq(p.overall.count, 2);
        assertEq(p.quality.average, 10000);
        assertEq(p.communication.count, 0);
        assertEq(p.timeliness.average, 5000);
        assertEq(p.reliability.count, 0);

        // Empty profile is all zeros, matching the individual getters.
        ReputationRegistry.Profile memory empty = registry.getProfile(dave);
        assertEq(empty.overall.average, 0);
        assertEq(empty.quality.count, 0);
    }
}
