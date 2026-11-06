// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Dispute escalation: a subject may escalate a dispute the
///         attester ignored for 7 days to the registry owner, who
///         arbitrates it (uphold or concede) on the attester's behalf.
contract DisputeEscalationTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    event DisputeEscalated(
        uint256 indexed id,
        address indexed attester,
        address indexed subject
    );
    event DisputeResolvedByOwner(
        uint256 indexed id,
        address indexed attester,
        address indexed subject,
        bool upheld
    );

    function setUp() public {
        registry = new ReputationRegistry();
    }

    /// @notice bob 90 + carol 100 on alice; alice disputes bob's record.
    ///         Returns bob's attestation id (0).
    function _disputedId() internal returns (uint256) {
        vm.prank(bob);
        uint256 id = registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("v1")
        );
        vm.prank(carol);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            100,
            bytes32("v2")
        );
        assertEq(registry.getScore(alice).average, 9500);
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("unfair"));
        // Only carol's 100 counts while disputed.
        assertEq(registry.getScore(alice).average, 10000);
        return id;
    }

    function testEscalateAfterDelaySetsFlagAndEmitsEvent() public {
        uint256 id = _disputedId();
        assertFalse(registry.isDisputeEscalated(id));

        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true, address(registry));
        emit DisputeEscalated(id, bob, alice);
        vm.prank(alice);
        registry.escalateDispute(id);

        assertTrue(registry.isDisputeEscalated(id));
        assertTrue(registry.attestation(id).escalated);
        assertTrue(registry.attestation(id).disputed);
    }

    function testEscalateTooEarlyReverts() public {
        uint256 id = _disputedId();

        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.EscalationTooEarly.selector);
        registry.escalateDispute(id);

        vm.warp(block.timestamp + 1); // exactly 7 days now
        vm.prank(alice);
        registry.escalateDispute(id);
        assertTrue(registry.isDisputeEscalated(id));
    }

    function testEscalateRequiresOpenDispute() public {
        vm.prank(bob);
        uint256 id = registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32(0)
        );
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotDisputed.selector);
        registry.escalateDispute(id);
    }

    function testEscalateOnlySubject() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotSubject.selector);
        registry.escalateDispute(id);

        vm.prank(dave);
        vm.expectRevert(ReputationRegistry.NotSubject.selector);
        registry.escalateDispute(id);
    }

    function testEscalateTwiceReverts() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AlreadyEscalated.selector);
        registry.escalateDispute(id);
    }

    function testEscalateUnknownIdReverts() public {
        vm.expectRevert(ReputationRegistry.UnknownAttestation.selector);
        registry.escalateDispute(99);
        vm.expectRevert(ReputationRegistry.UnknownAttestation.selector);
        registry.isDisputeEscalated(99);
    }

    function testEscalatedRecordStaysExcludedFromScore() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        // Escalation changes no score: still only carol's 100.
        ReputationRegistry.Score memory s = registry.getScore(alice);
        assertEq(s.average, 10000);
        assertEq(s.count, 1);
    }

    function testEscalationDoesNotRefreshDecayClock() public {
        uint256 id = _disputedId();
        uint64 updatedBefore = registry.attestation(id).updatedAt;
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);
        assertEq(registry.attestation(id).updatedAt, updatedBefore);
    }

    function testAttesterCanStillResolveAfterEscalation() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        registry.resolveDispute(id, true);

        ReputationRegistry.Attestation memory a = registry.attestation(id);
        assertFalse(a.disputed);
        assertFalse(a.escalated);
        assertEq(a.updatedAt, block.timestamp); // uphold refreshes decay
        assertEq(registry.getScore(alice).average, 9500);
    }

    function testAttesterConcedeAfterEscalationRevokes() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        vm.prank(bob);
        registry.resolveDispute(id, false);

        ReputationRegistry.Attestation memory a = registry.attestation(id);
        assertTrue(a.revoked);
        assertFalse(a.disputed);
        assertFalse(a.escalated);
        // Subject can be re-attested after the concede.
        vm.prank(bob);
        uint256 fresh = registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            80,
            bytes32(0)
        );
        assertEq(fresh, 2);
    }

    function testOwnerResolveUpholdRestoresScore() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, true, true, true, address(registry));
        emit DisputeResolvedByOwner(id, bob, alice, true);
        registry.resolveDisputeAsOwner(id, true);

        ReputationRegistry.Attestation memory a = registry.attestation(id);
        assertFalse(a.disputed);
        assertFalse(a.escalated);
        assertEq(a.updatedAt, block.timestamp);
        assertEq(registry.getScore(alice).average, 9500);
    }

    function testOwnerResolveConcedeRevokes() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        vm.expectEmit(true, true, true, true, address(registry));
        emit DisputeResolvedByOwner(id, bob, alice, false);
        registry.resolveDisputeAsOwner(id, false);

        ReputationRegistry.Attestation memory a = registry.attestation(id);
        assertTrue(a.revoked);
        assertFalse(a.disputed);
        assertFalse(a.escalated);
        assertEq(registry.getScore(alice).average, 10000);
        assertEq(registry.getScore(alice).count, 1);

        vm.prank(bob);
        uint256 fresh = registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            80,
            bytes32(0)
        );
        assertEq(fresh, 2);
    }

    function testOwnerResolveRequiresEscalation() public {
        uint256 id = _disputedId();
        vm.expectRevert(ReputationRegistry.NotEscalated.selector);
        registry.resolveDisputeAsOwner(id, true);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);
        registry.resolveDisputeAsOwner(id, true);
        assertFalse(registry.attestation(id).disputed);
    }

    function testOwnerResolveRequiresOpenDispute() public {
        vm.prank(bob);
        uint256 id = registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32(0)
        );
        vm.expectRevert(ReputationRegistry.NotDisputed.selector);
        registry.resolveDisputeAsOwner(id, true);
    }

    function testOwnerResolveOnlyOwner() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.resolveDisputeAsOwner(id, true);

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.resolveDisputeAsOwner(id, true);
    }

    function testOwnerResolveUnknownIdReverts() public {
        vm.expectRevert(ReputationRegistry.UnknownAttestation.selector);
        registry.resolveDisputeAsOwner(99, true);
    }

    function testOwnerResolveAfterAttesterResolvedReverts() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);
        vm.prank(bob);
        registry.resolveDispute(id, true);

        vm.expectRevert(ReputationRegistry.NotDisputed.selector);
        registry.resolveDisputeAsOwner(id, true);
    }

    function testExpireDisputeClearsEscalation() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        vm.warp(block.timestamp + 23 days); // 30 days since the dispute
        vm.prank(alice);
        registry.expireDispute(id);

        ReputationRegistry.Attestation memory a = registry.attestation(id);
        assertFalse(a.disputed);
        assertFalse(a.escalated);
        assertEq(registry.getScore(alice).average, 9500);
    }

    function testRevokeClearsEscalation() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        vm.prank(bob);
        registry.revokeAttestation(id);

        ReputationRegistry.Attestation memory a = registry.attestation(id);
        assertTrue(a.revoked);
        assertFalse(a.disputed);
        assertFalse(a.escalated);
    }

    function testReAttestStillBlockedWhileEscalated() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AlreadyDisputed.selector);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            95,
            bytes32(0)
        );
        assertEq(id, 0);
    }

    function testEscalationAndOwnerResolveWorkWhilePaused() public {
        uint256 id = _disputedId();
        registry.pause();

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);
        assertTrue(registry.isDisputeEscalated(id));

        registry.resolveDisputeAsOwner(id, true);
        assertFalse(registry.attestation(id).disputed);
        assertEq(registry.getScore(alice).average, 9500);
    }

    function testEscalatedSubjectLeavesLeaderboardUntilResolved() public {
        vm.prank(bob);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32(0)
        );
        assertEq(registry.getLeaderboard(10).length, 1);

        vm.prank(alice);
        registry.disputeAttestation(0, bytes32("unfair"));
        assertEq(registry.getLeaderboard(10).length, 0);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(0);
        assertEq(registry.getLeaderboard(10).length, 0);

        registry.resolveDisputeAsOwner(0, true);
        assertEq(registry.getLeaderboard(10).length, 1);
        assertEq(registry.getLeaderboard(10)[0].average, 9000);
    }

    function testEscalationRecordsNoSnapshot() public {
        uint256 id = _disputedId();
        uint256 before = registry.scoreHistoryLength(
            alice,
            ReputationRegistry.Category.Overall
        );
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);
        assertEq(
            registry.scoreHistoryLength(
                alice,
                ReputationRegistry.Category.Overall
            ),
            before
        );
    }

    function testOwnerResolutionRecordsSnapshot() public {
        uint256 id = _disputedId();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);
        registry.resolveDisputeAsOwner(id, true);

        (ReputationRegistry.ScoreSnapshot memory latest, bool exists) = registry
            .latestScoreSnapshot(
                alice,
                ReputationRegistry.Category.Overall
            );
        assertTrue(exists);
        assertEq(latest.average, 9500);
        assertEq(latest.count, 2);
    }
}
