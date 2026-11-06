// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract GovernanceTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    uint256 bobKey = 0xB0B;
    address bobSigner;

    function setUp() public {
        registry = new ReputationRegistry();
        bobSigner = vm.addr(bobKey);
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

    function testPauseSetsFlagAndEmitsEvent() public {
        assertFalse(registry.paused());
        vm.expectEmit(true, false, false, false, address(registry));
        emit ReputationRegistry.Paused(address(this));
        registry.pause();
        assertTrue(registry.paused());

        vm.expectEmit(true, false, false, false, address(registry));
        emit ReputationRegistry.Unpaused(address(this));
        registry.unpause();
        assertFalse(registry.paused());
    }

    function testOnlyOwnerCanPauseAndUnpause() public {
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.pause();
        assertFalse(registry.paused());

        registry.pause();
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.unpause();
        assertTrue(registry.paused());
    }

    function testDoublePauseRevertsAndUnpauseWhenNotPausedReverts() public {
        registry.pause();
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.pause();

        registry.unpause();
        vm.expectRevert(ReputationRegistry.RegistryNotPaused.selector);
        registry.unpause();
    }

    function testAttestAndReattestBlockedWhilePaused() public {
        vm.prank(carol);
        registry.attest(bob, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        assertEq(registry.getScore(bob).average, 8000);

        registry.pause();
        vm.prank(dave);
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.attest(bob, ReputationRegistry.Category.Quality, 90, bytes32("c2"));
        // Re-attesting an existing record is blocked too.
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.attest(bob, ReputationRegistry.Category.Overall, 70, bytes32("c3"));
        assertEq(registry.attestationCount(), 1);
        assertEq(registry.getScore(bob).average, 8000);
    }

    function testBatchBlockedWhilePaused() public {
        registry.pause();
        ReputationRegistry.AttestInput[] memory inputs = new ReputationRegistry.AttestInput[](1);
        inputs[0] = ReputationRegistry.AttestInput({
            subject: bob,
            category: ReputationRegistry.Category.Overall,
            score: 80,
            commentHash: bytes32("c1")
        });
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.attestBatch(inputs);
        assertEq(registry.attestationCount(), 0);
    }

    function testSignedAttestBlockedWhilePaused() public {
        registry.pause();
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            bobKey, bobSigner, alice, ReputationRegistry.Category.Overall, 88, bytes32("c1"), 0, deadline
        );
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.attestBySignature(
            bobSigner, alice, ReputationRegistry.Category.Overall, 88, bytes32("c1"), deadline, v, r, s
        );
        // The revert rolls the nonce increment back: nothing was consumed.
        assertEq(registry.nonces(bobSigner), 0);
        assertEq(registry.attestationCount(), 0);
    }

    function testSetEvidenceBlockedWhilePaused() public {
        vm.prank(carol);
        uint256 id = registry.attestWithEvidence(
            bob, ReputationRegistry.Category.Overall, 80, bytes32("c1"), bytes32("e1")
        );
        registry.pause();
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.setEvidence(id, bytes32("e2"));
        assertEq(registry.attestation(id).evidenceHash, bytes32("e1"));
    }

    function testIssueScoreProofBlockedWhilePaused() public {
        vm.prank(carol);
        registry.attest(bob, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        registry.pause();
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.issueScoreProof(bob, 30 days);
        (, bool exists) = registry.scoreProofOf(bob);
        assertFalse(exists);
    }

    function testRevokeStillWorksWhilePaused() public {
        vm.prank(carol);
        uint256 id = registry.attest(bob, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        registry.pause();
        vm.prank(carol);
        registry.revokeAttestation(id);
        assertTrue(registry.attestation(id).revoked);
        assertEq(registry.getScore(bob).count, 0);
    }

    function testDisputeLifecycleStillWorksWhilePaused() public {
        vm.prank(carol);
        uint256 id = registry.attest(bob, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        registry.pause();

        vm.prank(bob);
        registry.disputeAttestation(id, bytes32("r1"));
        assertTrue(registry.attestation(id).disputed);
        assertEq(registry.getScore(bob).count, 0);

        vm.prank(carol);
        registry.resolveDispute(id, true);
        assertFalse(registry.attestation(id).disputed);
        assertEq(registry.getScore(bob).average, 8000);

        // A second dispute, left unanswered, can still expire while paused.
        vm.prank(bob);
        registry.disputeAttestation(id, bytes32("r2"));
        vm.warp(block.timestamp + 31 days);
        vm.prank(bob);
        registry.expireDispute(id);
        assertFalse(registry.attestation(id).disputed);
        assertEq(registry.getScore(bob).average, 8000);
    }

    function testReadsStillWorkWhilePaused() public {
        vm.prank(carol);
        registry.attest(bob, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        vm.prank(dave);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c2"));
        registry.pause();

        assertEq(registry.getScore(bob).average, 8000);
        // Count 1 is below the Established threshold (3), so Emerging.
        assertEq(uint256(registry.tierOf(bob)), uint256(ReputationRegistry.Tier.Emerging));
        ReputationRegistry.LeaderboardEntry[] memory board = registry.getLeaderboard(10);
        assertEq(board.length, 2);
        assertEq(board[0].subject, alice);
    }

    function testOwnerAdminStillWorksWhilePaused() public {
        registry.pause();
        registry.setVerifiedAttester(carol, true);
        assertTrue(registry.isVerifiedAttester(carol));
        registry.strikeAttester(dave);
        assertEq(registry.strikes(dave), 1);
        registry.setExpiryDuration(365 days);
        assertEq(registry.expiryDuration(), 365 days);
    }

    function testUnpauseResumesAttestingWithScoresIntact() public {
        vm.prank(carol);
        registry.attest(bob, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        registry.pause();
        registry.unpause();
        vm.prank(dave);
        registry.attest(bob, ReputationRegistry.Category.Quality, 90, bytes32("c2"));
        assertEq(registry.attestationCount(), 2);
        assertEq(registry.getScore(bob).count, 2);
    }
}
