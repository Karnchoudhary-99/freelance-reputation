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
}
