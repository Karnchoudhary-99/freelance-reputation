// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract ProfileExportTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");

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

    function _seedAlice() internal {
        _attest(bob, alice, ReputationRegistry.Category.Overall, 90);
        _attest(carol, alice, ReputationRegistry.Category.Overall, 80);
        _attest(bob, alice, ReputationRegistry.Category.Quality, 100);
        _attest(dave, alice, ReputationRegistry.Category.Timeliness, 70);
    }

    function _assertScoresEqual(
        ReputationRegistry.Score memory a,
        ReputationRegistry.Score memory b
    ) internal pure {
        assertEq(a.average, b.average);
        assertEq(a.count, b.count);
        assertEq(a.totalWeight, b.totalWeight);
        assertEq(a.effectiveWeight, b.effectiveWeight);
    }

    function testExportAgreesWithSingleViews() public {
        _seedAlice();

        ReputationRegistry.FullProfile memory full = registry
            .getFullProfile(alice);
        ReputationRegistry.Profile memory profile = registry.getProfile(
            alice
        );
        _assertScoresEqual(full.profile.overall, profile.overall);
        _assertScoresEqual(full.profile.quality, profile.quality);
        _assertScoresEqual(
            full.profile.communication,
            profile.communication
        );
        _assertScoresEqual(full.profile.timeliness, profile.timeliness);
        _assertScoresEqual(full.profile.reliability, profile.reliability);

        assertEq(uint8(full.tier), uint8(registry.tierOf(alice)));

        ReputationRegistry.Badge[] memory badges = registry.getBadges(alice);
        assertEq(full.badges.length, badges.length);
        for (uint256 i = 0; i < badges.length; i++) {
            assertEq(uint8(full.badges[i]), uint8(badges[i]));
        }

        (
            ReputationRegistry.ScoreSnapshot memory snap,
            bool exists
        ) = registry.latestScoreSnapshot(
                alice,
                ReputationRegistry.Category.Overall
            );
        assertTrue(full.hasSnapshot);
        assertTrue(exists);
        assertEq(full.latestSnapshot.timestamp, snap.timestamp);
        assertEq(full.latestSnapshot.average, snap.average);
        assertEq(full.latestSnapshot.count, snap.count);
        assertEq(
            full.latestSnapshot.effectiveWeight,
            snap.effectiveWeight
        );

        // No proof issued yet.
        assertFalse(full.hasProof);
        assertEq(full.proof.subject, address(0));
    }

    function testExportUnknownSubjectIsZero() public view {
        ReputationRegistry.FullProfile memory full = registry.getFullProfile(
            alice
        );
        assertEq(full.profile.overall.average, 0);
        assertEq(full.profile.overall.count, 0);
        assertEq(full.profile.quality.count, 0);
        assertEq(uint8(full.tier), uint8(ReputationRegistry.Tier.Unranked));
        assertEq(full.badges.length, 0);
        assertFalse(full.hasSnapshot);
        assertEq(full.latestSnapshot.average, 0);
        assertFalse(full.hasProof);
    }

    function testExportTracksRevokeAndDispute() public {
        _seedAlice();
        // The overall score aggregates every category, so all four
        // attestations count: (90 + 80 + 100 + 70) / 4 = 8500.
        assertEq(registry.getFullProfile(alice).profile.overall.count, 4);
        assertEq(
            registry.getFullProfile(alice).profile.overall.average,
            8500
        );

        // Revoke bob's overall attestation: the export's count drops.
        vm.prank(bob);
        registry.revokeAttestation(0);
        ReputationRegistry.FullProfile memory afterRevoke = registry
            .getFullProfile(alice);
        assertEq(afterRevoke.profile.overall.count, 3);
        // (80 + 100 + 70) / 3 = 8333.
        assertEq(afterRevoke.profile.overall.average, 8333);
        assertEq(
            afterRevoke.profile.quality.count,
            1,
            "other categories unaffected"
        );

        // Dispute carol's remaining overall attestation: excluded too.
        vm.prank(alice);
        registry.disputeAttestation(1, bytes32("bad work"));
        ReputationRegistry.FullProfile memory afterDispute = registry
            .getFullProfile(alice);
        assertEq(afterDispute.profile.overall.count, 2);
        // (100 + 70) / 2 = 8500, but only 2 attestations: Emerging.
        assertEq(afterDispute.profile.overall.average, 8500);
        assertEq(uint8(afterDispute.tier), uint8(ReputationRegistry.Tier.Emerging));
    }

    function testExportIncludesIssuedProof() public {
        _seedAlice();

        registry.issueScoreProof(alice, 30 days);
        ReputationRegistry.FullProfile memory full = registry.getFullProfile(
            alice
        );
        assertTrue(full.hasProof);
        assertEq(full.proof.subject, alice);
        assertEq(
            full.proof.average,
            registry.getProfile(alice).overall.average
        );
        assertEq(uint8(full.proof.tier), uint8(full.tier));
        assertEq(full.proof.count, full.profile.overall.count);

        // Revoking the proof clears it from the export, score untouched.
        registry.revokeScoreProof(alice);
        ReputationRegistry.FullProfile memory afterRevoke = registry
            .getFullProfile(alice);
        assertFalse(afterRevoke.hasProof);
        assertEq(
            afterRevoke.profile.overall.average,
            full.profile.overall.average
        );
    }

    function testExportAtAgreesWithPreviewViews() public {
        // Stagger the attestations so decay moves the average: bob's
        // 100 is 100 days old when carol's 50 and dave's 100 land, so
        // at the live moment bob counts at half weight (100*50 +
        // 50*100 + 100*100) / 250 = 8000, while 100 days later bob
        // and carol both count at half weight (100*50 + 50*50 +
        // 100*50) / 150 = 8333.
        _attest(bob, alice, ReputationRegistry.Category.Overall, 100);
        vm.warp(block.timestamp + 100 days);
        _attest(carol, alice, ReputationRegistry.Category.Overall, 50);
        _attest(dave, alice, ReputationRegistry.Category.Quality, 100);
        uint64 when = uint64(block.timestamp + 100 days);

        ReputationRegistry.FullProfile memory full = registry
            .getFullProfileAt(alice, when);
        ReputationRegistry.Profile memory preview = registry.getProfileAt(
            alice,
            when
        );
        _assertScoresEqual(full.profile.overall, preview.overall);
        _assertScoresEqual(full.profile.quality, preview.quality);
        _assertScoresEqual(full.profile.timeliness, preview.timeliness);
        assertEq(uint8(full.tier), uint8(registry.tierOfAt(alice, when)));

        ReputationRegistry.Badge[] memory badges = registry.getBadgesAt(
            alice,
            when
        );
        assertEq(full.badges.length, badges.length);
        for (uint256 i = 0; i < badges.length; i++) {
            assertEq(uint8(full.badges[i]), uint8(badges[i]));
        }

        // The preview moved away from the live score, and agrees with
        // the single preview view rather than the live one.
        assertEq(full.profile.overall.average, 8333);
        assertEq(
            full.profile.overall.average,
            registry.getScoreAt(alice, when).average
        );
        assertEq(registry.getScore(alice).average, 8000);
        assertTrue(full.profile.overall.average != registry.getScore(alice).average);

        // Snapshot and proof are frozen records, returned as they stand.
        assertTrue(full.hasSnapshot);
        (
            ReputationRegistry.ScoreSnapshot memory liveSnap,
            bool snapExists
        ) = registry.latestScoreSnapshot(
                alice,
                ReputationRegistry.Category.Overall
            );
        assertTrue(snapExists);
        assertEq(full.latestSnapshot.average, liveSnap.average);
    }

    function testExportAtNowEqualsLiveExport() public {
        _seedAlice();
        registry.issueScoreProof(alice, 30 days);

        ReputationRegistry.FullProfile memory live = registry.getFullProfile(
            alice
        );
        ReputationRegistry.FullProfile memory atNow = registry
            .getFullProfileAt(alice, uint64(block.timestamp));
        _assertScoresEqual(atNow.profile.overall, live.profile.overall);
        _assertScoresEqual(atNow.profile.quality, live.profile.quality);
        assertEq(uint8(atNow.tier), uint8(live.tier));
        assertEq(atNow.badges.length, live.badges.length);
        assertEq(atNow.hasSnapshot, live.hasSnapshot);
        assertEq(atNow.latestSnapshot.average, live.latestSnapshot.average);
        assertEq(atNow.hasProof, live.hasProof);
        assertEq(atNow.proof.average, live.proof.average);
    }

    function testExportShowsEarnedBadges() public {
        // Five distinct attesters at 80: average 8000, count 5 earns
        // RisingStar (60+/5) but not HighlyRated (needs 10).
        address[5] memory attesters = [bob, carol, dave, erin, frank];
        for (uint256 i = 0; i < attesters.length; i++) {
            _attest(
                attesters[i],
                alice,
                ReputationRegistry.Category.Overall,
                80
            );
        }

        ReputationRegistry.FullProfile memory full = registry.getFullProfile(
            alice
        );
        assertEq(full.badges.length, 1);
        assertEq(
            uint8(full.badges[0]),
            uint8(ReputationRegistry.Badge.RisingStar)
        );
        // Tier follows the same score: 8000 with 5 attestations.
        assertEq(uint8(full.tier), uint8(registry.tierOf(alice)));
    }
}
