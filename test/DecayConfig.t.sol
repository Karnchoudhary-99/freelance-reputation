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
}
