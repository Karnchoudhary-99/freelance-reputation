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
}
