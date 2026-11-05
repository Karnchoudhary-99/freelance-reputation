// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract EvidenceTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    bytes32 constant EVIDENCE_1 = keccak256("deliverable-v1");
    bytes32 constant EVIDENCE_2 = keccak256("invoice-2026-11-05");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function testAttestWithEvidenceStoresHash() public {
        vm.prank(bob);
        uint256 id = registry.attestWithEvidence(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"), EVIDENCE_1
        );
        assertEq(id, 0);
        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.evidenceHash, EVIDENCE_1);
        assertEq(a.score, 90);
        assertEq(a.commentHash, bytes32("c1"));
        // Evidence is metadata: the score is unaffected.
        assertEq(registry.getScore(alice).average, 9000);
    }

    function testPlainAttestLeavesEvidenceZero() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        assertEq(registry.attestation(0).evidenceHash, bytes32(0));
    }

    function testPlainReAttestPreservesEvidence() public {
        vm.prank(bob);
        registry.attestWithEvidence(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"), EVIDENCE_1
        );
        // Plain re-attest updates score/comment but must not wipe evidence.
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.evidenceHash, EVIDENCE_1);
        assertEq(a.score, 80);
        assertEq(a.commentHash, bytes32("c2"));
    }

    function testAttestWithEvidenceReplacesEvidenceOnReAttest() public {
        vm.prank(bob);
        registry.attestWithEvidence(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"), EVIDENCE_1
        );
        vm.prank(bob);
        registry.attestWithEvidence(
            alice, ReputationRegistry.Category.Quality, 85, bytes32("c2"), EVIDENCE_2
        );
        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.evidenceHash, EVIDENCE_2);
        assertEq(a.score, 85);
    }

    function testAttestWithEvidenceCanClearEvidence() public {
        vm.prank(bob);
        registry.attestWithEvidence(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"), EVIDENCE_1
        );
        vm.prank(bob);
        registry.attestWithEvidence(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"), bytes32(0)
        );
        assertEq(registry.attestation(0).evidenceHash, bytes32(0));
    }

    event EvidenceUpdated(
        uint256 indexed id,
        address indexed attester,
        address indexed subject,
        bytes32 evidenceHash
    );

    function testSetEvidenceAttachesLater() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        assertEq(registry.attestation(0).evidenceHash, bytes32(0));
        vm.prank(bob);
        registry.setEvidence(0, EVIDENCE_2);
        assertEq(registry.attestation(0).evidenceHash, EVIDENCE_2);
    }

    function testSetEvidenceOnlyAttester() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.NotAttester.selector);
        registry.setEvidence(0, EVIDENCE_1);
        // The subject may not rewrite the attester's evidence either.
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotAttester.selector);
        registry.setEvidence(0, EVIDENCE_1);
    }

    function testSetEvidenceUnknownReverts() public {
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.UnknownAttestation.selector);
        registry.setEvidence(99, EVIDENCE_1);
    }

    function testSetEvidenceRevokedReverts() public {
        vm.prank(bob);
        registry.attestWithEvidence(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"), EVIDENCE_1
        );
        vm.prank(bob);
        registry.revokeAttestation(0);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AlreadyRevoked.selector);
        registry.setEvidence(0, EVIDENCE_2);
        // The revoked record keeps its original evidence for the audit trail.
        assertEq(registry.attestation(0).evidenceHash, EVIDENCE_1);
    }

    function testSetEvidenceDoesNotTouchScoreOrDecayClock() public {
        vm.prank(bob);
        registry.attestWithEvidence(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"), EVIDENCE_1
        );
        uint64 updatedBefore = registry.attestation(0).updatedAt;
        vm.warp(block.timestamp + 100 days);
        vm.prank(bob);
        registry.setEvidence(0, EVIDENCE_2);
        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.updatedAt, updatedBefore);
        assertEq(a.evidenceHash, EVIDENCE_2);
        // Score still reflects the 100-day decay, unchanged by the edit.
        assertEq(registry.getScore(alice).average, 9000);
    }

    function testSetEvidenceEmitsEvent() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        vm.expectEmit(true, true, true, true);
        emit EvidenceUpdated(0, bob, alice, EVIDENCE_1);
        vm.prank(bob);
        registry.setEvidence(0, EVIDENCE_1);
    }
}
