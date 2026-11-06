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
///      An attestation may carry an evidence hash (e.g. a content hash of
///      the delivered work or invoice) alongside the comment hash, so a
///      reader can verify what the score was given for without trusting
///      the attester's word alone.
///      Scores decay with age: an attestation counts fully for its first 90
///      days, at half weight for the rest of its first year, and at quarter
///      weight after that. The decay clock runs from the last update, so a
///      re-attestation refreshes an endorsement; attester weights are read
///      from the same decayed average. A subject may dispute an attestation
///      they believe is unfair; disputed attestations are excluded from
///      scores until the attester upholds them, concedes (revokes), or the
///      30-day dispute window lapses and the subject reinstates them.
///      If the attester ignores a dispute for 7 days, the subject may
///      escalate it to the registry owner, who arbitrates it — upholding
///      or conceding on the attester's behalf — so an unresponsive
///      attester cannot stall a dispute for the full 30 days.
///      Attestations expire: after `expiryDuration` (730 days by
///      default, owner-configurable, 0 disables expiry) an attestation
///      stops counting toward every score until the attester
///      re-attests and refreshes it — stale endorsements fade out on
///      their own, like decay, but all the way to zero.
///      The deployer owns the registry and may mark attesters as
///      verified (e.g. a platform whose clients passed KYC, or a DAO
///      whose members passed a vote): a verified attester's next
///      attestation carries +1 snapshot weight, capped at 3, so
///      established clients count a little more. Verification is a
///      snapshot-time boost only — it never rewrites existing records.
///      The owner may also strike a misbehaving attester (fake
///      endorsements, spam, paid reviews): each strike lowers the
///      weight of the attester's next attestations by 1, floored at 1,
///      and at 3 strikes the attester is suspended and cannot attest
///      at all until the owner clears the strikes. Strikes are
///      snapshot-time only, like verification — existing records and
///      scores are never rewritten.
///      Finally, the owner may issue a portable score proof for a
///      freelancer: a frozen, expiry-bounded certificate of the
///      subject's live overall score, tier, and attestation count.
///      The proof lives on-chain, so any third party (a hiring
///      platform, a client) can verify a presented proof against
///      the registry instead of trusting a screenshot — and because
///      it is frozen at issuance, the live score moving afterwards
///      does not invalidate it until it expires (at most 90 days)
///      or the owner revokes it.
///      Governance and safety: the owner may pause the registry in an
///      emergency (a bug, a spam wave, a compromised relayer). While
///      paused, no new attestation can be created or updated and no
///      evidence or score proof can be issued — but safety exits stay
///      open: attestations can still be revoked and disputes can
///      still be raised, resolved, and expired, so a pause can never
///      trap a subject under a bad attestation. Ownership itself is
///      transferable in two steps (initiate, then the new owner
///      accepts), so a lost or mistyped owner key cannot lock the
///      registry forever, and a transfer to the wrong address can be
///      cancelled before it is accepted.
///      An attester may also delegate: they can authorize another
///      address (for example a platform's operations wallet) to
///      attest on their behalf until an expiry they choose. The
///      delegate's submissions carry the attester's identity and
///      snapshot weight — the delegate's own reputation never
///      matters — and the same guards apply (suspension, pause,
///      self-attestation, score range, disputed records). Sensitive
///      actions stay with the attester: only they may revoke an
///      attestation or resolve a dispute, and a delegate's authority
///      can be revoked at any time or simply lapses at its expiry.
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
        bytes32 evidenceHash; // content hash of supporting evidence (deliverable, invoice), or 0
        uint64 createdAt;
        uint64 updatedAt;
        bool revoked;
        bool disputed;
        bytes32 disputeReason; // keccak256 of off-chain dispute text, or 0
        uint64 disputedAt;
        bool escalated; // subject escalated the open dispute to the owner
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

    /// @notice One attestation-with-evidence input for a batch call: the
    ///         same fields as `AttestInput`, plus the evidence hash.
    struct AttestWithEvidenceInput {
        address subject;
        Category category;
        uint8 score;
        bytes32 commentHash;
        bytes32 evidenceHash;
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

    /// @notice One row of the top-attesters board: how many active
    ///         attestations an attester gave, their own overall average
    ///         (so the board shows whether the most prolific endorsers
    ///         are themselves well-rated), and the weight their next
    ///         attestation would carry right now.
    struct AttesterLeaderboardEntry {
        address attester;
        uint256 count; // active attestations they gave
        uint256 average; // their own overall average, scaled by 100
        uint8 weight; // attesterWeight(attester) right now
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

    /// @notice A portable reputation certificate: the subject's overall
    ///         score, tier, and active-attestation count as they stood
    ///         when the owner issued it, frozen until `expiresAt`.
    ///         `average` is scaled by 100, like `Score.average`.
    struct ScoreProof {
        address subject;
        uint256 average;
        Tier tier;
        uint256 count;
        uint64 issuedAt;
        uint64 expiresAt;
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
    error NotEscalated();
    error AlreadyEscalated();
    error EscalationTooEarly();
    error UnknownAttestation();
    error ExpiredSignature();
    error InvalidSignature();
    error NotOwner();
    error RegistryPaused();
    error RegistryNotPaused();
    error NotPendingOwner();
    error NoPendingTransfer();
    error AttestationExpired();
    error AttesterSuspended();
    error InvalidProofValidity();
    error NoScoreProof();
    error NotDelegate();
    error InvalidDelegate();

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
    event EvidenceUpdated(
        uint256 indexed id,
        address indexed attester,
        address indexed subject,
        bytes32 evidenceHash
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
    event DisputeEscalated(
        uint256 indexed id,
        address indexed attester,
        address indexed subject
    );
    event DisputeResolvedByOwner(
        uint256 indexed id,
        address indexed attester,
        address indexed subject,
        bool upheld
    );
    event AttesterVerified(address indexed attester, bool verified);
    event LeaderboardOptOut(address indexed subject, bool optedOut);
    event AttesterStruck(address indexed attester, uint256 strikes);
    event StrikesCleared(address indexed attester);
    event ExpiryDurationUpdated(uint64 expiryDuration);
    event ScoreProofIssued(
        address indexed subject,
        uint256 average,
        Tier tier,
        uint256 count,
        uint64 issuedAt,
        uint64 expiresAt
    );
    event ScoreProofRevoked(address indexed subject);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferInitiated(
        address indexed previousOwner,
        address indexed newOwner
    );
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event OwnershipTransferCancelled(
        address indexed previousOwner,
        address indexed newOwner
    );
    event DelegateSet(
        address indexed attester,
        address indexed delegate,
        uint256 expiresAt
    );
    event DelegateRevoked(
        address indexed attester,
        address indexed delegate
    );

    uint8 public constant MAX_SCORE = 100;
    uint8 public constant MAX_WEIGHT = 3;

    /// @notice Strikes at which an attester is suspended: they may not
    ///         attest (or re-attest) until the owner clears the strikes.
    uint256 public constant MAX_STRIKES = 3;

    /// @notice Decay tiers, in basis points of the snapshot weight.
    uint256 public constant DECAY_FULL_BPS = 10000; // first 90 days
    uint256 public constant DECAY_HALF_BPS = 5000; // rest of year one
    uint256 public constant DECAY_QUARTER_BPS = 2500; // after one year
    uint256 public constant DECAY_FULL_PERIOD = 90 days;
    uint256 public constant DECAY_HALF_PERIOD = 365 days;

    /// @notice How long an attester has to answer a dispute before the
    ///         subject may reinstate the attestation unilaterally.
    uint256 public constant DISPUTE_WINDOW = 30 days;

    /// @notice How long a dispute must sit unanswered before the subject
    ///         may escalate it to the owner for arbitration: long enough
    ///         that the attester had a fair chance to answer, short
    ///         enough that a stalled dispute does not hang for the full
    ///         30-day window.
    uint256 public constant ESCALATION_DELAY = 7 days;

    /// @notice Longest a score proof may stay valid: a certificate must
    ///         be re-issued regularly, so a stale reputation cannot be
    ///         presented as current forever.
    uint64 public constant MAX_PROOF_VALIDITY = 90 days;

    /// @notice How long an attestation counts toward scores after its
    ///         last update (attest, re-attest, or upheld dispute).
    ///         Past that point it is expired: excluded from every score
    ///         until the attester re-attests and refreshes the clock.
    ///         The owner may change this; 0 disables expiry entirely
    ///         (attestations then count forever, as before this feature).
    uint64 public expiryDuration = 730 days;

    /// @notice EIP-712 type hash for a signed attestation. The attester
    ///         signs off-chain (e.g. from a mobile wallet) and anyone —
    ///         a relayer, a platform backend — may submit it on-chain.
    bytes32 public constant ATTEST_TYPEHASH =
        keccak256(
            "Attest(address attester,address subject,uint8 category,uint8 score,bytes32 commentHash,uint256 nonce,uint256 deadline)"
        );

    /// @notice EIP-712 domain separator, fixed at deploy time.
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice The registry owner: the only account that may manage
    ///         the verified-attester registry, strike attesters, issue
    ///         score proofs, pause the registry, and start an ownership
    ///         transfer. Set to the deployer at construction; see
    ///         `transferOwnership` for how it changes hands.
    address public owner;

    /// @notice The address that may accept a pending ownership
    ///         transfer (see `transferOwnership`). Zero when no
    ///         transfer is in flight.
    address public pendingOwner;

    /// @notice Whether the registry is paused: while true, no new
    ///         attestation can be created or updated and no evidence
    ///         or score proof can be issued. Revokes and dispute
    ///         actions stay available (see `pause`).
    bool public paused;

    /// @notice Verified attesters, set by the owner (see
    ///         `setVerifiedAttester`).
    mapping(address => bool) private _verifiedAttesters;

    /// @notice Delegates per attester: when an authorized delegate's
    ///         authority lapses (see `setDelegate`). `_delegateList`
    ///         tracks every address ever authorized, in first-set
    ///         order, so `getDelegates` can enumerate them.
    mapping(address => mapping(address => uint256)) private _delegateExpiry;
    mapping(address => address[]) private _delegateList;

    /// @notice Strikes per attester, set by the owner (see
    ///         `strikeAttester`). Three strikes suspends the attester.
    mapping(address => uint256) private _strikes;

    /// @notice Next usable nonce per attester (replay protection).
    mapping(address => uint256) public nonces;

    constructor() {
        owner = msg.sender;
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
    // Every address that has ever attested, in first-seen order (updates
    // and re-attestations after revocation do not add a second entry).
    // Powers the top-attesters board; attesters whose records are all
    // revoked now stay listed but rank with count 0 and are excluded.
    address[] private _attesters;
    mapping(address => bool) private _isAttester;
    // keccak256(attester, subject, category) => id + 1 (0 == none active)
    mapping(bytes32 => uint256) private _activeByKey;
    // Every address that has ever received an attestation, in first-seen
    // order (updates and re-attestations after revocation do not add a
    // second entry). Powers the leaderboard; revoked/disputed-only
    // subjects stay listed but rank with count 0 and are excluded.
    address[] private _subjects;
    mapping(address => bool) private _isSubject;
    // subject => whether they opted out of public discovery
    // (leaderboards and the tier directory). Opting out hides the
    // subject from public listings only: their scores, tier, and
    // attestations stay readable directly, and they keep receiving
    // attestations. A subject that never received an attestation
    // cannot opt out of a listing they are not on — the setter
    // simply records the choice for when they are listed.
    mapping(address => bool) private _leaderboardOptOut;
    // subject => category => snapshots, in chronological order. Every
    // state change appends an Overall snapshot plus, when the changed
    // attestation belongs to a specific category, one for that category.
    mapping(address => mapping(Category => ScoreSnapshot[]))
        private _scoreHistory;
    // subject => latest issued score proof (re-issuing replaces it).
    mapping(address => ScoreProof) private _scoreProofs;
    // subject => whether a proof was ever issued (and not revoked).
    mapping(address => bool) private _hasScoreProof;

    /// @notice Attest a freelancer's work, or update your existing attestation
    ///         for the same subject + category.
    /// @return id The attestation id (stable across updates).
    function attest(
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash
    ) external returns (uint256 id) {
        return _attest(msg.sender, subject, category, score, commentHash, bytes32(0), false);
    }

    /// @notice Attest with supporting evidence attached: `evidenceHash` is
    ///         the content hash of the work the score refers to (a
    ///         deliverable, an invoice, a shipped artifact), so anyone
    ///         reading the attestation can check the claim against the
    ///         evidence instead of taking the attester's word for it.
    ///         Re-attesting with this function replaces the evidence;
    ///         plain `attest` leaves previously attached evidence untouched.
    /// @return id The attestation id (stable across updates).
    function attestWithEvidence(
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash,
        bytes32 evidenceHash
    ) external returns (uint256 id) {
        return _attest(msg.sender, subject, category, score, commentHash, evidenceHash, true);
    }

    /// @notice Attach or replace the evidence hash on one of your own
    ///         attestations — for evidence that only exists after the
    ///         work is delivered, or to correct a hash attached in error.
    ///         Only the attester (or their active delegate, via
    ///         `setEvidenceOnBehalf`) may do this, and only while the
    ///         record is active: a revoked attestation is a frozen
    ///         audit record. Evidence is metadata only; changing it
    ///         never touches the score, the decay clock, or the score
    ///         history.
    function setEvidence(uint256 id, bytes32 evidenceHash) external {
        _setEvidence(msg.sender, id, evidenceHash);
    }

    /// @notice `setEvidence` on behalf of `attester`: the delegate
    ///         check runs first, then the same rules as `setEvidence`.
    function setEvidenceOnBehalf(
        address attester,
        uint256 id,
        bytes32 evidenceHash
    ) external {
        if (!isDelegate(attester, msg.sender)) revert NotDelegate();
        _setEvidence(attester, id, evidenceHash);
    }

    function _setEvidence(
        address attester,
        uint256 id,
        bytes32 evidenceHash
    ) internal {
        if (paused) revert RegistryPaused();
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.attester != attester) revert NotAttester();
        if (a.revoked) revert AlreadyRevoked();
        a.evidenceHash = evidenceHash;
        emit EvidenceUpdated(id, attester, a.subject, evidenceHash);
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
                inputs[i].commentHash,
                bytes32(0),
                false
            );
        }
    }

    /// @notice Batch version of `attestWithEvidence`: attach evidence to
    ///         many attestations in one transaction, with the same atomicity
    ///         guarantees as `attestBatch`.
    function attestBatchWithEvidence(
        AttestWithEvidenceInput[] calldata inputs
    ) external returns (uint256[] memory ids) {
        ids = new uint256[](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            ids[i] = _attest(
                msg.sender,
                inputs[i].subject,
                inputs[i].category,
                inputs[i].score,
                inputs[i].commentHash,
                inputs[i].evidenceHash,
                true
            );
        }
    }

    /// @notice Authorize `delegate` to attest on your behalf until
    ///         `expiresAt` (a unix timestamp, must be in the future).
    ///         The delegate's submissions are recorded as yours: the
    ///         attestation's attester is you, and its snapshot weight
    ///         comes from your reputation, not the delegate's. Re-set
    ///         to extend (or shorten) the expiry; revoke any time
    ///         with `revokeDelegate`. A delegate may attest, re-attest,
    ///         batch-attest, and attach evidence — but never revoke an
    ///         attestation or resolve a dispute: those stay yours.
    function setDelegate(address delegate, uint256 expiresAt) external {
        if (delegate == address(0)) revert ZeroAddress();
        if (delegate == msg.sender) revert InvalidDelegate();
        if (expiresAt <= block.timestamp) revert InvalidDelegate();
        if (_delegateExpiry[msg.sender][delegate] == 0) {
            _delegateList[msg.sender].push(delegate);
        }
        _delegateExpiry[msg.sender][delegate] = expiresAt;
        emit DelegateSet(msg.sender, delegate, expiresAt);
    }

    /// @notice Revoke a delegate's authority immediately. Idempotent:
    ///         revoking an address that holds no authority is a no-op
    ///         (the event still records the intent).
    function revokeDelegate(address delegate) external {
        _delegateExpiry[msg.sender][delegate] = 0;
        emit DelegateRevoked(msg.sender, delegate);
    }

    /// @notice Whether `delegate` may currently attest for `attester`:
    ///         authorized and not yet expired.
    function isDelegate(
        address attester,
        address delegate
    ) public view returns (bool) {
        return _delegateExpiry[attester][delegate] > block.timestamp;
    }

    /// @notice When `delegate`'s authority for `attester` lapses
    ///         (0 when never authorized or revoked).
    function delegateExpiry(
        address attester,
        address delegate
    ) external view returns (uint256) {
        return _delegateExpiry[attester][delegate];
    }

    /// @notice The attester's currently active delegates, in the order
    ///         they were first authorized. Expired and revoked entries
    ///         are omitted.
    function getDelegates(
        address attester
    ) external view returns (address[] memory delegates) {
        address[] storage list = _delegateList[attester];
        uint256 active;
        for (uint256 i = 0; i < list.length; i++) {
            if (_delegateExpiry[attester][list[i]] > block.timestamp) {
                active++;
            }
        }
        delegates = new address[](active);
        uint256 j;
        for (uint256 i = 0; i < list.length; i++) {
            if (_delegateExpiry[attester][list[i]] > block.timestamp) {
                delegates[j++] = list[i];
            }
        }
    }

    /// @notice Attest on behalf of `attester` — only an active delegate
    ///         may call this, and the record is the attester's in every
    ///         way (attester field, snapshot weight, dispute ownership).
    ///         All of `_attest`'s guards still apply to the attester:
    ///         suspension, pause, self-attestation, score range, and
    ///         disputed records.
    function attestOnBehalf(
        address attester,
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash
    ) external returns (uint256 id) {
        if (!isDelegate(attester, msg.sender)) revert NotDelegate();
        return
            _attest(
                attester,
                subject,
                category,
                score,
                commentHash,
                bytes32(0),
                false
            );
    }

    /// @notice `attestWithEvidence` on behalf of `attester`: same
    ///         delegate check, same evidence semantics.
    function attestWithEvidenceOnBehalf(
        address attester,
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash,
        bytes32 evidenceHash
    ) external returns (uint256 id) {
        if (!isDelegate(attester, msg.sender)) revert NotDelegate();
        return
            _attest(
                attester,
                subject,
                category,
                score,
                commentHash,
                evidenceHash,
                true
            );
    }

    /// @notice `attestBatch` on behalf of `attester`: one delegate
    ///         check up front, then the same atomic batch semantics.
    function attestBatchOnBehalf(
        address attester,
        AttestInput[] calldata inputs
    ) external returns (uint256[] memory ids) {
        if (!isDelegate(attester, msg.sender)) revert NotDelegate();
        ids = new uint256[](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            ids[i] = _attest(
                attester,
                inputs[i].subject,
                inputs[i].category,
                inputs[i].score,
                inputs[i].commentHash,
                bytes32(0),
                false
            );
        }
    }

    /// @notice `attestBatchWithEvidence` on behalf of `attester`.
    function attestBatchWithEvidenceOnBehalf(
        address attester,
        AttestWithEvidenceInput[] calldata inputs
    ) external returns (uint256[] memory ids) {
        if (!isDelegate(attester, msg.sender)) revert NotDelegate();
        ids = new uint256[](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            ids[i] = _attest(
                attester,
                inputs[i].subject,
                inputs[i].category,
                inputs[i].score,
                inputs[i].commentHash,
                inputs[i].evidenceHash,
                true
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
        return _attest(attester, subject, category, score, commentHash, bytes32(0), false);
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
                inp.commentHash,
                bytes32(0),
                false
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
        bytes32 commentHash,
        bytes32 evidenceHash,
        bool replaceEvidence
    ) internal returns (uint256 id) {
        if (paused) revert RegistryPaused();
        if (subject == address(0)) revert ZeroAddress();
        if (subject == attester) revert SelfAttestation();
        if (score > MAX_SCORE) revert InvalidScore();
        if (_strikes[attester] >= MAX_STRIKES) revert AttesterSuspended();

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
            // Plain re-attests (attest / attestBatch / signed paths) pass
            // replaceEvidence == false and must not wipe evidence that
            // was attached earlier; attestWithEvidence replaces it.
            if (replaceEvidence) a.evidenceHash = evidenceHash;
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
                evidenceHash: evidenceHash,
                createdAt: uint64(block.timestamp),
                updatedAt: uint64(block.timestamp),
                revoked: false,
                disputed: false,
                disputeReason: bytes32(0),
                disputedAt: 0,
                escalated: false
            })
        );
        _subjectAttestations[subject].push(id);
        _attesterAttestations[attester].push(id);
        if (!_isAttester[attester]) {
            _isAttester[attester] = true;
            _attesters.push(attester);
        }
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
        a.escalated = false;
        _activeByKey[_key(a.attester, a.subject, a.category)] = 0;
        emit AttestationRevoked(id, msg.sender, a.subject);
        _recordSnapshot(a.subject, a.category);
    }

    /// @notice Dispute an attestation about you. Only the subject may
    ///         dispute, only while the attestation is active, and only once
    ///         at a time. While disputed it is excluded from every score.
    ///         An expired attestation cannot be disputed: it already
    ///         counts toward no score, so there is nothing to dispute —
    ///         if the attester re-attests and revives it, the fresh
    ///         record can be disputed like any other.
    function disputeAttestation(uint256 id, bytes32 reasonHash) external {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.subject != msg.sender) revert NotSubject();
        if (a.revoked) revert AlreadyRevoked();
        if (a.disputed) revert AlreadyDisputed();
        if (_isExpiredAt(a, uint64(block.timestamp))) {
            revert AttestationExpired();
        }
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
            a.escalated = false;
            a.updatedAt = uint64(block.timestamp);
        } else {
            a.revoked = true;
            a.disputed = false;
            a.disputeReason = bytes32(0);
            a.disputedAt = 0;
            a.escalated = false;
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
        a.escalated = false;
        emit DisputeExpired(id, a.attester, a.subject);
        _recordSnapshot(a.subject, a.category);
    }

    /// @notice Escalate an unanswered dispute to the registry owner for
    ///         arbitration. Only the subject may escalate, only once the
    ///         attester has had ESCALATION_DELAY (7 days) to answer, and
    ///         only while the dispute is still open. Escalation changes
    ///         no score — the record stays excluded — it only opens the
    ///         owner-arbitration path, so an unresponsive attester cannot
    ///         stall a dispute for the full 30-day window. Like the other
    ///         dispute exits, escalation stays open while paused.
    function escalateDispute(uint256 id) external {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.subject != msg.sender) revert NotSubject();
        if (!a.disputed) revert NotDisputed();
        if (a.escalated) revert AlreadyEscalated();
        if (block.timestamp < uint256(a.disputedAt) + ESCALATION_DELAY) {
            revert EscalationTooEarly();
        }
        a.escalated = true;
        emit DisputeEscalated(id, a.attester, a.subject);
    }

    /// @notice Arbitrate an escalated dispute as the registry owner.
    ///         Same outcome as the attester resolving it: upholding
    ///         clears the dispute (and refreshes the decay clock: the
    ///         attestation is re-confirmed); conceding revokes the
    ///         attestation, freeing the subject to be re-attested later.
    ///         The attester may still resolve the dispute themselves
    ///         after escalation — whichever resolution lands first
    ///         settles it. Owner arbitration stays open while paused,
    ///         like every other dispute exit.
    function resolveDisputeAsOwner(uint256 id, bool uphold) external {
        if (msg.sender != owner) revert NotOwner();
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (!a.disputed) revert NotDisputed();
        if (!a.escalated) revert NotEscalated();
        if (uphold) {
            a.disputed = false;
            a.disputeReason = bytes32(0);
            a.disputedAt = 0;
            a.escalated = false;
            a.updatedAt = uint64(block.timestamp);
        } else {
            a.revoked = true;
            a.disputed = false;
            a.disputeReason = bytes32(0);
            a.disputedAt = 0;
            a.escalated = false;
            _activeByKey[_key(a.attester, a.subject, a.category)] = 0;
        }
        emit DisputeResolvedByOwner(id, a.attester, a.subject, uphold);
        _recordSnapshot(a.subject, a.category);
    }

    /// @notice Whether the open dispute on an attestation has been
    ///         escalated to the owner for arbitration.
    function isDisputeEscalated(
        uint256 id
    ) external view returns (bool) {
        if (id >= _attestations.length) revert UnknownAttestation();
        return _attestations[id].escalated;
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

    /// @notice Weighted average as it will stand (or stood) at time
    ///         `when` — the decay preview behind "your reputation will be
    ///         X in 30 days" prompts. Decay is measured against `when`,
    ///         attestations created after `when` are excluded, and
    ///         revoked/disputed records stay excluded as they stand now
    ///         (see `_scoreAt` for the exact semantics). Passing the
    ///         current block time returns exactly `getScore`.
    function getScoreAt(
        address subject,
        uint64 when
    ) external view returns (Score memory) {
        return
            _scoreAt(_subjectAttestations[subject], Category.Overall, false, when);
    }

    /// @notice Category-scoped version of `getScoreAt`.
    function getScoreByCategoryAt(
        address subject,
        Category category,
        uint64 when
    ) external view returns (Score memory) {
        return _scoreAt(_subjectAttestations[subject], category, true, when);
    }

    /// @notice How many snapshots exist for a subject's score in one
    ///         scope (`Category.Overall` for the overall score, or one
    ///         specific category). Zero for a subject/category with no
    ///         recorded changes.
    function scoreHistoryLength(
        address subject,
        Category category
    ) external view returns (uint256) {
        return _scoreHistory[subject][category].length;
    }

    /// @notice One page of a subject's score history, oldest first — the
    ///         data behind a reputation-over-time chart. Same paging
    ///         semantics as `getAttestationsPaginated`: `limit` is clamped
    ///         to the remaining snapshots and an offset past the end
    ///         returns an empty array. History grows by one entry per
    ///         state change (plus a category entry when the change touched
    ///         one), so page it on busy subjects.
    function getScoreHistory(
        address subject,
        Category category,
        uint256 offset,
        uint256 limit
    ) external view returns (ScoreSnapshot[] memory) {
        ScoreSnapshot[] storage snapshots = _scoreHistory[subject][category];
        if (offset >= snapshots.length) return new ScoreSnapshot[](0);
        uint256 remaining = snapshots.length - offset;
        uint256 count = limit < remaining ? limit : remaining;
        ScoreSnapshot[] memory out = new ScoreSnapshot[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = snapshots[offset + i];
        }
        return out;
    }

    /// @notice The most recent snapshot of a subject's score in one
    ///         scope, plus whether any history exists at all — the
    ///         one-call version of reading the last page of
    ///         `getScoreHistory`. `exists` is false (and the snapshot
    ///         all zeros) for a subject/category with no recorded
    ///         changes. Like every snapshot, the result is frozen at
    ///         the last state change: after time passes (decay, expiry)
    ///         it can differ from the live score, which is the point —
    ///         it answers "what was the score after the last change",
    ///         not "what is it now".
    function latestScoreSnapshot(
        address subject,
        Category category
    )
        external
        view
        returns (ScoreSnapshot memory snapshot, bool exists)
    {
        ScoreSnapshot[] storage snapshots = _scoreHistory[subject][category];
        if (snapshots.length == 0) return (snapshot, false);
        return (snapshots[snapshots.length - 1], true);
    }

    /// @notice Issue a portable score proof for a subject: a frozen
    ///         certificate of their live overall score, tier, and
    ///         active-attestation count, valid for `validFor` (at most
    ///         `MAX_PROOF_VALIDITY`). Only the owner may issue — the
    ///         proof is the registry's word, not the subject's. A
    ///         subject with no attestations gets a valid proof of
    ///         average 0 / tier Unranked / count 0: "no reputation
    ///         yet" is itself a checkable claim. Re-issuing replaces
    ///         the previous proof for the subject.
    /// @return proof The issued proof, as stored on-chain.
    function issueScoreProof(
        address subject,
        uint64 validFor
    ) external returns (ScoreProof memory proof) {
        if (msg.sender != owner) revert NotOwner();
        if (paused) revert RegistryPaused();
        if (subject == address(0)) revert ZeroAddress();
        if (validFor == 0 || validFor > MAX_PROOF_VALIDITY) {
            revert InvalidProofValidity();
        }
        Score memory s = _score(
            _subjectAttestations[subject],
            Category.Overall,
            false
        );
        proof = ScoreProof({
            subject: subject,
            average: s.average,
            tier: _tierOf(s),
            count: s.count,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + validFor
        });
        _scoreProofs[subject] = proof;
        _hasScoreProof[subject] = true;
        emit ScoreProofIssued(
            subject,
            proof.average,
            proof.tier,
            proof.count,
            proof.issuedAt,
            proof.expiresAt
        );
    }

    /// @notice The latest issued proof for a subject, plus whether one
    ///         exists at all (false when never issued, or after a
    ///         revocation). An expired proof is still returned — check
    ///         `expiresAt` against the current time, or use
    ///         `verifyScoreProof`, which does that for you.
    function scoreProofOf(
        address subject
    ) external view returns (ScoreProof memory proof, bool exists) {
        return (_scoreProofs[subject], _hasScoreProof[subject]);
    }

    /// @notice Verify a presented proof against the registry: true
    ///         exactly when the proof matches the latest proof issued
    ///         for its subject, field for field, and has not expired.
    ///         A tampered average, tier, count, or timestamp fails;
    ///         so does a proof for a subject who never received one,
    ///         or one revoked by the owner. Note the check is against
    ///         the frozen proof, not the live score — a freelancer's
    ///         reputation moving after issuance does not invalidate
    ///         the certificate until it expires.
    function verifyScoreProof(
        ScoreProof calldata proof
    ) external view returns (bool) {
        if (!_hasScoreProof[proof.subject]) return false;
        ScoreProof storage stored = _scoreProofs[proof.subject];
        if (
            stored.average != proof.average ||
            stored.tier != proof.tier ||
            stored.count != proof.count ||
            stored.issuedAt != proof.issuedAt ||
            stored.expiresAt != proof.expiresAt
        ) {
            return false;
        }
        return block.timestamp <= proof.expiresAt;
    }

    /// @notice Revoke a subject's latest score proof — for a certificate
    ///         issued in error, or after fraud is discovered. Only the
    ///         owner may revoke; the subject keeps their attestations
    ///         and live score, only the certificate is withdrawn. A new
    ///         proof may be issued afterwards.
    function revokeScoreProof(address subject) external {
        if (msg.sender != owner) revert NotOwner();
        if (!_hasScoreProof[subject]) revert NoScoreProof();
        delete _scoreProofs[subject];
        _hasScoreProof[subject] = false;
        emit ScoreProofRevoked(subject);
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

    /// @notice One page of a subject's attestations in ONE category,
    ///         in creation order (oldest first) — the view behind "show
    ///         me every Quality endorsement for this freelancer". Same
    ///         paging semantics as `getAttestationsPaginated`: `limit`
    ///         is clamped to the remaining records in the category and
    ///         an offset past the end returns an empty array. Revoked
    ///         and disputed records are included, like in
    ///         `getAttestations` (check the flags to tell them apart).
    ///         This is a view over the subject's full history, so it
    ///         scans every record even when the page is small; frontends
    ///         should call it off-chain via `eth_call`.
    function getAttestationsByCategory(
        address subject,
        Category category,
        uint256 offset,
        uint256 limit
    ) external view returns (Attestation[] memory) {
        uint256[] storage ids = _subjectAttestations[subject];
        uint256 total;
        for (uint256 i = 0; i < ids.length; i++) {
            if (_attestations[ids[i]].category == category) total++;
        }
        if (offset >= total) return new Attestation[](0);
        uint256 remaining = total - offset;
        uint256 count = limit < remaining ? limit : remaining;
        Attestation[] memory out = new Attestation[](count);
        uint256 seen;
        uint256 written;
        for (uint256 i = 0; i < ids.length && written < count; i++) {
            Attestation storage a = _attestations[ids[i]];
            if (a.category != category) continue;
            if (seen >= offset) {
                out[written++] = a;
            }
            seen++;
        }
        return out;
    }

    /// @notice How many distinct attesters have ever created an
    ///         attestation (including attesters whose records are all
    ///         revoked now).
    function attesterCount() external view returns (uint256) {
        return _attesters.length;
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
        uint256 strikes;
        bool suspended;
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
        stats.strikes = _strikes[attester];
        stats.suspended = stats.strikes >= MAX_STRIKES;
    }

    /// @notice Top attesters by active attestations given, highest first;
    ///         ties break toward the attester with the higher own overall
    ///         average, then toward the attester seen first (insertion
    ///         sort is stable, so the ranking is deterministic). "Active"
    ///         means the record still counts toward a score — not revoked,
    ///         not disputed, not expired — the same rule the score views
    ///         use. Attesters with no active attestations are excluded.
    ///         A suspended attester stays ranked on the strength of their
    ///         past records (suspension blocks new attestations only),
    ///         and `weight` is their current `attesterWeight`, so a
    ///         suspended attester shows weight 0. `limit` clamps to the
    ///         ranked set and 0 returns an empty array. Like the subject
    ///         boards, this is a view over the whole attester set for
    ///         off-chain `eth_call`, not a transaction input.
    function getTopAttesters(
        uint256 limit
    ) external view returns (AttesterLeaderboardEntry[] memory) {
        AttesterLeaderboardEntry[] memory ranked = new AttesterLeaderboardEntry[](
            _attesters.length
        );
        uint256 rankedCount;
        for (uint256 i = 0; i < _attesters.length; i++) {
            address attester = _attesters[i];
            uint256 active = _activeAttestationCount(attester);
            if (active == 0) continue;
            Score memory own = _score(
                _subjectAttestations[attester],
                Category.Overall,
                false
            );
            ranked[rankedCount++] = AttesterLeaderboardEntry({
                attester: attester,
                count: active,
                average: own.average,
                weight: attesterWeight(attester)
            });
        }
        // Insertion sort, descending by count, then by own average.
        for (uint256 i = 1; i < rankedCount; i++) {
            AttesterLeaderboardEntry memory entry = ranked[i];
            uint256 j = i;
            while (
                j > 0 &&
                (ranked[j - 1].count < entry.count ||
                    (ranked[j - 1].count == entry.count &&
                        ranked[j - 1].average < entry.average))
            ) {
                ranked[j] = ranked[j - 1];
                j--;
            }
            ranked[j] = entry;
        }
        uint256 outCount = limit < rankedCount ? limit : rankedCount;
        AttesterLeaderboardEntry[] memory out = new AttesterLeaderboardEntry[](outCount);
        for (uint256 i = 0; i < outCount; i++) {
            out[i] = ranked[i];
        }
        return out;
    }

    /// @notice How many of an attester's records still count toward
    ///         scores: not revoked, not disputed, not expired. The
    ///         ranking rule for `getTopAttesters`, shared so the board
    ///         and any future caller agree on what "active" means.
    function _activeAttestationCount(
        address attester
    ) internal view returns (uint256 active) {
        uint256[] storage ids = _attesterAttestations[attester];
        for (uint256 i = 0; i < ids.length; i++) {
            Attestation storage a = _attestations[ids[i]];
            if (a.revoked) continue;
            if (a.disputed) continue;
            if (_isExpiredAt(a, uint64(block.timestamp))) continue;
            active++;
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

    /// @notice Tier as it will stand (or stood) at time `when`, from the
    ///         decay-preview score — so a frontend can warn that a
    ///         freelancer drops from Established to Emerging in N days
    ///         unless they land fresh work. Same preview semantics as
    ///         `getScoreAt`.
    function tierOfAt(address subject, uint64 when) external view returns (Tier) {
        return
            _tierOf(
                _scoreAt(
                    _subjectAttestations[subject],
                    Category.Overall,
                    false,
                    when
                )
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

    /// @notice Decay-preview version of `getProfile`: every scope's score
    ///         as it will stand (or stood) at time `when`.
    function getProfileAt(
        address subject,
        uint64 when
    ) external view returns (Profile memory profile) {
        uint256[] storage ids = _subjectAttestations[subject];
        profile.overall = _scoreAt(ids, Category.Overall, false, when);
        profile.quality = _scoreAt(ids, Category.Quality, true, when);
        profile.communication = _scoreAt(ids, Category.Communication, true, when);
        profile.timeliness = _scoreAt(ids, Category.Timeliness, true, when);
        profile.reliability = _scoreAt(ids, Category.Reliability, true, when);
    }

    /// @notice Overall scores for many subjects in one call, in the same
    ///         order as `subjects` — the multicall-style read a
    ///         marketplace needs to render a list of freelancers without
    ///         one RPC call per row. Unknown subjects (never attested)
    ///         return a zero Score, exactly like `getScore` does for
    ///         them. An empty input returns an empty array.
    function getScores(
        address[] calldata subjects
    ) external view returns (Score[] memory scores) {
        scores = new Score[](subjects.length);
        for (uint256 i = 0; i < subjects.length; i++) {
            scores[i] = _score(
                _subjectAttestations[subjects[i]],
                Category.Overall,
                false
            );
        }
    }

    /// @notice Full profiles (overall + all four category scores) for
    ///         many subjects in one call, in the same order as
    ///         `subjects` — one RPC call renders a whole directory page.
    ///         Unknown subjects return an all-zero Profile, exactly like
    ///         `getProfile` does for them. An empty input returns an
    ///         empty array. Like the other batch read, this is a view
    ///         for off-chain `eth_call`: it scans every subject's
    ///         attestations, so it grows linearly with the input list.
    function getProfiles(
        address[] calldata subjects
    ) external view returns (Profile[] memory profiles) {
        profiles = new Profile[](subjects.length);
        for (uint256 i = 0; i < subjects.length; i++) {
            uint256[] storage ids = _subjectAttestations[subjects[i]];
            profiles[i].overall = _score(ids, Category.Overall, false);
            profiles[i].quality = _score(ids, Category.Quality, true);
            profiles[i].communication = _score(
                ids,
                Category.Communication,
                true
            );
            profiles[i].timeliness = _score(ids, Category.Timeliness, true);
            profiles[i].reliability = _score(ids, Category.Reliability, true);
        }
    }

    /// @notice Tiers for many subjects in one call, in the same order as
    ///         `subjects` — the batch form of `tierOf`, for rendering
    ///         badges on a list of freelancers. Unknown subjects return
    ///         `Tier.Unranked`, exactly like `tierOf` does for them. An
    ///         empty input returns an empty array.
    function getTiers(
        address[] calldata subjects
    ) external view returns (Tier[] memory tiers) {
        tiers = new Tier[](subjects.length);
        for (uint256 i = 0; i < subjects.length; i++) {
            tiers[i] = _tierOf(
                _score(
                    _subjectAttestations[subjects[i]],
                    Category.Overall,
                    false
                )
            );
        }
    }

    /// @notice Every subject currently sitting in one tier, in first-seen
    ///         order — the directory view behind "show me all Trusted
    ///         freelancers". `limit` is clamped to the matching set and a
    ///         limit of 0 returns an empty array, like the leaderboards.
    ///         Subjects that opted out of public discovery are not
    ///         listed in any tier (see `setLeaderboardOptOut`).
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
            // The tier directory is public discovery too: opted-out
            // subjects are not listed in any tier.
            if (_leaderboardOptOut[_subjects[i]]) continue;
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
    ///         excluded, as are subjects that opted out of public
    ///         discovery (see `setLeaderboardOptOut`), and `limit` is clamped to the ranked set — a limit
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

    /// @notice Opt yourself out of — or back into — public discovery:
    ///         the leaderboards and the tier directory. Only the subject
    ///         themself may call this (the caller IS the subject), so no
    ///         one can hide or expose someone else. Opting out never
    ///         touches scores, tiers, attestations, or proofs: a hidden
    ///         freelancer's reputation is still readable directly, just
    ///         not listed publicly. A subject may opt out before ever
    ///         receiving an attestation; the choice applies as soon as
    ///         they are listed.
    function setLeaderboardOptOut(bool optOut) external {
        _leaderboardOptOut[msg.sender] = optOut;
        emit LeaderboardOptOut(msg.sender, optOut);
    }

    /// @notice Whether a subject opted out of public discovery.
    function isLeaderboardOptedOut(
        address subject
    ) external view returns (bool) {
        return _leaderboardOptOut[subject];
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
            // Opted-out subjects never appear on a public board, even
            // with active attestations — privacy is a listing rule,
            // not a score rule.
            if (_leaderboardOptOut[_subjects[i]]) continue;
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
        return decayFactorBpsAt(timestamp, uint64(block.timestamp));
    }

    /// @notice Decay factor (basis points) for an attestation last updated
    ///         at `timestamp`, measured against time `when` instead of the
    ///         current block time — the building block of the score-preview
    ///         views. A `when` before the update counts as full weight:
    ///         the attestation had not aged yet at that point.
    function decayFactorBpsAt(
        uint64 timestamp,
        uint64 when
    ) public pure returns (uint256) {
        if (when <= timestamp) return DECAY_FULL_BPS;
        uint256 age = when - timestamp;
        if (age < DECAY_FULL_PERIOD) return DECAY_FULL_BPS;
        if (age < DECAY_HALF_PERIOD) return DECAY_HALF_BPS;
        return DECAY_QUARTER_BPS;
    }

    /// @notice Mark an attester verified (or un-verify them). Only the
    ///         owner may call this. Verification is a trust signal the
    ///         deployer vouches for — e.g. a platform's KYC'd clients —
    ///         and it boosts the weight of the attester's NEXT
    ///         attestations (see `attesterWeight`); it never rewrites
    ///         records that already exist.
    function setVerifiedAttester(address attester, bool verified) external {
        if (msg.sender != owner) revert NotOwner();
        if (attester == address(0)) revert ZeroAddress();
        _verifiedAttesters[attester] = verified;
        emit AttesterVerified(attester, verified);
    }

    /// @notice Strike a misbehaving attester — fake endorsements, spam,
    ///         paid reviews. Only the owner may call this. Each strike
    ///         lowers the weight of the attester's next attestations by
    ///         1 (see `attesterWeight`); at 3 strikes the attester is
    ///         suspended and cannot attest until the owner clears the
    ///         strikes. Strikes keep counting past the suspension
    ///         threshold (a fourth offence is still an offence); only
    ///         `clearStrikes` resets the count. Existing records are
    ///         never rewritten — strikes are snapshot-time only, like
    ///         verification, so a suspended attester's past scores keep
    ///         counting. A suspended attester may still revoke their own
    ///         attestations and resolve disputes over them; only new
    ///         attestations are blocked.
    function strikeAttester(address attester) external {
        if (msg.sender != owner) revert NotOwner();
        if (attester == address(0)) revert ZeroAddress();
        _strikes[attester] += 1;
        emit AttesterStruck(attester, _strikes[attester]);
    }

    /// @notice Clear every strike on an attester, reinstating them:
    ///         they may attest again, at their un-struck weight. Only
    ///         the owner may call this. Clearing never touches the
    ///         attester's records — only future attestations change.
    function clearStrikes(address attester) external {
        if (msg.sender != owner) revert NotOwner();
        if (attester == address(0)) revert ZeroAddress();
        _strikes[attester] = 0;
        emit StrikesCleared(attester);
    }

    /// @notice How many strikes an attester currently holds.
    function strikes(address attester) external view returns (uint256) {
        return _strikes[attester];
    }

    /// @notice Whether an attester is suspended (3+ strikes) and
    ///         therefore cannot attest until the owner clears them.
    function isSuspended(address attester) external view returns (bool) {
        return _strikes[attester] >= MAX_STRIKES;
    }

    /// @notice Whether an attester is currently verified.
    function isVerifiedAttester(
        address attester
    ) external view returns (bool) {
        return _verifiedAttesters[attester];
    }

    /// @notice Change how long attestations count toward scores. Only
    ///         the owner may call this. The new duration applies to
    ///         every record from its own last update — it is not
    ///         per-attestation, so shortening it can expire old records
    ///         immediately, and setting it to 0 revives every expired
    ///         record at once (they count again, as if expiry never
    ///         happened). Existing records are never rewritten.
    function setExpiryDuration(uint64 duration) external {
        if (msg.sender != owner) revert NotOwner();
        expiryDuration = duration;
        emit ExpiryDurationUpdated(duration);
    }

    /// @notice Freeze the registry in an emergency: a bug, a spam
    ///         wave, a compromised relayer. Only the owner may call
    ///         this. While paused, no attestation can be created or
    ///         updated (direct, batch, or signed) and no evidence or
    ///         score proof can be issued. Deliberately NOT blocked:
    ///         revoking an attestation, and raising, resolving, or
    ///         expiring a dispute — a pause must never trap a subject
    ///         under a bad attestation, and the owner's own admin
    ///         controls (verify, strike, expiry) keep working so the
    ///         problem that caused the pause can be fixed while it
    ///         is in force. Scores, tiers, leaderboards, and all reads
    ///         keep working: pausing freezes writes, not the registry.
    function pause() external {
        if (msg.sender != owner) revert NotOwner();
        if (paused) revert RegistryPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unfreeze the registry after a pause. Only the owner
    ///         may call this. Attestations pick up exactly where they
    ///         left off — a pause never rewrites records, scores, or
    ///         the decay clock.
    function unpause() external {
        if (msg.sender != owner) revert NotOwner();
        if (!paused) revert RegistryNotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Start handing the registry to a new owner. Only the
    ///         current owner may call this. Nothing changes yet: the
    ///         new owner must call `acceptOwnership` themselves, so a
    ///         typo cannot hand the registry to a dead address, and a
    ///         transfer started in error can be cancelled before it
    ///         lands. Starting a second transfer overwrites the first
    ///         pending one. Works while paused — governance is not a
    ///         reputation write.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(owner, newOwner);
    }

    /// @notice Accept a pending ownership transfer. Only the address
    ///         named in `transferOwnership` may call this. The old
    ///         owner loses every admin right the moment this lands:
    ///         verify, strike, pause, proof issuance, and starting the
    ///         next transfer all move to the new owner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, owner);
    }

    /// @notice Cancel a pending ownership transfer. Only the current
    ///         owner may call this. The pending address loses the
    ///         right to accept, and the current owner keeps the
    ///         registry.
    function cancelOwnershipTransfer() external {
        if (msg.sender != owner) revert NotOwner();
        if (pendingOwner == address(0)) revert NoPendingTransfer();
        address cancelled = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(owner, cancelled);
    }

    /// @notice When an attestation stops counting toward scores: its
    ///         last update plus the current expiry duration. Returns 0
    ///         while expiry is disabled, so callers can tell "never
    ///         expires" apart from a timestamp.
    function expiresAt(uint256 id) external view returns (uint64) {
        if (id >= _attestations.length) revert UnknownAttestation();
        if (expiryDuration == 0) return 0;
        return _attestations[id].updatedAt + expiryDuration;
    }

    /// @notice Whether an attestation is expired right now (its last
    ///         update is older than the expiry duration). Expired
    ///         records stay readable and revocable, but count toward no
    ///         score until the attester re-attests.
    function isExpired(uint256 id) external view returns (bool) {
        if (id >= _attestations.length) revert UnknownAttestation();
        return _isExpiredAt(_attestations[id], uint64(block.timestamp));
    }

    /// @notice Expiry as it stands at time `when`: true once `when`
    ///         reaches the record's last update plus the current expiry
    ///         duration. The score-preview views use this so "your
    ///         reputation in 30 days" also reflects records expiring.
    function _isExpiredAt(
        Attestation storage a,
        uint64 when
    ) internal view returns (bool) {
        if (expiryDuration == 0) return false;
        return when >= a.updatedAt + expiryDuration;
    }

    /// @notice Weight this attester's next attestation would carry, from their
    ///         own current (decayed) average: <50 -> 1, 50-79 -> 2, >=80 -> 3.
    ///         A verified attester gets +1 on top, capped at 3: a newcomer
    ///         the owner vouches for counts as much as a mid-reputation
    ///         attester, but verification alone can never outrank a
    ///         consistently well-rated one. Each strike then lowers the
    ///         weight by 1, floored at 1, so one strike takes a verified
    ///         newcomer back to 1 and two strikes take a top attester to
    ///         1. A suspended attester (3+ strikes) weighs 0: they cannot
    ///         attest at all until the owner clears the strikes.
    function attesterWeight(address attester) public view returns (uint8) {
        if (_strikes[attester] >= MAX_STRIKES) return 0;
        Score memory s = _score(_subjectAttestations[attester], Category.Overall, false);
        uint8 weight;
        if (s.average >= 8000) weight = 3;
        else if (s.average >= 5000) weight = 2;
        else weight = 1;
        if (_verifiedAttesters[attester] && weight < MAX_WEIGHT) {
            weight += 1;
        }
        uint256 strikeCount = _strikes[attester];
        if (strikeCount > 0) {
            uint256 reduced = uint256(weight) > strikeCount
                ? uint256(weight) - strikeCount
                : 1;
            weight = uint8(reduced);
        }
        return weight;
    }

    function _score(
        uint256[] storage ids,
        Category category,
        bool filterCategory
    ) internal view returns (Score memory) {
        return _scoreAt(ids, category, filterCategory, uint64(block.timestamp));
    }

    /// @notice Score as it stands at time `when`, with decay measured
    ///         against `when` instead of the current block time.
    ///         Attestations created after `when` are excluded — they did
    ///         not exist yet at that point. Revoked/disputed flags are
    ///         read as they stand now: this is a decay preview, not a
    ///         full historical reconstruction — a revocation or dispute
    ///         that happened after `when` is not rewound. For a future
    ///         `when` the result is exact, given the records as they are.
    ///         Expired attestations are excluded the same way: a record
    ///         whose last update plus the expiry duration is at or
    ///         before `when` has faded out by then (and a re-attestation
    ///         after `when` does not revive it in the preview, because
    ///         the record's current `updatedAt` is what the check reads).
    function _scoreAt(
        uint256[] storage ids,
        Category category,
        bool filterCategory,
        uint64 when
    ) internal view returns (Score memory result) {
        uint256 weightedSum;
        for (uint256 i = 0; i < ids.length; i++) {
            Attestation storage a = _attestations[ids[i]];
            if (a.revoked) continue;
            if (a.disputed) continue;
            if (a.createdAt > when) continue;
            if (_isExpiredAt(a, when)) continue;
            if (filterCategory && a.category != category) continue;
            // Fixed-point decay: multiply before dividing so a weight-1
            // attestation at quarter weight still counts (2500 bps), instead
            // of truncating to zero.
            uint256 effective = uint256(a.weight) *
                decayFactorBpsAt(a.updatedAt, when);
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
