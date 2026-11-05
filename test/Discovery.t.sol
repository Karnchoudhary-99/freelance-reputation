// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract DiscoveryTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        registry = new ReputationRegistry();
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

    function testCategoryLeaderboardRankingAndTieBreak() public {
        // Carol beats alice on the count tie-break at equal Quality
        // average; bob trails. Alice also holds a top Overall score,
        // which must NOT leak into the Quality ranking.
        _attest(makeAddr("a1"), alice, ReputationRegistry.Category.Quality, 90);
        _attest(makeAddr("a2"), alice, ReputationRegistry.Category.Overall, 100);
        _attest(makeAddr("a3"), bob, ReputationRegistry.Category.Quality, 70);
        _attest(makeAddr("a4"), carol, ReputationRegistry.Category.Quality, 90);
        _attest(makeAddr("a5"), carol, ReputationRegistry.Category.Quality, 90);

        ReputationRegistry.LeaderboardEntry[] memory top = registry
            .getLeaderboardByCategory(
                ReputationRegistry.Category.Quality,
                2
            );
        assertEq(top.length, 2);
        assertEq(top[0].subject, carol);
        assertEq(top[0].average, 9000);
        assertEq(top[0].count, 2);
        assertEq(top[1].subject, alice);
        assertEq(top[1].average, 9000);
        assertEq(top[1].count, 1);

        // A limit larger than the ranked set returns the whole set.
        ReputationRegistry.LeaderboardEntry[] memory all = registry
            .getLeaderboardByCategory(
                ReputationRegistry.Category.Quality,
                100
            );
        assertEq(all.length, 3);
        assertEq(all[2].subject, bob);
    }

    function testCategoryLeaderboardExclusionsAndLimits() public {
        // Alice has only Overall attestations: present on the overall
        // board, absent from the Quality board.
        _attest(makeAddr("a1"), alice, ReputationRegistry.Category.Overall, 100);
        // Bob's only Quality attestation is revoked; carol's is disputed.
        _attest(makeAddr("a2"), bob, ReputationRegistry.Category.Quality, 80);
        vm.prank(makeAddr("a2"));
        registry.revokeAttestation(1);
        _attest(makeAddr("a3"), carol, ReputationRegistry.Category.Quality, 95);
        vm.prank(carol);
        registry.disputeAttestation(2, bytes32(uint256(1)));

        ReputationRegistry.LeaderboardEntry[] memory board = registry
            .getLeaderboardByCategory(
                ReputationRegistry.Category.Quality,
                10
            );
        assertEq(board.length, 0);
        // Limit 0 returns an empty array, not the whole board.
        assertEq(
            registry
                .getLeaderboardByCategory(
                    ReputationRegistry.Category.Quality,
                    0
                )
                .length,
            0
        );
        assertEq(registry.getLeaderboard(10).length, 1);
        assertEq(registry.getLeaderboard(10)[0].subject, alice);
    }

    function testCategoryBoardTierIsOverallTier() public {
        // Eve has ten Quality 90s (category Elite on its own) plus one
        // Overall 0, so her OVERALL average is 8181 with count 11:
        // Trusted, not Elite. The category row must carry Trusted.
        address eve = makeAddr("eve");
        for (uint256 i = 0; i < 10; i++) {
            _attest(
                makeAddr(string(abi.encodePacked("q", i))),
                eve,
                ReputationRegistry.Category.Quality,
                90
            );
        }
        _attest(
            makeAddr("overall-attester"),
            eve,
            ReputationRegistry.Category.Overall,
            0
        );
        assertEq(
            uint256(registry.tierOf(eve)),
            uint256(ReputationRegistry.Tier.Trusted)
        );
        ReputationRegistry.LeaderboardEntry[] memory board = registry
            .getLeaderboardByCategory(
                ReputationRegistry.Category.Quality,
                10
            );
        assertEq(board.length, 1);
        assertEq(board[0].average, 9000);
        assertEq(board[0].count, 10);
        assertEq(
            uint256(board[0].tier),
            uint256(ReputationRegistry.Tier.Trusted)
        );
    }

    function testOverallCategoryBoardMatchesOverallBoard() public {
        _attest(makeAddr("a1"), alice, ReputationRegistry.Category.Quality, 90);
        _attest(makeAddr("a2"), bob, ReputationRegistry.Category.Overall, 70);
        _attest(makeAddr("a3"), carol, ReputationRegistry.Category.Quality, 90);
        _attest(makeAddr("a4"), carol, ReputationRegistry.Category.Quality, 90);

        ReputationRegistry.LeaderboardEntry[] memory overall = registry
            .getLeaderboard(10);
        ReputationRegistry.LeaderboardEntry[] memory byCategory = registry
            .getLeaderboardByCategory(
                ReputationRegistry.Category.Overall,
                10
            );
        assertEq(byCategory.length, overall.length);
        for (uint256 i = 0; i < overall.length; i++) {
            assertEq(byCategory[i].subject, overall[i].subject);
            assertEq(byCategory[i].average, overall[i].average);
            assertEq(byCategory[i].count, overall[i].count);
            assertEq(uint256(byCategory[i].tier), uint256(overall[i].tier));
        }
    }
}
