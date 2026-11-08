// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {ReputationGate} from "../examples/ReputationGate.sol";

contract ReputationGateTest is Test {
    ReputationRegistry registry;
    ReputationGate gate;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address stranger = makeAddr("stranger");

    // Established tier (2) + average 6000: needs 3+ attestations at
    // 60+ average, so one good review is never enough to pass.
    function setUp() public {
        registry = new ReputationRegistry();
        gate = new ReputationGate(address(registry), 2, 6000);
    }

    function _attest(
        address attester,
        address subject,
        uint8 score
    ) internal {
        vm.prank(attester);
        registry.attest(
            subject,
            ReputationRegistry.Category.Overall,
            score,
            bytes32(0)
        );
    }

    function testUnknownSubjectIsNotEligible() public view {
        assertFalse(gate.isEligible(alice));
        assertEq(uint8(registry.tierOf(alice)), 0);
    }

    function testGatedActionRevertsForIneligible() public {
        vm.expectRevert(ReputationGate.NotEligible.selector);
        gate.gatedAction(alice);
    }

    function testSingleAttestationIsNotEnough() public {
        _attest(bob, alice, 100);
        // Average 10000, but count 1: still Emerging, below the
        // Established bar the gate requires.
        assertEq(uint8(registry.tierOf(alice)), 1);
        assertFalse(gate.isEligible(alice));
    }

    function testEligibilityFlipsAtEstablished() public {
        _attest(bob, alice, 90);
        _attest(carol, alice, 80);
        assertFalse(gate.isEligible(alice), "2 attestations: Emerging");

        _attest(dave, alice, 70);
        // Average 8000, count 3: Established, clears both bars.
        assertEq(uint8(registry.tierOf(alice)), 2);
        assertTrue(gate.isEligible(alice));

        vm.expectEmit(true, false, false, true);
        emit ReputationGate.GatedActionCalled(alice);
        gate.gatedAction(alice);
    }

    function testHighAverageButLowTierFails() public {
        // Three 100s would pass; use a gate with a Trusted bar
        // (tier 3 needs 5 attestations) to show the tier check binds.
        ReputationGate trustedGate = new ReputationGate(
            address(registry),
            3,
            6000
        );
        _attest(bob, alice, 100);
        _attest(carol, alice, 100);
        _attest(dave, alice, 100);
        assertEq(registry.getScore(alice).average, 10000);
        assertFalse(trustedGate.isEligible(alice));
    }

    function testLowAverageButHighTierFails() public {
        // A gate with an 8000 average bar: three attestations at 70
        // clear Established (7000 average, count 3) but not the bar —
        // the average check binds, not the tier check.
        ReputationGate strictGate = new ReputationGate(
            address(registry),
            2,
            8000
        );
        _attest(bob, alice, 70);
        _attest(carol, alice, 70);
        _attest(dave, alice, 70);
        assertEq(uint8(registry.tierOf(alice)), 2);
        assertEq(registry.getScore(alice).average, 7000);
        assertFalse(strictGate.isEligible(alice));
        assertTrue(gate.isEligible(alice), "looser gate still admits");
    }

    function testRevocationClosesTheGate() public {
        _attest(bob, alice, 90);
        _attest(carol, alice, 80);
        _attest(dave, alice, 70);
        assertTrue(gate.isEligible(alice));

        vm.prank(bob);
        registry.revokeAttestation(0);
        assertFalse(gate.isEligible(alice), "count fell to 2: Emerging");
    }

    function testOwnerCanRetuneThresholds() public {
        _attest(bob, alice, 90);
        _attest(carol, alice, 80);
        _attest(dave, alice, 70);
        assertTrue(gate.isEligible(alice));

        // Raise the average bar above the subject's 8000: gate closes
        // without touching anyone's reputation.
        gate.setThresholds(2, 9000);
        assertFalse(gate.isEligible(alice));

        vm.prank(stranger);
        vm.expectRevert(ReputationGate.NotOwner.selector);
        gate.setThresholds(0, 0);
    }

    function testConstructorRejectsBadThresholds() public {
        vm.expectRevert(ReputationGate.InvalidThreshold.selector);
        new ReputationGate(address(0), 2, 6000);

        vm.expectRevert(ReputationGate.InvalidThreshold.selector);
        new ReputationGate(address(registry), 5, 6000);

        vm.expectRevert(ReputationGate.InvalidThreshold.selector);
        new ReputationGate(address(registry), 2, 10001);
    }
}
