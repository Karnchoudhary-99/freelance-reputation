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
        disputed[id] = true;
        disputedAt[id] = uint64(block.timestamp);
    }

    function resolveDispute(uint256 seed, bool uphold) external {
        if (created == 0) return;
        uint256 id = seed % created;
        if (revoked[id] || !disputed[id]) return;
        vm.prank(recordAttester[id]);
        registry.resolveDispute(id, uphold);
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
        disputed[id] = false;
        disputedAt[id] = 0;
    }

    function warp(uint256 seed) external {
        // Forward only, up to ~400 days: crosses the 90-day and 365-day
        // decay tiers and the 30-day dispute window in a single run.
        vm.warp(block.timestamp + (seed % 400 days));
    }
}
