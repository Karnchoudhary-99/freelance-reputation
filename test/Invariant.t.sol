// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Fuzz handler driving the registry through attest / revoke /
///         dispute / resolve / expire cycles plus time warps.
/// @dev Every action is guarded to the state it is legal in, so a revert
///      can never mask a broken invariant: if the handler calls the
///      contract, the call is expected to succeed. Actions that are not
///      legal in the current state are no-ops. The handler mirrors the
///      registry's per-record flags because the contract exposes no
///      key-based lookup; every mutation goes through this handler, so
///      the mirror cannot drift.
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

    constructor(ReputationRegistry _registry, address[] memory _actors) {
        registry = _registry;
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
        vm.prank(attester);
        uint256 id = registry.attest(subject, category, score, bytes32(seed));
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

    function warp(uint256 seed) external {
        // Forward only, up to ~400 days: crosses the 90-day and 365-day
        // decay tiers and the 30-day dispute window in a single run.
        vm.warp(block.timestamp + (seed % 400 days));
    }
}
/// @notice Score-accounting invariants over the registry lifecycle.
contract ReputationInvariants is Test {
    ReputationRegistry public registry;
    ReputationHandler public handler;
    address[] public actors;

    function setUp() public {
        registry = new ReputationRegistry();
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        actors.push(makeAddr("erin"));
        actors.push(makeAddr("frank"));
        handler = new ReputationHandler(registry, actors);
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
        for (uint256 i = 0; i < actors.length; i++) {
            ReputationRegistry.Attestation[] memory recs = registry
                .getAttestations(actors[i]);
            uint256 active;
            for (uint256 j = 0; j < recs.length; j++) {
                if (!recs[j].revoked && !recs[j].disputed) active++;
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
        for (uint256 i = 0; i < actors.length; i++) {
            ReputationRegistry.Attestation[] memory recs = registry
                .getAttestations(actors[i]);
            uint256 weightedSum;
            uint256 effective;
            uint256 total;
            uint256 count;
            for (uint256 j = 0; j < recs.length; j++) {
                if (recs[j].revoked || recs[j].disputed) continue;
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
}
