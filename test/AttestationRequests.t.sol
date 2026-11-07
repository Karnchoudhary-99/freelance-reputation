// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Attestation requests: a subject asks a specific attester for
///         a rating, the attester answers with a linked attestation,
///         and the subject may withdraw the ask while it is open.
///         One open request per (subject, attester, category); an
///         expired request frees its slot, and a fulfilled request
///         links the attestation back to the ask.
contract AttestationRequestsTest is Test {
    ReputationRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");

    // Fixed base time so warps read like calendar dates.
    uint64 constant T0 = 1_700_000_000;

    function setUp() public {
        registry = new ReputationRegistry();
        vm.warp(T0);
    }

    function _request(
        address subject,
        address attester,
        ReputationRegistry.Category category
    ) internal returns (uint256 id) {
        vm.prank(subject);
        id = registry.requestAttestation(
            attester,
            category,
            keccak256("job-42")
        );
    }

    function _attest(
        address attester,
        address subject,
        ReputationRegistry.Category category,
        uint8 score
    ) internal {
        vm.prank(attester);
        registry.attest(subject, category, score, bytes32(0));
    }

    function _fulfill(
        address attester,
        uint256 requestId,
        uint8 score
    ) internal returns (uint256 attestationId) {
        vm.prank(attester);
        attestationId = registry.fulfillAttestationRequest(
            requestId,
            score,
            bytes32(0)
        );
    }

    function testRequestCreatesOpenRequest() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        assertEq(id, 0);
        assertEq(registry.attestationRequestCount(), 1);

        ReputationRegistry.AttestationRequest memory req = registry
            .attestationRequest(id);
        assertEq(req.subject, alice);
        assertEq(req.attester, bob);
        assertEq(
            uint256(req.category),
            uint256(ReputationRegistry.Category.Quality)
        );
        assertEq(req.contextHash, keccak256("job-42"));
        assertEq(req.createdAt, T0);
        assertEq(req.expiresAt, T0 + 30 days);
        assertEq(uint256(req.status), uint256(ReputationRegistry.RequestStatus.Open));
        assertEq(req.attestationId, 0);

        // openRequestId finds the ask by its own key — including when
        // the request id is 0, which the `exists` flag disambiguates.
        (bool exists, uint256 found) = registry.openRequestId(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        assertTrue(exists);
        assertEq(found, id);
        ReputationRegistry.AttestationRequest[]
            memory inbox = registry.getOpenRequestsForAttester(bob, 0, 10);
        assertEq(inbox.length, 1);
        assertEq(inbox[0].subject, alice);
        assertFalse(registry.isRequestExpired(id));
    }

    function testOpenRequestIdReturnsNotFoundWhenNone() public {
        (bool exists, uint256 found) = registry.openRequestId(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        assertFalse(exists);
        assertEq(found, 0);

        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        // A second subject's ask for the same attester/category is a
        // different key, so it gets its own id — and openRequestId
        // finds the first subject's request by its own key.
        _request(dave, bob, ReputationRegistry.Category.Quality);
        (exists, found) = registry.openRequestId(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        assertTrue(exists);
        assertEq(found, id);
    }

    function testDuplicateOpenRequestReverts() public {
        _request(alice, bob, ReputationRegistry.Category.Quality);
        vm.prank(alice);
        vm.expectRevert(
            ReputationRegistry.RequestAlreadyOpen.selector
        );
        registry.requestAttestation(
            bob,
            ReputationRegistry.Category.Quality,
            bytes32(0)
        );
        // Same subject + attester, different category: a different ask.
        _request(alice, bob, ReputationRegistry.Category.Timeliness);
        // Same subject + category, different attester: also fine.
        _request(alice, carol, ReputationRegistry.Category.Quality);
        assertEq(registry.attestationRequestCount(), 3);
    }

    function testRequestRejectsZeroAndSelf() public {
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.ZeroAddress.selector);
        registry.requestAttestation(
            address(0),
            ReputationRegistry.Category.Overall,
            bytes32(0)
        );
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.SelfAttestation.selector);
        registry.requestAttestation(
            alice,
            ReputationRegistry.Category.Overall,
            bytes32(0)
        );
    }

    function testRequestBlockedWhilePaused() public {
        registry.pause();
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.requestAttestation(
            bob,
            ReputationRegistry.Category.Overall,
            bytes32(0)
        );
        registry.unpause();
        _request(alice, bob, ReputationRegistry.Category.Overall);
        assertEq(registry.attestationRequestCount(), 1);
    }

    function testCancelFreesSlot() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        vm.prank(alice);
        registry.cancelAttestationRequest(id);
        ReputationRegistry.AttestationRequest memory req = registry
            .attestationRequest(id);
        assertEq(
            uint256(req.status),
            uint256(ReputationRegistry.RequestStatus.Cancelled)
        );
        (bool exists, ) = registry.openRequestId(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        assertFalse(exists);
        assertEq(registry.getOpenRequestsForAttester(bob, 0, 10).length, 0);
        // A fresh ask for the same triple is allowed again.
        uint256 id2 = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        assertEq(id2, 1);
    }

    function testCancelGuards() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        // Only the subject may cancel.
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.NotRequestSubject.selector);
        registry.cancelAttestationRequest(id);
        vm.prank(alice);
        registry.cancelAttestationRequest(id);
        // Cancelling twice reverts: the request is no longer open.
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.RequestNotOpen.selector);
        registry.cancelAttestationRequest(id);
        // Unknown id reverts.
        vm.prank(alice);
        vm.expectRevert(
            ReputationRegistry.UnknownAttestationRequest.selector
        );
        registry.cancelAttestationRequest(99);
    }

    function testCancelWorksWhilePaused() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        registry.pause();
        // Withdrawing an ask is a subject-side action like a revoke:
        // it stays available while paused.
        vm.prank(alice);
        registry.cancelAttestationRequest(id);
        assertEq(
            uint256(registry.attestationRequest(id).status),
            uint256(ReputationRegistry.RequestStatus.Cancelled)
        );
        registry.unpause();
    }

    function testFulfillCreatesLinkedAttestation() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        uint256 attestationId = _fulfill(bob, id, 90);
        assertEq(attestationId, 0);

        ReputationRegistry.AttestationRequest memory req = registry
            .attestationRequest(id);
        assertEq(
            uint256(req.status),
            uint256(ReputationRegistry.RequestStatus.Fulfilled)
        );
        assertEq(req.attestationId, attestationId);
        (bool exists, ) = registry.openRequestId(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        assertFalse(exists);

        ReputationRegistry.Attestation memory a = registry.attestation(
            attestationId
        );
        assertEq(a.attester, bob);
        assertEq(a.subject, alice);
        assertEq(a.score, 90);
        assertTrue(a.fromRequest);
        assertEq(a.requestId, id);

        // The score counts: one 90 in Quality.
        ReputationRegistry.Score memory score = registry.getScoreByCategory(
            alice,
            ReputationRegistry.Category.Quality
        );
        assertEq(score.average, 9000);
        assertEq(score.count, 1);
    }

    function testFulfillWithEvidence() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Overall
        );
        vm.prank(bob);
        uint256 attestationId = registry
            .fulfillAttestationRequestWithEvidence(
                id,
                80,
                bytes32(0),
                keccak256("deliverable")
            );
        ReputationRegistry.Attestation memory a = registry.attestation(
            attestationId
        );
        assertEq(a.evidenceHash, keccak256("deliverable"));
        assertTrue(a.fromRequest);
        assertEq(a.requestId, id);
    }

    function testFulfillGuards() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        // The subject may not fulfil their own request.
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotRequestAttester.selector);
        registry.fulfillAttestationRequest(id, 90, bytes32(0));
        // Neither may a bystander.
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.NotRequestAttester.selector);
        registry.fulfillAttestationRequest(id, 90, bytes32(0));

        _fulfill(bob, id, 90);
        // Fulfilling twice reverts: the request is no longer open.
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.RequestNotOpen.selector);
        registry.fulfillAttestationRequest(id, 90, bytes32(0));
        // Unknown id reverts.
        vm.prank(bob);
        vm.expectRevert(
            ReputationRegistry.UnknownAttestationRequest.selector
        );
        registry.fulfillAttestationRequest(99, 90, bytes32(0));
    }

    function testDelegateCannotFulfill() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        vm.prank(bob);
        registry.setDelegate(carol, T0 + 30 days);
        // The request names bob personally; his delegate's answer does
        // not count as bob answering it.
        vm.prank(carol);
        vm.expectRevert(ReputationRegistry.NotRequestAttester.selector);
        registry.fulfillAttestationRequest(id, 90, bytes32(0));
        // The delegate can still attest directly on bob's behalf.
        vm.prank(carol);
        registry.attestOnBehalf(
            bob,
            alice,
            ReputationRegistry.Category.Quality,
            90,
            bytes32(0)
        );
        assertEq(registry.attestationCount(), 1);
    }

    function testFulfillUpdatesExistingRecord() public {
        _attest(bob, alice, ReputationRegistry.Category.Quality, 60);
        assertEq(registry.attestationCount(), 1);
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        uint256 attestationId = _fulfill(bob, id, 95);
        // Same record, updated in place — no second attestation.
        assertEq(attestationId, 0);
        assertEq(registry.attestationCount(), 1);
        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertEq(a.score, 95);
        assertTrue(a.fromRequest);
        assertEq(a.requestId, id);
    }

    function testPlainReattestKeepsRequestLink() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        uint256 attestationId = _fulfill(bob, id, 90);
        _attest(bob, alice, ReputationRegistry.Category.Quality, 70);
        ReputationRegistry.Attestation memory a = registry.attestation(
            attestationId
        );
        assertEq(a.score, 70);
        // The record still remembers the request it came from.
        assertTrue(a.fromRequest);
        assertEq(a.requestId, id);
    }

    function testDirectAttestationHasNoRequestLink() public {
        _attest(bob, alice, ReputationRegistry.Category.Quality, 85);
        ReputationRegistry.Attestation memory a = registry.attestation(0);
        assertFalse(a.fromRequest);
        assertEq(a.requestId, 0);
    }

    function testExpiredRequestCannotFulfillOrCancel() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        vm.warp(T0 + 30 days + 1);
        assertTrue(registry.isRequestExpired(id));
        (bool exists, ) = registry.openRequestId(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        assertFalse(exists);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.RequestExpired.selector);
        registry.fulfillAttestationRequest(id, 90, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.RequestExpired.selector);
        registry.cancelAttestationRequest(id);
        // The dead request does not block a fresh ask.
        uint256 id2 = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        assertEq(id2, 1);
        assertEq(registry.attestationRequestCount(), 2);
    }

    function testRequestValidityConfig() public {
        assertEq(registry.requestValidity(), 30 days);
        registry.setRequestValidity(7 days);
        assertEq(registry.requestValidity(), 7 days);
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        assertEq(registry.attestationRequest(id).expiresAt, T0 + 7 days);
        // Retuning does not move an open request's deadline.
        registry.setRequestValidity(14 days);
        assertEq(registry.attestationRequest(id).expiresAt, T0 + 7 days);

        // Only the owner may retune.
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotOwner.selector);
        registry.setRequestValidity(7 days);
        // Bounds: at least a day, at most a year.
        vm.expectRevert(
            ReputationRegistry.InvalidRequestValidity.selector
        );
        registry.setRequestValidity(0);
        vm.expectRevert(
            ReputationRegistry.InvalidRequestValidity.selector
        );
        registry.setRequestValidity(366 days);
        registry.setRequestValidity(1 days);
        registry.setRequestValidity(365 days);
    }

    function testFulfillBlockedWhilePaused() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        registry.pause();
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.RegistryPaused.selector);
        registry.fulfillAttestationRequest(id, 90, bytes32(0));
        registry.unpause();
        _fulfill(bob, id, 90);
        assertEq(registry.attestationCount(), 1);
    }

    function testFulfillRespectsDailyRateLimit() public {
        // The Timeliness record exists before the quota is spent, so
        // fulfilling a request for it later is a re-attest (free).
        // It is created on a previous UTC day, so it does not consume
        // today's single slot.
        _attest(bob, alice, ReputationRegistry.Category.Timeliness, 50);
        vm.warp(T0 + 1 days);
        registry.setMaxAttestationsPerDay(1);
        uint256 id1 = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        uint256 id2 = _request(
            dave,
            bob,
            ReputationRegistry.Category.Quality
        );
        _fulfill(bob, id1, 90);
        // A second fresh attestation the same day hits the cap.
        vm.prank(bob);
        vm.expectRevert(
            ReputationRegistry.DailyAttestationLimitReached.selector
        );
        registry.fulfillAttestationRequest(id2, 80, bytes32(0));
        // But fulfilling a request that updates an existing record is
        // a re-attest, so it stays free.
        uint256 id3 = _request(
            alice,
            bob,
            ReputationRegistry.Category.Timeliness
        );
        _fulfill(bob, id3, 60);
        assertEq(registry.attestationCount(), 2);
    }

    function testFulfillRespectsSuspensionAndVerifiedOnly() public {
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        registry.strikeAttester(bob);
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AttesterSuspended.selector);
        registry.fulfillAttestationRequest(id, 90, bytes32(0));
        registry.clearStrikes(bob);

        registry.setVerifiedOnly(true);
        vm.prank(bob);
        vm.expectRevert(
            ReputationRegistry.NotVerifiedAttester.selector
        );
        registry.fulfillAttestationRequest(id, 90, bytes32(0));
        registry.setVerifiedAttester(bob, true);
        _fulfill(bob, id, 90);
        assertEq(registry.attestationCount(), 1);
    }

    function testFulfillDisputedRecordBlocked() public {
        _attest(bob, alice, ReputationRegistry.Category.Quality, 60);
        vm.prank(alice);
        registry.disputeAttestation(0, keccak256("unfair"));
        uint256 id = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        vm.prank(bob);
        vm.expectRevert(ReputationRegistry.AlreadyDisputed.selector);
        registry.fulfillAttestationRequest(id, 95, bytes32(0));
    }

    function testRequestAloneDoesNotAffectScores() public {
        _request(alice, bob, ReputationRegistry.Category.Quality);
        ReputationRegistry.Score memory score = registry.getScore(alice);
        assertEq(score.average, 0);
        assertEq(score.count, 0);
    }

    function testOpenRequestReads() public {
        // Bob's inbox: two open, one cancelled, one fulfilled, one expired.
        // The closed/expired requests are created first, then time moves
        // past the expired one's deadline, and only then are the two
        // open asks created — otherwise the warp would expire them too.
        uint256 cancelled = _request(
            alice,
            bob,
            ReputationRegistry.Category.Reliability
        );
        vm.prank(alice);
        registry.cancelAttestationRequest(cancelled);
        uint256 fulfilled = _request(
            dave,
            bob,
            ReputationRegistry.Category.Communication
        );
        _fulfill(bob, fulfilled, 88);
        uint256 expired = _request(
            alice,
            bob,
            ReputationRegistry.Category.Overall
        );
        vm.warp(T0 + 31 days);
        assertTrue(registry.isRequestExpired(expired));

        uint256 open1 = _request(
            alice,
            bob,
            ReputationRegistry.Category.Quality
        );
        uint256 open2 = _request(
            dave,
            bob,
            ReputationRegistry.Category.Timeliness
        );

        ReputationRegistry.AttestationRequest[]
            memory inbox = registry.getOpenRequestsForAttester(bob, 0, 10);
        assertEq(inbox.length, 2);
        assertEq(inbox[0].subject, alice);
        assertEq(inbox[1].subject, dave);

        // Paging: first page of one, then the rest, then empty.
        ReputationRegistry.AttestationRequest[]
            memory page1 = registry.getOpenRequestsForAttester(bob, 0, 1);
        assertEq(page1.length, 1);
        assertEq(
            uint256(page1[0].category),
            uint256(ReputationRegistry.Category.Quality)
        );
        ReputationRegistry.AttestationRequest[]
            memory page2 = registry.getOpenRequestsForAttester(bob, 1, 1);
        assertEq(page2.length, 1);
        assertEq(page2[0].subject, dave);
        assertEq(
            registry.getOpenRequestsForAttester(bob, 2, 10).length,
            0
        );

        // Alice's outbox holds only her one open ask.
        ReputationRegistry.AttestationRequest[]
            memory outbox = registry.getOpenRequestsBySubject(alice, 0, 10);
        assertEq(outbox.length, 1);
        assertEq(outbox[0].attester, bob);

        // Silence the unused-variable warnings for the ids we only
        // created to shape the inbox.
        assertEq(cancelled, 0);
        assertEq(fulfilled, 1);
        assertEq(expired, 2);
        assertEq(open1, 3);
        assertEq(open2, 4);
    }
}
