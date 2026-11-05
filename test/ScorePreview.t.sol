// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract ScorePreviewTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    uint256 constant T0 = 1_700_000_000;

    function setUp() public {
        registry = new ReputationRegistry();
        vm.warp(T0);
    }

    function _attest(
        address attester,
        address subject,
        ReputationRegistry.Category category,
        uint8 score
    ) internal returns (uint256) {
        vm.prank(attester);
        return registry.attest(subject, category, score, bytes32(0));
    }

    function testDecayFactorBpsAtTiers() public view {
        uint64 t = uint64(T0);
        assertEq(registry.decayFactorBpsAt(t, t), 10_000);
        assertEq(registry.decayFactorBpsAt(t, t + 89 days), 10_000);
        assertEq(registry.decayFactorBpsAt(t, t + 90 days), 5_000);
        assertEq(registry.decayFactorBpsAt(t, t + 364 days), 5_000);
        assertEq(registry.decayFactorBpsAt(t, t + 365 days), 2_500);
        // A "when" before the update counts as full weight: nothing had
        // aged yet at that point.
        assertEq(registry.decayFactorBpsAt(t, t - 1 days), 10_000);
        // The live view still delegates to the current block time.
        assertEq(registry.decayFactorBps(t), 10_000);
    }

    function testGetScoreAtDecaysEffectiveWeight() public {
        _attest(alice, bob, ReputationRegistry.Category.Overall, 90);

        ReputationRegistry.Score memory fresh = registry.getScoreAt(
            bob,
            uint64(T0 + 10 days)
        );
        assertEq(fresh.count, 1);
        assertEq(fresh.average, 9_000);
        assertEq(fresh.effectiveWeight, 10_000);

        ReputationRegistry.Score memory half = registry.getScoreAt(
            bob,
            uint64(T0 + 100 days)
        );
        assertEq(half.count, 1);
        assertEq(half.average, 9_000);
        assertEq(half.effectiveWeight, 5_000);

        ReputationRegistry.Score memory quarter = registry.getScoreAt(
            bob,
            uint64(T0 + 400 days)
        );
        assertEq(quarter.count, 1);
        assertEq(quarter.average, 9_000);
        assertEq(quarter.effectiveWeight, 2_500);
    }

    function testGetScoreAtMatchesLiveScoreAndShiftsAverage() public {
        _attest(alice, bob, ReputationRegistry.Category.Overall, 100);
        vm.warp(T0 + 100 days);
        _attest(carol, bob, ReputationRegistry.Category.Overall, 60);

        // Live: alice's attestation is 100 days old (half weight),
        // carol's is fresh: (100*5000 + 60*10000) / 15000 = 73.33.
        ReputationRegistry.Score memory live = registry.getScore(bob);
        assertEq(live.average, 7_333);
        assertEq(live.count, 2);
        assertEq(live.effectiveWeight, 15_000);

        ReputationRegistry.Score memory atNow = registry.getScoreAt(
            bob,
            uint64(T0 + 100 days)
        );
        assertEq(atNow.average, live.average);
        assertEq(atNow.count, live.count);
        assertEq(atNow.effectiveWeight, live.effectiveWeight);
        assertEq(atNow.totalWeight, live.totalWeight);

        // At +200 days both attestations sit at half weight, so the
        // average moves to the plain mean: (100 + 60) / 2 = 80.
        ReputationRegistry.Score memory later = registry.getScoreAt(
            bob,
            uint64(T0 + 200 days)
        );
        assertEq(later.average, 8_000);
        assertEq(later.effectiveWeight, 10_000);
    }

    function testGetScoreAtExcludesNotYetCreated() public {
        _attest(alice, bob, ReputationRegistry.Category.Overall, 90);

        ReputationRegistry.Score memory before = registry.getScoreAt(
            bob,
            uint64(T0 - 1 days)
        );
        assertEq(before.count, 0);
        assertEq(before.average, 0);

        ReputationRegistry.Score memory atCreation = registry.getScoreAt(
            bob,
            uint64(T0)
        );
        assertEq(atCreation.count, 1);
        assertEq(atCreation.average, 9_000);

        vm.warp(T0 + 10 days);
        ReputationRegistry.Score memory mid = registry.getScoreAt(
            bob,
            uint64(T0 + 5 days)
        );
        assertEq(mid.count, 1);
        assertEq(mid.effectiveWeight, 10_000);
    }

    function testGetScoreAtExcludesRevokedAndDisputed() public {
        uint256 id = _attest(alice, bob, ReputationRegistry.Category.Overall, 90);
        vm.prank(alice);
        registry.revokeAttestation(id);

        ReputationRegistry.Score memory revoked = registry.getScoreAt(
            bob,
            uint64(T0 + 400 days)
        );
        assertEq(revoked.count, 0);
        assertEq(revoked.average, 0);

        uint256 id2 = _attest(carol, bob, ReputationRegistry.Category.Overall, 80);
        vm.prank(bob);
        registry.disputeAttestation(id2, bytes32("unfair"));
        assertEq(registry.getScoreAt(bob, uint64(T0 + 400 days)).count, 0);

        vm.prank(carol);
        registry.resolveDispute(id2, true);
        ReputationRegistry.Score memory upheld = registry.getScoreAt(
            bob,
            uint64(T0 + 400 days)
        );
        assertEq(upheld.count, 1);
        assertEq(upheld.average, 8_000);
    }

    function testPreviewDoesNotRewindRevocation() public {
        // Documented semantics: revocation/dispute state is read as it
        // stands now, so a past "when" does not resurrect a record that
        // was revoked afterwards.
        uint256 id = _attest(alice, bob, ReputationRegistry.Category.Overall, 90);
        vm.warp(T0 + 10 days);
        vm.prank(alice);
        registry.revokeAttestation(id);

        ReputationRegistry.Score memory beforeRevoke = registry.getScoreAt(
            bob,
            uint64(T0 + 5 days)
        );
        assertEq(beforeRevoke.count, 0);
    }

    function testGetScoreByCategoryAt() public {
        _attest(alice, bob, ReputationRegistry.Category.Quality, 80);
        _attest(alice, bob, ReputationRegistry.Category.Communication, 40);

        ReputationRegistry.Score memory quality = registry
            .getScoreByCategoryAt(
                bob,
                ReputationRegistry.Category.Quality,
                uint64(T0 + 400 days)
            );
        assertEq(quality.count, 1);
        assertEq(quality.average, 8_000);
        assertEq(quality.effectiveWeight, 2_500);

        ReputationRegistry.Score memory comms = registry
            .getScoreByCategoryAt(
                bob,
                ReputationRegistry.Category.Communication,
                uint64(T0 + 400 days)
            );
        assertEq(comms.average, 4_000);

        // Overall spans both categories: (80*2500 + 40*2500) / 5000 = 60.
        ReputationRegistry.Score memory overall = registry.getScoreAt(
            bob,
            uint64(T0 + 400 days)
        );
        assertEq(overall.average, 6_000);
        assertEq(overall.count, 2);
    }

    function testGetProfileAt() public {
        _attest(alice, bob, ReputationRegistry.Category.Quality, 80);
        _attest(alice, bob, ReputationRegistry.Category.Communication, 40);

        ReputationRegistry.Profile memory profile = registry.getProfileAt(
            bob,
            uint64(T0 + 400 days)
        );
        assertEq(profile.overall.average, 6_000);
        assertEq(profile.overall.count, 2);
        assertEq(profile.quality.average, 8_000);
        assertEq(profile.communication.average, 4_000);
        assertEq(profile.timeliness.count, 0);
        assertEq(profile.timeliness.average, 0);
        assertEq(profile.reliability.count, 0);
    }

    function testTierOfAtTransitions() public {
        _attest(alice, bob, ReputationRegistry.Category.Overall, 100);
        _attest(carol, bob, ReputationRegistry.Category.Overall, 100);
        vm.warp(T0 + 350 days);
        _attest(dave, bob, ReputationRegistry.Category.Overall, 30);

        // At +100 days only the two 100s exist: count 2 -> Emerging.
        assertEq(
            uint256(registry.tierOfAt(bob, uint64(T0 + 100 days))),
            uint256(ReputationRegistry.Tier.Emerging)
        );

        // At +350 days all three count: the 100s at half weight, the 30
        // fresh: (100*5000*2 + 30*10000) / 20000 = 65 -> Established.
        assertEq(
            uint256(registry.tierOfAt(bob, uint64(T0 + 350 days))),
            uint256(ReputationRegistry.Tier.Established)
        );

        // At +400 days the 100s have fallen to quarter weight while the
        // 30 is still fresh: (100*2500*2 + 30*10000) / 15000 = 53.33,
        // below the Established bar -> back to Emerging.
        assertEq(
            uint256(registry.tierOfAt(bob, uint64(T0 + 400 days))),
            uint256(ReputationRegistry.Tier.Emerging)
        );

        // Live tier at +350 days agrees with the preview.
        assertEq(
            uint256(registry.tierOf(bob)),
            uint256(ReputationRegistry.Tier.Established)
        );
    }
}
