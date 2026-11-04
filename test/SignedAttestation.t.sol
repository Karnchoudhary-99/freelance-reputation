// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract SignedAttestationTest is Test {
    ReputationRegistry registry;

    uint256 bobKey = 0xB0B;
    uint256 carolKey = 0xCA901;
    address bob;
    address carol;
    address alice = makeAddr("alice");

    function setUp() public {
        registry = new ReputationRegistry();
        bob = vm.addr(bobKey);
        carol = vm.addr(carolKey);
    }

    function _sign(
        uint256 key,
        address attester,
        address subject,
        ReputationRegistry.Category category,
        uint8 score,
        bytes32 commentHash,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.ATTEST_TYPEHASH(),
                attester,
                subject,
                category,
                score,
                commentHash,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash)
        );
        (v, r, s) = vm.sign(key, digest);
    }

    function testSignedAttestationAttestsViaRelayer() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            bobKey, bob, alice, ReputationRegistry.Category.Quality, 88, bytes32("c1"), 0, deadline
        );
        // Submitted by a third-party relayer, not by bob himself.
        vm.prank(carol);
        uint256 id = registry.attestBySignature(
            bob, alice, ReputationRegistry.Category.Quality, 88, bytes32("c1"), deadline, v, r, s
        );
        assertEq(id, 0);
        assertEq(registry.nonces(bob), 1);
        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.attester, bob);
        assertEq(a.score, 88);
        ReputationRegistry.Score memory sc = registry.getScore(alice);
        assertEq(sc.average, 8800);
        assertEq(sc.count, 1);
    }

    function testSignedAttestationCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            bobKey, bob, alice, ReputationRegistry.Category.Overall, 70, bytes32(0), 0, deadline
        );
        registry.attestBySignature(
            bob, alice, ReputationRegistry.Category.Overall, 70, bytes32(0), deadline, v, r, s
        );
        // Same signature again: nonce moved to 1, so recovery mismatches.
        vm.expectRevert(ReputationRegistry.InvalidSignature.selector);
        registry.attestBySignature(
            bob, alice, ReputationRegistry.Category.Overall, 70, bytes32(0), deadline, v, r, s
        );
    }

    function testSignedAttestationRejectsExpiredDeadline() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            bobKey, bob, alice, ReputationRegistry.Category.Overall, 70, bytes32(0), 0, deadline
        );
        vm.warp(deadline + 1);
        vm.expectRevert(ReputationRegistry.ExpiredSignature.selector);
        registry.attestBySignature(
            bob, alice, ReputationRegistry.Category.Overall, 70, bytes32(0), deadline, v, r, s
        );
        // An expired submission must not burn the nonce.
        assertEq(registry.nonces(bob), 0);
    }

    function testSignedAttestationRejectsWrongSignerAndTampering() public {
        uint256 deadline = block.timestamp + 1 days;
        // Signed by carol's key but presented as bob's attestation.
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            carolKey, bob, alice, ReputationRegistry.Category.Overall, 70, bytes32(0), 0, deadline
        );
        vm.expectRevert(ReputationRegistry.InvalidSignature.selector);
        registry.attestBySignature(
            bob, alice, ReputationRegistry.Category.Overall, 70, bytes32(0), deadline, v, r, s
        );
        // Genuine bob signature, but the relayer tampered with the score.
        (v, r, s) = _sign(
            bobKey, bob, alice, ReputationRegistry.Category.Overall, 70, bytes32(0), 0, deadline
        );
        vm.expectRevert(ReputationRegistry.InvalidSignature.selector);
        registry.attestBySignature(
            bob, alice, ReputationRegistry.Category.Overall, 71, bytes32(0), deadline, v, r, s
        );
        assertEq(registry.nonces(bob), 0);
    }

    function testSignedAttestationKeepsCoreGuards() public {
        uint256 deadline = block.timestamp + 1 days;
        // Self-attestation via signature.
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            bobKey, bob, bob, ReputationRegistry.Category.Overall, 100, bytes32(0), 0, deadline
        );
        vm.expectRevert(ReputationRegistry.SelfAttestation.selector);
        registry.attestBySignature(
            bob, bob, ReputationRegistry.Category.Overall, 100, bytes32(0), deadline, v, r, s
        );
        // Score above 100 via signature.
        (v, r, s) = _sign(
            bobKey, bob, alice, ReputationRegistry.Category.Overall, 101, bytes32(0), 1, deadline
        );
        vm.expectRevert(ReputationRegistry.InvalidScore.selector);
        registry.attestBySignature(
            bob, alice, ReputationRegistry.Category.Overall, 101, bytes32(0), deadline, v, r, s
        );
    }
}
