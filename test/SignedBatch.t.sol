// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract SignedBatchTest is Test {
    ReputationRegistry registry;

    uint256 bobKey = 0xB0B;
    uint256 carolKey = 0xCA901;
    address bob;
    address carol;
    address alice = makeAddr("alice");
    address dave = makeAddr("dave");

    function setUp() public {
        registry = new ReputationRegistry();
        bob = vm.addr(bobKey);
        carol = vm.addr(carolKey);
    }

    function _signed(
        uint256 key,
        address attester,
        address subject,
        ReputationRegistry.Category category,
        uint8 score,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (ReputationRegistry.SignedAttestInput memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.ATTEST_TYPEHASH(),
                attester,
                subject,
                category,
                score,
                bytes32(0),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return ReputationRegistry.SignedAttestInput({
            attester: attester,
            subject: subject,
            category: category,
            score: score,
            commentHash: bytes32(0),
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });
    }

    function testSignedBatchRelaysMixedAttesters() public {
        uint256 deadline = block.timestamp + 1 days;
        ReputationRegistry.SignedAttestInput[] memory inputs =
            new ReputationRegistry.SignedAttestInput[](2);
        inputs[0] = _signed(
            bobKey, bob, alice, ReputationRegistry.Category.Overall, 80, 0, deadline
        );
        inputs[1] = _signed(
            carolKey, carol, alice, ReputationRegistry.Category.Quality, 90, 0, deadline
        );
        // Submitted by a relayer who is neither attester.
        vm.prank(dave);
        uint256[] memory ids = registry.attestBatchBySignature(inputs);
        assertEq(ids.length, 2);
        assertEq(registry.nonces(bob), 1);
        assertEq(registry.nonces(carol), 1);
        ReputationRegistry.Score memory overall = registry.getScore(alice);
        assertEq(overall.average, 8500);
        assertEq(overall.count, 2);
        ReputationRegistry.Score memory quality =
            registry.getScoreByCategory(alice, ReputationRegistry.Category.Quality);
        assertEq(quality.average, 9000);
        assertEq(quality.count, 1);
    }

    function testSignedBatchIsAtomicOnBadSignature() public {
        uint256 deadline = block.timestamp + 1 days;
        ReputationRegistry.SignedAttestInput[] memory inputs =
            new ReputationRegistry.SignedAttestInput[](2);
        inputs[0] = _signed(
            bobKey, bob, alice, ReputationRegistry.Category.Overall, 80, 0, deadline
        );
        // Second entry signed by carol's key but presented as bob's.
        inputs[1] = _signed(
            carolKey, bob, dave, ReputationRegistry.Category.Overall, 90, 1, deadline
        );
        vm.expectRevert(ReputationRegistry.InvalidSignature.selector);
        registry.attestBatchBySignature(inputs);
        // Atomicity: nothing landed and no nonce was consumed.
        assertEq(registry.attestationCount(), 0);
        assertEq(registry.nonces(bob), 0);
        assertEq(registry.nonces(carol), 0);
    }

    function testSignedBatchIsAtomicOnExpiredEntry() public {
        uint256 goodDeadline = block.timestamp + 1 days;
        uint256 badDeadline = block.timestamp + 1 hours;
        ReputationRegistry.SignedAttestInput[] memory inputs =
            new ReputationRegistry.SignedAttestInput[](2);
        inputs[0] = _signed(
            bobKey, bob, alice, ReputationRegistry.Category.Overall, 80, 0, goodDeadline
        );
        inputs[1] = _signed(
            carolKey, carol, dave, ReputationRegistry.Category.Overall, 90, 0, badDeadline
        );
        vm.warp(badDeadline + 1);
        vm.expectRevert(ReputationRegistry.ExpiredSignature.selector);
        registry.attestBatchBySignature(inputs);
        assertEq(registry.attestationCount(), 0);
        assertEq(registry.nonces(bob), 0);
    }
}
