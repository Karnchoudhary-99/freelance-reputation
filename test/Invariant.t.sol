// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Fuzz handler driving the registry through attest / revoke /
///         dispute / resolve / expire / escalate / owner-arbitrate /
///         appeal / appeal-arbitrate / request / fulfil / cancel
///         cycles plus time warps, with owner strikes and
///         strike-clearing mixed in, and pauses / unpauses so the
///         fuzz runs exercise the frozen state too.
///         Attestations are sometimes routed through an active
///         delegate (set / revoked by the handler), so the delegate
///         paths get the same lifecycle coverage as direct attests.
/// @dev Every action is guarded to the state it is legal in, so a revert
///      can never mask a broken invariant: if the handler calls the
///      contract, the call is expected to succeed. Actions that are not
///      legal in the current state are no-ops. The handler mirrors the
///      registry's per-record flags because the contract exposes no
///      key-based lookup; every mutation goes through this handler, so
///      the mirror cannot drift. The handler deploys the registry, so
///      it is the owner and may strike / clear strikes / pause.
contract ReputationHandler is Test {
    ReputationRegistry public registry;
    address[] public actors;

    uint256 public created;
    // Timestamps of the last state-changing handler call, per subject
    // (overall scope) and per subject + category (category scope) —
    // warps excluded. A snapshot is only guaranteed to equal the live
    // score while no time has passed since the last change touching
    // its scope: a warp ages every attestation (decay), and a later
    // change to another subject or category does not refresh this
    // subject's/category's frozen snapshot.
    mapping(address => uint256) public lastOverallChangeAt;
    mapping(address => mapping(uint256 => uint256))
        public lastCategoryChangeAt;
    // id => mirror of the record's lifecycle flags
    mapping(uint256 => bool) public revoked;
    mapping(uint256 => bool) public disputed;
    mapping(uint256 => bool) public escalated;
    mapping(uint256 => uint64) public disputedAt;
    // Appeal mirror: whether an appeal is open, when the last
    // resolution upheld the record (0 = no appeal available), and
    // whether the appeal for the current outcome was already used.
    mapping(uint256 => bool) public appealed;
    mapping(uint256 => uint64) public resolvedAt;
    mapping(uint256 => bool) public appealUsed;
    // Attestation-request mirror: every request ever created, in
    // creation order, plus per-request subject / attester / category
    // / expiry / open flag / status / fulfilled-attestation id. The
    // open-key mirror (id + 1, 0 == none open) enforces the
    // one-open-request rule in requestAttestation() so a fuzz call
    // never hits RequestAlreadyOpen. An expired open request stays
    // "open" in the mirror — the guards check expiry against the
    // live clock, like the contract does.
    uint256[] public requestIds;
    mapping(uint256 => address) public requestSubject;
    mapping(uint256 => address) public requestAttester;
    mapping(uint256 => ReputationRegistry.Category) public requestCategory;
    mapping(uint256 => uint64) public requestExpiresAt;
    mapping(uint256 => bool) public requestOpen;
    mapping(uint256 => ReputationRegistry.RequestStatus)
        public requestStatus;
    mapping(uint256 => uint256) public requestAttestationId;
    mapping(bytes32 => uint256) public openRequestByKey;
    mapping(uint256 => address) public recordAttester;
    mapping(uint256 => address) public recordSubject;
    mapping(uint256 => ReputationRegistry.Category) public recordCategory;
    // keccak256(attester, subject, category) => id + 1 (0 == none active)
    mapping(bytes32 => uint256) public activeByKey;
    mapping(address => uint256) public createdFor;
    // Strikes per actor, mirrored so attest() never calls as a
    // suspended attester (that would revert and mask an invariant).
    mapping(address => uint256) public strikes;
    // Dispute outcomes per actor, mirrored so the credibility
    // invariant can check the registry's counters: every ruling
    // (attester resolve, owner arbitration, appeal ruling, and
    // revoke-while-disputed as a concession) lands here exactly
    // once, and a dispute that expires unanswered lands nowhere.
    mapping(address => uint256) public credibilityUpheld;
    mapping(address => uint256) public credibilityConceded;
    // Pause mirror: attest() never calls while paused (that would
    // revert), and pausedAtCount freezes the attestation count at
    // the moment of pausing for the frozen-count invariant.
    bool public paused;
    uint256 public pausedAtCount;
    // Verified-only mirror: when the mode is on, attest() verifies
    // the attester first (the handler is the owner), so a fuzz
    // attestation never hits the NotVerifiedAttester guard. The
    // `verified` mapping mirrors the registry's verified flags.
    bool public verifiedOnly;
    mapping(address => bool) public verified;
    // Delegation mirror: expiry per (attester, delegate) pair, 0 when
    // never set or revoked. attest() routes through an active delegate
    // when one exists, so the mirror must track exactly what the
    // registry stores.
    mapping(address => mapping(address => uint256)) public delegateExpiry;
    // Dispute-bond mirror: bond posted per record id, and the total
    // outstanding. The handler funds disputes from the pranked
    // subject's balance (a pranked call draws its value from the
    // pranked address), so the invariant test deals each actor ETH
    // and enables a bond in setUp.
    mapping(uint256 => uint256) public bondOf;
    uint256 public outstandingBonds;
    // Category-weight mirror, per category index (0 == Overall).
    // Starts at the default for every category, like the registry.
    mapping(uint256 => uint256) public categoryWeights;
    // Sequence numbers for the snapshot invariant: a category-weight
    // retune moves the live overall score without appending a
    // snapshot, so the invariant must skip the overall scope when a
    // retune happened after its last attestation change. `seq`
    // orders handler actions; per-scope numbers record the last
    // attestation change, `lastWeightChangeSeq` the last retune.
    uint256 public seq;
    uint256 public lastWeightChangeSeq;
    mapping(address => uint256) public lastOverallChangeSeq;
    mapping(address => mapping(uint256 => uint256))
        public lastCategoryChangeSeq;

    constructor(address[] memory _actors) {
        registry = new ReputationRegistry();
        actors = _actors;
        for (uint256 c = 0; c < 5; c++) {
            categoryWeights[c] = registry.DEFAULT_CATEGORY_WEIGHT();
        }
    }

    function _key(
        address attester,
        address subject,
        ReputationRegistry.Category category
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(attester, subject, category));
    }

    function attest(uint256 seed) external {
        address attester = actors[seed % actors.length];
        // A suspended attester cannot attest (or re-attest).
        if (strikes[attester] >= registry.MAX_STRIKES()) return;
        // A paused registry accepts no new attestations.
        if (paused) return;
        // Verified-only mode gates every attestation: when it is on,
        // the attester must be verified first (the handler is the
        // owner, so it verifies on the fly and mirrors the flag).
        if (verifiedOnly && !verified[attester]) {
            registry.setVerifiedAttester(attester, true);
            verified[attester] = true;
        }
        // Subject is always a different actor, so self-attestation never fires.
        address subject = actors[(seed / actors.length + 1) % actors.length];
        if (subject == attester) return;
        ReputationRegistry.Category category = ReputationRegistry.Category(
            (seed / 36) % 5
        );
        uint8 score = uint8(seed % 101);
        bytes32 key = _key(attester, subject, category);
        uint256 existing = activeByKey[key];
        if (existing != 0 && disputed[existing - 1]) return; // must resolve first
        if (existing != 0 && appealed[existing - 1]) return; // must arbitrate first
        // Route about half the attestations through an active delegate
        // when the attester has one: the record is identical (same
        // attester, same weight), only the caller differs.
        address delegate;
        for (uint256 i = 0; i < actors.length; i++) {
            address cand = actors[i];
            if (cand == attester) continue;
            if (delegateExpiry[attester][cand] > block.timestamp) {
                delegate = cand;
                break;
            }
        }
        uint256 id;
        if (delegate != address(0) && seed % 2 == 0) {
            vm.prank(delegate);
            id = registry.attestOnBehalf(
                attester,
                subject,
                category,
                score,
                bytes32(seed)
            );
        } else {
            vm.prank(attester);
            id = registry.attest(subject, category, score, bytes32(seed));
        }
        _touch(subject, category);
        if (existing == 0) {
            recordAttester[id] = attester;
            recordSubject[id] = subject;
            recordCategory[id] = category;
            activeByKey[key] = id + 1;
            created++;
            createdFor[subject]++;
        }
    }

    function revoke(uint256 seed) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id]) return;
        vm.prank(recordAttester[id]);
        registry.revokeAttestation(id);
        _touch(recordSubject[id], recordCategory[id]);
        revoked[id] = true;
        // Revoking while disputed settles the dispute — and its bond —
        // and concedes it in effect, so the credibility mirror counts
        // it against the attester.
        if (disputed[id]) {
            _settleBond(id);
            _recordOutcome(recordAttester[id], false);
        }
        disputed[id] = false;
        escalated[id] = false;
        disputedAt[id] = 0;
        // A revoked record has nothing left to appeal.
        appealed[id] = false;
        resolvedAt[id] = 0;
        appealUsed[id] = false;
        activeByKey[
            _key(recordAttester[id], recordSubject[id], recordCategory[id])
        ] = 0;
    }

    function dispute(uint256 seed) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id] || disputed[id] || appealed[id]) return;
        if (_isExpired(id)) return; // expired records cannot be disputed
        // The bond comes from the pranked subject's balance — the
        // invariant test funds every actor.
        uint256 bond = registry.disputeBond();
        vm.prank(recordSubject[id]);
        registry.disputeAttestation{value: bond}(id, bytes32(seed));
        _touch(recordSubject[id], recordCategory[id]);
        disputed[id] = true;
        disputedAt[id] = uint64(block.timestamp);
        // A fresh dispute gets a fresh appeal right.
        resolvedAt[id] = 0;
        appealUsed[id] = false;
        bondOf[id] = bond;
        outstandingBonds += bond;
    }

    /// @notice Settle the mirrored bond when a dispute closes: the
    ///         bond is paid out on every exit (uphold, concede,
    ///         expiry, revoke-while-disputed), so the mirror clears
    ///         whenever the dispute flag does.
    function _settleBond(uint256 id) internal {
        if (bondOf[id] == 0) return;
        outstandingBonds -= bondOf[id];
        bondOf[id] = 0;
    }

    /// @notice Mirror one dispute ruling for the attester's
    ///         credibility (see the registry's `_disputesUpheld` /
    ///         `_disputesConceded`): uphold counts upheld, concede
    ///         counts conceded, and expiry records nothing.
    function _recordOutcome(address attester, bool uphold) internal {
        if (uphold) {
            credibilityUpheld[attester]++;
        } else {
            credibilityConceded[attester]++;
        }
    }

    function resolveDispute(uint256 seed, bool uphold) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id] || !disputed[id]) return;
        vm.prank(recordAttester[id]);
        registry.resolveDispute(id, uphold);
        _touch(recordSubject[id], recordCategory[id]);
        disputed[id] = false;
        escalated[id] = false;
        disputedAt[id] = 0;
        _settleBond(id);
        _recordOutcome(recordAttester[id], uphold);
        // An upheld resolution opens the subject's appeal window.
        if (uphold) {
            resolvedAt[id] = uint64(block.timestamp);
        }
        if (!uphold) {
            revoked[id] = true;
            activeByKey[
                _key(recordAttester[id], recordSubject[id], recordCategory[id])
            ] = 0;
        }
    }

    function expireDispute(uint256 seed) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id] || !disputed[id]) return;
        if (block.timestamp < uint256(disputedAt[id]) + registry.disputeWindow()) {
            return;
        }
        vm.prank(recordSubject[id]);
        registry.expireDispute(id);
        _touch(recordSubject[id], recordCategory[id]);
        disputed[id] = false;
        escalated[id] = false;
        disputedAt[id] = 0;
        _settleBond(id);
    }

    /// @notice Escalate a dispute the attester ignored for at least
    ///         `escalationDelay`. No-op until the delay has passed, and
    ///         never on a settled or already-escalated record. The
    ///         escalation changes no score, so no snapshot is touched.
    function escalate(uint256 seed) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id] || !disputed[id] || escalated[id]) return;
        if (
            block.timestamp <
            uint256(disputedAt[id]) + registry.escalationDelay()
        ) return;
        vm.prank(recordSubject[id]);
        registry.escalateDispute(id);
        escalated[id] = true;
    }

    /// @notice Arbitrate an escalated dispute as the registry owner
    ///         (the handler deployed the registry). Mirrors the
    ///         attester's resolveDispute, including the concede-revokes
    ///         branch, and clears the escalation flag either way.
    function resolveDisputeAsOwner(uint256 seed, bool uphold) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id] || !disputed[id] || !escalated[id]) return;
        registry.resolveDisputeAsOwner(id, uphold);
        _touch(recordSubject[id], recordCategory[id]);
        disputed[id] = false;
        escalated[id] = false;
        disputedAt[id] = 0;
        _settleBond(id);
        _recordOutcome(recordAttester[id], uphold);
        // An upheld resolution opens the subject's appeal window.
        if (uphold) {
            resolvedAt[id] = uint64(block.timestamp);
        }
        if (!uphold) {
            revoked[id] = true;
            activeByKey[
                _key(recordAttester[id], recordSubject[id], recordCategory[id])
            ] = 0;
        }
    }

    /// @notice Appeal an upheld resolution: subject-only, once per
    ///         outcome, within `appealWindow` of the resolution, and
    ///         never on an expired record. Posts the current bond,
    ///         mirrored so the bond-balance invariant stays exact.
    ///         Appeals record a snapshot, so the scope is touched.
    function appeal(uint256 seed) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id] || disputed[id] || appealed[id]) return;
        if (appealUsed[id] || resolvedAt[id] == 0) return;
        if (
            block.timestamp >
            uint256(resolvedAt[id]) + registry.appealWindow()
        ) return;
        if (_isExpired(id)) return;
        uint256 bond = registry.disputeBond();
        vm.prank(recordSubject[id]);
        registry.appealDispute{value: bond}(id);
        _touch(recordSubject[id], recordCategory[id]);
        appealed[id] = true;
        appealUsed[id] = true;
        resolvedAt[id] = 0;
        bondOf[id] = bond;
        outstandingBonds += bond;
    }

    /// @notice Arbitrate an open appeal as the registry owner (the
    ///         handler deployed the registry). Uphold re-confirms,
    ///         concede revokes; the bond settles either way.
    function resolveAppeal(uint256 seed, bool uphold) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id] || !appealed[id]) return;
        registry.resolveAppeal(id, uphold);
        _touch(recordSubject[id], recordCategory[id]);
        appealed[id] = false;
        _settleBond(id);
        _recordOutcome(recordAttester[id], uphold);
        if (!uphold) {
            revoked[id] = true;
            activeByKey[
                _key(recordAttester[id], recordSubject[id], recordCategory[id])
            ] = 0;
        }
    }

    /// @notice Key for the one-open-request-per-ask rule, mirroring
    ///         `ReputationRegistry._requestKey` (which is internal).
    function _requestKey(
        address subject,
        address attester,
        ReputationRegistry.Category category
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(subject, attester, category));
    }

    /// @notice Whether a mirrored request is dead by time: still open
    ///         in the mirror, but past its expiry.
    function _isRequestExpired(uint256 id) internal view returns (bool) {
        return
            requestOpen[id] &&
            requestExpiresAt[id] <= block.timestamp;
    }

    /// @notice Ask an attester for a rating: one open request per
    ///         (subject, attester, category). A paused registry takes
    ///         no new requests, and an unexpired open request for the
    ///         same triple blocks a second ask — an expired one does
    ///         not, so the call goes through and takes its place.
    function requestAttestation(uint256 seed) external {
        address subject = actors[seed % actors.length];
        // Subject is always a different actor, so self-requests never fire.
        address attester = actors[(seed / actors.length + 1) % actors.length];
        if (attester == subject) return;
        if (paused) return;
        ReputationRegistry.Category category = ReputationRegistry.Category(
            (seed / 36) % 5
        );
        bytes32 key = _requestKey(subject, attester, category);
        uint256 existing = openRequestByKey[key];
        if (existing != 0 && !_isRequestExpired(existing - 1)) return;
        vm.prank(subject);
        uint256 id = registry.requestAttestation(
            attester,
            category,
            bytes32(seed)
        );
        requestIds.push(id);
        requestSubject[id] = subject;
        requestAttester[id] = attester;
        requestCategory[id] = category;
        requestExpiresAt[id] =
            uint64(block.timestamp) +
            registry.requestValidity();
        requestOpen[id] = true;
        requestStatus[id] = ReputationRegistry.RequestStatus.Open;
        openRequestByKey[key] = id + 1;
    }

    /// @notice Answer an open request with a rating: the attester
    ///         fulfils it, creating (or updating) the attestation and
    ///         linking the two records. Guarded like attest(): a
    ///         suspended attester cannot answer, a paused registry
    ///         takes no fulfilments, verified-only mode verifies the
    ///         attester first, a disputed or appealed existing record
    ///         blocks the update, and a fresh record that would bust
    ///         the daily quota is skipped.
    function fulfillRequest(uint256 seed) external {
        if (requestIds.length == 0) return;
        uint256 id = requestIds[seed % requestIds.length];
        if (!requestOpen[id] || _isRequestExpired(id)) return;
        address attester = requestAttester[id];
        address subject = requestSubject[id];
        ReputationRegistry.Category category = requestCategory[id];
        if (strikes[attester] >= registry.MAX_STRIKES()) return;
        if (paused) return;
        if (verifiedOnly && !verified[attester]) {
            registry.setVerifiedAttester(attester, true);
            verified[attester] = true;
        }
        bytes32 key = _key(attester, subject, category);
        uint256 existing = activeByKey[key];
        if (existing != 0 && disputed[existing - 1]) return;
        if (existing != 0 && appealed[existing - 1]) return;
        // A fresh record consumes daily quota; an update does not.
        if (
            existing == 0 &&
            registry.maxAttestationsPerDay() > 0 &&
            registry.attestationsToday(attester) >=
            registry.maxAttestationsPerDay()
        ) return;
        uint8 score = uint8(seed % 101);
        vm.prank(attester);
        uint256 attestationId = registry.fulfillAttestationRequest(
            id,
            score,
            bytes32(seed)
        );
        _touch(subject, category);
        requestOpen[id] = false;
        requestStatus[id] = ReputationRegistry.RequestStatus.Fulfilled;
        requestAttestationId[id] = attestationId;
        bytes32 reqKey = _requestKey(subject, attester, category);
        if (openRequestByKey[reqKey] == id + 1) {
            openRequestByKey[reqKey] = 0;
        }
        if (existing == 0) {
            recordAttester[attestationId] = attester;
            recordSubject[attestationId] = subject;
            recordCategory[attestationId] = category;
            activeByKey[key] = attestationId + 1;
            created++;
            createdFor[subject]++;
        }
    }

    /// @notice Withdraw one of your own open requests. Only the
    ///         subject may cancel, and only while the request is
    ///         still open and unexpired.
    function cancelRequest(uint256 seed) external {
        if (requestIds.length == 0) return;
        uint256 id = requestIds[seed % requestIds.length];
        if (!requestOpen[id] || _isRequestExpired(id)) return;
        vm.prank(requestSubject[id]);
        registry.cancelAttestationRequest(id);
        requestOpen[id] = false;
        requestStatus[id] = ReputationRegistry.RequestStatus.Cancelled;
        bytes32 key = _requestKey(
            requestSubject[id],
            requestAttester[id],
            requestCategory[id]
        );
        if (openRequestByKey[key] == id + 1) openRequestByKey[key] = 0;
    }

    function _touch(
        address subject,
        ReputationRegistry.Category category
    ) internal {
        lastOverallChangeAt[subject] = block.timestamp;
        lastCategoryChangeAt[subject][uint256(category)] = block.timestamp;
        seq++;
        lastOverallChangeSeq[subject] = seq;
        lastCategoryChangeSeq[subject][uint256(category)] = seq;
    }

    /// @notice Whether a record is expired right now: its last update
    ///         plus the registry's expiry duration is at or before now.
    ///         Mirrors `ReputationRegistry.isExpired` so the handler
    ///         never calls a function the contract would revert on.
    function _isExpired(uint256 id) internal view returns (bool) {
        uint64 duration = registry.expiryDuration();
        if (duration == 0) return false;
        return
            block.timestamp >=
            uint256(registry.attestation(id).updatedAt) + duration;
    }

    function warp(uint256 seed) external {
        // Forward only, up to ~400 days: crosses the 90-day and 365-day
        // decay tiers and the 30-day dispute window in a single run.
        vm.warp(block.timestamp + (seed % 400 days));
    }

    /// @notice Set the dispute bond (the handler deployed the
    ///         registry, so it is the owner). The invariant test
    ///         enables a bond so the fuzz exercises the bonded
    ///         dispute path; the unit suite covers the free path.
    ///         Guarded like every handler action: an over-cap value
    ///         is a no-op, never a revert, so a fuzz call can never
    ///         mask a broken invariant.
    function setBond(uint256 bond) external {
        if (bond > registry.MAX_DISPUTE_BOND()) return;
        registry.setDisputeBond(bond);
    }

    /// @notice Toggle verified-only mode (on for roughly a third of
    ///         calls). The handler is the registry owner, so this
    ///         always succeeds, and attest() verifies attesters on
    ///         the fly while it is on.
    function setVerifiedOnly(uint256 seed) external {
        bool enabled = seed % 3 == 0;
        registry.setVerifiedOnly(enabled);
        verifiedOnly = enabled;
    }

    /// @notice Retune all three governance windows. The ordering rule
    ///         (escalation delay always shorter than the dispute
    ///         window) forces a sequence: open the window to its
    ///         ceiling first, then set the delay, then the window —
    ///         every step stays inside its bounds, so a fuzz call can
    ///         never revert. The dispute / escalation / appeal mirrors
    ///         read the live values, so a retune mid-run keeps them
    ///         exact.
    function setGovernanceWindows(uint256 seed) external {
        uint256 delay = 1 hours + (seed % (30 days - 1 hours + 1));
        uint256 window = delay +
            1 days +
            ((seed / 1000) % (365 days - delay - 1 days + 1));
        uint256 appeal = 1 days + ((seed / 1000000) % (90 days - 1 days + 1));
        registry.setDisputeWindow(365 days);
        registry.setEscalationDelay(delay);
        registry.setDisputeWindow(window);
        registry.setAppealWindow(appeal);
    }

    /// @notice Retune one category's weight in the overall score,
    ///         mirrored so the weights invariant can check it. The
    ///         handler is the registry owner, so this always succeeds.
    ///         Biased toward the default (100) and toward 0, so the
    ///         fuzz exercises both the equal blend and full exclusion
    ///         regularly instead of only random weights.
    function setCategoryWeight(uint256 seed) external {
        ReputationRegistry.Category category = ReputationRegistry.Category(
            seed % 5
        );
        uint256 weight = seed % 1001;
        if (seed % 4 == 0) weight = registry.DEFAULT_CATEGORY_WEIGHT();
        if (seed % 7 == 0) weight = 0;
        registry.setCategoryWeight(category, weight);
        categoryWeights[uint256(category)] = weight;
        seq++;
        lastWeightChangeSeq = seq;
    }

    /// @notice Strike one actor: their next attestations weigh less,
    ///         and at 3 strikes they are suspended until cleared. The
    ///         handler is the registry owner, so this always succeeds.
    function strike(uint256 seed) external {
        address attester = actors[seed % actors.length];
        registry.strikeAttester(attester);
        strikes[attester]++;
    }

    /// @notice Clear one actor's strikes, reinstating them. No-op when
    ///         they hold no strikes, so the call is always legal.
    function clearStrikes(uint256 seed) external {
        address attester = actors[seed % actors.length];
        if (strikes[attester] == 0) return;
        registry.clearStrikes(attester);
        strikes[attester] = 0;
    }

    /// @notice Authorize one actor as another's delegate for 1-31
    ///         days, mirrored so the delegate invariant can check it.
    function setDelegate(uint256 seed) external {
        address attester = actors[seed % actors.length];
        address delegate = actors[(seed / actors.length + 1) % actors.length];
        if (delegate == attester) return;
        uint256 expiry = block.timestamp + (seed % 30 days) + 1 days;
        vm.prank(attester);
        registry.setDelegate(delegate, expiry);
        delegateExpiry[attester][delegate] = expiry;
    }

    /// @notice Revoke a delegation, mirrored. No-op on the mirror
    ///         when nothing was set (the contract call is idempotent).
    function revokeDelegate(uint256 seed) external {
        address attester = actors[seed % actors.length];
        address delegate = actors[(seed / actors.length + 1) % actors.length];
        if (delegate == attester) return;
        vm.prank(attester);
        registry.revokeDelegate(delegate);
        delegateExpiry[attester][delegate] = 0;
    }

    /// @notice Pause the registry and freeze the attestation count for
    ///         the frozen-count invariant. No-op while already paused.
    function pause() external {
        if (paused) return;
        registry.pause();
        paused = true;
        pausedAtCount = registry.attestationCount();
    }

    /// @notice Unpause the registry. No-op while not paused.
    function unpause() external {
        if (!paused) return;
        registry.unpause();
        paused = false;
    }
}
/// @notice Score-accounting invariants over the registry lifecycle.
contract ReputationInvariants is Test {
    ReputationRegistry public registry;
    ReputationHandler public handler;
    address[] public actors;

    function setUp() public {
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        actors.push(makeAddr("erin"));
        actors.push(makeAddr("frank"));
        handler = new ReputationHandler(actors);
        registry = handler.registry();
        // Fund the handler and enable a bond, so the fuzz exercises
        // bonded disputes and the bond-balance invariant. A pranked
        // call draws its value from the pranked address, so each
        // actor (the dispute subjects) is funded, not the handler.
        for (uint256 i = 0; i < actors.length; i++) {
            vm.deal(actors[i], 100 ether);
        }
        handler.setBond(0.01 ether);
        targetContract(address(handler));
    }

    function invariant_score_bounds_and_zero() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            ReputationRegistry.Score memory s = registry.getScore(actors[i]);
            assertLe(s.average, 10000);
            if (s.count == 0) {
                assertEq(s.average, 0);
                assertEq(s.effectiveWeight, 0);
                assertEq(s.totalWeight, 0);
            } else {
                assertGt(s.effectiveWeight, 0);
                assertGt(s.totalWeight, 0);
            }
        }
    }

    function invariant_count_matches_active_records() public view {
        uint64 duration = registry.expiryDuration();
        for (uint256 i = 0; i < actors.length; i++) {
            ReputationRegistry.Attestation[] memory recs = registry
                .getAttestations(actors[i]);
            uint256 active;
            for (uint256 j = 0; j < recs.length; j++) {
                if (recs[j].revoked || recs[j].disputed || recs[j].appealed) {
                    continue;
                }
                // Expired records stop counting, like revoked ones.
                if (
                    duration > 0 &&
                    block.timestamp >=
                    uint256(recs[j].updatedAt) + duration
                ) continue;
                // Zero-weight categories drop out of the overall
                // score entirely, count included.
                if (registry.categoryWeight(recs[j].category) == 0) continue;
                active++;
            }
            assertEq(registry.getScore(actors[i]).count, active);
        }
    }

    function invariant_category_counts_sum_to_overall() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 sum;
            for (uint256 c = 0; c < 5; c++) {
                // Zero-weight categories drop out of the overall
                // score, count included, so only weighted categories
                // sum to it.
                if (
                    registry.categoryWeight(
                        ReputationRegistry.Category(c)
                    ) == 0
                ) continue;
                sum += registry
                    .getScoreByCategory(
                        actors[i],
                        ReputationRegistry.Category(c)
                    )
                    .count;
            }
            assertEq(sum, registry.getScore(actors[i]).count);
        }
    }

    function invariant_recomputed_average_matches() public view {
        uint64 duration = registry.expiryDuration();
        for (uint256 i = 0; i < actors.length; i++) {
            ReputationRegistry.Attestation[] memory recs = registry
                .getAttestations(actors[i]);
            uint256 weightedSum;
            uint256 effective;
            uint256 total;
            uint256 count;
            for (uint256 j = 0; j < recs.length; j++) {
                if (recs[j].revoked || recs[j].disputed || recs[j].appealed) {
                    continue;
                }
                if (
                    duration > 0 &&
                    block.timestamp >=
                    uint256(recs[j].updatedAt) + duration
                ) continue;
                // Zero-weight categories drop out of the overall
                // score entirely, so they contribute nothing here.
                if (registry.categoryWeight(recs[j].category) == 0) {
                    continue;
                }
                // The overall score weights each record by its
                // category too (per-category scores never are — this
                // invariant recomputes the overall scope only).
                uint256 eff = uint256(recs[j].weight) *
                    registry.decayFactorBps(recs[j].updatedAt) *
                    registry.categoryWeight(recs[j].category) /
                    registry.DEFAULT_CATEGORY_WEIGHT();
                weightedSum += uint256(recs[j].score) * eff;
                effective += eff;
                total += recs[j].weight;
                count++;
            }
            ReputationRegistry.Score memory s = registry.getScore(actors[i]);
            assertEq(s.count, count);
            assertEq(s.effectiveWeight, effective);
            assertEq(s.totalWeight, total);
            if (count > 0) {
                assertEq(s.average, (weightedSum * 100) / effective);
            } else {
                assertEq(s.average, 0);
            }
        }
    }

    function invariant_no_duplicate_active_keys() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            ReputationRegistry.Attestation[] memory recs = registry
                .getAttestations(actors[i]);
            for (uint256 j = 0; j < recs.length; j++) {
                if (recs[j].revoked || recs[j].disputed || recs[j].appealed) {
                    continue;
                }
                for (uint256 k = j + 1; k < recs.length; k++) {
                    if (
                        recs[k].revoked ||
                        recs[k].disputed ||
                        recs[k].appealed
                    ) continue;
                    // Two active records for the same subject must never
                    // share (attester, category): re-attesting updates.
                    assertTrue(
                        recs[j].attester != recs[k].attester ||
                            recs[j].category != recs[k].category
                    );
                }
            }
        }
    }

    function invariant_record_ranges_and_totals() public view {
        assertEq(registry.attestationCount(), handler.created());
        uint256 summed;
        for (uint256 i = 0; i < actors.length; i++) {
            ReputationRegistry.Attestation[] memory recs = registry
                .getAttestations(actors[i]);
            summed += recs.length;
            assertEq(recs.length, handler.createdFor(actors[i]));
            for (uint256 j = 0; j < recs.length; j++) {
                assertLe(recs[j].score, 100);
                assertGe(recs[j].weight, 1);
                assertLe(recs[j].weight, 3);
                assertTrue(recs[j].attester != recs[j].subject);
            }
        }
        assertEq(summed, handler.created());
    }

    /// @notice The handler's strike mirror matches the registry, the
    ///         suspension flag follows the 3-strike threshold, and the
    ///         snapshot weight is 0 exactly while suspended, 1-3
    ///         otherwise — strikes never rewrite a stored record, so
    ///         weights already on-chain stay in range.
    function invariant_strikes_mirror_and_weight_bounds() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 s = registry.strikes(actors[i]);
            assertEq(s, handler.strikes(actors[i]));
            assertEq(
                registry.isSuspended(actors[i]),
                s >= registry.MAX_STRIKES()
            );
            uint8 w = registry.attesterWeight(actors[i]);
            if (s >= registry.MAX_STRIKES()) {
                assertEq(w, 0);
            } else {
                assertGe(w, 1);
                assertLe(w, 3);
            }
        }
    }

    /// @notice The latest frozen snapshot must equal the live score —
    ///         but only while no time has passed since the last state
    ///         change touching that scope: a warp ages every attestation
    ///         (decay), so the live score drifts from the frozen snapshot
    ///         by design, and a change to another subject or category
    ///         does not refresh this scope's snapshot. The handler
    ///         tracks the last mutation timestamp per subject and per
    ///         subject + category, so this invariant checks exactly the
    ///         scopes where the two must agree, overall + all four
    ///         categories. One more drift is by design: a category-weight
    ///         retune moves the live OVERALL score without appending a
    ///         snapshot, so the overall scope is skipped when a retune
    ///         happened after its last attestation change (the handler
    ///         orders actions with sequence numbers for exactly this).
    ///         Per-category snapshots never drift on a retune — those
    ///         scores are never weighted.
    function invariant_latest_snapshot_matches_live_score() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            for (uint256 c = 0; c < 5; c++) {
                uint256 lastChange = c == 0
                    ? handler.lastOverallChangeAt(actors[i])
                    : handler.lastCategoryChangeAt(actors[i], c);
                if (block.timestamp != lastChange) continue;
                if (
                    c == 0 &&
                    handler.lastWeightChangeSeq() >
                    handler.lastOverallChangeSeq(actors[i])
                ) continue;
                ReputationRegistry.Category category = ReputationRegistry
                    .Category(c);
                uint256 len = registry.scoreHistoryLength(
                    actors[i],
                    category
                );
                if (len == 0) continue;
                ReputationRegistry.ScoreSnapshot[] memory last = registry
                    .getScoreHistory(actors[i], category, len - 1, 1);
                ReputationRegistry.Score memory live = c == 0
                    ? registry.getScore(actors[i])
                    : registry.getScoreByCategory(actors[i], category);
                assertEq(last[0].average, live.average);
                assertEq(last[0].count, live.count);
                assertEq(last[0].effectiveWeight, live.effectiveWeight);
            }
        }
    }

    /// @notice While the registry is paused, no attestation can be
    ///         created or updated, so the attestation count must stay
    ///         exactly where it was when the pause landed. Revokes
    ///         do not change the count (records stay on-chain), and
    ///         the handler never attests while paused, so any drift
    ///         means the pause guard leaked a write.
    function invariant_attestation_count_frozen_while_paused() public view {
        if (!handler.paused()) return;
        assertTrue(registry.paused());
        assertEq(registry.attestationCount(), handler.pausedAtCount());
    }

    /// @notice The handler's delegation mirror matches the registry
    ///         exactly — expiry per (attester, delegate) pair — and
    ///         `isDelegate` is true exactly while the mirrored expiry
    ///         is still in the future. Warps age the mirror the same
    ///         way they age the registry, because both compare the
    ///         stored expiry against the current time.
    function invariant_delegate_mirror_matches() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            for (uint256 j = 0; j < actors.length; j++) {
                if (i == j) continue;
                uint256 expiry = handler.delegateExpiry(actors[i], actors[j]);
                assertEq(
                    registry.delegateExpiry(actors[i], actors[j]),
                    expiry
                );
                assertEq(
                    registry.isDelegate(actors[i], actors[j]),
                    expiry > block.timestamp
                );
            }
        }
    }

    /// @notice The handler's escalation mirror matches the registry
    ///         exactly, and an escalated record is always still
    ///         disputed — escalation never settles a dispute, it only
    ///         opens the owner-arbitration path, and every exit
    ///         (attester resolve, owner resolve, expiry, revoke)
    ///         clears the flag on both sides.
    function invariant_escalation_mirror_matches() public view {
        uint256 created = handler.created();
        for (uint256 id = 0; id < created; id++) {
            ReputationRegistry.Attestation memory a = registry.attestation(
                id
            );
            assertEq(a.escalated, handler.escalated(id));
            assertEq(registry.isDisputeEscalated(id), handler.escalated(id));
            if (a.escalated) {
                assertTrue(a.disputed);
            }
        }
    }

    /// @notice No attester ever exceeds the daily fresh-attestation
    ///         limit in the current UTC day. The fuzz handler never
    ///         lowers the limit, so the default (50) applies — and a
    ///         run can create at most 25 fresh records per attester
    ///         (5 other subjects x 5 categories), so the bound is
    ///         reachable in principle but never crossed in practice.
    function invariant_daily_limit_never_exceeded() public view {
        uint256 limit = registry.maxAttestationsPerDay();
        if (limit == 0) return; // 0 disables the limit entirely
        for (uint256 i = 0; i < actors.length; i++) {
            assertLe(registry.attestationsToday(actors[i]), limit);
        }
    }

    /// @notice The registry holds exactly the bonds posted on open
    ///         disputes — no more, no less. Every dispute escrows
    ///         exactly `disputeBond`, and every exit (uphold, concede,
    ///         expiry, revoke-while-disputed) pays its bond out, so
    ///         the balance can never drift from the mirrored total.
    ///         A stuck bond (or a payout that created ETH from
    ///         nowhere) would break this on the next invariant check.
    function invariant_dispute_bond_balance_matches() public view {
        assertEq(address(registry).balance, handler.outstandingBonds());
        uint256 created = handler.created();
        for (uint256 id = 0; id < created; id++) {
            assertEq(registry.disputeBondOf(id), handler.bondOf(id));
        }
    }

    /// @notice The handler's category-weight mirror matches the
    ///         registry exactly, and every weight stays in the
    ///         owner-settable range (0 to the 1000 cap). A retune
    ///         that wrote a different weight — or a weight above the
    ///         cap — would break this on the next invariant check.
    function invariant_category_weights_mirror_matches() public view {
        for (uint256 c = 0; c < 5; c++) {
            uint256 weight = registry.categoryWeight(
                ReputationRegistry.Category(c)
            );
            assertEq(weight, handler.categoryWeights(c));
            assertLe(weight, registry.MAX_CATEGORY_WEIGHT());
        }
        uint256[5] memory all = registry.categoryWeights();
        for (uint256 c = 0; c < 5; c++) {
            assertEq(
                all[c],
                registry.categoryWeight(ReputationRegistry.Category(c))
            );
        }
    }

    /// @notice The handler's appeal mirror matches the registry
    ///         exactly: an appealed record is always still active
    ///         (not revoked, not disputed), an appeal is usable
    ///         exactly once per upheld resolution, and a stored
    ///         resolution time implies no appeal is open or used.
    ///         The deadline view agrees with the stored time.
    function invariant_appeal_mirror_matches() public view {
        uint256 created = handler.created();
        for (uint256 id = 0; id < created; id++) {
            ReputationRegistry.Attestation memory a = registry.attestation(
                id
            );
            assertEq(a.appealed, handler.appealed(id));
            assertEq(registry.isAppealed(id), handler.appealed(id));
            assertEq(a.resolvedAt, handler.resolvedAt(id));
            assertEq(a.appealUsed, handler.appealUsed(id));
            if (a.appealed) {
                assertFalse(a.revoked);
                assertFalse(a.disputed);
                assertTrue(a.appealUsed);
                assertEq(a.resolvedAt, 0);
            }
            if (a.resolvedAt != 0) {
                assertFalse(a.disputed);
                assertFalse(a.appealed);
                assertFalse(a.appealUsed);
                assertFalse(a.revoked);
            }
            assertEq(
                registry.appealDeadline(id),
                a.resolvedAt == 0
                    ? 0
                    : a.resolvedAt + uint64(registry.appealWindow())
            );
        }
    }

    /// @notice The overall average is a weighted mean of the active
    ///         attestations' scores, so it can never fall outside
    ///         their range: at least the lowest active score, at most
    ///         the highest. Category weights, decay, and snapshot
    ///         weights only move the blend inside that range — a
    ///         weight that leaked into the average itself (or a
    ///         division slip) would break this.
    function invariant_overall_average_within_active_score_range()
        public
        view
    {
        uint64 duration = registry.expiryDuration();
        for (uint256 i = 0; i < actors.length; i++) {
            ReputationRegistry.Attestation[] memory recs = registry
                .getAttestations(actors[i]);
            uint256 minScore = 100;
            uint256 maxScore;
            uint256 count;
            for (uint256 j = 0; j < recs.length; j++) {
                if (recs[j].revoked || recs[j].disputed || recs[j].appealed) {
                    continue;
                }
                if (
                    duration > 0 &&
                    block.timestamp >=
                    uint256(recs[j].updatedAt) + duration
                ) continue;
                // Zero-weight categories drop out of the overall
                // score entirely, so the range is over the records
                // that actually count toward it.
                if (registry.categoryWeight(recs[j].category) == 0) {
                    continue;
                }
                if (recs[j].score < minScore) minScore = recs[j].score;
                if (recs[j].score > maxScore) maxScore = recs[j].score;
                count++;
            }
            if (count == 0) continue;
            uint256 average = registry.getScore(actors[i]).average;
            assertGe(average, minScore * 100);
            assertLe(average, maxScore * 100);
        }
    }

    /// @notice The governance windows always stay inside the bounds
    ///         their setters enforce, and the escalation delay always
    ///         stays shorter than the dispute window — a retune that
    ///         broke the ordering would make escalation unreachable
    ///         before a dispute expires.
    function invariant_governance_windows_in_bounds_and_ordered()
        public
        view
    {
        assertGe(registry.disputeWindow(), 1 days);
        assertLe(registry.disputeWindow(), 365 days);
        assertGe(registry.escalationDelay(), 1 hours);
        assertLe(registry.escalationDelay(), 30 days);
        assertLt(registry.escalationDelay(), registry.disputeWindow());
        assertGe(registry.appealWindow(), 1 days);
        assertLe(registry.appealWindow(), 90 days);
    }

    /// @notice The verified-only mode and the verified flags always
    ///         match the handler's mirror: a mode toggle the mirror
    ///         missed would let the handler attest as an unverified
    ///         attester (reverting and masking the other invariants),
    ///         and a verification the mirror missed would misstate
    ///         who may attest.
    function invariant_verified_only_mirror_matches() public view {
        assertEq(registry.verifiedOnly(), handler.verifiedOnly());
        for (uint256 i = 0; i < actors.length; i++) {
            assertEq(
                registry.isVerifiedAttester(actors[i]),
                handler.verified(actors[i])
            );
        }
    }

    /// @notice Attestation requests mirror the handler, and every
    ///         fulfilled request links to a matching attestation:
    ///         the record it names carries the same attester, subject
    ///         and category and flags itself as from a request, and
    ///         the record's own link points back at a fulfilled
    ///         request for the same triple (the latest one, when the
    ///         same ask was requested and fulfilled twice — the
    ///         record is updated in place, so its link moves to the
    ///         newest request). An open, unexpired request is always
    ///         findable through `openRequestId` for its triple.
    function invariant_fulfilled_requests_link_to_attestations()
        public
        view
    {
        uint256 count = registry.attestationRequestCount();
        for (uint256 i = 0; i < count; i++) {
            ReputationRegistry.AttestationRequest memory req = registry
                .attestationRequest(i);
            assertEq(req.subject, handler.requestSubject(i));
            assertEq(req.attester, handler.requestAttester(i));
            assertEq(
                uint256(req.category),
                uint256(handler.requestCategory(i))
            );
            assertEq(req.expiresAt, handler.requestExpiresAt(i));
            assertEq(
                uint256(req.status),
                uint256(handler.requestStatus(i))
            );
            assertEq(req.attestationId, handler.requestAttestationId(i));
            if (
                req.status ==
                ReputationRegistry.RequestStatus.Fulfilled
            ) {
                ReputationRegistry.Attestation memory a = registry
                    .attestation(req.attestationId);
                assertTrue(a.fromRequest);
                assertEq(a.attester, req.attester);
                assertEq(a.subject, req.subject);
                assertEq(uint256(a.category), uint256(req.category));
                ReputationRegistry.AttestationRequest
                    memory linked = registry.attestationRequest(
                        a.requestId
                    );
                assertEq(
                    uint256(linked.status),
                    uint256(ReputationRegistry.RequestStatus.Fulfilled)
                );
                assertEq(linked.attester, req.attester);
                assertEq(linked.subject, req.subject);
                assertEq(
                    uint256(linked.category),
                    uint256(req.category)
                );
                assertEq(linked.attestationId, req.attestationId);
            }
            if (
                req.status == ReputationRegistry.RequestStatus.Open &&
                block.timestamp < uint256(req.expiresAt)
            ) {
                (bool exists, uint256 found) = registry.openRequestId(
                    req.subject,
                    req.attester,
                    req.category
                );
                assertTrue(exists);
                assertEq(found, i);
            }
        }
    }

    /// @notice The handler's dispute-outcome mirror matches the
    ///         registry's credibility counters exactly, and the
    ///         basis-points score is exactly the upheld share (or
    ///         10000 with no ruled dispute yet). Every ruling path
    ///         — attester resolve, owner arbitration, appeal ruling,
    ///         revoke-while-disputed as a concession — must land in
    ///         the counters once, and a dispute that expires
    ///         unanswered must land nowhere: a counter that drifted
    ///         from the mirror would misstate an attester's track
    ///         record on the board.
    function invariant_credibility_mirror_matches() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            (
                uint256 bps,
                uint256 upheld,
                uint256 conceded
            ) = registry.attesterCredibility(actors[i]);
            assertEq(upheld, handler.credibilityUpheld(actors[i]));
            assertEq(conceded, handler.credibilityConceded(actors[i]));
            uint256 total = upheld + conceded;
            if (total == 0) {
                assertEq(bps, 10000);
            } else {
                assertEq(bps, (upheld * 10000) / total);
            }
            ReputationRegistry.AttesterStats memory st = registry
                .attesterStats(actors[i]);
            assertEq(st.disputesUpheld, upheld);
            assertEq(st.disputesConceded, conceded);
            assertEq(st.credibilityBps, bps);
        }
    }
}
