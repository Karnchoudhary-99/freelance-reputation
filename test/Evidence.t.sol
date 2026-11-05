// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract EvidenceTest is Test {
    ReputationRegistry registry;

    uint256 bobKey = 0xB0B;
    address bob;
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");

    bytes32 constant EVIDENCE_1 = keccak256("deliverable-v1");
    bytes32 constant EVIDENCE_2 = keccak256("invoice-2026-11-05");

    function setUp() public {
        registry = new ReputationRegistry();
        bob = vm.addr(bobKey);
    }

    function _sign(
        uint256 key,
        address attester,
        address subject,
        ReputationRegistry.Category category,
        uint8 score,
        bytes32 commentHash,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.ATTEST_TYPEHASH(),
                attester,
                subject,
                category,
                score,
                commentHash,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash)
        );
        (v, r, s) = vm.sign(key, digest);
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

    function testBatchWithEvidenceStoresHashes() public {
        ReputationRegistry.AttestWithEvidenceInput[] memory inputs =
            new ReputationRegistry.AttestWithEvidenceInput[](2);
        inputs[0] = ReputationRegistry.AttestWithEvidenceInput(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("b1"), EVIDENCE_1
        );
        inputs[1] = ReputationRegistry.AttestWithEvidenceInput(
            alice, ReputationRegistry.Category.Timeliness, 70, bytes32("b2"), EVIDENCE_2
        );
        vm.prank(bob);
        uint256[] memory ids = registry.attestBatchWithEvidence(inputs);
        assertEq(ids.length, 2);
        assertEq(registry.attestation(ids[0]).evidenceHash, EVIDENCE_1);
        assertEq(registry.attestation(ids[1]).evidenceHash, EVIDENCE_2);
    }

    function testBatchWithEvidenceAtomicOnBadEntry() public {
        ReputationRegistry.AttestWithEvidenceInput[] memory inputs =
            new ReputationRegistry.AttestWithEvidenceInput[](2);
        inputs[0] = ReputationRegistry.AttestWithEvidenceInput(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("b1"), EVIDENCE_1
        );
        inputs[1] = ReputationRegistry.AttestWithEvidenceInput(
            alice, ReputationRegistry.Category.Timeliness, 101, bytes32("b2"), EVIDENCE_2
        );
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.InvalidScore.selector);
        registry.attestBatchWithEvidence(inputs);
        // Atomic: the valid first entry was rolled back too.
        assertEq(registry.attestationCount(), 0);
        assertEq(registry.getScore(alice).count, 0);
    }

    function testPlainBatchReAttestPreservesEvidence() public {
        vm.prank(bob);
        registry.attestWithEvidence(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"), EVIDENCE_1
        );
        ReputationRegistry.AttestInput[] memory inputs = new ReputationRegistry.AttestInput[](1);
        inputs[0] = ReputationRegistry.AttestInput(
            alice, ReputationRegistry.Category.Quality, 80, bytes32("c2")
        );
        vm.prank(bob);
        registry.attestBatch(inputs);
        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.evidenceHash, EVIDENCE_1);
        assertEq(a.score, 80);
    }

    function testSignedAttestHasNoEvidence() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            bobKey, bob, alice, ReputationRegistry.Category.Quality, 88, bytes32("c1"), 0, deadline
        );
        vm.prank(carol); // relayed by a third party
        registry.attestBySignature(
            bob, alice, ReputationRegistry.Category.Quality, 88, bytes32("c1"), deadline, v, r, s
        );
        // Signed attestations carry no evidence field (the EIP-712 type is
        // unchanged); the attester can attach it later via setEvidence.
        assertEq(registry.attestation(0).evidenceHash, bytes32(0));
        vm.prank(bob);
        registry.setEvidence(0, EVIDENCE_1);
        assertEq(registry.attestation(0).evidenceHash, EVIDENCE_1);
    }

    function testEvidenceSurvivesDisputeLifecycle() public {
        vm.prank(bob);
        registry.attestWithEvidence(
            alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"), EVIDENCE_1
        );
        vm.prank(alice);
        registry.disputeAttestation(0, bytes32("unfair"));
        assertEq(registry.attestation(0).evidenceHash, EVIDENCE_1);
        vm.prank(bob);
        registry.resolveDispute(0, true); // attester upholds
        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.evidenceHash, EVIDENCE_1);
        assertFalse(a.disputed);
        assertEq(registry.getScore(alice).average, 9000);
    }
}
