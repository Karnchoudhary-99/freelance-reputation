// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract CategoryWeightsTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address a1 = makeAddr("a1");
    address a2 = makeAddr("a2");
    address a3 = makeAddr("a3");

    // Fixed base time so warps read like calendar dates.
    uint64 constant T0 = 1_700_000_000;

    function setUp() public {
        registry = new ReputationRegistry();
        vm.warp(T0);
    }

    function _attest(
        address attester,
        address subject,
        ReputationRegistry.Category category,
        uint8 score
    ) internal {
        vm.prank(attester);
        registry.attest(subject, category, score, bytes32(0));
    }

    function testDefaultsAreEqualBlend() public view {
        // Every category starts at the default weight, so the overall
        // score is the plain blend of all attestations.
        assertEq(
            registry.categoryWeight(ReputationRegistry.Category.Overall),
            100
        );
        assertEq(
            registry.categoryWeight(ReputationRegistry.Category.Quality),
            100
        );
        assertEq(
            registry.categoryWeight(
                ReputationRegistry.Category.Communication
            ),
            100
        );
        assertEq(
            registry.categoryWeight(ReputationRegistry.Category.Timeliness),
            100
        );
        assertEq(
            registry.categoryWeight(ReputationRegistry.Category.Reliability),
            100
        );
        uint256[5] memory weights = registry.categoryWeights();
        assertEq(weights[0], 100);
        assertEq(weights[1], 100);
        assertEq(weights[2], 100);
        assertEq(weights[3], 100);
        assertEq(weights[4], 100);
        assertEq(registry.DEFAULT_CATEGORY_WEIGHT(), 100);
        assertEq(registry.MAX_CATEGORY_WEIGHT(), 1000);
    }

    function testSetterValidationOwnerGuardAndEvent() public {
        // Only the owner (the test contract, which deployed the
        // registry) may retune the weights.
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.setCategoryWeight(ReputationRegistry.Category.Quality, 200);

        // Above the 1000 cap.
        vm.expectRevert(ReputationRegistry.InvalidCategoryWeight.selector);
        registry.setCategoryWeight(ReputationRegistry.Category.Quality, 1001);

        // A valid retune lands, emits, and the getters report it.
        vm.expectEmit(true, false, false, true);
        emit ReputationRegistry.CategoryWeightUpdated(
            ReputationRegistry.Category.Quality,
            200
        );
        registry.setCategoryWeight(ReputationRegistry.Category.Quality, 200);
        assertEq(
            registry.categoryWeight(ReputationRegistry.Category.Quality),
            200
        );
        assertEq(registry.categoryWeights()[1], 200);

        // The bounds themselves are accepted: 0 excludes, 1000 is the cap.
        registry.setCategoryWeight(ReputationRegistry.Category.Quality, 0);
        assertEq(
            registry.categoryWeight(ReputationRegistry.Category.Quality),
            0
        );
        registry.setCategoryWeight(
            ReputationRegistry.Category.Quality,
            1000
        );
        assertEq(
            registry.categoryWeight(ReputationRegistry.Category.Quality),
            1000
        );
    }

    function testDoublingQualityPullsOverallTowardQuality() public {
        // Quality 100, Timeliness 0, both weight-1 attesters at full
        // decay: the default blend is 50.
        _attest(a1, alice, ReputationRegistry.Category.Quality, 100);
        _attest(a2, alice, ReputationRegistry.Category.Timeliness, 0);
        assertEq(registry.getScore(alice).average, 5000);

        // Quality at 200 (double): (100*2 + 0*1) / 3 = 66.66.
        registry.setCategoryWeight(ReputationRegistry.Category.Quality, 200);
        assertEq(registry.getScore(alice).average, 6666);
        assertEq(registry.getScore(alice).count, 2);

        // Quality at 1000 (10x): (100*10 + 0*1) / 11 = 90.90.
        registry.setCategoryWeight(
            ReputationRegistry.Category.Quality,
            1000
        );
        assertEq(registry.getScore(alice).average, 9090);

        // Back to the default: the plain blend returns.
        registry.setCategoryWeight(ReputationRegistry.Category.Quality, 100);
        assertEq(registry.getScore(alice).average, 5000);
    }

    function testZeroWeightExcludesCategoryFromOverallOnly() public {
        _attest(a1, alice, ReputationRegistry.Category.Quality, 100);
        _attest(a2, alice, ReputationRegistry.Category.Timeliness, 0);

        // Timeliness at 0: the overall score is the Quality score
        // alone, and the count drops to 1 — but the Timeliness
        // per-category score is untouched.
        registry.setCategoryWeight(
            ReputationRegistry.Category.Timeliness,
            0
        );
        ReputationRegistry.Score memory overall = registry.getScore(alice);
        assertEq(overall.average, 10000);
        assertEq(overall.count, 1);
        assertEq(overall.effectiveWeight, 10000);
        assertEq(
            registry
                .getScoreByCategory(
                    alice,
                    ReputationRegistry.Category.Timeliness
                )
                .average,
            0
        );
        assertEq(
            registry
                .getScoreByCategory(
                    alice,
                    ReputationRegistry.Category.Timeliness
                )
                .count,
            1
        );

        // Weighting every category to 0 leaves an empty overall score.
        registry.setCategoryWeight(ReputationRegistry.Category.Quality, 0);
        assertEq(registry.getScore(alice).average, 0);
        assertEq(registry.getScore(alice).count, 0);
        assertEq(registry.getScore(alice).effectiveWeight, 0);
        // totalWeight counts only records included in the score, so
        // it is 0 too — the records still exist and still count
        // toward their per-category scores.
        assertEq(registry.getScore(alice).totalWeight, 0);
    }

    function testOverallCategoryAttestationsAreWeightedToo() public {
        // An Overall-category attestation and a Quality one, both 100
        // and 0: default blend 50. Weighting Overall to 200 pulls the
        // overall score toward the Overall attestation.
        _attest(a1, alice, ReputationRegistry.Category.Overall, 100);
        _attest(a2, alice, ReputationRegistry.Category.Quality, 0);
        assertEq(registry.getScore(alice).average, 5000);
        registry.setCategoryWeight(ReputationRegistry.Category.Overall, 200);
        assertEq(registry.getScore(alice).average, 6666);
    }

    function testWeightsComposeWithDecay() public {
        // Quality 100 at T0, Timeliness 0 at T0 + 100 days. At T0 + 100
        // days the Quality attestation is half decay (age 100 >= 90)
        // while the Timeliness one is still full, so the default blend
        // is (100*5000 + 0*10000) / 15000 = 33.33.
        _attest(a1, alice, ReputationRegistry.Category.Quality, 100);
        vm.warp(T0 + 100 days);
        _attest(a2, alice, ReputationRegistry.Category.Timeliness, 0);
        assertEq(registry.getScore(alice).average, 3333);

        // Quality at 200: (100*5000*2 + 0*10000*1) / 20000 = 50.
        registry.setCategoryWeight(ReputationRegistry.Category.Quality, 200);
        assertEq(registry.getScore(alice).average, 5000);
    }

    function testWeightsFollowTiersBadgesAndPreview() public {
        // Three Quality 100s and three Timeliness 0s: default blend 50,
        // Emerging (needs 6000 for Established). Weighting Quality to
        // 1000 lifts the overall average to (100*10*3) / (10*3 + 1*3)
        // = 90.90, so the tier rises to Trusted (7500 avg, 5 count —
        // Elite needs 10 attestations).
        _attest(a1, alice, ReputationRegistry.Category.Quality, 100);
        _attest(a2, alice, ReputationRegistry.Category.Quality, 100);
        _attest(a3, alice, ReputationRegistry.Category.Quality, 100);
        // Second attester per category would clash on (attester,
        // subject, category) — use fresh attesters for Timeliness,
        // filed 150 days later so the preview decay differs.
        vm.warp(T0 + 150 days);
        _attest(makeAddr("b1"), alice, ReputationRegistry.Category.Timeliness, 0);
        _attest(makeAddr("b2"), alice, ReputationRegistry.Category.Timeliness, 0);
        _attest(makeAddr("b3"), alice, ReputationRegistry.Category.Timeliness, 0);
        // At T0 + 150 days the Quality attestations are half decay
        // (age 150 >= 90) and the Timeliness ones are full, so the
        // default blend is (100*5000*3) / (5000*3 + 10000*3) = 33.33.
        assertEq(registry.getScore(alice).average, 3333);
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Emerging)
        );

        registry.setCategoryWeight(
            ReputationRegistry.Category.Quality,
            1000
        );
        // (100*5000*10*3) / (5000*10*3 + 10000*1*3) = 83.33.
        assertEq(registry.getScore(alice).average, 8333);
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Trusted)
        );

        // The decay preview follows the retune too: at T0 + 200 days
        // the Quality attestations are half weight and the Timeliness
        // ones are still full, so the blend is the same 83.33.
        assertEq(registry.getScoreAt(alice, T0 + 200 days).average, 8333);
        assertEq(
            uint256(registry.tierOfAt(alice, T0 + 200 days)),
            uint256(ReputationRegistry.Tier.Trusted)
        );

        // A retune back to equal weights drops the tier again.
        registry.setCategoryWeight(ReputationRegistry.Category.Quality, 100);
        assertEq(registry.getScore(alice).average, 3333);
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Emerging)
        );
    }

    function testProfileOverallFollowsWeightsButCategoriesDoNot() public {
        _attest(a1, alice, ReputationRegistry.Category.Quality, 100);
        _attest(a2, alice, ReputationRegistry.Category.Timeliness, 0);
        registry.setCategoryWeight(ReputationRegistry.Category.Quality, 200);

        ReputationRegistry.Profile memory p = registry.getProfile(alice);
        assertEq(p.overall.average, 6666);
        assertEq(p.quality.average, 10000);
        assertEq(p.timeliness.average, 0);
        assertEq(p.quality.count, 1);
        assertEq(p.timeliness.count, 1);
    }
}
