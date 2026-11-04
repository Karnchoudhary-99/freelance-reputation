// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract TiersTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function _attestFrom(address attester, uint8 score) internal {
        vm.prank(attester);
        registry.attest(alice, ReputationRegistry.Category.Overall, score, bytes32(0));
    }

    function testTierBoundaries() public {
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Unranked)
        );
        // One attestation, however perfect, is only Emerging.
        _attestFrom(makeAddr("a1"), 100);
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Emerging)
        );
        // Three at 60: average 60 but count short of Trusted, and the
        // average is exactly the Established bar.
        _attestFrom(makeAddr("a2"), 60);
        _attestFrom(makeAddr("a3"), 60);
        // Average is (100 + 60 + 60) / 3 = 73.33, count 3 -> Established
        // needs 60+ average and 3+ count; Trusted needs 75+ and 5+.
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Established)
        );
        _attestFrom(makeAddr("a4"), 100);
        _attestFrom(makeAddr("a5"), 100);
        // Average (100+60+60+100+100)/5 = 84, count 5 -> Trusted.
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Trusted)
        );
    }

    function testEliteNeedsBothHighAverageAndCount() public {
        // Ten attestations at 90: average high, count exactly 10 -> Elite.
        for (uint256 i = 0; i < 10; i++) {
            _attestFrom(makeAddr(string(abi.encodePacked("e", i))), 90);
        }
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Elite)
        );
    }

    function testHighAverageWithFewAttestationsIsNotElite() public {
        // Nine perfect attestations: average 100 but count short of 10.
        for (uint256 i = 0; i < 9; i++) {
            _attestFrom(makeAddr(string(abi.encodePacked("n", i))), 100);
        }
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Trusted)
        );
    }

    function testDecayedEndorsementsWeighLessInTier() public {
        // An old perfect endorsement decayed to quarter weight plus a
        // fresh zero: (100*2500 + 0*10000) / 12500 = 20 average, count 2
        // -> Emerging, not Established, despite the 100 on record.
        _attestFrom(makeAddr("old"), 100);
        vm.warp(block.timestamp + 400 days);
        _attestFrom(makeAddr("fresh"), 0);
        ReputationRegistry.Score memory sc = registry.getScore(alice);
        assertEq(sc.average, 2000);
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Emerging)
        );
    }

    function testTierDropsWhenEndorsementCountFalls() public {
        for (uint256 i = 0; i < 10; i++) {
            _attestFrom(makeAddr(string(abi.encodePacked("d", i))), 95);
        }
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Elite)
        );
        // Revoke five: count falls to 5, average still 95 -> Trusted.
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(makeAddr(string(abi.encodePacked("d", i))));
            registry.revokeAttestation(i);
        }
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Trusted)
        );
    }
}
