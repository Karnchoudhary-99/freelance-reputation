// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract ScoreProofsTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function _giveAliceReputation() internal {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("c2"));
        vm.prank(dave);
        registry.attest(alice, ReputationRegistry.Category.Overall, 85, bytes32("c3"));
    }

    function testIssueFreezesLiveScoreTierAndCount() public {
        _giveAliceReputation();
        ReputationRegistry.ScoreProof memory proof = registry.issueScoreProof(alice, 30 days);
        assertEq(proof.subject, alice);
        assertEq(proof.average, 8500);
        assertEq(uint8(proof.tier), uint8(ReputationRegistry.Tier.Established));
        assertEq(proof.count, 3);
        assertEq(proof.issuedAt, block.timestamp);
        assertEq(proof.expiresAt, block.timestamp + 30 days);

        (ReputationRegistry.ScoreProof memory stored, bool exists) = registry.scoreProofOf(alice);
        assertTrue(exists);
        assertEq(stored.average, 8500);
        assertEq(stored.expiresAt, proof.expiresAt);
    }

    function testVerifyIssuedProof() public {
        _giveAliceReputation();
        ReputationRegistry.ScoreProof memory proof = registry.issueScoreProof(alice, 30 days);
        assertTrue(registry.verifyScoreProof(proof));
    }

    function testIssueForSubjectWithNoAttestations() public {
        ReputationRegistry.ScoreProof memory proof = registry.issueScoreProof(alice, 7 days);
        assertEq(proof.average, 0);
        assertEq(uint8(proof.tier), uint8(ReputationRegistry.Tier.Unranked));
        assertEq(proof.count, 0);
        assertTrue(registry.verifyScoreProof(proof));
    }

    function testScoreProofOfUnknownSubjectHasNoProof() public view {
        (, bool exists) = registry.scoreProofOf(alice);
        assertFalse(exists);
    }

    function testVerifyUnknownSubjectProofFails() public view {
        ReputationRegistry.ScoreProof memory proof = ReputationRegistry.ScoreProof({
            subject: alice,
            average: 8500,
            tier: ReputationRegistry.Tier.Established,
            count: 3,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 30 days
        });
        assertFalse(registry.verifyScoreProof(proof));
    }

    function testVerifyRejectsTamperedFields() public {
        _giveAliceReputation();
        ReputationRegistry.ScoreProof memory proof = registry.issueScoreProof(alice, 30 days);

        ReputationRegistry.ScoreProof memory tampered = proof;
        tampered.average = 9999;
        assertFalse(registry.verifyScoreProof(tampered));

        tampered = proof;
        tampered.tier = ReputationRegistry.Tier.Elite;
        assertFalse(registry.verifyScoreProof(tampered));

        tampered = proof;
        tampered.count = 99;
        assertFalse(registry.verifyScoreProof(tampered));

        tampered = proof;
        tampered.issuedAt = proof.issuedAt + 1;
        assertFalse(registry.verifyScoreProof(tampered));

        tampered = proof;
        tampered.expiresAt = proof.expiresAt + 1 days;
        assertFalse(registry.verifyScoreProof(tampered));

        tampered = proof;
        tampered.subject = bob;
        assertFalse(registry.verifyScoreProof(tampered));
    }

    function testProofExpires() public {
        _giveAliceReputation();
        ReputationRegistry.ScoreProof memory proof = registry.issueScoreProof(alice, 30 days);
        assertTrue(registry.verifyScoreProof(proof));

        vm.warp(block.timestamp + 30 days);
        assertTrue(registry.verifyScoreProof(proof));

        vm.warp(block.timestamp + 1);
        assertFalse(registry.verifyScoreProof(proof));
    }

    function testProofStaysValidWhenLiveScoreMoves() public {
        _giveAliceReputation();
        ReputationRegistry.ScoreProof memory proof = registry.issueScoreProof(alice, 30 days);
        assertEq(proof.average, 8500);

        // A fresh low attestation drags the live score down...
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 40, bytes32("c4"));
        assertLt(registry.getScore(alice).average, 8500);

        // ...but the frozen certificate still verifies until expiry.
        assertTrue(registry.verifyScoreProof(proof));
    }

    function testReissueReplacesPreviousProof() public {
        _giveAliceReputation();
        ReputationRegistry.ScoreProof memory first = registry.issueScoreProof(alice, 30 days);
        assertEq(first.average, 8500);

        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 100, bytes32("c4"));
        ReputationRegistry.ScoreProof memory second = registry.issueScoreProof(alice, 14 days);
        assertGt(second.average, 8500);
        assertEq(second.expiresAt, second.issuedAt + 14 days);

        assertTrue(registry.verifyScoreProof(second));
        assertFalse(registry.verifyScoreProof(first));
    }

    function testRevokeWithdrawsProof() public {
        _giveAliceReputation();
        ReputationRegistry.ScoreProof memory proof = registry.issueScoreProof(alice, 30 days);
        assertTrue(registry.verifyScoreProof(proof));

        registry.revokeScoreProof(alice);
        assertFalse(registry.verifyScoreProof(proof));
        (, bool exists) = registry.scoreProofOf(alice);
        assertFalse(exists);
    }

    function testReissueAfterRevokeWorks() public {
        _giveAliceReputation();
        registry.issueScoreProof(alice, 30 days);
        registry.revokeScoreProof(alice);

        ReputationRegistry.ScoreProof memory proof = registry.issueScoreProof(alice, 7 days);
        assertTrue(registry.verifyScoreProof(proof));
    }

    function testOnlyOwnerCanIssueAndRevoke() public {
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.issueScoreProof(alice, 30 days);

        registry.issueScoreProof(alice, 30 days);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.revokeScoreProof(alice);
        assertTrue(registry.verifyScoreProof(registry.issueScoreProof(alice, 30 days)));
    }

    function testIssueRejectsZeroValidity() public {
        vm.expectRevert(ReputationRegistry.InvalidProofValidity.selector);
        registry.issueScoreProof(alice, 0);
    }

    function testIssueRejectsValidityOverNinetyDays() public {
        vm.expectRevert(ReputationRegistry.InvalidProofValidity.selector);
        registry.issueScoreProof(alice, 91 days);
        // Exactly 90 days is the cap and is allowed.
        registry.issueScoreProof(alice, 90 days);
    }

    function testIssueRejectsZeroAddress() public {
        vm.expectRevert(ReputationRegistry.ZeroAddress.selector);
        registry.issueScoreProof(address(0), 30 days);
    }

    function testRevokeWithoutProofReverts() public {
        vm.expectRevert(ReputationRegistry.NoScoreProof.selector);
        registry.revokeScoreProof(alice);
    }

    function testScoreProofIssuedEvent() public {
        _giveAliceReputation();
        vm.expectEmit(true, false, false, true, address(registry));
        emit ReputationRegistry.ScoreProofIssued(
            alice,
            8500,
            ReputationRegistry.Tier.Established,
            3,
            uint64(block.timestamp),
            uint64(block.timestamp) + 30 days
        );
        registry.issueScoreProof(alice, 30 days);
    }

    function testScoreProofRevokedEvent() public {
        registry.issueScoreProof(alice, 30 days);
        vm.expectEmit(true, false, false, false, address(registry));
        emit ReputationRegistry.ScoreProofRevoked(alice);
        registry.revokeScoreProof(alice);
    }
}
