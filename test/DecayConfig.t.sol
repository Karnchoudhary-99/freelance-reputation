// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract DecayConfigTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address a1 = makeAddr("a1");
    address a2 = makeAddr("a2");

    // Fixed base time so warps read like calendar dates.
    uint64 constant T0 = 1_700_000_000;

    function setUp() public {
        registry = new ReputationRegistry();
        vm.warp(T0);
    }

    function _attest(address attester, address subject, uint8 score) internal {
        vm.prank(attester);
        registry.attest(subject, ReputationRegistry.Category.Overall, score, bytes32(0));
    }

    function testDefaultPeriodsMatchDocumentedTiers() public view {
        assertEq(registry.decayFullPeriod(), 90 days);
        assertEq(registry.decayHalfPeriod(), 365 days);
        assertEq(registry.DECAY_FULL_PERIOD(), 90 days);
        assertEq(registry.DECAY_HALF_PERIOD(), 365 days);
        assertEq(registry.decayFactorBpsAt(T0, T0 + 89 days), 10_000);
        assertEq(registry.decayFactorBpsAt(T0, T0 + 90 days), 5_000);
        assertEq(registry.decayFactorBpsAt(T0, T0 + 364 days), 5_000);
        assertEq(registry.decayFactorBpsAt(T0, T0 + 365 days), 2_500);
    }

    function testSetterValidationOwnerGuardAndEvent() public {
        // Only the owner (the test contract, which deployed the
        // registry) may retune the schedule.
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.setDecayPeriods(30 days, 180 days);

        // Full period below 1 day.
        vm.expectRevert(ReputationRegistry.InvalidDecayPeriods.selector);
        registry.setDecayPeriods(0, 180 days);
        vm.expectRevert(ReputationRegistry.InvalidDecayPeriods.selector);
        registry.setDecayPeriods(12 hours, 180 days);

        // Half period not longer than the full period.
        vm.expectRevert(ReputationRegistry.InvalidDecayPeriods.selector);
        registry.setDecayPeriods(30 days, 30 days);
        vm.expectRevert(ReputationRegistry.InvalidDecayPeriods.selector);
        registry.setDecayPeriods(180 days, 30 days);

        // Half period beyond the 10-year cap.
        vm.expectRevert(ReputationRegistry.InvalidDecayPeriods.selector);
        registry.setDecayPeriods(30 days, 3651 days);

        // A valid retune lands, emits, and the getters report it.
        vm.expectEmit(false, false, false, true);
        emit ReputationRegistry.DecayPeriodsUpdated(30 days, 180 days);
        registry.setDecayPeriods(30 days, 180 days);
        assertEq(registry.decayFullPeriod(), 30 days);
        assertEq(registry.decayHalfPeriod(), 180 days);

        // The bounds themselves are accepted: 1-day full, 10-year half.
        registry.setDecayPeriods(1 days, 3650 days);
        assertEq(registry.decayFullPeriod(), 1 days);
        assertEq(registry.decayHalfPeriod(), 3650 days);
    }

    function testScoresDecayOnConfiguredSchedule() public {
        // Two attestations 40 days apart: 100 first, then 50.
        _attest(a1, alice, 100);
        vm.warp(T0 + 40 days);
        _attest(a2, alice, 50);

        // Default schedule: both still full weight at 40 days, so the
        // average is the plain mean, 75.
        assertEq(registry.getScore(alice).average, 7500);
        assertEq(registry.getScore(alice).count, 2);

        // Retune to a 30-day full period: the 100 is now half weight
        // (5000 bps) while the 50 is still full (10000 bps), so the
        // average drops to (100*5000 + 50*10000) / 15000 = 66.66.
        registry.setDecayPeriods(30 days, 180 days);
        assertEq(registry.getScore(alice).average, 6666);
        assertEq(registry.getScore(alice).count, 2);

        // Lengthening the schedule back revives the decayed weight.
        registry.setDecayPeriods(90 days, 365 days);
        assertEq(registry.getScore(alice).average, 7500);
    }

    function testPreviewViewsFollowConfiguredPeriods() public {
        // 100 at T0, then 0 at T0 + 190 days; read at T0 + 200 days.
        _attest(a1, alice, 100);
        vm.warp(T0 + 190 days);
        _attest(a2, alice, 0);
        vm.warp(T0 + 200 days);

        // Default schedule at T0 + 200 days: the 100 is half weight
        // (age 200 < 365), the 0 is full (age 10 < 90) — 1:2, so the
        // average is (100*5000) / 15000 = 33.33.
        assertEq(registry.getScoreAt(alice, T0 + 200 days).average, 3333);
        assertEq(registry.getProfileAt(alice, T0 + 200 days).overall.average, 3333);

        // Retuned schedule (30/180 days): the 100 is quarter weight
        // (age 200 >= 180), the 0 is still full (age 10 < 30) — 1:4,
        // so the average is (100*2500) / 12500 = 20.
        registry.setDecayPeriods(30 days, 180 days);
        assertEq(registry.getScoreAt(alice, T0 + 200 days).average, 2000);
        assertEq(registry.getProfileAt(alice, T0 + 200 days).overall.average, 2000);
        assertEq(registry.decayFactorBpsAt(T0, T0 + 30 days), 5_000);
        assertEq(registry.decayFactorBpsAt(T0, T0 + 180 days), 2_500);
    }
}
