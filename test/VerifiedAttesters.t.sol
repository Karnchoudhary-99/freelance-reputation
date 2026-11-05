// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract VerifiedAttestersTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function testDeployerIsOwner() public view {
        assertEq(registry.owner(), address(this));
    }

    function testVerifiedNewcomerAttestsAtWeightTwo() public {
        registry.setVerifiedAttester(bob, true);
        assertTrue(registry.isVerifiedAttester(bob));
        assertEq(registry.attesterWeight(bob), 2);

        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.weight, 2);

        ReputationRegistry.Score memory s = registry.getScore(alice);
        assertEq(s.average, 9000);
        assertEq(s.totalWeight, 2);
        assertEq(s.effectiveWeight, 20000);
    }

    function testVerifiedBoostCapsAtThree() public {
        // Give bob a >= 80 average first (weight 3 on reputation alone).
        vm.prank(carol);
        registry.attest(bob, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        vm.prank(dave);
        registry.attest(bob, ReputationRegistry.Category.Overall, 95, bytes32("c1"));
        assertEq(registry.attesterWeight(bob), 3);

        registry.setVerifiedAttester(bob, true);
        assertEq(registry.attesterWeight(bob), 3);

        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        assertEq(registry.attestation(2).weight, 3);
    }

    function testVerifiedBoostLiftsMidReputationAttesterToThree() public {
        // Bob at ~60 average: base weight 2, verified -> 3.
        vm.prank(carol);
        registry.attest(bob, ReputationRegistry.Category.Overall, 60, bytes32("c1"));
        assertEq(registry.attesterWeight(bob), 2);

        registry.setVerifiedAttester(bob, true);
        assertEq(registry.attesterWeight(bob), 3);

        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 70, bytes32("c1"));
        assertEq(registry.attestation(1).weight, 3);
    }

    function testUnverifiedAttesterStaysAtBaseWeight() public {
        assertEq(registry.attesterWeight(bob), 1);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        assertEq(registry.attestation(0).weight, 1);
    }
}
