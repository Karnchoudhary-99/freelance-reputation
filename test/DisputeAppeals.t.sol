// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Dispute appeals: after a dispute is resolved by upholding the
///         attestation, the subject gets one appeal within 7 days, and
///         the owner arbitrates it. While appealed the record counts
///         toward no score, exactly like a disputed one.
contract DisputeAppealsTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    event AppealRaised(
        uint256 indexed id,
        address indexed attester,
        address indexed subject
    );
    event AppealResolved(
        uint256 indexed id,
        address indexed attester,
        address indexed subject,
        bool upheld
    );

    function setUp() public {
        registry = new ReputationRegistry();
    }

    /// @notice bob 90 + carol 100 on alice; alice disputes bob's record
    ///         and bob upholds it. Returns bob's attestation id (0).
    function _upheldId() internal returns (uint256) {
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
        assertEq(registry.getScore(alice).average, 10000);
        vm.prank(bob);
        registry.resolveDispute(id, true);
        assertEq(registry.getScore(alice).average, 9500);
        return id;
    }

    function testAppealAfterUpholdExcludesScoreAndEmitsEvent() public {
        uint256 id = _upheldId();
        assertEq(registry.appealDeadline(id), block.timestamp + 7 days);
        assertFalse(registry.isAppealed(id));

        vm.expectEmit(true, true, true, true, address(registry));
        emit AppealRaised(id, bob, alice);
        vm.prank(alice);
        registry.appealDispute(id);

        assertTrue(registry.isAppealed(id));
        assertTrue(registry.attestation(id).appealed);
        assertTrue(registry.attestation(id).appealUsed);
        assertEq(registry.appealDeadline(id), 0);
        // Only carol's 100 counts while appealed.
        assertEq(registry.getScore(alice).average, 10000);
        assertEq(registry.getScore(alice).count, 1);
    }

    function testResolveAppealUpholdRestoresScore() public {
        uint256 id = _upheldId();
        vm.prank(alice);
        registry.appealDispute(id);

        vm.expectEmit(true, true, true, true, address(registry));
        emit AppealResolved(id, bob, alice, true);
        registry.resolveAppeal(id, true);

        assertFalse(registry.isAppealed(id));
        assertEq(registry.getScore(alice).average, 9500);
        assertEq(registry.getScore(alice).count, 2);
    }

    function testResolveAppealConcedeRevokes() public {
        uint256 id = _upheldId();
        vm.prank(alice);
        registry.appealDispute(id);

        vm.expectEmit(true, true, true, true, address(registry));
        emit AppealResolved(id, bob, alice, false);
        registry.resolveAppeal(id, false);

        assertFalse(registry.isAppealed(id));
        assertTrue(registry.attestation(id).revoked);
        assertEq(registry.getScore(alice).average, 10000);
        assertEq(registry.getScore(alice).count, 1);
        // The subject can be re-attested in the freed slot.
        vm.prank(bob);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            80,
            bytes32("v3")
        );
        assertEq(registry.getScore(alice).count, 2);
    }

    function testAppealOnlySubject() public {
        uint256 id = _upheldId();

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotSubject.selector);
        registry.appealDispute(id);

        vm.prank(dave);
        vm.expectRevert(ReputationRegistry.NotSubject.selector);
        registry.appealDispute(id);
    }

    function testAppealRequiresUpheldResolution() public {
        // Never disputed at all: nothing to appeal.
        vm.prank(bob);
        uint256 id = registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("v1")
        );
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotAppealable.selector);
        registry.appealDispute(id);

        // Disputed but not yet resolved: appeal is the wrong tool.
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("unfair"));
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AlreadyDisputed.selector);
        registry.appealDispute(id);
    }

    function testAppealAfterConcedeReverts() public {
        vm.prank(bob);
        uint256 id = registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("v1")
        );
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("unfair"));
        vm.prank(bob);
        registry.resolveDispute(id, false);

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AlreadyRevoked.selector);
        registry.appealDispute(id);
    }

    function testAppealAfterDisputeExpiryReverts() public {
        vm.prank(bob);
        uint256 id = registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("v1")
        );
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("unfair"));
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        registry.expireDispute(id);

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotAppealable.selector);
        registry.appealDispute(id);
    }

    function testAppealWindowExpires() public {
        uint256 id = _upheldId();

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.appealDispute(id);
        assertTrue(registry.isAppealed(id));
    }

    function testAppealAfterWindowReverts() public {
        uint256 id = _upheldId();

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AppealWindowExpired.selector);
        registry.appealDispute(id);
    }

    function testAppealTwiceReverts() public {
        uint256 id = _upheldId();
        vm.prank(alice);
        registry.appealDispute(id);

        // While the appeal is open.
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AlreadyAppealed.selector);
        registry.appealDispute(id);

        // After the appeal is arbitrated: one appeal per outcome.
        registry.resolveAppeal(id, true);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotAppealable.selector);
        registry.appealDispute(id);
    }

    function testResolveAppealOnlyOwner() public {
        uint256 id = _upheldId();
        vm.prank(alice);
        registry.appealDispute(id);

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.resolveAppeal(id, true);

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.resolveAppeal(id, true);
    }

    function testResolveAppealRequiresOpenAppeal() public {
        uint256 id = _upheldId();
        vm.expectRevert(ReputationRegistry.NotAppealed.selector);
        registry.resolveAppeal(id, true);
    }

    function testOwnerResolvedDisputeIsAppealable() public {
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
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("unfair"));
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        registry.escalateDispute(id);
        registry.resolveDisputeAsOwner(id, true);
        assertEq(registry.getScore(alice).average, 9500);

        vm.prank(alice);
        registry.appealDispute(id);
        assertEq(registry.getScore(alice).average, 10000);
        registry.resolveAppeal(id, false);
        assertTrue(registry.attestation(id).revoked);
    }

    function testFreshDisputeResetsAppealRight() public {
        uint256 id = _upheldId();
        vm.prank(alice);
        registry.appealDispute(id);
        registry.resolveAppeal(id, true);

        // A new dispute on the same record gets a new appeal.
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("again"));
        vm.prank(bob);
        registry.resolveDispute(id, true);

        vm.prank(alice);
        registry.appealDispute(id);
        assertTrue(registry.isAppealed(id));
    }

    function testAppealExcludesFromLeaderboardAndStats() public {
        uint256 id = _upheldId();
        ReputationRegistry.LeaderboardEntry[] memory board = registry
            .getLeaderboard(10);
        assertEq(board.length, 1);
        assertEq(board[0].subject, alice);

        vm.prank(alice);
        registry.appealDispute(id);

        // Only carol's 100 remains, so alice still boards — but the
        // appealed record no longer counts in the attester stats.
        ReputationRegistry.AttesterStats memory stats = registry
            .attesterStats(bob);
        assertEq(stats.active, 0);
        assertEq(stats.disputed, 1);
        assertEq(registry.getTopAttesters(10).length, 1); // carol only
        assertEq(registry.getTopAttesters(10)[0].attester, carol);
    }

    function testAppealRecordsSnapshots() public {
        uint256 id = _upheldId();
        uint256 before = registry.scoreHistoryLength(
            alice,
            ReputationRegistry.Category.Overall
        );

        vm.prank(alice);
        registry.appealDispute(id);
        assertEq(
            registry.scoreHistoryLength(
                alice,
                ReputationRegistry.Category.Overall
            ),
            before + 1
        );
        // Latest frozen snapshot shows the exclusion.
        (uint64 ts, uint256 avg, uint256 count, ) = _latest(alice);
        assertEq(avg, 10000);
        assertEq(count, 1);
        assertEq(ts, block.timestamp);

        registry.resolveAppeal(id, true);
        assertEq(
            registry.scoreHistoryLength(
                alice,
                ReputationRegistry.Category.Overall
            ),
            before + 2
        );
        (, avg, count, ) = _latest(alice);
        assertEq(avg, 9500);
        assertEq(count, 2);
    }

    function testDisputeWhileAppealedReverts() public {
        uint256 id = _upheldId();
        vm.prank(alice);
        registry.appealDispute(id);

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AlreadyAppealed.selector);
        registry.disputeAttestation(id, bytes32("again"));

        // Once the appeal is arbitrated, disputing works again.
        registry.resolveAppeal(id, true);
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("again"));
        assertTrue(registry.attestation(id).disputed);
    }

    function testReattestWhileAppealedReverts() public {
        uint256 id = _upheldId();
        vm.prank(alice);
        registry.appealDispute(id);

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AlreadyAppealed.selector);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            95,
            bytes32("v2")
        );

        // Once the appeal is arbitrated, re-attesting works again.
        registry.resolveAppeal(id, true);
        vm.prank(bob);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            95,
            bytes32("v2")
        );
        assertEq(registry.getScore(alice).average, 9750);
    }

    function testAppealBondUpholdPaysAttester() public {
        registry.setDisputeBond(0.1 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        uint256 id = _upheldIdWithBond();
        // Dispute bond went to bob on the upheld resolution.
        assertEq(bob.balance, 10.1 ether);
        assertEq(alice.balance, 9.9 ether);

        vm.prank(alice);
        registry.appealDispute{value: 0.1 ether}(id);
        assertEq(alice.balance, 9.8 ether);

        registry.resolveAppeal(id, true);
        // Appeal upheld: the new bond goes to the attester too.
        assertEq(bob.balance, 10.2 ether);
        assertEq(alice.balance, 9.8 ether);
        assertEq(address(registry).balance, 0);
    }

    function testAppealBondConcedeRefundsSubject() public {
        registry.setDisputeBond(0.1 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        uint256 id = _upheldIdWithBond();
        assertEq(bob.balance, 10.1 ether);

        vm.prank(alice);
        registry.appealDispute{value: 0.1 ether}(id);
        registry.resolveAppeal(id, false);
        // Appeal conceded: the bond comes back to the subject.
        assertEq(alice.balance, 9.9 ether);
        assertEq(bob.balance, 10.1 ether);
        assertEq(address(registry).balance, 0);
    }

    function testAppealRequiresExactBond() public {
        registry.setDisputeBond(0.1 ether);
        vm.deal(alice, 10 ether);
        uint256 id = _upheldIdWithBond();

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.IncorrectDisputeBond.selector);
        registry.appealDispute(id);

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.IncorrectDisputeBond.selector);
        registry.appealDispute{value: 0.05 ether}(id);
    }

    function testAppealWhilePaused() public {
        uint256 id = _upheldId();
        registry.pause();

        vm.prank(alice);
        registry.appealDispute(id);
        assertTrue(registry.isAppealed(id));
        registry.resolveAppeal(id, true);
        assertFalse(registry.isAppealed(id));
        assertEq(registry.getScore(alice).average, 9500);
    }

    function testAppealOnExpiredRecordReverts() public {
        // Shrink expiry so the record fades inside the appeal window.
        registry.setExpiryDuration(1 days);
        uint256 id = _upheldId();
        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.AttestationExpired.selector);
        registry.appealDispute(id);
    }

    function testAppealRefreshesDecayOnUphold() public {
        vm.prank(bob);
        uint256 id = registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32("v1")
        );
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("unfair"));
        vm.prank(bob);
        registry.resolveDispute(id, true);
        vm.prank(alice);
        registry.appealDispute(id);

        // Age 200 days while the appeal is open, then arbitrate.
        vm.warp(block.timestamp + 200 days);
        registry.resolveAppeal(id, true);
        // Upholding the appeal re-confirms: the decay clock restarts
        // at the arbitration, so the record counts at full weight
        // (10000 bps) instead of the 200-day half weight (5000).
        assertEq(registry.getScore(alice).average, 9000);
        assertEq(registry.getScore(alice).effectiveWeight, 10000);
    }

    /// @notice Same as _upheldId but with the dispute bond posted, so
    ///         the caller can assert on balances afterwards.
    function _upheldIdWithBond() internal returns (uint256) {
        uint256 bond = registry.disputeBond();
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
        vm.prank(alice);
        registry.disputeAttestation{value: bond}(id, bytes32("unfair"));
        vm.prank(bob);
        registry.resolveDispute(id, true);
        return id;
    }

    function _latest(
        address subject
    ) internal view returns (uint64, uint256, uint256, uint256) {
        (
            ReputationRegistry.ScoreSnapshot memory s,
            bool exists
        ) = registry.latestScoreSnapshot(
                subject,
                ReputationRegistry.Category.Overall
            );
        assertTrue(exists);
        return (s.timestamp, s.average, s.count, s.effectiveWeight);
    }
}
