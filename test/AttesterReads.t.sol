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

    function testAttesterPaginationBounds() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32(0));
        vm.prank(bob);
        registry.attest(carol, ReputationRegistry.Category.Quality, 70, bytes32(0));
        vm.prank(bob);
        registry.attest(dave, ReputationRegistry.Category.Timeliness, 60, bytes32(0));

        ReputationRegistry.Attestation[] memory page =
            registry.getAttestationsByAttester(bob, 1, 1);
        assertEq(page.length, 1);
        assertEq(page[0].subject, carol);

        // Limit clamps to the remainder.
        page = registry.getAttestationsByAttester(bob, 2, 99);
        assertEq(page.length, 1);
        assertEq(page[0].subject, dave);

        // Offset past the end returns an empty page, not a revert.
        page = registry.getAttestationsByAttester(bob, 3, 10);
        assertEq(page.length, 0);
        page = registry.getAttestationsByAttester(alice, 0, 10);
        assertEq(page.length, 0);
    }

    function testAttesterStatsCountsStates() public {
        vm.prank(bob);
        uint256 active = registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32(0));
        vm.prank(bob);
        uint256 revoked = registry.attest(carol, ReputationRegistry.Category.Quality, 70, bytes32(0));
        vm.prank(bob);
        uint256 disputed = registry.attest(dave, ReputationRegistry.Category.Timeliness, 60, bytes32(0));
        vm.prank(bob);
        registry.revokeAttestation(revoked);
        vm.prank(dave);
        registry.disputeAttestation(disputed, bytes32("unfair"));

        ReputationRegistry.AttesterStats memory st = registry.attesterStats(bob);
        assertEq(st.given, 3);
        assertEq(st.active, 1);
        assertEq(st.revoked, 1);
        assertEq(st.disputed, 1);
        // Keep the compiler honest about which id is which.
        assertEq(active, 0);
    }

    function testSignedAttestationsAppearInAttesterIndex() public {
        // Signed attestations go through the same _attest path, so the
        // attester index must include them.
        uint256 bobKey = 0xB0B;
        address bobAddr = vm.addr(bobKey);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(
            abi.encode(
                registry.ATTEST_TYPEHASH(),
                bobAddr,
                alice,
                ReputationRegistry.Category.Overall,
                85,
                bytes32(0),
                0,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, digest);
        registry.attestBySignature(
            bobAddr, alice, ReputationRegistry.Category.Overall, 85, bytes32(0), deadline, v, r, s
        );
        assertEq(registry.attesterAttestationCount(bobAddr), 1);
        ReputationRegistry.AttesterStats memory st = registry.attesterStats(bobAddr);
        assertEq(st.given, 1);
        assertEq(st.active, 1);
    }
}
