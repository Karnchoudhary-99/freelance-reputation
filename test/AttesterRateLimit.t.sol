// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Daily attestation limit: fresh attestations per attester
///         per UTC day are capped (default 50, owner-configurable,
///         0 disables). Re-attests never consume quota, and the cap
///         applies identically across the direct, batch, signed, and
///         delegated entry points because enforcement lives in
///         `_attest`.
contract AttesterRateLimitTest is Test {
    ReputationRegistry registry;

    uint256 bobKey = 0xB0B;
    address bob;
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");
    address grace = makeAddr("grace");

    function setUp() public {
        registry = new ReputationRegistry();
        bob = vm.addr(bobKey);
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

    function testDefaultLimitIsFifty() public view {
        assertEq(registry.maxAttestationsPerDay(), 50);
        assertEq(registry.MAX_DAILY_LIMIT(), 1000);
    }

    function testFreshAttestationsCountTowardToday() public {
        vm.startPrank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        registry.attest(carol, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        registry.attest(dave, ReputationRegistry.Category.Timeliness, 70, bytes32("c3"));
        vm.stopPrank();
        assertEq(registry.attestationsToday(bob), 3);
        assertEq(registry.attestationsToday(carol), 0);
    }

    function testLimitEnforcedAtBoundary() public {
        registry.setMaxAttestationsPerDay(3);
        vm.startPrank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        registry.attest(carol, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        registry.attest(dave, ReputationRegistry.Category.Quality, 70, bytes32("c3"));
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.attest(erin, ReputationRegistry.Category.Quality, 60, bytes32("c4"));
        vm.stopPrank();
        assertEq(registry.attestationsToday(bob), 3);
    }

    function testReattestDoesNotConsumeQuota() public {
        registry.setMaxAttestationsPerDay(2);
        vm.startPrank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        registry.attest(carol, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        // Updating an existing record is always free, even at the cap.
        registry.attest(alice, ReputationRegistry.Category.Quality, 95, bytes32("c1b"));
        registry.attest(carol, ReputationRegistry.Category.Quality, 85, bytes32("c2b"));
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.attest(dave, ReputationRegistry.Category.Quality, 70, bytes32("c3"));
        vm.stopPrank();
        assertEq(registry.attestationsToday(bob), 2);
    }

    function testQuotaResetsAtUtcMidnight() public {
        registry.setMaxAttestationsPerDay(1);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        vm.prank(bob);
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.attest(carol, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        // Roll to the next UTC midnight: a fresh quota day.
        vm.warp(((block.timestamp / 1 days) + 1) * 1 days);
        vm.prank(bob);
        registry.attest(carol, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        assertEq(registry.attestationsToday(bob), 1);
    }

    function testOnlyOwnerCanChangeLimit() public {
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.setMaxAttestationsPerDay(5);
    }

    function testLimitAboveCapReverts() public {
        vm.expectRevert(ReputationRegistry.InvalidDailyLimit.selector);
        registry.setMaxAttestationsPerDay(1001);
        // The cap itself is allowed.
        registry.setMaxAttestationsPerDay(1000);
        assertEq(registry.maxAttestationsPerDay(), 1000);
    }

    function testSetLimitEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit ReputationRegistry.MaxAttestationsPerDayUpdated(5);
        registry.setMaxAttestationsPerDay(5);
    }

    function testZeroDisablesLimit() public {
        registry.setMaxAttestationsPerDay(1);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        vm.prank(bob);
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.attest(carol, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        // Disabling the limit unblocks the attester at once.
        registry.setMaxAttestationsPerDay(0);
        vm.prank(bob);
        registry.attest(carol, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        vm.prank(bob);
        registry.attest(dave, ReputationRegistry.Category.Quality, 70, bytes32("c3"));
        // While disabled, the counter is not incremented further: it
        // still shows the 1 filing from before the limit was lifted.
        assertEq(registry.attestationsToday(bob), 1);
    }

    function testLoweringLimitBlocksImmediately() public {
        vm.startPrank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        registry.attest(carol, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        vm.stopPrank();
        registry.setMaxAttestationsPerDay(2);
        vm.prank(bob);
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.attest(dave, ReputationRegistry.Category.Quality, 70, bytes32("c3"));
        // Raising it again unblocks at once.
        registry.setMaxAttestationsPerDay(3);
        vm.prank(bob);
        registry.attest(dave, ReputationRegistry.Category.Quality, 70, bytes32("c3"));
        assertEq(registry.attestationsToday(bob), 3);
    }

    function testLimitAppliesPerAttester() public {
        registry.setMaxAttestationsPerDay(1);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        // A different attester has their own quota.
        vm.prank(carol);
        registry.attest(alice, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        assertEq(registry.attestationsToday(bob), 1);
        assertEq(registry.attestationsToday(carol), 1);
    }

    function testBatchCountsEachFreshItemAtomically() public {
        registry.setMaxAttestationsPerDay(2);
        ReputationRegistry.AttestInput[]
            memory inputs = new ReputationRegistry.AttestInput[](3);
        inputs[0] = ReputationRegistry.AttestInput(
            alice,
            ReputationRegistry.Category.Quality,
            90,
            bytes32("c1")
        );
        inputs[1] = ReputationRegistry.AttestInput(
            carol,
            ReputationRegistry.Category.Quality,
            80,
            bytes32("c2")
        );
        inputs[2] = ReputationRegistry.AttestInput(
            dave,
            ReputationRegistry.Category.Quality,
            70,
            bytes32("c3")
        );
        vm.prank(bob);
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.attestBatch(inputs);
        // The revert is atomic: no record was created, no quota spent.
        assertEq(registry.attestationCount(), 0);
        assertEq(registry.attestationsToday(bob), 0);
        // A batch that fits the quota succeeds and counts each item.
        ReputationRegistry.AttestInput[]
            memory fitting = new ReputationRegistry.AttestInput[](2);
        fitting[0] = inputs[0];
        fitting[1] = inputs[1];
        vm.prank(bob);
        registry.attestBatch(fitting);
        assertEq(registry.attestationsToday(bob), 2);
    }

    function testSignedAttestationCountsAgainstAttester() public {
        registry.setMaxAttestationsPerDay(1);
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            bobKey,
            bob,
            alice,
            ReputationRegistry.Category.Quality,
            90,
            bytes32("c1"),
            0,
            deadline
        );
        registry.attestBySignature(
            bob,
            alice,
            ReputationRegistry.Category.Quality,
            90,
            bytes32("c1"),
            deadline,
            v,
            r,
            s
        );
        assertEq(registry.attestationsToday(bob), 1);
        (v, r, s) = _sign(
            bobKey,
            bob,
            carol,
            ReputationRegistry.Category.Quality,
            80,
            bytes32("c2"),
            1,
            deadline
        );
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.attestBySignature(
            bob,
            carol,
            ReputationRegistry.Category.Quality,
            80,
            bytes32("c2"),
            deadline,
            v,
            r,
            s
        );
    }

    function testDelegateAttestationsCountAgainstAttester() public {
        registry.setMaxAttestationsPerDay(1);
        vm.prank(bob);
        registry.setDelegate(carol, block.timestamp + 1 days);
        vm.prank(carol);
        registry.attestOnBehalf(
            bob,
            alice,
            ReputationRegistry.Category.Quality,
            90,
            bytes32("c1")
        );
        // The quota belongs to the attester, not the delegate.
        assertEq(registry.attestationsToday(bob), 1);
        assertEq(registry.attestationsToday(carol), 0);
        vm.prank(carol);
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.attestOnBehalf(
            bob,
            dave,
            ReputationRegistry.Category.Quality,
            70,
            bytes32("c3")
        );
        // The delegate's own quota is untouched, so they may still
        // attest as themselves.
        vm.prank(carol);
        registry.attest(
            alice,
            ReputationRegistry.Category.Quality,
            80,
            bytes32("c2")
        );
        assertEq(registry.attestationsToday(carol), 1);
    }

    function testRevokedRecordRefilingStillCounts() public {
        registry.setMaxAttestationsPerDay(1);
        vm.prank(bob);
        uint256 id = registry.attest(
            alice,
            ReputationRegistry.Category.Quality,
            90,
            bytes32("c1")
        );
        vm.prank(bob);
        registry.revokeAttestation(id);
        // The quota counts filings, not live records: revoking does
        // not refund the day's quota.
        vm.prank(bob);
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.attest(
            alice,
            ReputationRegistry.Category.Quality,
            90,
            bytes32("c1")
        );
        assertEq(registry.attestationsToday(bob), 1);
    }

    function testDifferentDaysAreSeparateBuckets() public {
        registry.setMaxAttestationsPerDay(2);
        vm.startPrank(bob);
        registry.attest(alice, ReputationRegistry.Category.Quality, 90, bytes32("c1"));
        registry.attest(carol, ReputationRegistry.Category.Quality, 80, bytes32("c2"));
        vm.stopPrank();
        // Two days later: yesterday's filings do not count.
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(bob);
        registry.attest(dave, ReputationRegistry.Category.Quality, 70, bytes32("c3"));
        registry.attest(erin, ReputationRegistry.Category.Quality, 60, bytes32("c4"));
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.attest(frank, ReputationRegistry.Category.Quality, 50, bytes32("c5"));
        vm.stopPrank();
        assertEq(registry.attestationsToday(bob), 2);
    }
}
