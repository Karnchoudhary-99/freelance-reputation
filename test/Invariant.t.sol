// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Fuzz handler driving the registry through attest / revoke /
///         dispute / resolve / expire cycles plus time warps, with
///         owner strikes and strike-clearing mixed in, and pauses /
///         unpauses so the fuzz runs exercise the frozen state too.
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
    mapping(uint256 => uint64) public disputedAt;
    mapping(uint256 => address) public recordAttester;
    mapping(uint256 => address) public recordSubject;
    mapping(uint256 => ReputationRegistry.Category) public recordCategory;
    // keccak256(attester, subject, category) => id + 1 (0 == none active)
    mapping(bytes32 => uint256) public activeByKey;
    mapping(address => uint256) public createdFor;
    // Strikes per actor, mirrored so attest() never calls as a
    // suspended attester (that would revert and mask an invariant).
    mapping(address => uint256) public strikes;
    // Pause mirror: attest() never calls while paused (that would
    // revert), and pausedAtCount freezes the attestation count at
    // the moment of pausing for the frozen-count invariant.
    bool public paused;
    uint256 public pausedAtCount;
    // Delegation mirror: expiry per (attester, delegate) pair, 0 when
    // never set or revoked. attest() routes through an active delegate
    // when one exists, so the mirror must track exactly what the
    // registry stores.
    mapping(address => mapping(address => uint256)) public delegateExpiry;

    constructor(address[] memory _actors) {
        registry = new ReputationRegistry();
        actors = _actors;
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
        disputed[id] = false;
        disputedAt[id] = 0;
        activeByKey[
            _key(recordAttester[id], recordSubject[id], recordCategory[id])
        ] = 0;
    }

    function dispute(uint256 seed) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id] || disputed[id]) return;
        if (_isExpired(id)) return; // expired records cannot be disputed
        vm.prank(recordSubject[id]);
        registry.disputeAttestation(id, bytes32(seed));
        _touch(recordSubject[id], recordCategory[id]);
        disputed[id] = true;
        disputedAt[id] = uint64(block.timestamp);
    }

    function resolveDispute(uint256 seed, bool uphold) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id] || !disputed[id]) return;
        vm.prank(recordAttester[id]);
        registry.resolveDispute(id, uphold);
        _touch(recordSubject[id], recordCategory[id]);
        disputed[id] = false;
        disputedAt[id] = 0;
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
        if (block.timestamp < uint256(disputedAt[id]) + registry.DISPUTE_WINDOW()) {
            return;
        }
        vm.prank(recordSubject[id]);
        registry.expireDispute(id);
        _touch(recordSubject[id], recordCategory[id]);
        disputed[id] = false;
        disputedAt[id] = 0;
    }

    function _touch(
        address subject,
        ReputationRegistry.Category category
    ) internal {
        lastOverallChangeAt[subject] = block.timestamp;
        lastCategoryChangeAt[subject][uint256(category)] = block.timestamp;
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
                if (recs[j].revoked || recs[j].disputed) continue;
                // Expired records stop counting, like revoked ones.
                if (
                    duration > 0 &&
                    block.timestamp >=
                    uint256(recs[j].updatedAt) + duration
                ) continue;
                active++;
            }
            assertEq(registry.getScore(actors[i]).count, active);
        }
    }

    function invariant_category_counts_sum_to_overall() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 sum;
            for (uint256 c = 0; c < 5; c++) {
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
                if (recs[j].revoked || recs[j].disputed) continue;
                if (
                    duration > 0 &&
                    block.timestamp >=
                    uint256(recs[j].updatedAt) + duration
                ) continue;
                uint256 eff = uint256(recs[j].weight) *
                    registry.decayFactorBps(recs[j].updatedAt);
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
                if (recs[j].revoked || recs[j].disputed) continue;
                for (uint256 k = j + 1; k < recs.length; k++) {
                    if (recs[k].revoked || recs[k].disputed) continue;
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
    ///         categories.
    function invariant_latest_snapshot_matches_live_score() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            for (uint256 c = 0; c < 5; c++) {
                uint256 lastChange = c == 0
                    ? handler.lastOverallChangeAt(actors[i])
                    : handler.lastCategoryChangeAt(actors[i], c);
                if (block.timestamp != lastChange) continue;
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
}
