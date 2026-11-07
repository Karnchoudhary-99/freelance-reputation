// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Time-windowed leaderboards: `getLeaderboardAt` and
///         `getLeaderboardByCategoryAt` rebuild the board for any
///         past or future moment from the decay-preview scores, so a
///         ranking can flip as old endorsements decay — and flip back
///         when they all settle at quarter weight.
contract LeaderboardAtTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");
    address gail = makeAddr("gail");
    address heidi = makeAddr("heidi");

    // Fixed base time so warps read like calendar dates.
    uint64 constant T0 = 1_700_000_000;

    function setUp() public {
        registry = new ReputationRegistry();
        vm.warp(T0);
        // Alice: 100 from bob at T0, then 60 from carol 300 days
        // later. Dave: a single 75 from bob at T0. Frank: five 90s
        // across categories at T0, then a 0 from heidi 300 days
        // later — his average falls from 9000 to 7200 and his tier
        // drops from Trusted to Emerging. (Attester weights matter
        // here: alice weighs 3 and dave 2, so Frank's five 90s do
        // not blend evenly — the 0 lands at full weight against
        // half-weight 90s.)
        _attest(
            bob,
            alice,
            ReputationRegistry.Category.Overall,
            100
        );
        _attest(
            bob,
            dave,
            ReputationRegistry.Category.Overall,
            75
        );
        _attest(
            bob,
            frank,
            ReputationRegistry.Category.Overall,
            90
        );
        _attest(
            carol,
            frank,
            ReputationRegistry.Category.Quality,
            90
        );
        _attest(
            dave,
            frank,
            ReputationRegistry.Category.Communication,
            90
        );
        _attest(
            alice,
            frank,
            ReputationRegistry.Category.Timeliness,
            90
        );
        _attest(
            erin,
            frank,
            ReputationRegistry.Category.Reliability,
            90
        );
        vm.warp(T0 + 300 days);
        _attest(
            carol,
            alice,
            ReputationRegistry.Category.Overall,
            60
        );
        _attest(
            heidi,
            frank,
            ReputationRegistry.Category.Overall,
            0
        );
    }

    function _attest(
        address attester,
        address subject,
        ReputationRegistry.Category category,
        uint8 score
    ) internal {
        vm.prank(attester);
        registry.attest(subject, category, score, bytes32(0));
    }

    function testLeaderboardAtNowEqualsLeaderboard() public view {
        // At the current time the preview board is the live board.
        ReputationRegistry.LeaderboardEntry[]
            memory live = registry.getLeaderboard(10);
        ReputationRegistry.LeaderboardEntry[]
            memory preview = registry.getLeaderboardAt(
                uint64(block.timestamp),
                10
            );
        assertEq(live.length, preview.length);
        for (uint256 i = 0; i < live.length; i++) {
            assertEq(live[i].subject, preview[i].subject);
            assertEq(live[i].average, preview[i].average);
            assertEq(live[i].count, preview[i].count);
            assertEq(uint256(live[i].tier), uint256(preview[i].tier));
        }
    }

    function testRankingFlipsOverTime() public view {
        // At T0+100d Alice holds a single fresh 100, Dave a 75:
        // Alice leads.
        ReputationRegistry.LeaderboardEntry[]
            memory early = registry.getLeaderboardAt(T0 + 100 days, 10);
        assertEq(early.length, 3);
        assertEq(early[0].subject, alice);
        assertEq(early[0].average, 10000);
        assertEq(early[0].count, 1);
        assertEq(early[1].subject, frank);
        assertEq(early[1].average, 9000);
        assertEq(early[1].count, 5);
        assertEq(early[2].subject, dave);
        assertEq(early[2].average, 7500);

        // At T0+300d carol's 60 has landed on Alice (her 100 is now
        // half-weight, the 60 full-weight: 73.33), so Dave's steady
        // 75 passes her — and heidi's 0 drags Frank from 9000 to
        // 7200 (his 90s are half-weight, the 0 full-weight, and
        // alice's weight-3 90 counts triple), so he falls to last.
        ReputationRegistry.LeaderboardEntry[]
            memory mid = registry.getLeaderboardAt(T0 + 300 days, 10);
        assertEq(mid.length, 3);
        assertEq(mid[0].subject, dave);
        assertEq(mid[0].average, 7500);
        assertEq(mid[1].subject, alice);
        assertEq(mid[1].average, 7333);
        assertEq(mid[1].count, 2);
        assertEq(mid[2].subject, frank);
        assertEq(mid[2].average, 7200);
        assertEq(mid[2].count, 6);
    }

    function testLeaderboardAtBeforeAnyAttestationIsEmpty() public view {
        // A moment before the first attestation existed: no board.
        ReputationRegistry.LeaderboardEntry[]
            memory board = registry.getLeaderboardAt(T0 - 1, 10);
        assertEq(board.length, 0);
    }

    function testLeaderboardAtFuturePreviewTieBreak() public view {
        // At T0+700d both of Alice's records sit at quarter weight,
        // so her average is back to the plain blend (100+60)/2 = 80;
        // Frank's five 90s and heidi's 0 are all quarter-weight too,
        // so his average is 8000 as well — and the tie breaks on
        // count, 6 attestations over 2.
        ReputationRegistry.LeaderboardEntry[]
            memory future = registry.getLeaderboardAt(T0 + 700 days, 10);
        assertEq(future.length, 3);
        assertEq(future[0].subject, frank);
        assertEq(future[0].average, 8000);
        assertEq(future[0].count, 6);
        assertEq(future[1].subject, alice);
        assertEq(future[1].average, 8000);
        assertEq(future[1].count, 2);
        assertEq(future[2].subject, dave);
        assertEq(future[2].average, 7500);
    }

    function testExpiredRecordsFadeFromFutureBoard() public view {
        // At T0+800d the 730-day expiry has faded out every record
        // last updated at T0: Dave drops off the board entirely, and
        // Alice and Frank keep only the records refreshed at T0+300d
        // (carol's 60 and heidi's 0).
        ReputationRegistry.LeaderboardEntry[]
            memory future = registry.getLeaderboardAt(T0 + 800 days, 10);
        assertEq(future.length, 2);
        assertEq(future[0].subject, alice);
        assertEq(future[0].average, 6000);
        assertEq(future[0].count, 1);
        assertEq(future[1].subject, frank);
        assertEq(future[1].average, 0);
        assertEq(future[1].count, 1);
    }

    function testBoardTierFollowsPreview() public view {
        // Frank: five 90s at T0+100d is Trusted (avg 9000, count 5);
        // after heidi's 0 lands at T0+300d his average is 7200 and
        // he falls to Established — and the board tier matches
        // tierOfAt.
        ReputationRegistry.LeaderboardEntry[]
            memory early = registry.getLeaderboardAt(T0 + 100 days, 10);
        assertEq(
            uint256(early[1].tier),
            uint256(ReputationRegistry.Tier.Trusted)
        );
        assertEq(
            uint256(registry.tierOfAt(frank, T0 + 100 days)),
            uint256(ReputationRegistry.Tier.Trusted)
        );

        ReputationRegistry.LeaderboardEntry[]
            memory mid = registry.getLeaderboardAt(T0 + 300 days, 10);
        assertEq(
            uint256(mid[2].tier),
            uint256(ReputationRegistry.Tier.Established)
        );
        assertEq(
            uint256(registry.tierOfAt(frank, T0 + 300 days)),
            uint256(ReputationRegistry.Tier.Established)
        );
    }
}
