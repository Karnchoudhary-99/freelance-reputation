// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract ScoreHistoryTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function _attest(
        address attester,
        address subject,
        ReputationRegistry.Category category,
        uint8 score
    ) internal returns (uint256) {
        vm.prank(attester);
        return registry.attest(subject, category, score, bytes32(0));
    }

    function testAttestRecordsOneOverallSnapshot() public {
        _attest(bob, alice, ReputationRegistry.Category.Overall, 90);

        assertEq(
            registry.scoreHistoryLength(
                alice,
                ReputationRegistry.Category.Overall
            ),
            1
        );
        ReputationRegistry.ScoreSnapshot[] memory history = registry
            .getScoreHistory(alice, ReputationRegistry.Category.Overall, 0, 10);
        assertEq(history.length, 1);
        assertEq(history[0].average, 9000);
        assertEq(history[0].count, 1);
        assertEq(history[0].effectiveWeight, 10000);
        assertEq(history[0].timestamp, uint64(block.timestamp));
    }

    function testCategoryAttestRecordsBothScopes() public {
        _attest(bob, alice, ReputationRegistry.Category.Quality, 80);

        // Overall history gets the snapshot, and so does Quality...
        assertEq(
            registry.scoreHistoryLength(
                alice,
                ReputationRegistry.Category.Overall
            ),
            1
        );
        assertEq(
            registry.scoreHistoryLength(
                alice,
                ReputationRegistry.Category.Quality
            ),
            1
        );
        // ...but an untouched category stays empty.
        assertEq(
            registry.scoreHistoryLength(
                alice,
                ReputationRegistry.Category.Communication
            ),
            0
        );
        ReputationRegistry.ScoreSnapshot[] memory quality = registry
            .getScoreHistory(alice, ReputationRegistry.Category.Quality, 0, 10);
        assertEq(quality[0].average, 8000);
        assertEq(quality[0].count, 1);
    }

    function testSecondAttestAppendsWithUpdatedAverage() public {
        _attest(bob, alice, ReputationRegistry.Category.Overall, 90);
        _attest(carol, alice, ReputationRegistry.Category.Overall, 70);

        ReputationRegistry.ScoreSnapshot[] memory history = registry
            .getScoreHistory(alice, ReputationRegistry.Category.Overall, 0, 10);
        assertEq(history.length, 2);
        // The first snapshot is frozen: it still shows the score as it
        // stood after the first attestation.
        assertEq(history[0].average, 9000);
        assertEq(history[0].count, 1);
        assertEq(history[1].average, 8000);
        assertEq(history[1].count, 2);
        assertEq(history[1].effectiveWeight, 20000);
    }

    function testReAttestAppendsSnapshot() public {
        _attest(bob, alice, ReputationRegistry.Category.Overall, 60);
        _attest(bob, alice, ReputationRegistry.Category.Overall, 90);

        ReputationRegistry.ScoreSnapshot[] memory history = registry
            .getScoreHistory(alice, ReputationRegistry.Category.Overall, 0, 10);
        assertEq(history.length, 2);
        assertEq(history[0].average, 6000);
        // One active attestation, updated in place.
        assertEq(history[1].average, 9000);
        assertEq(history[1].count, 1);
    }

    function testRevokeAppendsZeroSnapshot() public {
        uint256 id = _attest(
            bob,
            alice,
            ReputationRegistry.Category.Overall,
            90
        );
        vm.prank(bob);
        registry.revokeAttestation(id);

        ReputationRegistry.ScoreSnapshot[] memory history = registry
            .getScoreHistory(alice, ReputationRegistry.Category.Overall, 0, 10);
        assertEq(history.length, 2);
        assertEq(history[1].average, 0);
        assertEq(history[1].count, 0);
        assertEq(history[1].effectiveWeight, 0);
    }

    function testDisputeLifecycleSnapshots() public {
        uint256 id = _attest(
            bob,
            alice,
            ReputationRegistry.Category.Overall,
            90
        );

        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("unfair"));
        ReputationRegistry.ScoreSnapshot[] memory history = registry
            .getScoreHistory(alice, ReputationRegistry.Category.Overall, 0, 10);
        assertEq(history.length, 2);
        assertEq(history[1].average, 0);
        assertEq(history[1].count, 0);

        vm.prank(bob);
        registry.resolveDispute(id, true);
        history = registry.getScoreHistory(
            alice,
            ReputationRegistry.Category.Overall,
            0,
            10
        );
        assertEq(history.length, 3);
        assertEq(history[2].average, 9000);
        assertEq(history[2].count, 1);

        vm.prank(alice);
        registry.disputeAttestation(id, bytes32("still unfair"));
        vm.prank(bob);
        registry.resolveDispute(id, false);
        history = registry.getScoreHistory(
            alice,
            ReputationRegistry.Category.Overall,
            0,
            10
        );
        assertEq(history.length, 5);
        assertEq(history[4].average, 0);
        assertEq(history[4].count, 0);
    }

    function testExpireDisputeAppendsSnapshot() public {
        uint256 id = _attest(
            bob,
            alice,
            ReputationRegistry.Category.Overall,
            90
        );
        vm.prank(alice);
        registry.disputeAttestation(id, bytes32(0));
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        registry.expireDispute(id);

        ReputationRegistry.ScoreSnapshot[] memory history = registry
            .getScoreHistory(alice, ReputationRegistry.Category.Overall, 0, 10);
        assertEq(history.length, 3);
        assertEq(history[2].average, 9000);
        assertEq(history[2].count, 1);
    }

    function testPagination() public {
        _attest(bob, alice, ReputationRegistry.Category.Overall, 90);
        _attest(carol, alice, ReputationRegistry.Category.Overall, 80);
        _attest(dave, alice, ReputationRegistry.Category.Overall, 70);

        // Middle page: offset 1, limit 1.
        ReputationRegistry.ScoreSnapshot[] memory page = registry
            .getScoreHistory(alice, ReputationRegistry.Category.Overall, 1, 1);
        assertEq(page.length, 1);
        assertEq(page[0].average, 8500);
        assertEq(page[0].count, 2);

        // Limit clamps to what remains.
        page = registry.getScoreHistory(
            alice,
            ReputationRegistry.Category.Overall,
            1,
            99
        );
        assertEq(page.length, 2);

        // Offset past the end returns an empty page, not a revert.
        page = registry.getScoreHistory(
            alice,
            ReputationRegistry.Category.Overall,
            3,
            10
        );
        assertEq(page.length, 0);
    }

    function testDecayReflectedInSnapshot() public {
        _attest(bob, alice, ReputationRegistry.Category.Overall, 100);
        // 400 days later bob's attestation is at quarter weight (2500
        // bps); carol's fresh attestation is at full weight (10000 bps).
        vm.warp(block.timestamp + 400 days);
        _attest(carol, alice, ReputationRegistry.Category.Overall, 60);

        ReputationRegistry.ScoreSnapshot[] memory history = registry
            .getScoreHistory(alice, ReputationRegistry.Category.Overall, 0, 10);
        assertEq(history.length, 2);
        // (100 * 2500 + 60 * 10000) * 100 / 12500 == 6800.
        assertEq(history[1].average, 6800);
        assertEq(history[1].count, 2);
        assertEq(history[1].effectiveWeight, 12500);
    }

    function testUnknownSubjectHistoryIsEmpty() public view {
        assertEq(
            registry.scoreHistoryLength(
                alice,
                ReputationRegistry.Category.Overall
            ),
            0
        );
        ReputationRegistry.ScoreSnapshot[] memory history = registry
            .getScoreHistory(alice, ReputationRegistry.Category.Overall, 0, 10);
        assertEq(history.length, 0);
    }
}
