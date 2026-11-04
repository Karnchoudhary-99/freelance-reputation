// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract AttesterReadsTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function testAttesterIndexTracksCreatesNotUpdates() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32(0));
        vm.prank(bob);
        registry.attest(carol, ReputationRegistry.Category.Quality, 70, bytes32(0));
        // Update, not a new record: index must stay at 2.
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32(0));
        assertEq(registry.attesterAttestationCount(bob), 2);
        assertEq(registry.attesterAttestationCount(alice), 0);

        ReputationRegistry.Attestation[] memory recs =
            registry.getAttestationsByAttester(bob, 0, 10);
        assertEq(recs.length, 2);
        assertEq(recs[0].subject, alice);
        assertEq(recs[0].score, 90); // updated value, same record
        assertEq(recs[1].subject, carol);
    }
}
