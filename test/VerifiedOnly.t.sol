// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Verified-only mode: when the owner switches it on, only
///         verified attesters may attest — on every path, including
///         re-attests. Existing records and scores are never touched:
///         the mode gates new writes, not reads.
contract VerifiedOnlyTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    event VerifiedOnlyUpdated(bool verifiedOnly);

    uint256 bobKey = 0xB0B;
    address bobSigner;

    function setUp() public {
        registry = new ReputationRegistry();
        bobSigner = vm.addr(bobKey);
    }

    function _attest(address attester, address subject, uint8 score)
        internal
        returns (uint256)
    {
        vm.prank(attester);
        return
            registry.attest(
                subject,
                ReputationRegistry.Category.Overall,
                score,
                bytes32(0)
            );
    }

    function testDefaultsOff() public view {
        assertFalse(registry.verifiedOnly());
    }

    function testSetVerifiedOnlyOwnerGuardAndEvent() public {
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.setVerifiedOnly(true);

        vm.expectEmit(false, false, false, true, address(registry));
        emit VerifiedOnlyUpdated(true);
        registry.setVerifiedOnly(true);
        assertTrue(registry.verifiedOnly());

        vm.expectEmit(false, false, false, true, address(registry));
        emit VerifiedOnlyUpdated(false);
        registry.setVerifiedOnly(false);
        assertFalse(registry.verifiedOnly());
    }

    function testUnverifiedAttestationRevertsWhenOn() public {
        registry.setVerifiedOnly(true);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotVerifiedAttester.selector);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32(0)
        );
        assertEq(registry.attestationCount(), 0);
    }

    function testVerifiedAttestationWorksWhenOn() public {
        registry.setVerifiedAttester(bob, true);
        registry.setVerifiedOnly(true);
        uint256 id = _attest(bob, alice, 90);
        assertEq(id, 0);
        assertEq(registry.getScore(alice).average, 9000);
        assertEq(registry.getScore(alice).count, 1);
    }

    function testReattestBlockedForUnverifiedWhenOn() public {
        // Bob attests while the mode is off, then the owner switches
        // it on: bob may no longer update his own record.
        uint256 id = _attest(bob, alice, 90);
        registry.setVerifiedOnly(true);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotVerifiedAttester.selector);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            50,
            bytes32(0)
        );
        assertEq(registry.attestation(id).score, 90);

        // Verifying bob unblocks the re-attest at once.
        registry.setVerifiedAttester(bob, true);
        vm.prank(bob);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            50,
            bytes32(0)
        );
        assertEq(registry.attestation(id).score, 50);
    }

    function testDisablingModeReallowsUnverified() public {
        registry.setVerifiedOnly(true);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotVerifiedAttester.selector);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32(0)
        );
        registry.setVerifiedOnly(false);
        uint256 id = _attest(bob, alice, 90);
        assertEq(id, 0);
    }

    function testVerifyingMidwayUnblocksAttester() public {
        registry.setVerifiedOnly(true);
        registry.setVerifiedAttester(bob, true);
        uint256 id = _attest(bob, alice, 90);
        assertEq(id, 0);

        // Un-verifying blocks the next attestation again.
        registry.setVerifiedAttester(bob, false);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotVerifiedAttester.selector);
        registry.attest(
            alice,
            ReputationRegistry.Category.Quality,
            80,
            bytes32(0)
        );
    }

    function testBatchBlockedForUnverifiedWhenOn() public {
        registry.setVerifiedAttester(bob, true);
        registry.setVerifiedOnly(true);
        ReputationRegistry.AttestInput[]
            memory inputs = new ReputationRegistry.AttestInput[](2);
        inputs[0] = ReputationRegistry.AttestInput({
            subject: alice,
            category: ReputationRegistry.Category.Overall,
            score: 90,
            commentHash: bytes32(0)
        });
        inputs[1] = ReputationRegistry.AttestInput({
            subject: dave,
            category: ReputationRegistry.Category.Overall,
            score: 80,
            commentHash: bytes32(0)
        });
        // Carol is unverified, so her whole batch reverts atomically
        // — not even bob's entries land.
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.NotVerifiedAttester.selector);
        registry.attestBatch(inputs);
        assertEq(registry.attestationCount(), 0);

        // Bob's own batch lands.
        vm.prank(bob);
        registry.attestBatch(inputs);
        assertEq(registry.attestationCount(), 2);
    }

    function testReadsUnaffectedByMode() public {
        // Records written before the mode switched on keep counting:
        // the mode gates writes, never reads.
        _attest(bob, alice, 90);
        _attest(carol, alice, 100);
        registry.setVerifiedOnly(true);
        assertEq(registry.getScore(alice).average, 9500);
        assertEq(registry.getScore(alice).count, 2);
        assertEq(registry.getLeaderboard(10).length, 1);
        assertEq(registry.getLeaderboard(10)[0].average, 9500);
        // Two strong attestations: Emerging, exactly as before the
        // mode switched on.
        assertEq(
            uint256(registry.tierOf(alice)),
            uint256(ReputationRegistry.Tier.Emerging)
        );
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
            abi.encodePacked(
                "\x19\x01",
                registry.DOMAIN_SEPARATOR(),
                structHash
            )
        );
        (v, r, s) = vm.sign(key, digest);
    }

    function testSignedPathBlockedForUnverifiedWhenOn() public {
        registry.setVerifiedOnly(true);
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            bobKey,
            bobSigner,
            alice,
            ReputationRegistry.Category.Quality,
            88,
            bytes32("c1"),
            0,
            deadline
        );
        // Relayed by carol, but the attester is bob — unverified.
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.NotVerifiedAttester.selector);
        registry.attestBySignature(
            bobSigner,
            alice,
            ReputationRegistry.Category.Quality,
            88,
            bytes32("c1"),
            deadline,
            v,
            r,
            s
        );
        assertEq(registry.nonces(bobSigner), 0);

        // Verifying bob lets the same signature land — and the nonce
        // was not burned by the reverted attempt.
        registry.setVerifiedAttester(bobSigner, true);
        vm.prank(carol);
        uint256 id = registry.attestBySignature(
            bobSigner,
            alice,
            ReputationRegistry.Category.Quality,
            88,
            bytes32("c1"),
            deadline,
            v,
            r,
            s
        );
        assertEq(id, 0);
        assertEq(registry.nonces(bobSigner), 1);
    }

    function testDelegatedPathFollowsTheAttester() public {
        // Dave is bob's delegate; the gate reads bob (the attester),
        // never dave (the delegate).
        vm.prank(bob);
        registry.setDelegate(dave, block.timestamp + 30 days);
        registry.setVerifiedOnly(true);
        vm.prank(dave);
        vm.expectRevert(ReputationRegistry.NotVerifiedAttester.selector);
        registry.attestOnBehalf(
            bob,
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32(0)
        );

        registry.setVerifiedAttester(bob, true);
        vm.prank(dave);
        uint256 id = registry.attestOnBehalf(
            bob,
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32(0)
        );
        assertEq(id, 0);
        assertEq(registry.attestation(0).attester, bob);
    }

    function testSuspensionStillTakesPrecedence() public {
        // A verified attester with 3 strikes is suspended: the
        // suspension guard fires first, so the error stays
        // AttesterSuspended, not NotVerifiedAttester.
        registry.setVerifiedAttester(bob, true);
        registry.setVerifiedOnly(true);
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AttesterSuspended.selector);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32(0)
        );
    }

    function testPauseStillTakesPrecedence() public {
        // Pause is checked first in _attest: while paused, even a
        // verified attester gets RegistryPaused, and an unverified
        // one does too.
        registry.setVerifiedOnly(true);
        registry.pause();
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.attest(
            alice,
            ReputationRegistry.Category.Overall,
            90,
            bytes32(0)
        );
    }

    function testOwnerCanVerifyWhileModeOn() public {
        // The mode never locks the owner out of the registry itself:
        // verifying an attester while it is on unblocks them at once.
        registry.setVerifiedOnly(true);
        registry.setVerifiedAttester(bob, true);
        uint256 id = _attest(bob, alice, 90);
        assertEq(id, 0);
        assertTrue(registry.isVerifiedAttester(bob));
    }
}
