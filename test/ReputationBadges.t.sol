// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract ReputationBadgesTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    // Fresh attester per call: re-using an attester on the same subject
    // and category would update their existing attestation in place
    // instead of adding a new one.
    uint256 private _attesterSeq;

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function _attest(address subject, uint8 score, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.prank(
                makeAddr(string(abi.encodePacked("att", _attesterSeq++)))
            );
            registry.attest(
                subject,
                ReputationRegistry.Category.Overall,
                score,
                bytes32(0)
            );
        }
    }

    function _attestFrom(address attester, uint8 score) internal {
        vm.prank(attester);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            score,
            bytes32(0)
        );
    }

    function _badgeList(
        address subject
    ) internal view returns (uint256[] memory) {
        ReputationRegistry.Badge[] memory badges = registry.getBadges(subject);
        uint256[] memory out = new uint256[](badges.length);
        for (uint256 i = 0; i < badges.length; i++) {
            out[i] = uint256(badges[i]);
        }
        return out;
    }

    function testUnknownSubjectHoldsNoBadges() public view {
        assertEq(registry.getBadges(alice).length, 0);
        assertEq(registry.getBadgesAt(alice, uint64(block.timestamp)).length, 0);
        ReputationRegistry.Badge[][] memory batch = registry.getBadgesFor(
            _subjects(alice)
        );
        assertEq(batch.length, 1);
        assertEq(batch[0].length, 0);
    }

    function testRisingStarAtExactThreshold() public {
        // Four perfect attestations: average 100, but count short of 5.
        _attest(alice, 100, 4);
        assertEq(registry.getBadges(alice).length, 0);
        // Five at 59: average 59, below the 60 bar.
        _attest(bob, 59, 5);
        assertEq(registry.getBadges(bob).length, 0);
        // Five at exactly 60: average 6000, count 5 -> RisingStar.
        _attest(carol, 60, 5);
        assertEq(_badgeList(carol), _asUintArray(0));
    }

    function testBadgesAreCumulative() public {
        _attest(alice, 90, 10);
        // Average 90, count 10 -> RisingStar + HighlyRated.
        assertEq(_badgeList(alice), _asUintArray(0, 1));
        _attest(alice, 90, 15);
        // Average still 90, count 25 -> TopRated joins them.
        assertEq(_badgeList(alice), _asUintArray(0, 1, 2));
    }

    function testVeteranIsAVolumeBadge() public {
        // Fifty attestations at 70: solid but never highly rated —
        // RisingStar for the 60+ average, Veteran for the 50 count,
        // and neither HighlyRated (needs 75+) nor TopRated (needs 85+).
        _attest(alice, 70, 50);
        assertEq(_badgeList(alice), _asUintArray(0, 3));
    }

    function testAllFourBadges() public {
        _attest(alice, 90, 50);
        assertEq(_badgeList(alice), _asUintArray(0, 1, 2, 3));
    }

    function testBadgesLostOnRevocation() public {
        _attest(alice, 90, 10);
        assertEq(_badgeList(alice), _asUintArray(0, 1));
        // Revoke six: count falls to 4, average still 90, no badge
        // survives — every badge needs at least 5 active attestations.
        for (uint256 i = 0; i < 6; i++) {
            vm.prank(makeAddr(string(abi.encodePacked("att", i))));
            registry.revokeAttestation(i);
        }
        assertEq(registry.getBadges(alice).length, 0);
    }

    function testDisputedAttestationsDoNotCount() public {
        _attest(alice, 90, 5);
        assertEq(_badgeList(alice), _asUintArray(0));
        vm.prank(alice);
        registry.disputeAttestation(0, bytes32("unfair"));
        // Four active left: RisingStar needs five.
        assertEq(registry.getBadges(alice).length, 0);
    }

    function testBadgesLostAsScoresDecay() public {
        // Five old perfect endorsements, then five fresh zeroes after a
        // 400-day warp: old weight 2500, fresh weight 10000, so the
        // average is (5*100*2500) / (5*2500 + 5*10000) = 20.
        _attest(alice, 100, 5);
        assertEq(_badgeList(alice), _asUintArray(0));
        vm.warp(block.timestamp + 400 days);
        for (uint256 i = 5; i < 10; i++) {
            _attestFrom(makeAddr(string(abi.encodePacked("att", i))), 0);
        }
        assertEq(registry.getScore(alice).average, 2000);
        assertEq(registry.getBadges(alice).length, 0);
    }

    function testBadgesPreviewAtEarlierTime() public {
        uint64 start = uint64(block.timestamp);
        _attest(alice, 100, 5);
        // Four hundred days on, the five fresh zeroes above have dragged
        // the live average to 20 — but as of the start, before those
        // zeroes existed, the subject held RisingStar.
        vm.warp(block.timestamp + 400 days);
        for (uint256 i = 5; i < 10; i++) {
            _attestFrom(makeAddr(string(abi.encodePacked("att", i))), 0);
        }
        assertEq(registry.getBadges(alice).length, 0);
        ReputationRegistry.Badge[] memory then = registry.getBadgesAt(
            alice,
            start
        );
        assertEq(then.length, 1);
        assertEq(uint256(then[0]), uint256(ReputationRegistry.Badge.RisingStar));
    }

    function testExpiredAttestationsDoNotCount() public {
        uint64 start = uint64(block.timestamp);
        _attest(alice, 90, 5);
        assertEq(_badgeList(alice), _asUintArray(0));
        // Past the 730-day default expiry every attestation is inactive.
        vm.warp(block.timestamp + 731 days);
        assertEq(registry.getBadges(alice).length, 0);
        // The preview at the start still shows the badge: nothing had
        // expired yet.
        ReputationRegistry.Badge[] memory then = registry.getBadgesAt(
            alice,
            start
        );
        assertEq(then.length, 1);
        assertEq(uint256(then[0]), uint256(ReputationRegistry.Badge.RisingStar));
    }

    function testOptOutDoesNotHideBadges() public {
        _attest(alice, 90, 5);
        vm.prank(alice);
        registry.setLeaderboardOptOut(true);
        assertTrue(registry.isLeaderboardOptedOut(alice));
        // Badges are a direct read about one subject, like tierOf — the
        // discovery opt-out only hides leaderboard and tier listings.
        assertEq(_badgeList(alice), _asUintArray(0));
    }

    function testBatchBadgesAgreeWithSingleReads() public {
        _attest(alice, 90, 5);
        _attest(bob, 90, 25);
        // carol never attested: empty.
        ReputationRegistry.Badge[][] memory batch = registry.getBadgesFor(
            _subjects(alice, bob, carol)
        );
        assertEq(batch.length, 3);
        assertEq(batch[0].length, 1);
        assertEq(uint256(batch[0][0]), uint256(ReputationRegistry.Badge.RisingStar));
        assertEq(batch[1].length, 3);
        assertEq(uint256(batch[1][0]), uint256(ReputationRegistry.Badge.RisingStar));
        assertEq(uint256(batch[1][1]), uint256(ReputationRegistry.Badge.HighlyRated));
        assertEq(uint256(batch[1][2]), uint256(ReputationRegistry.Badge.TopRated));
        assertEq(batch[2].length, 0);
        // Empty input returns an empty array.
        assertEq(registry.getBadgesFor(new address[](0)).length, 0);
    }

    function _subjects(
        address a
    ) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _subjects(
        address a,
        address b,
        address c
    ) internal pure returns (address[] memory out) {
        out = new address[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _asUintArray(
        uint256 a
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _asUintArray(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _asUintArray(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _asUintArray(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](4);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
    }
}
