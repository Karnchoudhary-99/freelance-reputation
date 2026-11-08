// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Attester credibility: dispute rulings tracked per attester,
///         exposed as a basis-points score plus the raw counts, and
///         ranked on a board that only lists attesters whose
///         credibility was actually tested.
contract AttesterCredibilityTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function _attest(
        address attester,
        address subject,
        ReputationRegistry.Category category,
        uint8 score
    ) internal returns (uint256 id) {
        vm.prank(attester);
        id = registry.attest(subject, category, score, bytes32(0));
    }

    function _dispute(address subject, uint256 id) internal {
        vm.prank(subject);
        registry.disputeAttestation(id, bytes32("unfair"));
    }

    function _credibility(
        address attester
    )
        internal
        view
        returns (uint256 bps, uint256 upheld, uint256 conceded)
    {
        (bps, upheld, conceded) = registry.attesterCredibility(attester);
    }

    function testFreshAttesterReadsFullCredibility() public view {
        (uint256 bps, uint256 upheld, uint256 conceded) = _credibility(bob);
        // No ruled dispute yet: 10000, and the counts say why.
        assertEq(bps, 10000);
        assertEq(upheld, 0);
        assertEq(conceded, 0);

        ReputationRegistry.AttesterStats memory st = registry.attesterStats(bob);
        assertEq(st.disputesUpheld, 0);
        assertEq(st.disputesConceded, 0);
        assertEq(st.credibilityBps, 10000);

        assertEq(registry.getTopAttestersByCredibility(10).length, 0);
    }

    function testUpholdCountsOnce() public {
        uint256 id = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        _dispute(alice, id);
        vm.prank(bob);
        registry.resolveDispute(id, true);

        (uint256 bps, uint256 upheld, uint256 conceded) = _credibility(bob);
        assertEq(upheld, 1);
        assertEq(conceded, 0);
        assertEq(bps, 10000);
    }

    function testConcedeCountsOnce() public {
        uint256 id = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        _dispute(alice, id);
        vm.prank(bob);
        registry.resolveDispute(id, false);

        (uint256 bps, uint256 upheld, uint256 conceded) = _credibility(bob);
        assertEq(upheld, 0);
        assertEq(conceded, 1);
        assertEq(bps, 0);
    }

    function testMixedOutcomesGiveTwoThirds() public {
        uint256 a = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        uint256 b = _attest(bob, dave, ReputationRegistry.Category.Overall, 90);
        uint256 c = _attest(bob, frank, ReputationRegistry.Category.Overall, 70);
        _dispute(alice, a);
        _dispute(dave, b);
        _dispute(frank, c);
        vm.prank(bob);
        registry.resolveDispute(a, true);
        vm.prank(bob);
        registry.resolveDispute(b, true);
        vm.prank(bob);
        registry.resolveDispute(c, false);

        (uint256 bps, uint256 upheld, uint256 conceded) = _credibility(bob);
        assertEq(upheld, 2);
        assertEq(conceded, 1);
        assertEq(bps, 6666); // 2 * 10000 / 3, integer division
    }

    function testOwnerArbitrationCountsBothWays() public {
        uint256 a = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        uint256 b = _attest(bob, dave, ReputationRegistry.Category.Overall, 90);
        _dispute(alice, a);
        _dispute(dave, b);
        // Escalation opens only after the delay.
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        registry.escalateDispute(a);
        vm.prank(dave);
        registry.escalateDispute(b);
        registry.resolveDisputeAsOwner(a, true);
        registry.resolveDisputeAsOwner(b, false);

        (uint256 bps, uint256 upheld, uint256 conceded) = _credibility(bob);
        assertEq(upheld, 1);
        assertEq(conceded, 1);
        assertEq(bps, 5000);
    }

    function testAppealRulingCountsAsSecondRuling() public {
        uint256 id = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        _dispute(alice, id);
        vm.prank(bob);
        registry.resolveDispute(id, true); // +1 upheld
        vm.prank(alice);
        registry.appealDispute(id);
        registry.resolveAppeal(id, true); // +1 upheld again

        (uint256 bps, uint256 upheld, uint256 conceded) = _credibility(bob);
        assertEq(upheld, 2);
        assertEq(conceded, 0);
        assertEq(bps, 10000);
    }

    function testAppealConcedeCountsAgainstAttester() public {
        uint256 id = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        _dispute(alice, id);
        vm.prank(bob);
        registry.resolveDispute(id, true); // +1 upheld
        vm.prank(alice);
        registry.appealDispute(id);
        registry.resolveAppeal(id, false); // +1 conceded

        (uint256 bps, uint256 upheld, uint256 conceded) = _credibility(bob);
        assertEq(upheld, 1);
        assertEq(conceded, 1);
        assertEq(bps, 5000);
    }

    function testRevokeWhileDisputedCountsAsConcede() public {
        uint256 id = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        _dispute(alice, id);
        vm.prank(bob);
        registry.revokeAttestation(id);

        (uint256 bps, uint256 upheld, uint256 conceded) = _credibility(bob);
        assertEq(upheld, 0);
        assertEq(conceded, 1);
        assertEq(bps, 0);
    }

    function testDisputeExpiryCountsAsNeither() public {
        uint256 id = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        _dispute(alice, id);
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        registry.expireDispute(id);

        (uint256 bps, uint256 upheld, uint256 conceded) = _credibility(bob);
        assertEq(upheld, 0);
        assertEq(conceded, 0);
        assertEq(bps, 10000);
    }

    function testAttesterStatsIncludesCredibility() public {
        uint256 a = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        uint256 b = _attest(bob, dave, ReputationRegistry.Category.Overall, 90);
        _dispute(alice, a);
        _dispute(dave, b);
        vm.prank(bob);
        registry.resolveDispute(a, true);
        vm.prank(bob);
        registry.resolveDispute(b, false);

        ReputationRegistry.AttesterStats memory st = registry.attesterStats(bob);
        assertEq(st.given, 2);
        assertEq(st.active, 1); // the upheld record counts again
        assertEq(st.revoked, 1); // the conceded record was revoked
        assertEq(st.disputesUpheld, 1);
        assertEq(st.disputesConceded, 1);
        assertEq(st.credibilityBps, 5000);
    }

    function testCredibilityBoardOrderingAndLimits() public {
        // bob: 2 upheld, 0 conceded -> 10000.
        uint256 b1 = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        uint256 b2 = _attest(bob, dave, ReputationRegistry.Category.Overall, 90);
        _dispute(alice, b1);
        _dispute(dave, b2);
        vm.prank(bob);
        registry.resolveDispute(b1, true);
        vm.prank(bob);
        registry.resolveDispute(b2, true);
        // carol: 1 upheld, 1 conceded -> 5000.
        uint256 c1 = _attest(carol, alice, ReputationRegistry.Category.Communication, 80);
        uint256 c2 = _attest(carol, dave, ReputationRegistry.Category.Communication, 70);
        _dispute(alice, c1);
        _dispute(dave, c2);
        vm.prank(carol);
        registry.resolveDispute(c1, true);
        vm.prank(carol);
        registry.resolveDispute(c2, false);
        // erin: 0 upheld, 1 conceded -> 0.
        uint256 e1 = _attest(erin, alice, ReputationRegistry.Category.Timeliness, 60);
        _dispute(alice, e1);
        vm.prank(erin);
        registry.resolveDispute(e1, false);
        // dave attested once and was never disputed: no rulings, so
        // he must not appear on the board at all.
        _attest(dave, alice, ReputationRegistry.Category.Quality, 70);

        ReputationRegistry.AttesterCredibilityEntry[] memory board =
            registry.getTopAttestersByCredibility(10);
        assertEq(board.length, 3);
        assertEq(board[0].attester, bob);
        assertEq(board[0].credibilityBps, 10000);
        assertEq(board[0].upheld, 2);
        assertEq(board[0].conceded, 0);
        assertEq(board[1].attester, carol);
        assertEq(board[1].credibilityBps, 5000);
        assertEq(board[1].upheld, 1);
        assertEq(board[1].conceded, 1);
        assertEq(board[2].attester, erin);
        assertEq(board[2].credibilityBps, 0);
        assertEq(board[2].upheld, 0);
        assertEq(board[2].conceded, 1);

        board = registry.getTopAttestersByCredibility(2);
        assertEq(board.length, 2);
        assertEq(board[0].attester, bob);
        assertEq(board[1].attester, carol);

        board = registry.getTopAttestersByCredibility(0);
        assertEq(board.length, 0);
    }

    function testCredibilityBoardTieBreaksByUpheldThenFirstSeen() public {
        // bob: 2 upheld / 2 conceded -> 5000.
        // carol: 1 upheld / 1 conceded -> 5000, seen after bob.
        // erin: 1 upheld / 1 conceded -> 5000, seen after carol.
        // Same credibility: more upheld rulings first, then first-seen.
        uint256 b1 = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        uint256 b2 = _attest(bob, dave, ReputationRegistry.Category.Overall, 90);
        uint256 b3 = _attest(bob, frank, ReputationRegistry.Category.Overall, 70);
        uint256 b4 = _attest(bob, alice, ReputationRegistry.Category.Quality, 80);
        _dispute(alice, b1);
        _dispute(dave, b2);
        _dispute(frank, b3);
        _dispute(alice, b4);
        vm.prank(bob);
        registry.resolveDispute(b1, true);
        vm.prank(bob);
        registry.resolveDispute(b2, true);
        vm.prank(bob);
        registry.resolveDispute(b3, false);
        vm.prank(bob);
        registry.resolveDispute(b4, false);

        uint256 c1 = _attest(carol, alice, ReputationRegistry.Category.Communication, 80);
        uint256 c2 = _attest(carol, dave, ReputationRegistry.Category.Communication, 70);
        _dispute(alice, c1);
        _dispute(dave, c2);
        vm.prank(carol);
        registry.resolveDispute(c1, true);
        vm.prank(carol);
        registry.resolveDispute(c2, false);

        uint256 e1 = _attest(erin, alice, ReputationRegistry.Category.Timeliness, 80);
        uint256 e2 = _attest(erin, dave, ReputationRegistry.Category.Timeliness, 70);
        _dispute(alice, e1);
        _dispute(dave, e2);
        vm.prank(erin);
        registry.resolveDispute(e1, true);
        vm.prank(erin);
        registry.resolveDispute(e2, false);

        ReputationRegistry.AttesterCredibilityEntry[] memory board =
            registry.getTopAttestersByCredibility(10);
        assertEq(board.length, 3);
        assertEq(board[0].attester, bob); // 2 upheld beats 1
        assertEq(board[1].attester, carol); // same counts as erin, seen first
        assertEq(board[2].attester, erin);
    }

    function testCredibilityUpdatesWhilePaused() public {
        uint256 id = _attest(bob, alice, ReputationRegistry.Category.Overall, 80);
        _dispute(alice, id);
        // The test contract deployed the registry, so it is the owner.
        registry.pause();
        // Dispute exits stay open while paused.
        vm.prank(bob);
        registry.resolveDispute(id, true);

        (uint256 bps, uint256 upheld, uint256 conceded) = _credibility(bob);
        assertEq(upheld, 1);
        assertEq(conceded, 0);
        assertEq(bps, 10000);
    }
}
