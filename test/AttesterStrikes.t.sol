// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract AttesterStrikesTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");

    function setUp() public {
        registry = new ReputationRegistry();
    }

    function testStrikeCountsAndEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit ReputationRegistry.AttesterStruck(bob, 1);
        registry.strikeAttester(bob);
        assertEq(registry.strikes(bob), 1);
        assertFalse(registry.isSuspended(bob));

        vm.expectEmit(true, false, false, true, address(registry));
        emit ReputationRegistry.AttesterStruck(bob, 2);
        registry.strikeAttester(bob);
        assertEq(registry.strikes(bob), 2);
        assertFalse(registry.isSuspended(bob));
    }

    function testOnlyOwnerCanStrike() public {
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.strikeAttester(carol);
        assertEq(registry.strikes(carol), 0);

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.clearStrikes(carol);
    }

    function testStrikeAndClearRejectZeroAddress() public {
        vm.expectRevert(ReputationRegistry.ZeroAddress.selector);
        registry.strikeAttester(address(0));
        vm.expectRevert(ReputationRegistry.ZeroAddress.selector);
        registry.clearStrikes(address(0));
    }

    function testOneStrikeLowersWeightByOne() public {
        // Bob at ~60 average: base weight 2.
        vm.prank(carol);
        registry.attest(bob, ReputationRegistry.Category.Overall, 60, bytes32("c1"));
        assertEq(registry.attesterWeight(bob), 2);

        registry.strikeAttester(bob);
        assertEq(registry.attesterWeight(bob), 1);

        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        assertEq(registry.attestation(1).weight, 1);
    }

    function testWeightFloorsAtOne() public {
        // Bob is a newcomer: base weight 1, and two strikes cannot
        // push the next attestation below weight 1.
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        assertEq(registry.attesterWeight(bob), 1);
        assertFalse(registry.isSuspended(bob));

        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        assertEq(registry.attestation(0).weight, 1);
    }

    function testVerifiedBoostThenStrike() public {
        // Verified newcomer: 1 + 1 = 2; one strike brings it back to 1.
        registry.setVerifiedAttester(bob, true);
        assertEq(registry.attesterWeight(bob), 2);
        registry.strikeAttester(bob);
        assertEq(registry.attesterWeight(bob), 1);

        // Verified top attester: base 3 (capped, boost adds nothing),
        // two strikes land the next attestation at weight 1.
        vm.prank(carol);
        registry.attest(dave, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        vm.prank(erin);
        registry.attest(dave, ReputationRegistry.Category.Overall, 95, bytes32("c1"));
        assertEq(registry.attesterWeight(dave), 3);
        registry.setVerifiedAttester(dave, true);
        assertEq(registry.attesterWeight(dave), 3);
        registry.strikeAttester(dave);
        registry.strikeAttester(dave);
        assertEq(registry.attesterWeight(dave), 1);

        vm.prank(dave);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        assertEq(registry.attestation(2).weight, 1);
    }

    function testReAttestAfterStrikePicksUpReducedWeight() public {
        // Bob at ~60 average attests at weight 2, then one strike:
        // the re-attest updates the same record with weight 1.
        vm.prank(carol);
        registry.attest(bob, ReputationRegistry.Category.Overall, 60, bytes32("c1"));
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        assertEq(registry.attestation(1).weight, 2);

        registry.strikeAttester(bob);
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        ReputationRegistry.Attestation memory a = registry.attestation(1);
        assertEq(a.score, 80);
        assertEq(a.weight, 1);
        assertEq(registry.attestationCount(), 2);
    }

    function testThreeStrikesSuspendsAttesting() public {
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        assertEq(registry.strikes(bob), 3);
        assertTrue(registry.isSuspended(bob));
        assertEq(registry.attesterWeight(bob), 0);

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AttesterSuspended.selector);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        assertEq(registry.attestationCount(), 0);
    }

    function testSuspensionBlocksReAttest() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AttesterSuspended.selector);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        // The record is untouched by the failed update.
        assertEq(registry.attestation(0).score, 90);
        assertEq(registry.attestation(0).weight, 1);
    }

    function testSuspensionBlocksBatchAttest() public {
        ReputationRegistry.AttestInput[] memory inputs = new ReputationRegistry.AttestInput[](2);
        inputs[0] = ReputationRegistry.AttestInput({
            subject: alice,
            category: ReputationRegistry.Category.Quality,
            score: 90,
            commentHash: bytes32("c1")
        });
        inputs[1] = ReputationRegistry.AttestInput({
            subject: carol,
            category: ReputationRegistry.Category.Timeliness,
            score: 80,
            commentHash: bytes32("c2")
        });
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);

        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AttesterSuspended.selector);
        registry.attestBatch(inputs);
        // Atomic: nothing from the batch landed.
        assertEq(registry.attestationCount(), 0);
    }

    function testSuspensionBlocksSignedAttest() public {
        uint256 bobKey = 0xB0B;
        address signedBob = vm.addr(bobKey);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(
            abi.encode(
                registry.ATTEST_TYPEHASH(),
                signedBob,
                alice,
                ReputationRegistry.Category.Overall,
                88,
                bytes32("c1"),
                0,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, digest);

        registry.strikeAttester(signedBob);
        registry.strikeAttester(signedBob);
        registry.strikeAttester(signedBob);

        // Relayed by a third party, not by bob himself.
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.AttesterSuspended.selector);
        registry.attestBySignature(
            signedBob, alice, ReputationRegistry.Category.Overall, 88, bytes32("c1"), deadline, v, r, s
        );
        assertEq(registry.attestationCount(), 0);
    }

    function testStrikesDoNotRewriteExistingRecordsOrScores() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        assertEq(registry.attestation(0).weight, 1);

        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        assertEq(registry.attestation(0).weight, 1);
        assertEq(registry.getScore(alice).average, 9000);

        // Even fully suspended, the past scores keep counting.
        registry.strikeAttester(bob);
        assertTrue(registry.isSuspended(bob));
        assertEq(registry.getScore(alice).average, 9000);
        assertEq(registry.getScore(alice).count, 1);
        assertEq(registry.attestation(0).weight, 1);
    }

    function testClearStrikesReinstatesAttester() public {
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        assertTrue(registry.isSuspended(bob));

        vm.expectEmit(true, false, false, false, address(registry));
        emit ReputationRegistry.StrikesCleared(bob);
        registry.clearStrikes(bob);

        assertEq(registry.strikes(bob), 0);
        assertFalse(registry.isSuspended(bob));
        assertEq(registry.attesterWeight(bob), 1);

        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        assertEq(registry.attestation(0).weight, 1);
    }

    function testOnlyOwnerCanClearStrikes() public {
        registry.strikeAttester(bob);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.clearStrikes(bob);
        assertEq(registry.strikes(bob), 1);
    }

    function testStrikesKeepCountingPastSuspension() public {
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        assertEq(registry.strikes(bob), 4);
        assertTrue(registry.isSuspended(bob));
        assertEq(registry.attesterWeight(bob), 0);
        // Clearing resets the whole count, not just to the threshold.
        registry.clearStrikes(bob);
        assertEq(registry.strikes(bob), 0);
    }

    function testSuspendedAttesterCanStillRevokeAndResolve() public {
        vm.prank(bob);
        uint256 first = registry.attest(alice, ReputationRegistry.Category.Overall, 90, bytes32("c1"));
        vm.prank(bob);
        uint256 second = registry.attest(carol, ReputationRegistry.Category.Quality, 80, bytes32("c1"));
        vm.prank(carol);
        registry.disputeAttestation(second, bytes32("unfair"));

        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        assertTrue(registry.isSuspended(bob));

        // Revoking their own attestation still works while suspended.
        vm.prank(bob);
        registry.revokeAttestation(first);
        assertTrue(registry.attestation(first).revoked);

        // So does resolving the open dispute (uphold reinstates it).
        vm.prank(bob);
        registry.resolveDispute(second, true);
        assertFalse(registry.attestation(second).disputed);
        assertEq(registry.getScore(carol).average, 8000);
    }

    function testAttesterStatsIncludesStrikes() public {
        vm.prank(bob);
        registry.attest(alice, ReputationRegistry.Category.Overall, 80, bytes32("c1"));
        registry.strikeAttester(bob);

        ReputationRegistry.AttesterStats memory st = registry.attesterStats(bob);
        assertEq(st.given, 1);
        assertEq(st.active, 1);
        assertEq(st.strikes, 1);
        assertFalse(st.suspended);

        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        st = registry.attesterStats(bob);
        assertEq(st.strikes, 3);
        assertTrue(st.suspended);
        // Stats still describe the track record, strikes aside.
        assertEq(st.given, 1);
        assertEq(st.active, 1);
    }

    function testStrikingAnAttesterWithNoRecordsWorks() public {
        // Strikes need no prior attestation: the owner can act on an
        // off-chain report before the attester ever writes on-chain.
        registry.strikeAttester(erin);
        assertEq(registry.strikes(erin), 1);
        assertEq(registry.attesterStats(erin).given, 0);

        registry.strikeAttester(erin);
        registry.strikeAttester(erin);
        vm.prank(erin);
        vm.expectRevert(ReputationRegistry.AttesterSuspended.selector);
        registry.attest(alice, ReputationRegistry.Category.Overall, 70, bytes32("c1"));
    }
}
