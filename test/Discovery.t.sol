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
}
