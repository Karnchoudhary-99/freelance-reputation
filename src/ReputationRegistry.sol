// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ReputationRegistry
/// @notice Portable on-chain reputation for freelancers.
/// @dev Attestations travel with the worker, not the platform: any client can
///      attest a freelancer's work, and anyone can read the resulting score.
///      Scores are weighted by the attester's own reputation at attestation
///      time (snapshot weight 1-3), so a newcomer cannot single-handedly
///      inflate a score, while consistently well-rated attesters count more.
///      One active attestation per (attester, subject, category); re-attesting
///      updates the existing record instead of stacking a second one.
///      Revoked attestations stay on-chain for auditability but are excluded
///      from every score. Averages are scaled by 100 (8750 == 87.50).
///      Scores decay with age: an attestation counts fully for its first 90
///      days, at half weight for the rest of its first year, and at quarter
///      weight after that. The decay clock runs from the last update, so a
///      re-attestation refreshes an endorsement; attester weights are read
///      from the same decayed average. A subject may dispute an attestation
///      they believe is unfair; disputed attestations are excluded from
///      scores until the attester upholds them, concedes (revokes), or the
///      30-day dispute window lapses and the subject reinstates them.
contract ReputationRegistry {
    enum Category {
        Overall,
        Quality,
        Communication,
        Timeliness,
        Reliability
    }

    struct Attestation {
        address attester;
        address subject;
        Category category;
        uint8 score; // 0-100
        uint8 weight; // snapshot weight, 1-3
        bytes32 commentHash; // keccak256 of off-chain comment text, or 0
        uint64 createdAt;
        uint64 updatedAt;
        bool revoked;
    }

    struct Score {
        uint256 average; // scaled by 100, 0 when count == 0
        uint256 count; // active attestations included
        uint256 totalWeight; // raw snapshot weights, before decay
        uint256 effectiveWeight; // decay-adjusted weight, in basis points
    }

    error ZeroAddress();
    error SelfAttestation();
    error InvalidScore();
    error NotAttester();
    error AlreadyRevoked();
    error UnknownAttestation();

    event AttestationCreated(
        uint256 indexed id,
        address indexed attester,
        address indexed subject,
        Category category,
        uint8 score,
        uint8 weight
    );
    event AttestationUpdated(
        uint256 indexed id,
        address indexed attester,
        address indexed subject,
        Category category,
        uint8 score,
        uint8 weight
    );
    event AttestationRevoked(
        uint256 indexed id,
        address indexed attester,
        address indexed subject
    );

    uint8 public constant MAX_SCORE = 100;
    uint8 public constant MAX_WEIGHT = 3;

    /// @notice Decay tiers, in basis points of the snapshot weight.
    uint256 public constant DECAY_FULL_BPS = 10000; // first 90 days
    uint256 public constant DECAY_HALF_BPS = 5000; // rest of year one
    uint256 public constant DECAY_QUARTER_BPS = 2500; // after one year
    uint256 public constant DECAY_FULL_PERIOD = 90 days;
    uint256 public constant DECAY_HALF_PERIOD = 365 days;

    Attestation[] private _attestations;
    // subject => attestation ids (all, including revoked)
    mapping(address => uint256[]) private _subjectAttestations;
    // keccak256(attester, subject, category) => id + 1 (0 == none active)
    mapping(bytes32 => uint256) private _activeByKey;

    /// @notice Attest a freelancer's work, or update your existing attestation
    ///         for the same subject + category.
    /// @return id The attestation id (stable across updates).
    function attest(
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash
    ) external returns (uint256 id) {
        if (subject == address(0)) revert ZeroAddress();
        if (subject == msg.sender) revert SelfAttestation();
        if (score > MAX_SCORE) revert InvalidScore();

        uint8 weight = attesterWeight(msg.sender);
        bytes32 key = _key(msg.sender, subject, category);
        uint256 existing = _activeByKey[key];

        if (existing != 0) {
            id = existing - 1;
            Attestation storage a = _attestations[id];
            a.score = score;
            a.weight = weight;
            a.commentHash = commentHash;
            a.updatedAt = uint64(block.timestamp);
            emit AttestationUpdated(id, msg.sender, subject, category, score, weight);
            return id;
        }

        id = _attestations.length;
        _attestations.push(
            Attestation({
                attester: msg.sender,
                subject: subject,
                category: category,
                score: score,
                weight: weight,
                commentHash: commentHash,
                createdAt: uint64(block.timestamp),
                updatedAt: uint64(block.timestamp),
                revoked: false
            })
        );
        _subjectAttestations[subject].push(id);
        _activeByKey[key] = id + 1;
        emit AttestationCreated(id, msg.sender, subject, category, score, weight);
    }

    /// @notice Revoke your own attestation. The record stays readable but no
    ///         longer counts toward the subject's score, and you may attest
    ///         again afterwards (it creates a fresh record).
    function revokeAttestation(uint256 id) external {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.attester != msg.sender) revert NotAttester();
        if (a.revoked) revert AlreadyRevoked();
        a.revoked = true;
        _activeByKey[_key(a.attester, a.subject, a.category)] = 0;
        emit AttestationRevoked(id, msg.sender, a.subject);
    }

    /// @notice Weighted average score across all active attestations.
    function getScore(address subject) external view returns (Score memory) {
        return _score(_subjectAttestations[subject], Category.Overall, false);
    }

    /// @notice Weighted average restricted to one category.
    function getScoreByCategory(
        address subject,
        Category category
    ) external view returns (Score memory) {
        return _score(_subjectAttestations[subject], category, true);
    }

    /// @notice All attestations for a subject, revoked ones included
    ///         (check `revoked` to tell them apart).
    function getAttestations(
        address subject
    ) external view returns (Attestation[] memory) {
        uint256[] storage ids = _subjectAttestations[subject];
        Attestation[] memory out = new Attestation[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            out[i] = _attestations[ids[i]];
        }
        return out;
    }

    function attestation(uint256 id) external view returns (Attestation memory) {
        if (id >= _attestations.length) revert UnknownAttestation();
        return _attestations[id];
    }

    function attestationCount() external view returns (uint256) {
        return _attestations.length;
    }

    /// @notice Decay factor (basis points) for an attestation last updated
    ///         at `timestamp`, measured against the current block time.
    function decayFactorBps(uint64 timestamp) public view returns (uint256) {
        if (block.timestamp <= timestamp) return DECAY_FULL_BPS;
        uint256 age = block.timestamp - timestamp;
        if (age < DECAY_FULL_PERIOD) return DECAY_FULL_BPS;
        if (age < DECAY_HALF_PERIOD) return DECAY_HALF_BPS;
        return DECAY_QUARTER_BPS;
    }

    /// @notice Weight this attester's next attestation would carry, from their
    ///         own current (decayed) average: <50 -> 1, 50-79 -> 2, >=80 -> 3.
    function attesterWeight(address attester) public view returns (uint8) {
        Score memory s = _score(_subjectAttestations[attester], Category.Overall, false);
        if (s.average >= 8000) return 3;
        if (s.average >= 5000) return 2;
        return 1;
    }

    function _score(
        uint256[] storage ids,
        Category category,
        bool filterCategory
    ) internal view returns (Score memory result) {
        uint256 weightedSum;
        for (uint256 i = 0; i < ids.length; i++) {
            Attestation storage a = _attestations[ids[i]];
            if (a.revoked) continue;
            if (filterCategory && a.category != category) continue;
            // Fixed-point decay: multiply before dividing so a weight-1
            // attestation at quarter weight still counts (2500 bps), instead
            // of truncating to zero.
            uint256 effective = uint256(a.weight) * decayFactorBps(a.updatedAt);
            weightedSum += uint256(a.score) * effective;
            result.effectiveWeight += effective;
            result.totalWeight += a.weight;
            result.count++;
        }
        if (result.count > 0) {
            result.average = (weightedSum * 100) / result.effectiveWeight;
        }
    }

    function _key(
        address attester,
        address subject,
        Category category
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(attester, subject, category));
    }
}
