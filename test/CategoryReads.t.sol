// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract CategoryReadsTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function _seedMixedCategories() internal {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("q1"));
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Timeliness, 70, bytes32("t1"));
        vm.prank(dave);
        registry.attest(alice, ReputationRegistry.Category.Quality, 80, bytes32("q2"));
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 95, bytes32("o1"));
    }

    function testCategoryReadsReturnOnlyThatCategory() public {
        _seedMixedCategories();
        ReputationRegistry.Attestation[] memory quality = registry
            .getAttestationsByCategory(alice, ReputationRegistry.Category.Quality, 0, 10);
        assertEq(quality.length, 2);
        assertEq(quality[0].score, 90);
        assertEq(quality[0].attester, bob);
        assertEq(quality[1].score, 80);
        assertEq(quality[1].attester, dave);

        ReputationRegistry.Attestation[] memory timeliness = registry
            .getAttestationsByCategory(alice, ReputationRegistry.Category.Timeliness, 0, 10);
        assertEq(timeliness.length, 1);
        assertEq(timeliness[0].score, 70);

        ReputationRegistry.Attestation[] memory reliability = registry
            .getAttestationsByCategory(alice, ReputationRegistry.Category.Reliability, 0, 10);
        assertEq(reliability.length, 0);
    }

    function testCategoryReadsPaginate() public {
        _seedMixedCategories();
        ReputationRegistry.Attestation[] memory page = registry
            .getAttestationsByCategory(alice, ReputationRegistry.Category.Quality, 1, 1);
        assertEq(page.length, 1);
        assertEq(page[0].score, 80);

        // Limit clamps to the remaining records in the category.
        ReputationRegistry.Attestation[] memory clamped = registry
            .getAttestationsByCategory(alice, ReputationRegistry.Category.Quality, 1, 100);
        assertEq(clamped.length, 1);

        // Offset past the end returns an empty array, not a revert.
        ReputationRegistry.Attestation[] memory empty = registry
            .getAttestationsByCategory(alice, ReputationRegistry.Category.Quality, 2, 10);
        assertEq(empty.length, 0);
    }

    function testCategoryReadsIncludeRevokedAndDisputed() public {
        _seedMixedCategories();
        vm.prank(bob);
        registry.revokeAttestation(0);
        vm.prank(alice);
        registry.disputeAttestation(1, bytes32("late"));

        // Revoked/disputed records stay visible, flags tell them apart.
        ReputationRegistry.Attestation[] memory quality = registry
            .getAttestationsByCategory(alice, ReputationRegistry.Category.Quality, 0, 10);
        assertEq(quality.length, 2);
        assertTrue(quality[0].revoked);
        assertFalse(quality[1].revoked);

        ReputationRegistry.Attestation[] memory timeliness = registry
            .getAttestationsByCategory(alice, ReputationRegistry.Category.Timeliness, 0, 10);
        assertEq(timeliness.length, 1);
        assertTrue(timeliness[0].disputed);
    }

    function testCategoryReadsOnUnknownSubjectAreEmpty() public view {
        ReputationRegistry.Attestation[] memory out = registry
            .getAttestationsByCategory(alice, ReputationRegistry.Category.Quality, 0, 10);
        assertEq(out.length, 0);
    }

    function testReAttestDoesNotDuplicateCategoryReads() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 60, bytes32("v1"));
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("v2"));

        // An update rewrites the record in place: still one Quality row.
        ReputationRegistry.Attestation[] memory quality = registry
            .getAttestationsByCategory(alice, ReputationRegistry.Category.Quality, 0, 10);
        assertEq(quality.length, 1);
        assertEq(quality[0].score, 90);
    }
}
