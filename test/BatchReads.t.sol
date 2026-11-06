// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract BatchReadsTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address unknown = makeAddr("unknown");

    function setUp() public {
        registry = new ReputationRegistry();
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

    function _subjects() internal view returns (address[] memory) {
        address[] memory subjects = new address[](4);
        subjects[0] = alice;
        subjects[1] = bob;
        subjects[2] = carol;
        subjects[3] = unknown;
        return subjects;
    }

    function testGetScoresReturnsPerSubjectScoresInOrder() public {
        _attest(makeAddr("a1"), alice, ReputationRegistry.Category.Overall, 90);
        _attest(makeAddr("a2"), bob, ReputationRegistry.Category.Overall, 70);
        _attest(makeAddr("a3"), carol, ReputationRegistry.Category.Overall, 90);
        _attest(makeAddr("a4"), carol, ReputationRegistry.Category.Overall, 80);

        ReputationRegistry.Score[] memory scores = registry.getScores(_subjects());
        assertEq(scores.length, 4);
        assertEq(scores[0].average, 9000);
        assertEq(scores[0].count, 1);
        assertEq(scores[1].average, 7000);
        assertEq(scores[1].count, 1);
        // Carol: two attestations, average 85.
        assertEq(scores[2].average, 8500);
        assertEq(scores[2].count, 2);
        // Unknown subject: zero score, like getScore.
        assertEq(scores[3].average, 0);
        assertEq(scores[3].count, 0);
    }

    function testGetProfilesReturnsFullProfilesInOrder() public {
        _attest(makeAddr("a1"), alice, ReputationRegistry.Category.Quality, 80);
        _attest(makeAddr("a2"), alice, ReputationRegistry.Category.Communication, 100);
        _attest(makeAddr("a3"), bob, ReputationRegistry.Category.Timeliness, 60);

        ReputationRegistry.Profile[] memory profiles = registry.getProfiles(_subjects());
        assertEq(profiles.length, 4);
        assertEq(profiles[0].overall.average, 9000);
        assertEq(profiles[0].overall.count, 2);
        assertEq(profiles[0].quality.average, 8000);
        assertEq(profiles[0].quality.count, 1);
        assertEq(profiles[0].communication.average, 10000);
        assertEq(profiles[0].communication.count, 1);
        assertEq(profiles[0].timeliness.count, 0);
        assertEq(profiles[1].overall.average, 6000);
        assertEq(profiles[1].timeliness.average, 6000);
        assertEq(profiles[1].quality.count, 0);
        assertEq(profiles[2].overall.count, 0);
        assertEq(profiles[3].overall.count, 0);
        assertEq(profiles[3].quality.count, 0);
    }

    function testGetTiersReturnsPerSubjectTiersInOrder() public {
        // Alice: 3 attestations at 90 -> Established (avg 9000, count 3).
        _attest(makeAddr("a1"), alice, ReputationRegistry.Category.Overall, 90);
        _attest(makeAddr("a2"), alice, ReputationRegistry.Category.Overall, 90);
        _attest(makeAddr("a3"), alice, ReputationRegistry.Category.Overall, 90);
        // Bob: 1 attestation at 70 -> Emerging.
        _attest(makeAddr("a4"), bob, ReputationRegistry.Category.Overall, 70);

        ReputationRegistry.Tier[] memory tiers = registry.getTiers(_subjects());
        assertEq(tiers.length, 4);
        assertEq(uint256(tiers[0]), uint256(ReputationRegistry.Tier.Established));
        assertEq(uint256(tiers[1]), uint256(ReputationRegistry.Tier.Emerging));
        assertEq(uint256(tiers[2]), uint256(ReputationRegistry.Tier.Unranked));
        assertEq(uint256(tiers[3]), uint256(ReputationRegistry.Tier.Unranked));
    }

    function testBatchReadsMatchSingleSubjectViews() public {
        _attest(makeAddr("a1"), alice, ReputationRegistry.Category.Quality, 80);
        _attest(makeAddr("a2"), alice, ReputationRegistry.Category.Communication, 100);
        _attest(makeAddr("a3"), bob, ReputationRegistry.Category.Timeliness, 60);
        _attest(makeAddr("a4"), carol, ReputationRegistry.Category.Overall, 95);

        address[] memory subjects = _subjects();
        ReputationRegistry.Score[] memory scores = registry.getScores(subjects);
        ReputationRegistry.Profile[] memory profiles = registry.getProfiles(subjects);
        ReputationRegistry.Tier[] memory tiers = registry.getTiers(subjects);
        for (uint256 i = 0; i < subjects.length; i++) {
            ReputationRegistry.Score memory single = registry.getScore(subjects[i]);
            assertEq(scores[i].average, single.average);
            assertEq(scores[i].count, single.count);
            assertEq(scores[i].totalWeight, single.totalWeight);
            assertEq(scores[i].effectiveWeight, single.effectiveWeight);
            ReputationRegistry.Profile memory profile = registry.getProfile(subjects[i]);
            assertEq(profiles[i].overall.average, profile.overall.average);
            assertEq(profiles[i].quality.average, profile.quality.average);
            assertEq(profiles[i].communication.average, profile.communication.average);
            assertEq(profiles[i].timeliness.average, profile.timeliness.average);
            assertEq(profiles[i].reliability.average, profile.reliability.average);
            assertEq(uint256(tiers[i]), uint256(registry.tierOf(subjects[i])));
        }
    }

    function testBatchReadsEmptyInput() public view {
        address[] memory empty = new address[](0);
        assertEq(registry.getScores(empty).length, 0);
        assertEq(registry.getProfiles(empty).length, 0);
        assertEq(registry.getTiers(empty).length, 0);
    }

    function testBatchReadsReflectRevocation() public {
        _attest(makeAddr("a1"), alice, ReputationRegistry.Category.Overall, 90);
        _attest(makeAddr("a2"), bob, ReputationRegistry.Category.Overall, 70);
        vm.prank(makeAddr("a1"));
        registry.revokeAttestation(0);

        address[] memory subjects = new address[](2);
        subjects[0] = alice;
        subjects[1] = bob;
        ReputationRegistry.Score[] memory scores = registry.getScores(subjects);
        assertEq(scores[0].count, 0);
        assertEq(scores[0].average, 0);
        assertEq(scores[1].average, 7000);
        assertEq(uint256(registry.getTiers(subjects)[0]), uint256(ReputationRegistry.Tier.Unranked));
    }
}
