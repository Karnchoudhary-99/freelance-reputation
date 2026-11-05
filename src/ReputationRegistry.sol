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
        bool disputed;
        bytes32 disputeReason; // keccak256 of off-chain dispute text, or 0
        uint64 disputedAt;
    }

    struct Score {
        uint256 average; // scaled by 100, 0 when count == 0
        uint256 count; // active attestations included
        uint256 totalWeight; // raw snapshot weights, before decay
        uint256 effectiveWeight; // decay-adjusted weight, in basis points
    }

    /// @notice One attestation input for a batch call.
    struct AttestInput {
        address subject;
        Category category;
        uint8 score;
        bytes32 commentHash;
    }

    /// @notice One signed attestation input for a relayed batch call: the
    ///         same fields as a signed attestation, plus the signature.
    struct SignedAttestInput {
        address attester;
        address subject;
        Category category;
        uint8 score;
        bytes32 commentHash;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Overall + per-category scores in a single read, so an
    ///         integrating frontend needs one RPC call, not five.
    struct Profile {
        Score overall;
        Score quality;
        Score communication;
        Score timeliness;
        Score reliability;
    }

    /// @notice One leaderboard row: a subject's overall score plus tier,
    ///         so a marketplace can rank freelancers in a single call.
    struct LeaderboardEntry {
        address subject;
        uint256 average; // scaled by 100, same as Score.average
        uint256 count; // active attestations included
        Tier tier;
    }

    /// @notice One point in a subject's score history: the score as it
    ///         stood right after a state change (attest, update, revoke,
    ///         dispute raise/resolve/expire). A frontend can chart a
    ///         freelancer's reputation over time without indexing events.
    ///         `average`/`count`/`effectiveWeight` are the same fields as
    ///         `Score`, frozen at `timestamp`.
    struct ScoreSnapshot {
        uint64 timestamp;
        uint256 average; // scaled by 100, 0 when count == 0
        uint256 count; // active attestations included
        uint256 effectiveWeight; // decay-adjusted weight, in basis points
    }

    error ZeroAddress();
    error SelfAttestation();
    error InvalidScore();
    error NotAttester();
    error NotSubject();
    error AlreadyRevoked();
    error AlreadyDisputed();
    error NotDisputed();
    error DisputeNotExpired();
    error UnknownAttestation();
    error ExpiredSignature();
    error InvalidSignature();

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
    event DisputeRaised(
        uint256 indexed id,
        address indexed attester,
        address indexed subject
    );
    event DisputeResolved(
        uint256 indexed id,
        address indexed attester,
        address indexed subject,
        bool upheld
    );
    event DisputeExpired(
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

    /// @notice How long an attester has to answer a dispute before the
    ///         subject may reinstate the attestation unilaterally.
    uint256 public constant DISPUTE_WINDOW = 30 days;

    /// @notice EIP-712 type hash for a signed attestation. The attester
    ///         signs off-chain (e.g. from a mobile wallet) and anyone —
    ///         a relayer, a platform backend — may submit it on-chain.
    bytes32 public constant ATTEST_TYPEHASH =
        keccak256(
            "Attest(address attester,address subject,uint8 category,uint8 score,bytes32 commentHash,uint256 nonce,uint256 deadline)"
        );

    /// @notice EIP-712 domain separator, fixed at deploy time.
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice Next usable nonce per attester (replay protection).
    mapping(address => uint256) public nonces;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("ReputationRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    Attestation[] private _attestations;
    // subject => attestation ids (all, including revoked)
    mapping(address => uint256[]) private _subjectAttestations;
    // attester => attestation ids they created (updates do not add a second
    // entry: the index tracks records, not writes)
    mapping(address => uint256[]) private _attesterAttestations;
    // keccak256(attester, subject, category) => id + 1 (0 == none active)
    mapping(bytes32 => uint256) private _activeByKey;
    // Every address that has ever received an attestation, in first-seen
    // order (updates and re-attestations after revocation do not add a
    // second entry). Powers the leaderboard; revoked/disputed-only
    // subjects stay listed but rank with count 0 and are excluded.
    address[] private _subjects;
    mapping(address => bool) private _isSubject;
    // subject => category => snapshots, in chronological order. Every
    // state change appends an Overall snapshot plus, when the changed
    // attestation belongs to a specific category, one for that category.
    mapping(address => mapping(Category => ScoreSnapshot[]))
        private _scoreHistory;

    /// @notice Attest a freelancer's work, or update your existing attestation
    ///         for the same subject + category.
    /// @return id The attestation id (stable across updates).
    function attest(
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash
    ) external returns (uint256 id) {
        return _attest(msg.sender, subject, category, score, commentHash);
    }

    /// @notice Attest many subjects/categories in one transaction — the
    ///         onboarding path for a platform migrating its freelancer base.
    ///         Atomic: any invalid entry (zero address, self-attestation,
    ///         score > 100, disputed record) reverts the whole batch, so a
    ///         caller never lands in a half-applied state. Existing active
    ///         records are updated in place, exactly as `attest` would.
    function attestBatch(
        AttestInput[] calldata inputs
    ) external returns (uint256[] memory ids) {
        ids = new uint256[](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            ids[i] = _attest(
                msg.sender,
                inputs[i].subject,
                inputs[i].category,
                inputs[i].score,
                inputs[i].commentHash
            );
        }
    }

    /// @notice Submit an attestation signed off-chain by the attester.
    ///         Anyone may relay it; the recovered signer IS the attester,
    ///         so the usual guards (self-attestation, score range, disputed
    ///         records) still apply inside `_attest`. The nonce is consumed
    ///         before the call, so a signature can never be replayed — even
    ///         a signature for an attestation that reverts still burns its
    ///         nonce, exactly like a mined transaction's nonce.
    function attestBySignature(
        address attester,
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 id) {
        if (block.timestamp > deadline) revert ExpiredSignature();
        uint256 nonce = nonces[attester];
        address recovered = ecrecover(
            _attestDigest(attester, subject, category, score, commentHash, nonce, deadline),
            v,
            r,
            s
        );
        if (recovered == address(0) || recovered != attester) {
            revert InvalidSignature();
        }
        nonces[attester] = nonce + 1;
        return _attest(attester, subject, category, score, commentHash);
    }

    /// @notice Submit many signed attestations in one transaction — the
    ///         onboarding path for a platform whose clients sign off-chain.
    ///         Atomic like `attestBatch`: any invalid entry (expired,
    ///         bad signature, bad score) reverts the whole batch, and a
    ///         revert rolls back every nonce increment, so no signer loses
    ///         a nonce to a failed batch. Entries may mix attesters; each
    ///         entry is verified against its own attester's nonce.
    function attestBatchBySignature(
        SignedAttestInput[] calldata inputs
    ) external returns (uint256[] memory ids) {
        ids = new uint256[](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            SignedAttestInput calldata inp = inputs[i];
            _verifySignedAttest(inp);
            ids[i] = _attest(
                inp.attester,
                inp.subject,
                inp.category,
                inp.score,
                inp.commentHash
            );
        }
    }

    /// @notice Verify one signed attestation and consume its nonce.
    function _verifySignedAttest(SignedAttestInput calldata inp) internal {
        if (block.timestamp > inp.deadline) revert ExpiredSignature();
        uint256 nonce = nonces[inp.attester];
        address recovered = ecrecover(
            _attestDigest(
                inp.attester,
                inp.subject,
                inp.category,
                inp.score,
                inp.commentHash,
                nonce,
                inp.deadline
            ),
            inp.v,
            inp.r,
            inp.s
        );
        if (recovered == address(0) || recovered != inp.attester) {
            revert InvalidSignature();
        }
        nonces[inp.attester] = nonce + 1;
    }

    /// @notice EIP-712 digest for a signed attestation (extracted so the
    ///         caller stays under the stack limit).
    function _attestDigest(
        address attester,
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ATTEST_TYPEHASH,
                attester,
                subject,
                category,
                score,
                commentHash,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _attest(
        address attester,
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash
    ) internal returns (uint256 id) {
        if (subject == address(0)) revert ZeroAddress();
        if (subject == attester) revert SelfAttestation();
        if (score > MAX_SCORE) revert InvalidScore();

        uint8 weight = attesterWeight(attester);
        bytes32 key = _key(attester, subject, category);
        uint256 existing = _activeByKey[key];

        if (existing != 0) {
            id = existing - 1;
            Attestation storage a = _attestations[id];
            // A disputed attestation cannot be quietly overwritten by the
            // attester; it must go through resolveDispute first.
            if (a.disputed) revert AlreadyDisputed();
            a.score = score;
            a.weight = weight;
            a.commentHash = commentHash;
            a.updatedAt = uint64(block.timestamp);
            emit AttestationUpdated(id, attester, subject, category, score, weight);
            _recordSnapshot(subject, category);
            return id;
        }

        id = _attestations.length;
        _attestations.push(
            Attestation({
                attester: attester,
                subject: subject,
                category: category,
                score: score,
                weight: weight,
                commentHash: commentHash,
                createdAt: uint64(block.timestamp),
                updatedAt: uint64(block.timestamp),
                revoked: false,
                disputed: false,
                disputeReason: bytes32(0),
                disputedAt: 0
            })
        );
        _subjectAttestations[subject].push(id);
        _attesterAttestations[attester].push(id);
        if (!_isSubject[subject]) {
            _isSubject[subject] = true;
            _subjects.push(subject);
        }
        _activeByKey[key] = id + 1;
        emit AttestationCreated(id, attester, subject, category, score, weight);
        _recordSnapshot(subject, category);
    }

    /// @notice Append a snapshot of the subject's current scores to
    ///         history: always the Overall score, plus the changed
    ///         category's score when the change touched one category.
    ///         An attestation in `Category.Overall` records one snapshot
    ///         only — the overall score already covers it.
    function _recordSnapshot(address subject, Category category) internal {
        uint256[] storage ids = _subjectAttestations[subject];
        Score memory overall = _score(ids, Category.Overall, false);
        _scoreHistory[subject][Category.Overall].push(
            ScoreSnapshot({
                timestamp: uint64(block.timestamp),
                average: overall.average,
                count: overall.count,
                effectiveWeight: overall.effectiveWeight
            })
        );
        if (category == Category.Overall) return;
        Score memory scoped = _score(ids, category, true);
        _scoreHistory[subject][category].push(
            ScoreSnapshot({
                timestamp: uint64(block.timestamp),
                average: scoped.average,
                count: scoped.count,
                effectiveWeight: scoped.effectiveWeight
            })
        );
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
        // Revoking also settles any open dispute on this record.
        a.disputed = false;
        a.disputeReason = bytes32(0);
        a.disputedAt = 0;
        _activeByKey[_key(a.attester, a.subject, a.category)] = 0;
        emit AttestationRevoked(id, msg.sender, a.subject);
        _recordSnapshot(a.subject, a.category);
    }

    /// @notice Dispute an attestation about you. Only the subject may
    ///         dispute, only while the attestation is active, and only once
    ///         at a time. While disputed it is excluded from every score.
    function disputeAttestation(uint256 id, bytes32 reasonHash) external {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.subject != msg.sender) revert NotSubject();
        if (a.revoked) revert AlreadyRevoked();
        if (a.disputed) revert AlreadyDisputed();
        a.disputed = true;
        a.disputeReason = reasonHash;
        a.disputedAt = uint64(block.timestamp);
        emit DisputeRaised(id, a.attester, a.subject);
        _recordSnapshot(a.subject, a.category);
    }

    /// @notice Resolve a dispute over your attestation. Upholding clears the
    ///         dispute (and refreshes the decay clock: the attestation is
    ///         re-confirmed); conceding revokes the attestation, freeing the
    ///         subject to be re-attested later.
    function resolveDispute(uint256 id, bool uphold) external {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.attester != msg.sender) revert NotAttester();
        if (!a.disputed) revert NotDisputed();
        if (uphold) {
            a.disputed = false;
            a.disputeReason = bytes32(0);
            a.disputedAt = 0;
            a.updatedAt = uint64(block.timestamp);
        } else {
            a.revoked = true;
            a.disputed = false;
            a.disputeReason = bytes32(0);
            a.disputedAt = 0;
            _activeByKey[_key(a.attester, a.subject, a.category)] = 0;
        }
        emit DisputeResolved(id, a.attester, a.subject, uphold);
        _recordSnapshot(a.subject, a.category);
    }

    /// @notice Reinstate an attestation whose dispute went unanswered for the
    ///         full dispute window. Only the subject may call this: it stops
    ///         an attester from suppressing a score forever by ignoring the
    ///         dispute. The decay clock is NOT refreshed — expiry is not a
    ///         re-confirmation.
    function expireDispute(uint256 id) external {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.subject != msg.sender) revert NotSubject();
        if (!a.disputed) revert NotDisputed();
        if (block.timestamp < uint256(a.disputedAt) + DISPUTE_WINDOW) {
            revert DisputeNotExpired();
        }
        a.disputed = false;
        a.disputeReason = bytes32(0);
        a.disputedAt = 0;
        emit DisputeExpired(id, a.attester, a.subject);
        _recordSnapshot(a.subject, a.category);
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

    /// @notice One page of a subject's attestations, in creation order
    ///         (oldest first); callers paginate by offset.
    ///         `limit` is clamped to the remaining records, and an offset
    ///         past the end returns an empty array instead of reverting,
    ///         so a frontend can page until it gets an empty page. Prefer
    ///         this over `getAttestations` once a subject has many records:
    ///         the unbounded read grows linearly in gas with history.
    function getAttestationsPaginated(
        address subject,
        uint256 offset,
        uint256 limit
    ) external view returns (Attestation[] memory) {
        uint256[] storage ids = _subjectAttestations[subject];
        if (offset >= ids.length) return new Attestation[](0);
        uint256 remaining = ids.length - offset;
        uint256 count = limit < remaining ? limit : remaining;
        Attestation[] memory out = new Attestation[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = _attestations[ids[offset + i]];
        }
        return out;
    }

    /// @notice How many records an attester has created (updates excluded).
    function attesterAttestationCount(
        address attester
    ) external view returns (uint256) {
        return _attesterAttestations[attester].length;
    }

    /// @notice One page of an attester's records, in creation order, with
    ///         the same empty-page-past-the-end semantics as
    ///         `getAttestationsPaginated` — the audit view for "what has
    ///         this client endorsed, and what did they later revoke?".
    function getAttestationsByAttester(
        address attester,
        uint256 offset,
        uint256 limit
    ) external view returns (Attestation[] memory) {
        uint256[] storage ids = _attesterAttestations[attester];
        if (offset >= ids.length) return new Attestation[](0);
        uint256 remaining = ids.length - offset;
        uint256 count = limit < remaining ? limit : remaining;
        Attestation[] memory out = new Attestation[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = _attestations[ids[offset + i]];
        }
        return out;
    }

    /// @notice An attester's track record, computed from their index: how
    ///         many attestations they gave, how many are still active, how
    ///         many they revoked, and how many are currently disputed.
    ///         A client deciding whether to trust an endorsement can weigh
    ///         the attester, not just the score.
    struct AttesterStats {
        uint256 given;
        uint256 active;
        uint256 revoked;
        uint256 disputed;
    }

    function attesterStats(
        address attester
    ) external view returns (AttesterStats memory stats) {
        uint256[] storage ids = _attesterAttestations[attester];
        stats.given = ids.length;
        for (uint256 i = 0; i < ids.length; i++) {
            Attestation storage a = _attestations[ids[i]];
            if (a.revoked) {
                stats.revoked++;
            } else if (a.disputed) {
                stats.disputed++;
            } else {
                stats.active++;
            }
        }
    }

    /// @notice Human-readable reputation tiers, from the overall score
    ///         and the number of active attestations behind it. A single
    ///         100 from a friend is not "Elite"; tiers require both a high
    ///         average AND enough endorsements, so they cannot be gamed by
    ///         one attestation. Decayed scores apply: an aged-out Elite
    ///         falls back down the tiers.
    enum Tier {
        Unranked,
        Emerging,
        Established,
        Trusted,
        Elite
    }

    /// @notice Tier thresholds: (minimum average scaled by 100, minimum
    ///         active attestations).
    uint256 public constant TIER_ESTABLISHED_AVG = 6000;
    uint256 public constant TIER_ESTABLISHED_COUNT = 3;
    uint256 public constant TIER_TRUSTED_AVG = 7500;
    uint256 public constant TIER_TRUSTED_COUNT = 5;
    uint256 public constant TIER_ELITE_AVG = 9000;
    uint256 public constant TIER_ELITE_COUNT = 10;

    function tierOf(address subject) external view returns (Tier) {
        return
            _tierOf(
                _score(_subjectAttestations[subject], Category.Overall, false)
            );
    }

    function _tierOf(Score memory s) internal pure returns (Tier) {
        if (s.count == 0) return Tier.Unranked;
        if (s.average >= TIER_ELITE_AVG && s.count >= TIER_ELITE_COUNT) {
            return Tier.Elite;
        }
        if (s.average >= TIER_TRUSTED_AVG && s.count >= TIER_TRUSTED_COUNT) {
            return Tier.Trusted;
        }
        if (
            s.average >= TIER_ESTABLISHED_AVG &&
            s.count >= TIER_ESTABLISHED_COUNT
        ) {
            return Tier.Established;
        }
        return Tier.Emerging;
    }

    /// @notice Overall + all four category scores in one call.
    function getProfile(
        address subject
    ) external view returns (Profile memory profile) {
        uint256[] storage ids = _subjectAttestations[subject];
        profile.overall = _score(ids, Category.Overall, false);
        profile.quality = _score(ids, Category.Quality, true);
        profile.communication = _score(ids, Category.Communication, true);
        profile.timeliness = _score(ids, Category.Timeliness, true);
        profile.reliability = _score(ids, Category.Reliability, true);
    }

    /// @notice Every subject currently sitting in one tier, in first-seen
    ///         order — the directory view behind "show me all Trusted
    ///         freelancers". `limit` is clamped to the matching set and a
    ///         limit of 0 returns an empty array, like the leaderboards.
    ///         Querying `Tier.Unranked` includes subjects whose attestations
    ///         are all revoked or disputed now (they still hold the tier,
    ///         just with no active score behind it); subjects that never
    ///         received an attestation are not in the registry at all.
    function getSubjectsByTier(
        Tier tier,
        uint256 limit
    ) external view returns (address[] memory) {
        address[] memory matched = new address[](_subjects.length);
        uint256 matchedCount;
        for (uint256 i = 0; i < _subjects.length; i++) {
            Score memory s = _score(
                _subjectAttestations[_subjects[i]],
                Category.Overall,
                false
            );
            if (_tierOf(s) == tier) {
                matched[matchedCount++] = _subjects[i];
            }
        }
        uint256 outCount = limit < matchedCount ? limit : matchedCount;
        address[] memory out = new address[](outCount);
        for (uint256 i = 0; i < outCount; i++) {
            out[i] = matched[i];
        }
        return out;
    }

    /// @notice How many distinct subjects have ever received an attestation
    ///         (including subjects whose attestations are all revoked now).
    function subjectCount() external view returns (uint256) {
        return _subjects.length;
    }

    /// @notice Top subjects by overall average, highest first; ties break
    ///         toward more active attestations, then toward the subject
    ///         seen first (insertion sort is stable, so the ranking is
    ///         deterministic). Subjects with no active attestations are
    ///         excluded, and `limit` is clamped to the ranked set — a limit
    ///         of 0 returns an empty array. This is a view over the whole
    ///         subject set, so it grows linearly with registered subjects;
    ///         frontends should page with a small limit on a busy registry.
    function getLeaderboard(
        uint256 limit
    ) external view returns (LeaderboardEntry[] memory) {
        return _rankedLeaderboard(Category.Overall, false, limit);
    }

    /// @notice Top subjects by one category's average — the "best
    ///         communicators" board, as opposed to the overall board.
    ///         Passing `Category.Overall` returns exactly `getLeaderboard`:
    ///         the overall score already spans every category, so there is
    ///         no separate "Overall-category-only" ranking. `average` and
    ///         `count` are category-scoped; `tier` stays the subject's
    ///         overall tier. Same exclusion, tie-break, and limit rules as
    ///         `getLeaderboard`.
    function getLeaderboardByCategory(
        Category category,
        uint256 limit
    ) external view returns (LeaderboardEntry[] memory) {
        bool filterCategory = category != Category.Overall;
        return _rankedLeaderboard(category, filterCategory, limit);
    }

    /// @notice Shared ranking behind `getLeaderboard` and
    ///         `getLeaderboardByCategory`: score every subject, drop the
    ///         ones with no active attestations in scope, sort descending
    ///         by average then count (stable, so first-seen order breaks
    ///         remaining ties), and clamp to `limit`.
    function _rankedLeaderboard(
        Category category,
        bool filterCategory,
        uint256 limit
    ) internal view returns (LeaderboardEntry[] memory) {
        LeaderboardEntry[] memory ranked = new LeaderboardEntry[](
            _subjects.length
        );
        uint256 rankedCount;
        for (uint256 i = 0; i < _subjects.length; i++) {
            Score memory s = _score(
                _subjectAttestations[_subjects[i]],
                category,
                filterCategory
            );
            if (s.count == 0) continue;
            // The tier is always the subject's OVERALL tier, even on a
            // category board: a category average must not promote someone
            // to Elite on the strength of one category alone.
            Tier tier = filterCategory
                ? _tierOf(
                    _score(
                        _subjectAttestations[_subjects[i]],
                        Category.Overall,
                        false
                    )
                )
                : _tierOf(s);
            ranked[rankedCount++] = LeaderboardEntry({
                subject: _subjects[i],
                average: s.average,
                count: s.count,
                tier: tier
            });
        }
        // Insertion sort, descending by average, then by count.
        for (uint256 i = 1; i < rankedCount; i++) {
            LeaderboardEntry memory entry = ranked[i];
            uint256 j = i;
            while (
                j > 0 &&
                (ranked[j - 1].average < entry.average ||
                    (ranked[j - 1].average == entry.average &&
                        ranked[j - 1].count < entry.count))
            ) {
                ranked[j] = ranked[j - 1];
                j--;
            }
            ranked[j] = entry;
        }
        uint256 outCount = limit < rankedCount ? limit : rankedCount;
        LeaderboardEntry[] memory out = new LeaderboardEntry[](outCount);
        for (uint256 i = 0; i < outCount; i++) {
            out[i] = ranked[i];
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
            if (a.disputed) continue;
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
