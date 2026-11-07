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
///      dispute window (30 days by default, owner-configurable) lapses
///      and the subject reinstates them.
///      The overall score blends every category, but not necessarily
///      equally: the owner may weight categories (see
///      `setCategoryWeight`), so a registry for, say, safety-critical
///      work can count Reliability twice as much as Timeliness.
///      Weights default to 100 for every category (an equal blend) and
///      may be set from 0 (the category drops out of the overall score
///      entirely) to 1000 (ten times the default). Per-category scores
///      are never weighted — a category's own average is always the
///      plain blend of its attestations — and a retune re-weights the
///      live overall score at once without rewriting any record.
///      If the attester ignores a dispute for the escalation delay
///      (7 days by default, owner-configurable), the subject may
///      escalate it to the registry owner, who arbitrates it — upholding
///      or conceding on the attester's behalf — so an unresponsive
///      attester cannot stall a dispute for the full dispute window.
///      And if a dispute is resolved by upholding the attestation, the
///      subject gets one appeal within the appeal window (7 days by
///      default, owner-configurable): the record stays excluded from
///      scores until the owner arbitrates the appeal, so neither party
///      judges their own case.
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
///      The owner may also switch the registry to verified-only
///      mode, so only verified attesters can attest at all — the
///      allowlist a registry needs after a spam wave, or from the
///      start when only KYC'd clients should ever file.
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
        bool appealed; // subject appealed an upheld resolution; excluded
        // from every score until the owner arbitrates the appeal
        uint64 resolvedAt; // when the last dispute resolution upheld the
        // attestation (0 = no appeal available: never disputed, or the
        // dispute was conceded/expired/revoked instead of upheld)
        bool appealUsed; // an appeal was already raised for the current
        // dispute outcome; a fresh dispute resets this
        uint256 requestId; // the request this record was created or last
        // updated through (see `fulfillAttestationRequest`); 0 when
        // the record never came from a request
        bool fromRequest; // whether `requestId` names a real request
    }

    struct Score {
        uint256 average; // scaled by 100, 0 when count == 0
        uint256 count; // active attestations included
        uint256 totalWeight; // raw snapshot weights, before decay
        uint256 effectiveWeight; // decay-adjusted weight, in basis points;
        // for the overall score the category weight scales it too
        // (see `_scoreAt`), so it is the weight that actually
        // counted toward the average
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

    /// @notice Whether an attestation request is still waiting for an
    ///         answer. Expiry is time-derived, not a stored status: an
    ///         Open request past `expiresAt` is dead — it can no longer
    ///         be fulfilled or cancelled — but it stays Open in storage
    ///         so the history of what was asked remains readable.
    enum RequestStatus {
        Open,
        Fulfilled,
        Cancelled
    }

    /// @notice A subject's ask for an attestation from a specific
    ///         attester: "you worked with me, please rate me". The
    ///         attester answers with `fulfillAttestationRequest`, which
    ///         creates (or updates) the attestation and links the two
    ///         records; the subject may withdraw the ask with
    ///         `cancelAttestationRequest` while it is still open.
    ///         `contextHash` is the keccak256 of off-chain context (a
    ///         job id, a deliverable reference) so the request can be
    ///         tied to a specific piece of work without storing the
    ///         details on-chain. `attestationId` is the record the
    ///         fulfilment created or updated; it is 0 until fulfilled.
    struct AttestationRequest {
        address subject;
        address attester;
        Category category;
        bytes32 contextHash;
        uint64 createdAt;
        uint64 expiresAt;
        RequestStatus status;
        uint256 attestationId;
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
    error InvalidDecayPeriods();
    error InvalidGovernanceWindow();
    error InvalidProofValidity();
    error NoScoreProof();
    error NotDelegate();
    error InvalidDelegate();
    error DailyAttestationLimitReached();
    error InvalidDailyLimit();
    error IncorrectDisputeBond();
    error InvalidDisputeBond();
    error InvalidCategoryWeight();
    error NotVerifiedAttester();
    error BondTransferFailed();
    error ReentrantCall();
    error NotAppealable();
    error AlreadyAppealed();
    error AppealWindowExpired();
    error NotAppealed();
    error UnknownAttestationRequest();
    error RequestAlreadyOpen();
    error NotRequestSubject();
    error NotRequestAttester();
    error RequestNotOpen();
    error RequestExpired();
    error InvalidRequestValidity();

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
    event AppealRaised(
        uint256 indexed id,
        address indexed attester,
        address indexed subject
    );
    event AppealResolved(
        uint256 indexed id,
        address indexed attester,
        address indexed subject,
        bool upheld
    );
    event AttesterVerified(address indexed attester, bool verified);
    event VerifiedOnlyUpdated(bool verifiedOnly);
    event LeaderboardOptOut(address indexed subject, bool optedOut);
    event AttesterStruck(address indexed attester, uint256 strikes);
    event StrikesCleared(address indexed attester);
    event ExpiryDurationUpdated(uint64 expiryDuration);
    event DecayPeriodsUpdated(uint256 fullPeriod, uint256 halfPeriod);
    event DisputeWindowUpdated(uint256 disputeWindow);
    event EscalationDelayUpdated(uint256 escalationDelay);
    event AppealWindowUpdated(uint256 appealWindow);
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
    event MaxAttestationsPerDayUpdated(uint256 maxAttestationsPerDay);
    event DisputeBondUpdated(uint256 disputeBond);
    event CategoryWeightUpdated(Category indexed category, uint256 weight);
    event DisputeBondSettled(
        uint256 indexed id,
        address indexed recipient,
        uint256 amount
    );
    event AttestationRequested(
        uint256 indexed id,
        address indexed subject,
        address indexed attester,
        Category category
    );
    event AttestationRequestCancelled(
        uint256 indexed id,
        address indexed subject,
        address indexed attester
    );
    event AttestationRequestFulfilled(
        uint256 indexed id,
        address indexed attester,
        address indexed subject,
        uint256 attestationId
    );
    event RequestValidityUpdated(uint64 validity);

    uint8 public constant MAX_SCORE = 100;
    uint8 public constant MAX_WEIGHT = 3;

    /// @notice Strikes at which an attester is suspended: they may not
    ///         attest (or re-attest) until the owner clears the strikes.
    uint256 public constant MAX_STRIKES = 3;

    /// @notice Decay tiers, in basis points of the snapshot weight.
    uint256 public constant DECAY_FULL_BPS = 10000; // first 90 days
    uint256 public constant DECAY_HALF_BPS = 5000; // rest of year one
    uint256 public constant DECAY_QUARTER_BPS = 2500; // after one year
    /// @notice The deploy-time decay periods (see `decayFullPeriod` /
    ///         `decayHalfPeriod`): full weight for the first 90 days,
    ///         half weight for the rest of year one, quarter weight
    ///         after. The owner may change both (see
    ///         `setDecayPeriods`); these constants stay as the
    ///         documented defaults.
    uint256 public constant DECAY_FULL_PERIOD = 90 days;
    uint256 public constant DECAY_HALF_PERIOD = 365 days;

    /// @notice Current decay periods: an attestation keeps full weight
    ///         until `decayFullPeriod` after its last update, half
    ///         weight until `decayHalfPeriod`, quarter weight after.
    ///         Start at the documented defaults; the owner may retune
    ///         them for a registry whose work cycles are shorter or
    ///         longer than a year (see `setDecayPeriods`). Changing them
    ///         re-weights every existing record from its own last
    ///         update — no record is ever rewritten.
    uint256 public decayFullPeriod = DECAY_FULL_PERIOD;
    uint256 public decayHalfPeriod = DECAY_HALF_PERIOD;

    /// @notice How long an attester has to answer a dispute before the
    ///         subject may reinstate the attestation unilaterally.
    ///         The deploy-time default (see `disputeWindow`): 30 days.
    uint256 public constant DEFAULT_DISPUTE_WINDOW = 30 days;

    /// @notice How long a dispute must sit unanswered before the subject
    ///         may escalate it to the owner for arbitration: long enough
    ///         that the attester had a fair chance to answer, short
    ///         enough that a stalled dispute does not hang for the full
    ///         dispute window. The deploy-time default (see
    ///         `escalationDelay`): 7 days.
    uint256 public constant DEFAULT_ESCALATION_DELAY = 7 days;

    /// @notice How long a subject has to appeal an upheld dispute
    ///         resolution: a week is long enough to notice the outcome
    ///         and file, short enough that an upheld attestation does
    ///         not hang in limbo indefinitely — after the window the
    ///         resolution is final and the record counts again. The
    ///         deploy-time default (see `appealWindow`): 7 days.
    uint256 public constant DEFAULT_APPEAL_WINDOW = 7 days;

    /// @notice Current dispute window: how long an attester has to
    ///         answer a dispute before the subject may reinstate the
    ///         attestation unilaterally (see `expireDispute`). Starts
    ///         at the documented default; the owner may retune it
    ///         (see `setDisputeWindow`). Shortening it lets subjects
    ///         reclaim disputed attestations sooner; lengthening it
    ///         gives attesters more time to answer. It must always
    ///         stay longer than `escalationDelay`, so escalation can
    ///         still fire before the window lapses.
    uint256 public disputeWindow = DEFAULT_DISPUTE_WINDOW;

    /// @notice Current escalation delay: how long a dispute must sit
    ///         unanswered before the subject may escalate it to the
    ///         owner (see `escalateDispute`). Starts at the documented
    ///         default; the owner may retune it (see
    ///         `setEscalationDelay`). It must always stay shorter than
    ///         `disputeWindow`, so a dispute can be escalated before
    ///         it expires.
    uint256 public escalationDelay = DEFAULT_ESCALATION_DELAY;

    /// @notice Current appeal window: how long a subject has to appeal
    ///         an upheld dispute resolution (see `appealDispute`).
    ///         Starts at the documented default; the owner may retune
    ///         it (see `setAppealWindow`). After the window the
    ///         resolution is final and the record counts again.
    uint256 public appealWindow = DEFAULT_APPEAL_WINDOW;

    /// @notice How long an attestation request stays answerable after
    ///         it is created. The deploy-time default (see
    ///         `requestValidity`): 30 days — long enough for a busy
    ///         client to answer, short enough that a stale ask does
    ///         not linger as an open obligation forever.
    uint64 public constant DEFAULT_REQUEST_VALIDITY = 30 days;

    /// @notice Bounds on `requestValidity` (see `setRequestValidity`):
    ///         at least a day, so a request is never born dead, and
    ///         at most a year, so the owner cannot create requests
    ///         that outlive the attestation expiry horizon in spirit.
    uint64 public constant MIN_REQUEST_VALIDITY = 1 days;
    uint64 public constant MAX_REQUEST_VALIDITY = 365 days;

    /// @notice Current request validity: how long a request stays
    ///         open (see `requestAttestation`). Starts at the
    ///         documented default; the owner may retune it (see
    ///         `setRequestValidity`). The new validity applies to
    ///         requests created after the retune, from their own
    ///         `createdAt` — open requests keep the deadline they
    ///         were born with.
    uint64 public requestValidity = DEFAULT_REQUEST_VALIDITY;

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

    /// @notice The highest daily attestation limit the owner may set:
    ///         a limit above this would stop being a spam control and
    ///         start looking like no limit at all, so it is capped.
    uint256 public constant MAX_DAILY_LIMIT = 1000;

    /// @notice Most fresh attestations one attester may create in a
    ///         single UTC day. Default 50 — far above what a genuine
    ///         attester files in a day, low enough that a spam account
    ///         cannot flood the registry with new records. Only fresh
    ///         attestations count: re-attesting (updating) an existing
    ///         record is always free, so an attester can keep their
    ///         existing assessments current without burning the quota.
    ///         The owner may change this (see
    ///         `setMaxAttestationsPerDay`); 0 disables the limit
    ///         entirely. The day bucket is `block.timestamp / 1 days`,
    ///         so the quota resets at each UTC midnight.
    uint256 public maxAttestationsPerDay = 50;

    /// @notice Largest dispute bond the owner may set: a bond above
    ///         this would stop being a spam deterrent and start
    ///         pricing genuine disputes out, so it is capped.
    uint256 public constant MAX_DISPUTE_BOND = 1 ether;

    /// @notice Default weight of a category in the overall score:
    ///         100 for every category, i.e. the overall score is the
    ///         plain blend of all active attestations, exactly as
    ///         before this feature.
    uint256 public constant DEFAULT_CATEGORY_WEIGHT = 100;

    /// @notice Largest weight the owner may give a category: 1000 is
    ///         ten times the default, so one category can dominate the
    ///         overall score but can never make the arithmetic overflow
    ///         (see `_scoreAt`).
    uint256 public constant MAX_CATEGORY_WEIGHT = 1000;

    /// @notice ETH a subject must stake to open a dispute. Default 0
    ///         — disputes are free until the owner opts in — so a
    ///         registry that wants free disputes keeps it at 0 and an
    ///         owner fighting dispute spam sets it (see
    ///         `setDisputeBond`). The bond is posted per dispute and
    ///         settled when the dispute closes: the attester keeps it
    ///         when the dispute is upheld, the subject gets it back
    ///         when the attester concedes, the dispute expires, or the
    ///         attestation is revoked while disputed. Changing the
    ///         bond never touches bonds already posted — each dispute
    ///         settles at the amount it was opened with.
    uint256 public disputeBond;

    /// @notice Bond posted on each open dispute, by attestation id.
    ///         Zero when no bond was posted (the bond was 0) or the
    ///         dispute has closed.
    mapping(uint256 => uint256) private _disputeBond;

    /// @notice Weight of each category in the overall score, relative
    ///         to `DEFAULT_CATEGORY_WEIGHT` (100). Set to the default
    ///         for every category at deploy time; the owner may retune
    ///         them (see `setCategoryWeight`). A weight of 0 excludes
    ///         the category from the overall score entirely — its
    ///         attestations still count toward its own per-category
    ///         score, which is never weighted.
    mapping(Category => uint256) private _categoryWeights;

    /// @notice Reentrancy lock: the registry pays out ETH when a
    ///         dispute closes, so the dispute exits are guarded even
    ///         though every payout follows checks-effects-interactions
    ///         (the bond is cleared before the transfer lands).
    bool private _locked;

    modifier nonReentrant() {
        if (_locked) revert ReentrantCall();
        _locked = true;
        _;
        _locked = false;
    }

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

    /// @notice Whether only verified attesters may attest (see
    ///         `setVerifiedOnly`). Off by default: any attester may
    ///         file an attestation, and verification is only a +1
    ///         weight boost. When the owner switches it on, the
    ///         registry becomes allowlist-only — an unverified
    ///         attester's calls revert with `NotVerifiedAttester`
    ///         on every path (direct, batch, signed, delegated),
    ///         including re-attests of their own records. Existing
    ///         records and scores are never touched: the mode gates
    ///         new writes, not reads.
    bool public verifiedOnly;

    /// @notice Delegates per attester: when an authorized delegate's
    ///         authority lapses (see `setDelegate`). `_delegateList`
    ///         tracks every address ever authorized, in first-set
    ///         order, so `getDelegates` can enumerate them.
    mapping(address => mapping(address => uint256)) private _delegateExpiry;
    mapping(address => address[]) private _delegateList;

    /// @notice Strikes per attester, set by the owner (see
    ///         `strikeAttester`). Three strikes suspends the attester.
    mapping(address => uint256) private _strikes;

    /// @notice Fresh attestations per attester per UTC day, keyed by
    ///         `block.timestamp / 1 days`. Only fresh records count
    ///         (see `maxAttestationsPerDay`); re-attests never touch
    ///         this mapping. Old buckets are never read again, so they
    ///         are left to sit — deleting them would cost gas for no
    ///         benefit.
    mapping(address => mapping(uint256 => uint256)) private _attestationsPerDay;

    /// @notice Next usable nonce per attester (replay protection).
    mapping(address => uint256) public nonces;

    constructor() {
        owner = msg.sender;
        // Every category starts at the default weight, so the overall
        // score is the plain blend of all attestations until the
        // owner retunes it.
        _categoryWeights[Category.Overall] = DEFAULT_CATEGORY_WEIGHT;
        _categoryWeights[Category.Quality] = DEFAULT_CATEGORY_WEIGHT;
        _categoryWeights[Category.Communication] = DEFAULT_CATEGORY_WEIGHT;
        _categoryWeights[Category.Timeliness] = DEFAULT_CATEGORY_WEIGHT;
        _categoryWeights[Category.Reliability] = DEFAULT_CATEGORY_WEIGHT;
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
    // Every attestation request, in creation order. Requests are never
    // deleted: a fulfilled or cancelled request stays readable as the
    // history of what was asked.
    AttestationRequest[] private _attestationRequests;
    // subject => request ids they created, attester => request ids
    // addressed to them, both in creation order. Powers the
    // open-request reads; fulfilled/cancelled/expired entries are
    // filtered out by the views.
    mapping(address => uint256[]) private _subjectRequests;
    mapping(address => uint256[]) private _attesterRequests;
    // keccak256(subject, attester, category) => id + 1 of the open
    // request (0 == none open). Enforces one open request per
    // (subject, attester, category): a subject cannot spam the same
    // attester with the same ask. An expired open request still
    // occupies its key until a fresh request replaces it — the
    // creation check treats an expired entry as free, and the
    // open-request views filter expired entries out.
    mapping(bytes32 => uint256) private _openRequestByKey;

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

    /// @notice Whether an attestation request is dead by time: still
    ///         Open in storage, but past `expiresAt`. A dead request
    ///         can no longer be fulfilled or cancelled — the subject
    ///         simply makes a fresh request — and the open-request
    ///         views skip it.
    function _isRequestExpired(
        AttestationRequest storage req
    ) internal view returns (bool) {
        return
            req.status == RequestStatus.Open &&
            req.expiresAt <= block.timestamp;
    }

    /// @notice Key for the one-open-request-per-ask rule: a subject
    ///         may have only one open request to a given attester for
    ///         a given category at a time.
    function _requestKey(
        address subject,
        address attester,
        Category category
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(subject, attester, category));
    }

    /// @notice Ask a specific attester to rate you in `category` —
    ///         the outbound half of the request flow (see
    ///         `fulfillAttestationRequest`). Only one open request
    ///         per (subject, attester, category) may exist: a second
    ///         ask while one is still open reverts, so a subject
    ///         cannot spam the same attester with the same request.
    ///         An expired open request does not block a fresh one —
    ///         it is dead, and the new request takes its place.
    ///         `contextHash` ties the ask to off-chain context (a job
    ///         id, a deliverable reference) without storing the
    ///         details on-chain. The request stays answerable for
    ///         `requestValidity` from creation. Blocked while the
    ///         registry is paused: a request is the first step of an
    ///         attestation, and no new attestation may start while
    ///         paused.
    /// @return id The request id.
    function requestAttestation(
        address attester,
        Category category,
        bytes32 contextHash
    ) external returns (uint256 id) {
        if (paused) revert RegistryPaused();
        if (attester == address(0)) revert ZeroAddress();
        if (attester == msg.sender) revert SelfAttestation();
        bytes32 key = _requestKey(msg.sender, attester, category);
        uint256 existing = _openRequestByKey[key];
        if (existing != 0) {
            AttestationRequest storage old = _attestationRequests[
                existing - 1
            ];
            if (!_isRequestExpired(old)) revert RequestAlreadyOpen();
        }
        id = _attestationRequests.length;
        _attestationRequests.push(
            AttestationRequest({
                subject: msg.sender,
                attester: attester,
                category: category,
                contextHash: contextHash,
                createdAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + requestValidity,
                status: RequestStatus.Open,
                attestationId: 0
            })
        );
        _subjectRequests[msg.sender].push(id);
        _attesterRequests[attester].push(id);
        _openRequestByKey[key] = id + 1;
        emit AttestationRequested(id, msg.sender, attester, category);
    }

    /// @notice Withdraw one of your own open requests. Only the
    ///         subject may cancel, and only while the request is
    ///         still open and unexpired: an expired request is
    ///         already dead, so there is nothing to withdraw — make
    ///         a fresh request instead. Cancelling frees the
    ///         (subject, attester, category) slot at once.
    function cancelAttestationRequest(uint256 id) external {
        if (id >= _attestationRequests.length) {
            revert UnknownAttestationRequest();
        }
        AttestationRequest storage req = _attestationRequests[id];
        if (req.subject != msg.sender) revert NotRequestSubject();
        if (req.status != RequestStatus.Open) revert RequestNotOpen();
        if (_isRequestExpired(req)) revert RequestExpired();
        req.status = RequestStatus.Cancelled;
        bytes32 key = _requestKey(req.subject, req.attester, req.category);
        if (_openRequestByKey[key] == id + 1) _openRequestByKey[key] = 0;
        emit AttestationRequestCancelled(id, req.subject, req.attester);
    }

    /// @notice Retune how long a new attestation request stays
    ///         answerable. Only the owner may call this. The new
    ///         validity applies to requests created after the retune,
    ///         from their own `createdAt` — open requests keep the
    ///         deadline they were born with. Bounds: at least
    ///         `MIN_REQUEST_VALIDITY` (a request must never be born
    ///         dead), at most `MAX_REQUEST_VALIDITY`.
    function setRequestValidity(uint64 validity) external {
        if (msg.sender != owner) revert NotOwner();
        if (validity < MIN_REQUEST_VALIDITY || validity > MAX_REQUEST_VALIDITY) {
            revert InvalidRequestValidity();
        }
        requestValidity = validity;
        emit RequestValidityUpdated(validity);
    }

    /// @notice Answer one of your open attestation requests: file the
    ///         rating the subject asked for. Only the attester named
    ///         in the request may fulfil it — a delegate cannot
    ///         answer on their behalf, because the request is a
    ///         personal ask to that attester, and a delegate's
    ///         attestation would not carry the attester's own answer
    ///         to it (a delegate can still attest directly via
    ///         `attestOnBehalf`). The rating goes through `_attest`
    ///         with all its guards — pause, suspension, verified-only
    ///         mode, score range, daily rate limit (a fresh
    ///         attestation consumes quota; updating an existing
    ///         record is free) — and a disputed existing record
    ///         blocks the fulfilment until the dispute resolves.
    ///         Fulfilling when you already have an active attestation
    ///         for the same subject + category updates that record
    ///         in place (and links it to this request) instead of
    ///         creating a second one. On success the request is
    ///         Fulfilled, the slot frees, and the attestation records
    ///         which request it came from.
    /// @return attestationId The attestation created or updated.
    function fulfillAttestationRequest(
        uint256 id,
        uint8 score,
        bytes32 commentHash
    ) external returns (uint256 attestationId) {
        return
            _fulfillRequest(
                msg.sender,
                id,
                score,
                commentHash,
                bytes32(0),
                false
            );
    }

    /// @notice `fulfillAttestationRequest` with supporting evidence
    ///         attached: same request rules, same evidence semantics
    ///         as `attestWithEvidence` (replaces the evidence on an
    ///         updated record).
    function fulfillAttestationRequestWithEvidence(
        uint256 id,
        uint8 score,
        bytes32 commentHash,
        bytes32 evidenceHash
    ) external returns (uint256 attestationId) {
        return
            _fulfillRequest(
                msg.sender,
                id,
                score,
                commentHash,
                evidenceHash,
                true
            );
    }

    function _fulfillRequest(
        address attester,
        uint256 id,
        uint8 score,
        bytes32 commentHash,
        bytes32 evidenceHash,
        bool replaceEvidence
    ) internal returns (uint256 attestationId) {
        if (id >= _attestationRequests.length) {
            revert UnknownAttestationRequest();
        }
        AttestationRequest storage req = _attestationRequests[id];
        if (req.attester != attester) revert NotRequestAttester();
        if (req.status != RequestStatus.Open) revert RequestNotOpen();
        if (_isRequestExpired(req)) revert RequestExpired();
        attestationId = _attestWithRequest(
            attester,
            req.subject,
            req.category,
            score,
            commentHash,
            evidenceHash,
            replaceEvidence,
            id + 1
        );
        req.status = RequestStatus.Fulfilled;
        req.attestationId = attestationId;
        bytes32 key = _requestKey(req.subject, req.attester, req.category);
        if (_openRequestByKey[key] == id + 1) _openRequestByKey[key] = 0;
        emit AttestationRequestFulfilled(
            id,
            attester,
            req.subject,
            attestationId
        );
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

    /// @notice Direct (non-request) attestations carry no request
    ///         link: `requestIdPlusOne` 0.
    function _attest(
        address attester,
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash,
        bytes32 evidenceHash,
        bool replaceEvidence
    ) internal returns (uint256 id) {
        return
            _attestWithRequest(
                attester,
                subject,
                category,
                score,
                commentHash,
                evidenceHash,
                replaceEvidence,
                0
            );
    }

    /// @notice The shared attestation writer: direct, batch, signed,
    ///         delegated, and request-fulfilment paths all land here,
    ///         so no entry point can bypass the guards. A request
    ///         fulfilment passes its request id + 1 (`requestIdPlusOne`;
    ///         0 means "not from a request", the same sentinel the
    ///         `_activeByKey` and `_openRequestByKey` mappings use);
    ///         every other path passes 0. Updating an existing record
    ///         through a request links the record to that request; a
    ///         plain re-attest leaves an existing link untouched, so
    ///         the record keeps the provenance of the request it came
    ///         from.
    function _attestWithRequest(
        address attester,
        address subject,
        Category category,
        uint8 score,
        bytes32 commentHash,
        bytes32 evidenceHash,
        bool replaceEvidence,
        uint256 requestIdPlusOne
    ) internal returns (uint256 id) {
        if (paused) revert RegistryPaused();
        if (subject == address(0)) revert ZeroAddress();
        if (subject == attester) revert SelfAttestation();
        if (score > MAX_SCORE) revert InvalidScore();
        if (_strikes[attester] >= MAX_STRIKES) revert AttesterSuspended();
        // Verified-only mode gates every attestation path — direct,
        // batch, signed, delegated — and re-attests too: an
        // unverified attester cannot create or update a record while
        // it is on. The check sits in `_attest` so no entry point
        // can bypass it, and it reads the live flag, so verifying
        // an attester unblocks them at once.
        if (verifiedOnly && !_verifiedAttesters[attester]) {
            revert NotVerifiedAttester();
        }

        uint8 weight = attesterWeight(attester);
        bytes32 key = _key(attester, subject, category);
        uint256 existing = _activeByKey[key];

        if (existing != 0) {
            id = existing - 1;
            Attestation storage a = _attestations[id];
            // A disputed attestation cannot be quietly overwritten by the
            // attester; it must go through resolveDispute first. An
            // appealed one is under arbitration for the same reason:
            // the attester must not change the score mid-appeal.
            if (a.disputed) revert AlreadyDisputed();
            if (a.appealed) revert AlreadyAppealed();
            a.score = score;
            a.weight = weight;
            a.commentHash = commentHash;
            // A request fulfilment that updates an existing record
            // links the record to the request; a plain re-attest
            // never clears an existing link (see `_attestWithRequest`).
            if (requestIdPlusOne != 0) {
                a.requestId = requestIdPlusOne - 1;
                a.fromRequest = true;
            }
            // Plain re-attests (attest / attestBatch / signed paths) pass
            // replaceEvidence == false and must not wipe evidence that
            // was attached earlier; attestWithEvidence replaces it.
            if (replaceEvidence) a.evidenceHash = evidenceHash;
            a.updatedAt = uint64(block.timestamp);
            emit AttestationUpdated(id, attester, subject, category, score, weight);
            _recordSnapshot(subject, category);
            return id;
        }

        // Fresh attestations only: re-attests (the branch above) never
        // consume quota, so updating an existing assessment is always
        // free. The check sits after the pause / suspension guards at
        // the top, and the limit hit reverts before any storage is
        // written, so a failed batch leaves no partial state behind.
        // The day bucket is computed inline (no local) to keep this
        // function under the stack limit.
        if (maxAttestationsPerDay > 0) {
            if (
                _attestationsPerDay[attester][block.timestamp / 1 days] >=
                maxAttestationsPerDay
            ) {
                revert DailyAttestationLimitReached();
            }
            _attestationsPerDay[attester][block.timestamp / 1 days]++;
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
                escalated: false,
                appealed: false,
                resolvedAt: 0,
                appealUsed: false,
                requestId: requestIdPlusOne == 0
                    ? 0
                    : requestIdPlusOne - 1,
                fromRequest: requestIdPlusOne != 0
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
    function revokeAttestation(uint256 id) external nonReentrant {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.attester != msg.sender) revert NotAttester();
        if (a.revoked) revert AlreadyRevoked();
        a.revoked = true;
        // Revoking also settles any open dispute on this record.
        bool wasDisputed = a.disputed;
        a.disputed = false;
        a.disputeReason = bytes32(0);
        a.disputedAt = 0;
        a.escalated = false;
        // A revoked record has nothing left to appeal.
        a.appealed = false;
        a.resolvedAt = 0;
        a.appealUsed = false;
        _activeByKey[_key(a.attester, a.subject, a.category)] = 0;
        emit AttestationRevoked(id, msg.sender, a.subject);
        _recordSnapshot(a.subject, a.category);
        // A revoked dispute is a dispute the subject did not lose:
        // the bond goes back to the subject.
        if (wasDisputed) _settleDisputeBond(id, a.subject);
    }

    /// @notice Dispute an attestation about you. Only the subject may
    ///         dispute, only while the attestation is active, and only once
    ///         at a time. While disputed it is excluded from every score.
    ///         An expired attestation cannot be disputed: it already
    ///         counts toward no score, so there is nothing to dispute —
    ///         if the attester re-attests and revives it, the fresh
    ///         record can be disputed like any other.
    ///         When the owner has set a dispute bond (see
    ///         `setDisputeBond`), disputing stakes exactly that much
    ///         ETH: it is the attester's when the dispute is upheld and
    ///         refunded to you when it is conceded, expires, or the
    ///         attestation is revoked while disputed. Sending any other
    ///         amount reverts, and a 0 bond means disputes are free.
    function disputeAttestation(
        uint256 id,
        bytes32 reasonHash
    ) external payable nonReentrant {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.subject != msg.sender) revert NotSubject();
        if (a.revoked) revert AlreadyRevoked();
        if (a.disputed) revert AlreadyDisputed();
        // An appealed record is under arbitration, like a disputed
        // one: the subject must wait for the owner to rule before
        // opening a fresh dispute over it.
        if (a.appealed) revert AlreadyAppealed();
        if (_isExpiredAt(a, uint64(block.timestamp))) {
            revert AttestationExpired();
        }
        if (msg.value != disputeBond) revert IncorrectDisputeBond();
        _disputeBond[id] = msg.value;
        a.disputed = true;
        a.disputeReason = reasonHash;
        a.disputedAt = uint64(block.timestamp);
        // A fresh dispute gets a fresh appeal right: any earlier
        // resolution (and its appeal window) no longer stands.
        a.resolvedAt = 0;
        a.appealUsed = false;
        emit DisputeRaised(id, a.attester, a.subject);
        _recordSnapshot(a.subject, a.category);
    }

    /// @notice Resolve a dispute over your attestation. Upholding clears the
    ///         dispute (and refreshes the decay clock: the attestation is
    ///         re-confirmed); conceding revokes the attestation, freeing the
    ///         subject to be re-attested later. The dispute bond, if one
    ///         was posted, goes to you when you uphold and back to the
    ///         subject when you concede.
    function resolveDispute(uint256 id, bool uphold) external nonReentrant {
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
            // An upheld resolution opens the subject's appeal window.
            a.resolvedAt = uint64(block.timestamp);
        } else {
            a.revoked = true;
            a.disputed = false;
            a.disputeReason = bytes32(0);
            a.disputedAt = 0;
            a.escalated = false;
            a.resolvedAt = 0;
            _activeByKey[_key(a.attester, a.subject, a.category)] = 0;
        }
        emit DisputeResolved(id, a.attester, a.subject, uphold);
        _recordSnapshot(a.subject, a.category);
        _settleDisputeBond(id, uphold ? a.attester : a.subject);
    }

    /// @notice Reinstate an attestation whose dispute went unanswered for the
    ///         full dispute window. Only the subject may call this: it stops
    ///         an attester from suppressing a score forever by ignoring the
    ///         dispute. The decay clock is NOT refreshed — expiry is not a
    ///         re-confirmation. The dispute bond, if one was posted, is
    ///         refunded to the subject: an unanswered dispute is not a
    ///         dispute the subject lost.
    function expireDispute(uint256 id) external nonReentrant {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.subject != msg.sender) revert NotSubject();
        if (!a.disputed) revert NotDisputed();
        if (block.timestamp < uint256(a.disputedAt) + disputeWindow) {
            revert DisputeNotExpired();
        }
        a.disputed = false;
        a.disputeReason = bytes32(0);
        a.disputedAt = 0;
        a.escalated = false;
        emit DisputeExpired(id, a.attester, a.subject);
        _recordSnapshot(a.subject, a.category);
        _settleDisputeBond(id, a.subject);
    }

    /// @notice Escalate an unanswered dispute to the registry owner for
    ///         arbitration. Only the subject may escalate, only once the
    ///         attester has had `escalationDelay` to answer, and
    ///         only while the dispute is still open. Escalation changes
    ///         no score — the record stays excluded — it only opens the
    ///         owner-arbitration path, so an unresponsive attester cannot
    ///         stall a dispute for the full dispute window. Like the other
    ///         dispute exits, escalation stays open while paused.
    function escalateDispute(uint256 id) external {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.subject != msg.sender) revert NotSubject();
        if (!a.disputed) revert NotDisputed();
        if (a.escalated) revert AlreadyEscalated();
        if (block.timestamp < uint256(a.disputedAt) + escalationDelay) {
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
    ///         like every other dispute exit. The bond settles the same
    ///         way as an attester resolution: to the attester on uphold,
    ///         back to the subject on concede.
    function resolveDisputeAsOwner(
        uint256 id,
        bool uphold
    ) external nonReentrant {
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
            // An upheld resolution opens the subject's appeal window.
            a.resolvedAt = uint64(block.timestamp);
        } else {
            a.revoked = true;
            a.disputed = false;
            a.disputeReason = bytes32(0);
            a.disputedAt = 0;
            a.escalated = false;
            a.resolvedAt = 0;
            _activeByKey[_key(a.attester, a.subject, a.category)] = 0;
        }
        emit DisputeResolvedByOwner(id, a.attester, a.subject, uphold);
        _recordSnapshot(a.subject, a.category);
        _settleDisputeBond(id, uphold ? a.attester : a.subject);
    }

    /// @notice Whether the open dispute on an attestation has been
    ///         escalated to the owner for arbitration.
    function isDisputeEscalated(
        uint256 id
    ) external view returns (bool) {
        if (id >= _attestations.length) revert UnknownAttestation();
        return _attestations[id].escalated;
    }

    /// @notice Appeal an upheld dispute resolution. Only the subject may
    ///         appeal, only once per dispute outcome, and only within
    ///         `appealWindow` of the resolution — after that the
    ///         resolution is final. The appeal re-excludes the
    ///         attestation from every score until the owner arbitrates
    ///         it: an attester who "won" a dispute does not get the
    ///         score back while the subject's last word is pending.
    ///         Like a dispute, appealing stakes the current dispute
    ///         bond: it goes to the attester when the appeal is upheld
    ///         and back to you when the owner concedes it. A conceded
    ///         or expired dispute has nothing to appeal — the record
    ///         is already revoked or reinstated — and an expired
    ///         attestation cannot be appealed either, since it counts
    ///         toward no score. Appeals stay open while paused, like
    ///         every other dispute exit.
    function appealDispute(uint256 id) external payable nonReentrant {
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (a.subject != msg.sender) revert NotSubject();
        if (a.revoked) revert AlreadyRevoked();
        if (a.disputed) revert AlreadyDisputed();
        if (a.appealed) revert AlreadyAppealed();
        if (a.appealUsed || a.resolvedAt == 0) revert NotAppealable();
        if (block.timestamp > uint256(a.resolvedAt) + appealWindow) {
            revert AppealWindowExpired();
        }
        if (_isExpiredAt(a, uint64(block.timestamp))) {
            revert AttestationExpired();
        }
        if (msg.value != disputeBond) revert IncorrectDisputeBond();
        _disputeBond[id] = msg.value;
        a.appealed = true;
        a.appealUsed = true;
        a.resolvedAt = 0;
        emit AppealRaised(id, a.attester, a.subject);
        _recordSnapshot(a.subject, a.category);
    }

    /// @notice Arbitrate an open appeal as the registry owner. Upholding
    ///         re-confirms the attestation (decay clock refreshed) and
    ///         the record counts again; conceding revokes it, freeing
    ///         the subject to be re-attested later. The appeal bond
    ///         settles the same way as a dispute bond: to the attester
    ///         on uphold, back to the subject on concede. Only the
    ///         owner arbitrates an appeal, so neither party judges
    ///         their own case — and the owner may not appeal on the
    ///         subject's behalf either: an appeal is the subject's own
    ///         last word. Stays open while paused, like every other
    ///         dispute exit.
    function resolveAppeal(uint256 id, bool uphold) external nonReentrant {
        if (msg.sender != owner) revert NotOwner();
        if (id >= _attestations.length) revert UnknownAttestation();
        Attestation storage a = _attestations[id];
        if (!a.appealed) revert NotAppealed();
        if (uphold) {
            a.appealed = false;
            a.updatedAt = uint64(block.timestamp);
        } else {
            a.appealed = false;
            a.revoked = true;
            _activeByKey[_key(a.attester, a.subject, a.category)] = 0;
        }
        emit AppealResolved(id, a.attester, a.subject, uphold);
        _recordSnapshot(a.subject, a.category);
        _settleDisputeBond(id, uphold ? a.attester : a.subject);
    }

    /// @notice Whether an appeal of an upheld resolution is open on an
    ///         attestation.
    function isAppealed(uint256 id) external view returns (bool) {
        if (id >= _attestations.length) revert UnknownAttestation();
        return _attestations[id].appealed;
    }

    /// @notice Last moment the subject may appeal the upheld resolution
    ///         on an attestation (resolution time + `appealWindow`).
    ///         Returns 0 when no appeal is available.
    function appealDeadline(uint256 id) external view returns (uint64) {
        if (id >= _attestations.length) revert UnknownAttestation();
        uint64 resolvedAt = _attestations[id].resolvedAt;
        if (resolvedAt == 0) return 0;
        return resolvedAt + uint64(appealWindow);
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
            } else if (a.disputed || a.appealed) {
                // An appealed record is excluded from scores exactly
                // like a disputed one, so it counts here too.
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
    ///         not disputed, not appealed, not expired — the same rule the
    ///         score views use. Attesters with no active attestations are
    ///         excluded.
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
    ///         scores: not revoked, not disputed, not appealed, not
    ///         expired. The ranking rule for `getTopAttesters`, shared
    ///         so the board and any future caller agree on what
    ///         "active" means.
    function _activeAttestationCount(
        address attester
    ) internal view returns (uint256 active) {
        uint256[] storage ids = _attesterAttestations[attester];
        for (uint256 i = 0; i < ids.length; i++) {
            Attestation storage a = _attestations[ids[i]];
            if (a.revoked) continue;
            if (a.disputed) continue;
            if (a.appealed) continue;
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

    /// @notice Milestone badges: where tiers answer "how good is this
    ///         freelancer right now", badges answer "what have they
    ///         achieved" — a subject can hold several at once, and they
    ///         are earned in order, so a Veteran is also a RisingStar.
    ///         Unlike tiers, which only need a handful of strong
    ///         endorsements, the higher badges demand volume as well:
    ///         TopRated needs 25 active attestations, Veteran 50.
    enum Badge {
        RisingStar,
        HighlyRated,
        TopRated,
        Veteran
    }

    /// @notice Badge thresholds: (minimum average scaled by 100, minimum
    ///         active attestations). Veteran is the volume badge — it
    ///         asks for a solid average over a long track record, not a
    ///         perfect one.
    uint256 public constant BADGE_RISING_STAR_AVG = 6000;
    uint256 public constant BADGE_RISING_STAR_COUNT = 5;
    uint256 public constant BADGE_HIGHLY_RATED_AVG = 7500;
    uint256 public constant BADGE_HIGHLY_RATED_COUNT = 10;
    uint256 public constant BADGE_TOP_RATED_AVG = 8500;
    uint256 public constant BADGE_TOP_RATED_COUNT = 25;
    uint256 public constant BADGE_VETERAN_AVG = 6000;
    uint256 public constant BADGE_VETERAN_COUNT = 50;

    /// @notice The milestone badges a subject holds right now, in enum
    ///         order — the list a marketplace renders next to a
    ///         freelancer's name. Badges are a pure view over the live
    ///         decayed score, so they are earned and lost with the score
    ///         itself: revocations, disputes, expiry, and decay can all
    ///         take a badge away, exactly as they move tiers. Opting out
    ///         of public discovery (see `setLeaderboardOptOut`) does NOT
    ///         hide badges: they are a direct read about one subject,
    ///         like `tierOf`, not a discovery listing. Unknown subjects
    ///         hold no badges.
    function getBadges(
        address subject
    ) external view returns (Badge[] memory) {
        return
            _badgesOf(
                _score(_subjectAttestations[subject], Category.Overall, false)
            );
    }

    /// @notice Badges as they will stand (or stood) at time `when`, from
    ///         the decay-preview score — so a frontend can warn that a
    ///         freelancer loses TopRated in N days unless they land fresh
    ///         work. Same preview semantics as `getScoreAt` and
    ///         `tierOfAt`.
    function getBadgesAt(
        address subject,
        uint64 when
    ) external view returns (Badge[] memory) {
        return
            _badgesOf(
                _scoreAt(
                    _subjectAttestations[subject],
                    Category.Overall,
                    false,
                    when
                )
            );
    }

    /// @notice Badges for many subjects in one call, in the same order
    ///         as `subjects` — one RPC call renders the badge row of a
    ///         whole directory page. Unknown subjects return an empty
    ///         array, exactly like `getBadges` does for them. An empty
    ///         input returns an empty array.
    function getBadgesFor(
        address[] calldata subjects
    ) external view returns (Badge[][] memory badges) {
        badges = new Badge[][](subjects.length);
        for (uint256 i = 0; i < subjects.length; i++) {
            badges[i] = _badgesOf(
                _score(
                    _subjectAttestations[subjects[i]],
                    Category.Overall,
                    false
                )
            );
        }
    }

    function _badgesOf(Score memory s) internal pure returns (Badge[] memory) {
        uint256 earned;
        bool risingStar = s.average >= BADGE_RISING_STAR_AVG &&
            s.count >= BADGE_RISING_STAR_COUNT;
        bool highlyRated = s.average >= BADGE_HIGHLY_RATED_AVG &&
            s.count >= BADGE_HIGHLY_RATED_COUNT;
        bool topRated = s.average >= BADGE_TOP_RATED_AVG &&
            s.count >= BADGE_TOP_RATED_COUNT;
        bool veteran = s.average >= BADGE_VETERAN_AVG &&
            s.count >= BADGE_VETERAN_COUNT;
        if (risingStar) earned++;
        if (highlyRated) earned++;
        if (topRated) earned++;
        if (veteran) earned++;
        Badge[] memory badges = new Badge[](earned);
        uint256 at;
        if (risingStar) badges[at++] = Badge.RisingStar;
        if (highlyRated) badges[at++] = Badge.HighlyRated;
        if (topRated) badges[at++] = Badge.TopRated;
        if (veteran) badges[at++] = Badge.Veteran;
        return badges;
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

    /// @notice The leaderboard as it stood (or will stand) at time
    ///         `when` — the board behind \"who was on top last
    ///         quarter\" or \"who leads if nothing changes for a year\".
    ///         Ranks subjects by their decay-preview score at `when`
    ///         (see `_scoreAt`): attestations created after `when`
    ///         are excluded, decay is measured against `when`, and
    ///         `tier` is the subject's overall tier at `when` (see
    ///         `tierOfAt`). Same exclusion, tie-break, and limit rules
    ///         as `getLeaderboard`, and the same preview caveat:
    ///         revoked / disputed / appealed flags are read as they
    ///         stand now, so a record revoked after `when` is already
    ///         excluded from the board at `when`.
    function getLeaderboardAt(
        uint64 when,
        uint256 limit
    ) external view returns (LeaderboardEntry[] memory) {
        return _rankedLeaderboardAt(Category.Overall, false, limit, when);
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

    /// @notice The category board as it stood (or will stand) at time
    ///         `when` — the \"best communicators last quarter\" view.
    ///         Same ranking and preview semantics as
    ///         `getLeaderboardAt`, category-scoped; passing
    ///         `Category.Overall` returns exactly `getLeaderboardAt`.
    function getLeaderboardByCategoryAt(
        Category category,
        uint64 when,
        uint256 limit
    ) external view returns (LeaderboardEntry[] memory) {
        bool filterCategory = category != Category.Overall;
        return _rankedLeaderboardAt(category, filterCategory, limit, when);
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
    ///         remaining ties), and clamp to `limit`. Scores are read at
    ///         the current block time — see `_rankedLeaderboardAt` for
    ///         the time-parameterized version.
    function _rankedLeaderboard(
        Category category,
        bool filterCategory,
        uint256 limit
    ) internal view returns (LeaderboardEntry[] memory) {
        return
            _rankedLeaderboardAt(
                category,
                filterCategory,
                limit,
                uint64(block.timestamp)
            );
    }

    /// @notice The ranking at time `when`: the same board, but every
    ///         score is the decay preview at `when` (see `_scoreAt`),
    ///         so a board can be rebuilt for any past or future
    ///         moment. Opt-outs are read as they stand now — a subject
    ///         who opted out is hidden from every board, past or
    ///         future, exactly like on the live board.
    function _rankedLeaderboardAt(
        Category category,
        bool filterCategory,
        uint256 limit,
        uint64 when
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
            Score memory s = _scoreAt(
                _subjectAttestations[_subjects[i]],
                category,
                filterCategory,
                when
            );
            if (s.count == 0) continue;
            // The tier is always the subject's OVERALL tier at `when`,
            // even on a category board: a category average must not
            // promote someone to Elite on the strength of one category
            // alone.
            Tier tier = filterCategory
                ? _tierOf(
                    _scoreAt(
                        _subjectAttestations[_subjects[i]],
                        Category.Overall,
                        false,
                        when
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
    ///         the attestation had not aged yet at that point. The
    ///         periods are the currently configured ones (see
    ///         `setDecayPeriods`), so this is a view, not a pure function:
    ///         retuning the schedule changes what it returns for the
    ///         same inputs.
    function decayFactorBpsAt(
        uint64 timestamp,
        uint64 when
    ) public view returns (uint256) {
        if (when <= timestamp) return DECAY_FULL_BPS;
        uint256 age = when - timestamp;
        if (age < decayFullPeriod) return DECAY_FULL_BPS;
        if (age < decayHalfPeriod) return DECAY_HALF_BPS;
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

    /// @notice Switch verified-only mode on or off. Only the owner
    ///         may call this. When on, only verified attesters may
    ///         attest — the registry becomes allowlist-only, which is
    ///         what a registry that has been spammed (or one that
    ///         only ever wants KYC'd clients attesting) needs. When
    ///         off again, any attester may file, exactly as before.
    ///         The switch never touches existing records or scores:
    ///         it gates new writes only, and an attester verified
    ///         while the mode is on may attest at once.
    function setVerifiedOnly(bool enabled) external {
        if (msg.sender != owner) revert NotOwner();
        verifiedOnly = enabled;
        emit VerifiedOnlyUpdated(enabled);
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

    /// @notice How many fresh attestations an attester has filed in
    ///         the current UTC day (since the last UTC midnight).
    ///         Re-attests never count, so this is the number against
    ///         `maxAttestationsPerDay`.
    function attestationsToday(
        address attester
    ) external view returns (uint256) {
        return _attestationsPerDay[attester][block.timestamp / 1 days];
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

    /// @notice Retune the decay schedule: how long an attestation keeps
    ///         full weight (`fullPeriod`) and half weight
    ///         (`halfPeriod`) after its last update. Only the owner may
    ///         call this. The new schedule applies to every record from
    ///         its own last update — shortening the full period can drop
    ///         live scores immediately, and lengthening it can revive
    ///         decayed weight at once. Existing records are never
    ///         rewritten. Bounds: the full period must be at least 1
    ///         day (a shorter window would make fresh attestations decay
    ///         almost instantly), the half period must be longer than
    ///         the full period, and at most 10 years (beyond that decay
    ///         is effectively off — set the periods long instead of
    ///         pretending decay still applies).
    function setDecayPeriods(uint256 fullPeriod, uint256 halfPeriod) external {
        if (msg.sender != owner) revert NotOwner();
        if (
            fullPeriod < 1 days ||
            halfPeriod <= fullPeriod ||
            halfPeriod > 3650 days
        ) revert InvalidDecayPeriods();
        decayFullPeriod = fullPeriod;
        decayHalfPeriod = halfPeriod;
        emit DecayPeriodsUpdated(fullPeriod, halfPeriod);
    }

    /// @notice Retune the dispute window: how long an attester has to
    ///         answer a dispute before the subject may reinstate the
    ///         attestation unilaterally. Only the owner may call this.
    ///         The new window applies to every open dispute from its
    ///         own `disputedAt` — shortening it can let a subject
    ///         expire a dispute at once, lengthening it gives the
    ///         attester more time. Bounds: at least 1 day (shorter
    ///         would give the attester no real chance to answer), at
    ///         most 365 days, and always longer than `escalationDelay`
    ///         so escalation can still fire before the window lapses.
    function setDisputeWindow(uint256 window) external {
        if (msg.sender != owner) revert NotOwner();
        if (
            window < 1 days ||
            window > 365 days ||
            window <= escalationDelay
        ) revert InvalidGovernanceWindow();
        disputeWindow = window;
        emit DisputeWindowUpdated(window);
    }

    /// @notice Retune the escalation delay: how long a dispute must sit
    ///         unanswered before the subject may escalate it to the
    ///         owner. Only the owner may call this. The new delay
    ///         applies to every open dispute from its own `disputedAt`
    ///         — shortening it can make a stalled dispute escalatable
    ///         at once. Bounds: at least 1 hour (the attester deserves
    ///         a real chance to answer), at most 30 days, and always
    ///         shorter than `disputeWindow` so a dispute can be
    ///         escalated before it expires.
    function setEscalationDelay(uint256 delay) external {
        if (msg.sender != owner) revert NotOwner();
        if (
            delay < 1 hours ||
            delay > 30 days ||
            delay >= disputeWindow
        ) revert InvalidGovernanceWindow();
        escalationDelay = delay;
        emit EscalationDelayUpdated(delay);
    }

    /// @notice Retune the appeal window: how long a subject has to
    ///         appeal an upheld dispute resolution. Only the owner may
    ///         call this. The new window applies to every upheld
    ///         resolution from its own `resolvedAt` — shortening it
    ///         can close an open appeal window at once, lengthening
    ///         it reopens one that had lapsed. Bounds: at least 1 day
    ///         (a shorter window would give the subject no real chance
    ///         to notice the outcome), at most 90 days.
    function setAppealWindow(uint256 window) external {
        if (msg.sender != owner) revert NotOwner();
        if (window < 1 days || window > 90 days) {
            revert InvalidGovernanceWindow();
        }
        appealWindow = window;
        emit AppealWindowUpdated(window);
    }

    /// @notice Change the daily fresh-attestation limit per attester.
    ///         Only the owner may call this. The limit applies from
    ///         the moment it is set: lowering it can block an attester
    ///         who already filed that many today, and raising it (or
    ///         setting it to 0, which disables the limit entirely)
    ///         unblocks them at once. The cap is `MAX_DAILY_LIMIT`
    ///         (1000) — a higher number would not be a spam control.
    ///         Existing records and today's counts are never rewritten.
    function setMaxAttestationsPerDay(uint256 limit) external {
        if (msg.sender != owner) revert NotOwner();
        if (limit > MAX_DAILY_LIMIT) revert InvalidDailyLimit();
        maxAttestationsPerDay = limit;
        emit MaxAttestationsPerDayUpdated(limit);
    }

    /// @notice Set the ETH bond a subject must stake to open a
    ///         dispute (see `disputeBond`). Only the owner may call
    ///         this. Setting it to 0 disables the bond and disputes
    ///         are free again; anything above MAX_DISPUTE_BOND
    ///         reverts. Bonds already posted are never re-priced —
    ///         each open dispute settles at the amount it was opened
    ///         with, so a retune only affects disputes opened after
    ///         it.
    function setDisputeBond(uint256 bond) external {
        if (msg.sender != owner) revert NotOwner();
        if (bond > MAX_DISPUTE_BOND) revert InvalidDisputeBond();
        disputeBond = bond;
        emit DisputeBondUpdated(bond);
    }

    /// @notice Weight one category in the overall score. Only the
    ///         owner may call this. The weight is relative to
    ///         `DEFAULT_CATEGORY_WEIGHT` (100): 200 counts the category
    ///         twice as much as the default, 0 drops it from the
    ///         overall score entirely, 1000 is the cap (ten times the
    ///         default). The new weight applies to the live overall
    ///         score — and to the decay-preview views — at once: an
    ///         overall score can move on a retune even though no
    ///         attestation changed, and no record is ever rewritten.
    ///         Per-category scores are never weighted, so a retune
    ///         cannot move `getScoreByCategory` at all.
    function setCategoryWeight(Category category, uint256 weight) external {
        if (msg.sender != owner) revert NotOwner();
        if (weight > MAX_CATEGORY_WEIGHT) revert InvalidCategoryWeight();
        _categoryWeights[category] = weight;
        emit CategoryWeightUpdated(category, weight);
    }

    /// @notice Current weight of `category` in the overall score,
    ///         relative to `DEFAULT_CATEGORY_WEIGHT` (100).
    function categoryWeight(
        Category category
    ) external view returns (uint256) {
        return _categoryWeights[category];
    }

    /// @notice All five category weights in enum order (Overall,
    ///         Quality, Communication, Timeliness, Reliability), so a
    ///         frontend can read the blend in one call.
    function categoryWeights()
        external
        view
        returns (uint256[5] memory weights)
    {
        weights[0] = _categoryWeights[Category.Overall];
        weights[1] = _categoryWeights[Category.Quality];
        weights[2] = _categoryWeights[Category.Communication];
        weights[3] = _categoryWeights[Category.Timeliness];
        weights[4] = _categoryWeights[Category.Reliability];
    }

    /// @notice Bond currently posted on an open dispute, by
    ///         attestation id. Zero when no bond was posted or the
    ///         dispute has closed.
    function disputeBondOf(uint256 id) external view returns (uint256) {
        if (id >= _attestations.length) revert UnknownAttestation();
        return _disputeBond[id];
    }

    /// @notice Settle the bond posted on a dispute that just closed:
    ///         pay it to `recipient` (the attester when the dispute
    ///         was upheld, the subject otherwise). A no-op when no
    ///         bond was posted. The bond is cleared before the
    ///         transfer lands (checks-effects-interactions), and every
    ///         caller holds the reentrancy lock, so a receiving
    ///         contract cannot re-enter a dispute exit mid-payout.
    function _settleDisputeBond(
        uint256 id,
        address recipient
    ) internal {
        uint256 amount = _disputeBond[id];
        if (amount == 0) return;
        _disputeBond[id] = 0;
        (bool ok, ) = payable(recipient).call{value: amount}("");
        if (!ok) revert BondTransferFailed();
        emit DisputeBondSettled(id, recipient, amount);
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
    ///         not exist yet at that point. Revoked/disputed/appealed
    ///         flags are read as they stand now: this is a decay preview,
    ///         not a full historical reconstruction — a revocation or
    ///         dispute that happened after `when` is not rewound. For a
    ///         future `when` the result is exact, given the records as
    ///         they are.
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
            if (a.appealed) continue;
            if (a.createdAt > when) continue;
            if (_isExpiredAt(a, when)) continue;
            if (filterCategory && a.category != category) continue;
            // A category weighted 0 drops out of the overall score
            // entirely — its records are not counted there at all
            // (count, average, weights). Per-category scores are
            // never weighted, so this never applies to them.
            if (!filterCategory && _categoryWeights[a.category] == 0) {
                continue;
            }
            // Fixed-point decay: multiply before dividing so a weight-1
            // attestation at quarter weight still counts (2500 bps), instead
            // of truncating to zero. For the overall score the
            // category weight scales the effective weight too (a
            // category weighted 200 counts twice as much as the
            // default 100); per-category scores are never weighted,
            // so their effective weight is decay only. The multiply
            // cannot overflow: weight <= 3, decay <= 10000 bps,
            // category weight <= 1000, so effective <= 30,000,000
            // before the division by 100.
            uint256 effective = uint256(a.weight) *
                decayFactorBpsAt(a.updatedAt, when);
            if (!filterCategory) {
                effective =
                    (effective * _categoryWeights[a.category]) /
                    DEFAULT_CATEGORY_WEIGHT;
            }
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
