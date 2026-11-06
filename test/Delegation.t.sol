// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract DelegationTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function _delegateAliceToBob() internal {
        vm.prank(alice);
        registry.setDelegate(bob, block.timestamp + 30 days);
    }

    function testSetDelegateRegistersActiveDelegate() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.prank(alice);
        registry.setDelegate(bob, expiry);
        assertTrue(registry.isDelegate(alice, bob));
        assertEq(registry.delegateExpiry(alice, bob), expiry);
        address[] memory delegates = registry.getDelegates(alice);
        assertEq(delegates.length, 1);
        assertEq(delegates[0], bob);
    }

    function testSetDelegateEmitsEvent() public {
        uint256 expiry = block.timestamp + 30 days;
        vm.expectEmit(true, true, false, true);
        emit ReputationRegistry.DelegateSet(alice, bob, expiry);
        vm.prank(alice);
        registry.setDelegate(bob, expiry);
    }

    function testSetDelegateRejectsZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.ZeroAddress.selector);
        registry.setDelegate(address(0), block.timestamp + 30 days);
    }

    function testSetDelegateRejectsSelf() public {
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.InvalidDelegate.selector);
        registry.setDelegate(alice, block.timestamp + 30 days);
    }

    function testSetDelegateRejectsPastExpiry() public {
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.InvalidDelegate.selector);
        registry.setDelegate(bob, block.timestamp);
    }

    function testSetDelegateExtendsExpiryWithoutDuplicating() public {
        vm.prank(alice);
        registry.setDelegate(bob, block.timestamp + 30 days);
        vm.prank(alice);
        registry.setDelegate(bob, block.timestamp + 60 days);
        assertEq(registry.delegateExpiry(alice, bob), block.timestamp + 60 days);
        assertEq(registry.getDelegates(alice).length, 1);
    }

    function testDelegateLapsesAtExpiry() public {
        _delegateAliceToBob();
        vm.warp(block.timestamp + 30 days - 1);
        assertTrue(registry.isDelegate(alice, bob));
        vm.warp(block.timestamp + 1);
        assertFalse(registry.isDelegate(alice, bob));
        assertEq(registry.getDelegates(alice).length, 0);
    }

    function testRevokeDelegateClearsAuthority() public {
        _delegateAliceToBob();
        vm.prank(alice);
        registry.revokeDelegate(bob);
        assertFalse(registry.isDelegate(alice, bob));
        assertEq(registry.delegateExpiry(alice, bob), 0);
        assertEq(registry.getDelegates(alice).length, 0);
    }

    function testRevokeDelegateIsIdempotent() public {
        vm.prank(alice);
        registry.revokeDelegate(bob);
        vm.prank(alice);
        registry.revokeDelegate(bob);
        assertFalse(registry.isDelegate(alice, bob));
    }

    function testDelegateAttestsAsAttester() public {
        _delegateAliceToBob();
        vm.prank(bob);
        uint256 id = registry.attestOnBehalf(
            alice,
            carol,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("c1")
        );
        ReputationRegistry.Attestation memory a = registry.attestation(id);
        assertEq(a.attester, alice);
        assertEq(a.subject, carol);
        assertEq(a.score, 90);
        assertEq(a.weight, 1); // alice is a newcomer: weight 1
        assertEq(registry.getScore(carol).average, 9000);
    }

    function testDelegateAttestationUsesAttestersWeightNotDelegates() public {
        // Alice earns a >= 80 average first (weight 3 on reputation alone).
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        vm.prank(dave);
        registry.attest(alice, ReputationRegistry.Category.Overall, 95, bytes32("c1"));
        assertEq(registry.attesterWeight(alice), 3);
        // Bob has no reputation of his own (weight 1).
        assertEq(registry.attesterWeight(bob), 1);

        _delegateAliceToBob();
        vm.prank(bob);
        registry.attestOnBehalf(
            alice,
            carol,
            ReputationRegistry.Category.Overall,
            80,
            bytes32("c1")
        );
        assertEq(registry.attestation(2).weight, 3);
    }

    function testNonDelegateCannotAttestOnBehalf() public {
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.NotDelegate.selector);
        registry.attestOnBehalf(
            alice,
            dave,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("c1")
        );
    }

    function testExpiredDelegateCannotAttest() public {
        _delegateAliceToBob();
        vm.warp(block.timestamp + 31 days);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotDelegate.selector);
        registry.attestOnBehalf(
            alice,
            carol,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("c1")
        );
    }

    function testDelegateReAttestUpdatesSameRecord() public {
        _delegateAliceToBob();
        vm.prank(bob);
        uint256 first = registry.attestOnBehalf(
            alice,
            carol,
            ReputationRegistry.Category.Overall,
            80,
            bytes32("c1")
        );
        vm.prank(bob);
        uint256 second = registry.attestOnBehalf(
            alice,
            carol,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("c2")
        );
        assertEq(first, second);
        assertEq(registry.attestation(first).score, 90);
        assertEq(registry.getScore(carol).count, 1);
    }

    function testDelegateBatchAttest() public {
        _delegateAliceToBob();
        ReputationRegistry.AttestInput[]
            memory inputs = new ReputationRegistry.AttestInput[](2);
        inputs[0] = ReputationRegistry.AttestInput({
            subject: carol,
            category: ReputationRegistry.Category.Quality,
            score: 80,
            commentHash: bytes32("c1")
        });
        inputs[1] = ReputationRegistry.AttestInput({
            subject: dave,
            category: ReputationRegistry.Category.Timeliness,
            score: 70,
            commentHash: bytes32("c2")
        });
        vm.prank(bob);
        uint256[] memory ids = registry.attestBatchOnBehalf(alice, inputs);
        assertEq(ids.length, 2);
        assertEq(registry.attestation(ids[0]).attester, alice);
        assertEq(registry.attestation(ids[1]).attester, alice);
        assertEq(registry.getScore(carol).count, 1);
        assertEq(registry.getScore(dave).count, 1);
    }

    function testDelegateAttestWithEvidenceAndSetEvidenceOnBehalf() public {
        _delegateAliceToBob();
        vm.prank(bob);
        uint256 id = registry.attestWithEvidenceOnBehalf(
            alice,
            carol,
            ReputationRegistry.Category.Overall,
            85,
            bytes32("c1"),
            bytes32("e1")
        );
        assertEq(registry.attestation(id).evidenceHash, bytes32("e1"));

        vm.prank(bob);
        registry.setEvidenceOnBehalf(alice, id, bytes32("e2"));
        assertEq(registry.attestation(id).evidenceHash, bytes32("e2"));

        // The delegate may not use the attester-only entry point.
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotAttester.selector);
        registry.setEvidence(id, bytes32("e3"));
    }

    function testDelegateBatchWithEvidenceOnBehalf() public {
        _delegateAliceToBob();
        ReputationRegistry.AttestWithEvidenceInput[]
            memory inputs = new ReputationRegistry.AttestWithEvidenceInput[](1);
        inputs[0] = ReputationRegistry.AttestWithEvidenceInput({
            subject: carol,
            category: ReputationRegistry.Category.Overall,
            score: 88,
            commentHash: bytes32("c1"),
            evidenceHash: bytes32("e1")
        });
        vm.prank(bob);
        uint256[] memory ids = registry.attestBatchWithEvidenceOnBehalf(
            alice,
            inputs
        );
        assertEq(registry.attestation(ids[0]).evidenceHash, bytes32("e1"));
        assertEq(registry.attestation(ids[0]).attester, alice);
    }

    function testDelegateCannotRevoke() public {
        _delegateAliceToBob();
        vm.prank(bob);
        registry.attestOnBehalf(
            alice,
            carol,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("c1")
        );
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotAttester.selector);
        registry.revokeAttestation(0);
        // The attester herself still can.
        vm.prank(alice);
        registry.revokeAttestation(0);
        assertTrue(registry.attestation(0).revoked);
    }

    function testDelegateCannotResolveDispute() public {
        _delegateAliceToBob();
        vm.prank(bob);
        registry.attestOnBehalf(
            alice,
            carol,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("c1")
        );
        vm.prank(carol);
        registry.disputeAttestation(0, bytes32("r1"));
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotAttester.selector);
        registry.resolveDispute(0, true);
        vm.prank(alice);
        registry.resolveDispute(0, true);
        assertFalse(registry.attestation(0).disputed);
    }

    function testSuspendedAttesterBlocksDelegate() public {
        _delegateAliceToBob();
        registry.strikeAttester(alice);
        registry.strikeAttester(alice);
        registry.strikeAttester(alice);
        assertTrue(registry.isSuspended(alice));
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AttesterSuspended.selector);
        registry.attestOnBehalf(
            alice,
            carol,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("c1")
        );
    }

    function testPausedRegistryBlocksDelegate() public {
        _delegateAliceToBob();
        registry.pause();
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.attestOnBehalf(
            alice,
            carol,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("c1")
        );
    }

    function testDelegateCannotAttestAttesterAsSubject() public {
        _delegateAliceToBob();
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.SelfAttestation.selector);
        registry.attestOnBehalf(
            alice,
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("c1")
        );
    }

    function testGetDelegatesFiltersExpiredAndRevoked() public {
        vm.prank(alice);
        registry.setDelegate(bob, block.timestamp + 30 days);
        vm.prank(alice);
        registry.setDelegate(erin, block.timestamp + 60 days);
        assertEq(registry.getDelegates(alice).length, 2);

        vm.prank(alice);
        registry.revokeDelegate(bob);
        address[] memory delegates = registry.getDelegates(alice);
        assertEq(delegates.length, 1);
        assertEq(delegates[0], erin);

        vm.warp(block.timestamp + 61 days);
        assertEq(registry.getDelegates(alice).length, 0);
    }
}
