# Freelance Reputation Protocol

Portable on-chain reputation for freelancers — ratings and endorsements
that travel with the worker, not the platform.

## Roadmap

- [x] Project scaffold (README roadmap, license, gitignore)
- [x] Reputation registry (attestations, weighted scores, revocation)
- [x] Decay + dispute handling
- [x] Invariant fuzz tests + gas report
- [x] Integrator ergonomics (batch attestation, paginated reads, profile view)
- [x] Signed attestations (EIP-712, relayer-submitted, nonce replay protection)
- [x] Attester reads (per-attester index, paginated records, track-record stats)
- [x] Reputation tiers (Unranked → Elite, average-plus-count thresholds)
- [x] Signed batch attestations (mixed-attester relayed batches, atomic)
- [x] Discovery views (per-category leaderboards, tier directory)
- [x] Score history (on-chain snapshots per state change, paginated reads)
- [x] Score preview (decay-preview views: score/profile/tier as of any time)
- [x] Attestation evidence (evidence hash per attestation, batch + late attach)
- [x] Verified attesters (owner-managed registry, +1 snapshot weight, capped at 3)
- [x] Attestation expiry (730-day default, owner-configurable, re-attest revives)
- [x] Category reads + latest snapshot (paginated per-category attestations, one-call latest snapshot)
- [x] Attester strikes & suspension (owner-managed strikes, -1 weight each, 3 strikes suspends)
- [x] Score proofs (owner-issued portable certificates, on-chain verification, 90-day max validity)
- [x] Governance & safety (emergency pause, two-step ownership transfer)
- [x] Attester delegation (expiry-bounded delegates attest on your behalf)
- [x] Dispute escalation (subject escalates after 7 unanswered days, owner arbitrates)
- [x] Milestone badges (RisingStar → Veteran, cumulative, decay-aware, batch reads)
- [x] Attester daily rate limit (anti-spam cap, owner-configurable, re-attests free)
- [x] Dispute bonds (opt-in ETH stake on disputes, attester keeps it on uphold, subject refunded otherwise)
- [x] Category weights (owner-configurable per-category weights for the overall score)
- [x] Dispute appeals (one appeal per upheld resolution, 7-day window, owner arbitrates)
- [x] Configurable governance windows (dispute window, escalation delay, appeal window — owner-retunable, apply live)
- [x] Verified-only mode (owner toggle: only verified attesters may attest, every path)
- [x] Time-windowed leaderboards (leaderboard as of any past/future time, category boards)
- [x] Attestation requests (subjects ask a specific attester, fulfilment links the record)
- [x] Attester credibility (dispute rulings tracked per attester, credibility score + board)
- [ ] Self-review checklist, then public

## Reputation registry

`ReputationRegistry` is the core contract. Attestations travel with the
worker, not the platform: any client can attest a freelancer, and anyone can
read the resulting score.

### How scores work

- `attest(subject, category, score, commentHash)` — score 0–100, one of
  `Overall | Quality | Communication | Timeliness | Reliability`.
  Re-attesting the same subject + category updates the existing record
  instead of stacking a second one. Self-attestation and scores above 100
  revert. `commentHash` is the keccak256 of off-chain comment text (or zero)
  so comments stay cheap while remaining verifiable.
- **Weighted by attester reputation.** Each attestation carries a snapshot
  weight taken from the attester's own current average: below 50 → weight 1,
  50–79 → weight 2, 80+ → weight 3. New accounts count once; consistently
  well-rated attesters count up to three times.
- `revokeAttestation(id)` — only the attester, only once. The record stays
  on-chain for auditability but drops out of every score, and the attester
  may attest again afterwards (a fresh record).
- `getScore(subject)` / `getScoreByCategory(subject, category)` — weighted
  average scaled by 100 (8750 == 87.50), plus attestation count, raw total
  weight, and decay-adjusted effective weight (in basis points).
  `getAttestations(subject)` returns all records, revoked and disputed
  included (check the flags to tell them apart).
- **Category weights.** The overall score blends every category, but the
  owner may weight them: `setCategoryWeight(category, weight)` (owner-only,
  0–1000, default 100) counts a category more or less in the overall score
  — 200 is double, 0 drops the category from the overall score entirely.
  Per-category scores are never weighted. See [Category weights](#category-weights).

### Score decay

Reputation should reflect recent work, not a single good year long ago.
Each attestation's weight decays with the age of its last update:

| Age of last update | Weight multiplier |
| --- | --- |
| under 90 days | 100% |
| 90–364 days | 50% |
| 365 days or more | 25% |

Decay is computed in fixed point (weight × basis points) before dividing,
so a weight-1 attestation at quarter weight still counts instead of
truncating to zero. Re-attesting refreshes the clock, and attester weights
are read from the same decayed average — a formerly well-rated attester
whose endorsements all aged out counts as a newcomer again.

The schedule is configurable: `setDecayPeriods(fullPeriod,
halfPeriod)` — owner-only — retunes the two cutoffs for a registry
whose work cycles are shorter or longer than a year. `decayFullPeriod`
and `decayHalfPeriod` report the current values (defaults 90 and 365
days); `decayFactorBpsAt(timestamp, when)` reads the configured
periods, so the score-preview views follow a retune too. Bounds: the
full period must be at least 1 day, the half period longer than the
full period and at most 10 years. A retune re-weights every existing
record from its own last update — shortening the full period can drop
live scores immediately, lengthening it can revive decayed weight —
but no record is ever rewritten.

### Category weights

Not every dimension of good work matters equally to every registry. A
platform for safety-critical work may care about Reliability twice as much
as Timeliness; a marketplace for quick gigs may care most about Timeliness
itself. The overall score blends every category, but the owner can weight
the blend:

- `setCategoryWeight(category, weight)` — owner-only — sets one category's
  weight relative to the default 100: 200 counts it twice as much, 1000
  (the cap) ten times as much, 0 drops it from the overall score entirely.
  Emits `CategoryWeightUpdated`. Every category starts at 100, so a fresh
  registry blends all categories equally, exactly as before.
- `categoryWeight(category)` / `categoryWeights()` — the current weight of
  one category, or all five in enum order (Overall, Quality,
  Communication, Timeliness, Reliability).
- A retune re-weights the live overall score at once — tiers, badges,
  leaderboards, score history, and the decay-preview views all follow it —
  without rewriting any record, the same way a decay retune does. A weight
  of 0 does not delete anything: the category's attestations still count
  toward its own per-category score, which is never weighted, and a later
  retune back above 0 revives them in the overall score immediately.
- The overall score stays a weighted mean of the active attestations'
  scores, so it can never leave the range between the lowest and highest
  active score — the fuzz suite checks exactly that (see [Invariant fuzz
  tests](#invariant-fuzz-tests)).

### Attestation expiry

Decay fades an old endorsement to a quarter of its weight; expiry finishes
the job. After `expiryDuration` (730 days by default) from an
attestation's last update, the record stops counting toward every score —
tiers fall, leaderboards drop the subject — until the attester re-attests
and refreshes the clock. The expired record stays readable and revocable
on-chain; only its effect on scores ends.

- `expiryDuration()` — current duration in seconds; the owner changes it
  with `setExpiryDuration(duration)` (emits `ExpiryDurationUpdated`).
  `0` disables expiry entirely, and disabling it revives every expired
  record at once. Shortening the duration can expire old records
  immediately; the change applies to every record from its own last
  update and never rewrites records.
- `expiresAt(id)` / `isExpired(id)` — when a record stops counting, and
  whether it already has (`expiresAt` returns `0` while expiry is
  disabled).
- An expired attestation cannot be disputed — it already counts toward no
  score. Revoking one stays allowed, and a dispute that expires
  mid-flight can still resolve: upholding it refreshes the clock and
  revives the record.
- The score-preview views (`getScoreAt`, `getProfileAt`, `tierOfAt`)
  reflect expiry too: a preview past a record's expiry date shows it
  faded out.

### Disputes

A freelancer who believes an attestation is unfair can challenge it:

- `disputeAttestation(id, reasonHash)` — only the subject, only while the
  attestation is active. While disputed, the attestation is excluded from
  every score (like a revocation, but reversible).
- `resolveDispute(id, uphold)` — only the attester. Upholding clears the
  dispute and refreshes the decay clock (a re-confirmation); conceding
  revokes the attestation, so the attester may attest again later.
- `expireDispute(id)` — only the subject, only after the dispute window
  (30 days by default) unanswered. This stops an attester from
  suppressing a score forever by ignoring the dispute. Expiry
  reinstates the attestation as-is — it does not refresh the decay
  clock.
- `escalateDispute(id)` — only the subject, only once the dispute has sat
  unanswered for the escalation delay (7 days by default). Escalation
  changes no score — the record stays excluded — it only opens the
  owner-arbitration path, so an unresponsive attester cannot stall a
  dispute for the full dispute window.
- `resolveDisputeAsOwner(id, uphold)` — only the registry owner, only on
  an escalated dispute. Same outcome as the attester resolving it:
  upholding re-confirms the attestation (decay clock refreshed),
  conceding revokes it. The attester may still resolve the dispute
  themselves after escalation — whichever resolution lands first settles
  it. `isDisputeEscalated(id)` reports whether a dispute is escalated.
  Escalation and owner arbitration stay open while the registry is
  paused, like every other dispute exit.
- While a dispute is open, the attester cannot quietly overwrite the
  record with a fresh `attest` call; revoking it settles the dispute.

### Dispute appeals

A dispute resolution is not the last word — the subject gets one appeal:

- `appealDispute(id)` — only the subject, only once per dispute outcome,
  and only within the appeal window (7 days by default) of an upheld
  resolution.
  The appeal re-excludes the attestation from every score until the
  owner arbitrates it: an attester who "won" a dispute does not get
  the score back while the subject's last word is pending. A conceded
  or expired dispute has nothing to appeal — the record is already
  revoked or reinstated — and an expired attestation cannot be appealed
  either, since it counts toward no score. `appealDeadline(id)` reports
  the last moment to appeal (0 when no appeal is available), and
  `isAppealed(id)` reports whether one is open.
- `resolveAppeal(id, uphold)` — only the registry owner, so neither
  party judges their own case. Upholding re-confirms the attestation
  (decay clock refreshed) and the record counts again; conceding
  revokes it, freeing the subject to be re-attested later. Like a
  dispute, appealing stakes the current dispute bond: it goes to the
  attester when the appeal is upheld and back to the subject when the
  owner concedes it. The appeal bond settles on the same
  checks-effects-interactions + reentrancy-guard path as dispute
  bonds, and the fuzz suite mirrors it in the outstanding-bond total.
- A fresh dispute on the same record gets a fresh appeal right — the
  one-appeal limit is per dispute outcome, not per record. While an
  appeal is open the attester cannot overwrite the record with a
  fresh `attest` call either; the score under arbitration is frozen
  until the owner rules. Appeals and their arbitration stay open
  while the registry is paused, like every other dispute exit.

### Governance windows

The three dispute clocks are owner-configurable, so a registry can
match its own dispute culture instead of living with fixed delays:

- `setDisputeWindow(window)` — 1 day to 365 days (default 30 days).
  How long an attester has to answer before the subject may reinstate
  the attestation with `expireDispute`.
- `setEscalationDelay(delay)` — 1 hour to 30 days (default 7 days).
  How long a dispute must sit unanswered before the subject may
  escalate it to the owner.
- `setAppealWindow(window)` — 1 day to 90 days (default 7 days). How
  long a subject has to appeal an upheld resolution.
- The escalation delay must always stay shorter than the dispute
  window, so a dispute can be escalated before it expires — the
  setters enforce it (to shorten the window below the current delay,
  lower the delay first).
- A retune applies live, from each record's own timestamp: shortening
  the dispute window can make an open dispute expirable at once, and
  lengthening the appeal window can reopen an appeal that had just
  lapsed. `appealDeadline(id)` follows the live window. No record is
  ever rewritten by a retune.
- `disputeWindow()`, `escalationDelay()`, `appealWindow()` report the
  live values; `DEFAULT_DISPUTE_WINDOW`, `DEFAULT_ESCALATION_DELAY`,
  `DEFAULT_APPEAL_WINDOW` keep the deploy-time defaults. The fuzz
  suite retunes all three mid-run and checks they stay in bounds and
  ordered.

### Dispute bonds

Disputes are free by default, but a registry under dispute spam can
make the subject stake ETH to open one:

- `setDisputeBond(bond)` — only the owner. `0` disables the bond
  (disputes are free again); anything above `MAX_DISPUTE_BOND`
  (1 ether) reverts. Retuning never re-prices bonds already posted —
  each open dispute settles at the amount it was opened with.
- `disputeAttestation(id, reasonHash)` is `payable` and requires
  exactly `disputeBond` wei: too little, too much, or any value while
  the bond is 0 all revert with `IncorrectDisputeBond`.
  `disputeBondOf(id)` reports the bond posted on a dispute (0 once
  it has closed).
- Every dispute exit settles the bond: upholding pays it to the
  attester, conceding refunds it to the subject, expiry refunds it
  to the subject (an unanswered dispute is not one the subject
  lost), and revoking while disputed refunds it to the subject.
  Owner arbitration settles the same way as an attester resolution.
  The registry holds exactly the outstanding bonds — the fuzz suite
  checks the balance against a mirror on every run.
- Settlement is checks-effects-interactions (the bond is cleared
  before the transfer lands) plus a reentrancy guard on all five
  ETH-touching functions, so a receiving contract cannot re-enter a
  dispute exit mid-payout. One honest limitation: settlement is a
  direct transfer, so it fails closed — if the recipient cannot
  receive ETH, that dispute exit reverts and the dispute stays open
  until another exit path pays someone who can (e.g. expiry refunds
  the subject, or the owner arbitrates the other way).

### Integrator ergonomics

- `attestBatch(inputs)` — attest many subjects/categories in one
  transaction, the onboarding path for a platform migrating its
  freelancer base. Atomic: any invalid entry reverts the whole batch,
  so a caller never lands in a half-applied state. Entries for existing
  active records update in place, exactly as `attest` would.
- `getAttestationsPaginated(subject, offset, limit)` — one page of a
  subject's records in creation order. The limit clamps to the
  remainder and an offset past the end returns an empty page, so a
  frontend pages until it gets an empty page. Prefer this over
  `getAttestations` once a subject has many records: the unbounded
  read grows linearly in gas with history.
- `getProfile(subject)` — overall plus all four category scores in a
  single call, so an integrating frontend needs one RPC call, not five.

### Batch reads

Rendering a list of freelancers should not cost one RPC call per row:

- `getScores(subjects)` — overall `Score` for every subject in the
  input, in input order. Unknown subjects (never attested) return a
  zero `Score`, exactly like `getScore`.
- `getProfiles(subjects)` — the full `Profile` (overall + all four
  category scores) for every subject, in input order.
- `getTiers(subjects)` — the `Tier` for every subject, in input order,
  for rendering tier badges on a list. Unknown subjects return
  `Unranked`, exactly like `tierOf`.

All three return an empty array for an empty input, and they always
agree with the single-subject views — the batch is a convenience, not
a second source of truth. Like the leaderboards, these are views for
off-chain `eth_call`: they scan every listed subject's attestations,
so they grow linearly with the input list.

### Signed attestations (EIP-712)

A freelancer's client may not want to hold gas or call the contract
directly — a mobile wallet can sign an attestation off-chain and any
relayer (a platform backend, a friend) submits it:

- `attestBySignature(attester, subject, category, score, commentHash, deadline, v, r, s)`
  — the typed data is `Attest(address attester, address subject, uint8 category,
  uint8 score, bytes32 commentHash, uint256 nonce, uint256 deadline)` under
  domain `ReputationRegistry` version `1`. `nonces(attester)` is the next
  usable nonce; a signature is single-use, and an expired deadline reverts
  without burning the nonce. All the usual guards still apply inside
  `attest` — a signed self-attestation or an out-of-range score reverts,
  and a signed re-attestation updates the existing record in place.
- `attestBatchBySignature(inputs)` — the same, batched: a platform
  onboarding clients who sign off-chain submits many signed attestations
  (possibly from many attesters) in one transaction. Atomic like
  `attestBatch` — a bad signature or an expired entry reverts the whole
  batch, and the revert rolls every nonce increment back, so no signer
  loses a nonce to a failed batch.

### Attester reads

- `getAttestationsByAttester(attester, offset, limit)` — paginated audit
  view of what one client has endorsed, with the same empty-page
  semantics as the subject-side pagination. Updates do not add records,
  so the index counts attestations, not writes.
- `attesterStats(attester)` — `{given, active, revoked, disputed, strikes, suspended, disputesUpheld, disputesConceded, credibilityBps}`: the
  attester's track record. A client deciding whether to trust an
  endorsement can weigh the attester, not just the score.

### Top attesters

- `getTopAttesters(limit)` — the most prolific endorsers, ranked by
  active attestations given, highest first: `{attester, count,
  average, weight}`. Ties break toward the attester with the higher
  own overall average, then toward the attester seen first, so the
  ranking is deterministic. "Active" means the record still counts
  toward a score — not revoked, not disputed, not expired — the same
  rule the score views use. `average` is the attester's own overall
  average (so the board shows whether the most prolific endorsers
  are themselves well-rated) and `weight` is their current
  `attesterWeight`. A suspended attester stays ranked on past records
  (suspension blocks new attestations only) and shows weight 0.
  `attesterCount()` reports how many distinct attesters have ever
  attested. Like the subject boards, this is a view for off-chain
  `eth_call`: it scans the whole attester set, so keep `limit` small
  on a busy registry.

### Attester credibility

- `attesterCredibility(attester)` — `(credibilityBps, upheld,
  conceded)`: how an attester's endorsements held up when challenged.
  Every dispute ruling is counted — the attester resolving it, the
  owner arbitrating an escalated dispute, the owner arbitrating an
  appeal — and an attester who revokes their own record while it is
  disputed concedes in effect (the bond goes back to the subject), so
  that counts as conceded too. A dispute that expires unanswered is
  neither won nor lost: it lapses without a ruling. Credibility is the
  upheld share in basis points (`upheld * 10000 / (upheld +
  conceded)`); with no ruled dispute yet it reads 10000, and the
  counts travel alongside so a caller can tell a 10000-from-zero-rulings
  apart from a 10000-from-ten. One record can contribute twice — once
  for its dispute ruling, once for its appeal ruling — because
  credibility measures rulings, not records. It never changes a score
  by itself: it is a read for clients choosing whose endorsement to
  trust, next to `attesterWeight`, which measures how the attester is
  rated rather than how their own endorsements held up.
- `getTopAttestersByCredibility(limit)` — the most credible endorsers,
  ranked by `credibilityBps` highest first: `{attester,
  credibilityBps, upheld, conceded}`. Ties break toward the attester
  with more upheld rulings, then toward the attester seen first, so
  the ranking is deterministic. Only attesters with at least one ruled
  dispute appear: a 10000 from zero rulings is not a track record, and
  listing every never-disputed attester at the top would bury the ones
  whose credibility was actually tested. A suspended attester stays
  ranked on the strength of their rulings (suspension blocks new
  attestations only). `limit` clamps to the ranked set and 0 returns
  an empty array. Like the other boards, this is a view for off-chain
  `eth_call` over the whole attester set.

### Verified attesters

The deployer is the registry `owner` and may mark attesters verified with
`setVerifiedAttester(attester, verified)` (emits `AttesterVerified`);
`isVerifiedAttester(attester)` reads the flag. Verification is a trust
signal the owner vouches for — a platform's KYC'd clients, a DAO's voted
members — and it boosts the weight of the attester's *next* attestations:
`attesterWeight` adds 1 for a verified attester, capped at 3. A verified
newcomer counts as much as a mid-reputation attester (1 → 2), a verified
mid-reputation attester counts as a top one (2 → 3), but verification
alone can never outrank a consistently well-rated attester (3 stays 3).

The boost is snapshotted onto each attestation at attest time, so
verifying or un-verifying someone never rewrites existing records — only
later attestations (including re-attests, batch, and signed ones) pick up
the new weight. There is no admin key over scores: the owner can only
toggle the trust flag, never edit or delete an attestation.

### Verified-only mode

Verification can also be a gate, not just a boost:

- `setVerifiedOnly(enabled)` — only the owner. When on, only verified
  attesters may attest — the registry becomes allowlist-only. The gate
  sits in `_attest`, so it covers every path: direct, batch, signed,
  and delegated attestations, and re-attests of an attester's own
  records. An unverified attester's calls revert with
  `NotVerifiedAttester`.
- Switching the mode on never touches existing records or scores: it
  gates new writes only, and old attestations from now-unverified
  attesters keep counting. Verifying an attester while the mode is on
  unblocks them at once; switching the mode off restores open
  attestation for everyone.
- Suspension and pause still take precedence: a suspended attester
  gets `AttesterSuspended` and a paused registry gets
  `RegistryPaused`, even when the mode is on. The fuzz suite toggles
  the mode mid-run (verifying attesters on the fly) and mirrors it.

### Attester strikes & suspension

The other side of verification: the owner may strike a misbehaving
attester — fake endorsements, spam, paid reviews — with
`strikeAttester(attester)` (emits `AttesterStruck(attester, strikes)`).
Each strike lowers the weight of the attester's *next* attestations by 1,
floored at 1, so one strike takes a verified newcomer back to 1 and two
strikes take a top attester (3) to 1. At 3 strikes (`MAX_STRIKES`) the
attester is suspended: `attesterWeight` returns 0 and every attestation
path — direct, re-attest, batch, and signed — reverts with
`AttesterSuspended`. `strikes(attester)` and `isSuspended(attester)` read
the state; `clearStrikes(attester)` (emits `StrikesCleared`) resets the
count to 0 and reinstates the attester at their un-struck weight. Strikes
keep counting past the threshold (a fourth offence is still an offence);
only clearing resets them, and the owner may strike an attester who has
never attested yet, acting on an off-chain report before they write
anything on-chain.

Like verification, strikes are snapshot-time only: they never rewrite
existing records, and a suspended attester's past scores keep counting.
Suspension blocks only *new* attestations — a suspended attester may
still revoke their own attestations and resolve disputes over them, so
enforcement never traps a subject in an unresolvable dispute. Only the
owner may strike or clear; both functions reject the zero address.

### Daily attestation limit

Strikes punish a bad attester after the fact; the daily limit stops a
spam account from flooding the registry in the first place. Each
attester may create at most `maxAttestationsPerDay` *fresh*
attestations per UTC day — default 50 (`MAX_DAILY_LIMIT` caps the
setting at 1000), far above what a genuine attester files in a day and
low enough that a spam run cannot bury real records. The quota counts
filings, not live records: revoking a record does not refund the day's
quota, and the count resets at each UTC midnight
(`block.timestamp / 1 days`).

Only fresh attestations consume quota. Re-attesting — updating the
score or comment on an existing record — is always free, even at the
cap, so an attester can keep their existing assessments current
without burning the quota. Enforcement lives in `_attest`, so the
direct, batch, signed, and delegated paths all count against the
*attester* (a delegate's filings burn the attester's quota, not the
delegate's own). A batch that would cross the cap reverts atomically:
no partial records, no partial quota.

The owner may retune the limit with `setMaxAttestationsPerDay(limit)`
(emits `MaxAttestationsPerDayUpdated`); `0` disables the limit
entirely. Lowering it takes effect immediately — an attester who
already filed that many today is blocked at once — and raising it
unblocks them at once. `attestationsToday(attester)` reads the current
day's count; a 12th invariant fuzz test asserts it never exceeds the
limit. A limit hit reverts with `DailyAttestationLimitReached`, and a
setting above the cap reverts with `InvalidDailyLimit`.

### Reputation tiers

`tierOf(subject)` maps the overall score to a badge a frontend can show
without inventing its own thresholds:

| Tier | Rule |
| --- | --- |
| Unranked | no active attestations |
| Emerging | any active attestations below the bars below |
| Established | average ≥ 60 and ≥ 3 active attestations |
| Trusted | average ≥ 75 and ≥ 5 active attestations |
| Elite | average ≥ 90 and ≥ 10 active attestations |

Both conditions must hold: nine perfect attestations are Trusted, not
Elite, and a single 100 is only Emerging. Tiers read the decayed score,
so an aged-out reputation falls back down the tiers.

### Milestone badges

Where tiers answer "how good is this freelancer right now", badges
answer "what have they achieved" — a subject can hold several at once,
and they are earned in order, so a Veteran is also a RisingStar.
`getBadges(subject)` returns the badges held right now, in enum order:

| Badge | Rule |
| --- | --- |
| RisingStar | average ≥ 60 and ≥ 5 active attestations |
| HighlyRated | average ≥ 75 and ≥ 10 active attestations |
| TopRated | average ≥ 85 and ≥ 25 active attestations |
| Veteran | average ≥ 60 and ≥ 50 active attestations |

The higher badges demand volume as well as quality: TopRated needs 25
active attestations, Veteran 50 — so Veteran is the long-track-record
badge, earnable at a solid-but-not-perfect average (fifty 70s earn
RisingStar + Veteran, but neither HighlyRated nor TopRated). Badges are
pure views over the live decayed score, so revocations, disputes,
expiry, and decay can all take a badge away, exactly as they move
tiers. `getBadgesAt(subject, when)` previews badges as of any time
(same decay-preview semantics as `getScoreAt`), and
`getBadgesFor(subjects)` returns badges for a whole directory page in
one call. Opting out of public discovery does not hide badges: they
are a direct read about one subject, like `tierOf`, not a listing.

### Leaderboard

`getLeaderboard(limit)` ranks subjects by decayed overall average,
highest first, with one row per subject — `{subject, average, count,
tier}` — so a marketplace can show "top freelancers" in a single call.
Ties break toward more active attestations, then toward the subject
seen first, so the ranking is deterministic. Subjects with no active
attestations (all revoked, or all disputed) are excluded, and `limit`
clamps to the ranked set (0 returns an empty array). `subjectCount()`
reports how many distinct subjects have ever received an attestation.
The view scans the whole subject set, so keep `limit` small on a busy
registry.

`getLeaderboardAt(when, limit)` rebuilds the same board for any past
or future moment: subjects ranked by their decay-preview score at
`when` (see the score-preview views), so a ranking can flip as old
endorsements decay, and `tier` is the subject's overall tier at
`when`. `getLeaderboardByCategoryAt(category, when, limit)` does the
same for a category board. The same preview caveat applies as to the
score views: attestations created after `when` are excluded, but
revoked / disputed / appealed flags are read as they stand now — a
record revoked after `when` is already missing from the board at
`when` — and expired records fade out past their expiry. Opt-outs are
read as they stand now too, so an opted-out subject is hidden from
every board, past or future.

### Discovery: category boards and tier directory

Two more views sit on top of the same ranking, for marketplace
discovery pages:

- `getLeaderboardByCategory(category, limit)` — the "best
  communicators" board: subjects ranked by one category's decayed
  average, with the same tie-break, exclusion, and limit rules as the
  overall board. `average` and `count` are category-scoped, but `tier`
  stays the subject's overall tier — a category average alone never
  promotes someone to Elite. Passing `Category.Overall` returns
  exactly `getLeaderboard`, since the overall score already spans
  every category.
- `getSubjectsByTier(tier, limit)` — every subject currently in one
  tier, in first-seen order (not score order), so a directory page
  can list all Trusted freelancers. `limit` clamps like the boards,
  and 0 returns an empty array. Querying `Unranked` includes subjects
  whose attestations are all revoked or disputed now; subjects that
  never received an attestation are not in the registry at all.

Both views read decayed scores, so a tier directory reflects
reputation as it stands today, not as it stood when the
attestations were fresh.

### Leaderboard opt-out

A freelancer may not want to be listed publicly, even with a good
score. `setLeaderboardOptOut(true)` hides the caller — and only the
caller, since the caller IS the subject — from `getLeaderboard`,
`getLeaderboardByCategory`, and `getSubjectsByTier`. Opting out is a
listing rule, not a score rule: the subject's scores, tier, and
attestations stay readable directly (`getScore`, `tierOf`,
`getProfile`, `getAttestations`), they keep receiving new
attestations, and `subjectCount` still counts them.
`setLeaderboardOptOut(false)` opts back in, restoring the listing
with its rank. `isLeaderboardOptedOut(subject)` reports the choice,
and opting out before ever receiving an attestation applies as soon
as the subject is listed.

### Score history

Every state change — attest, re-attest, revoke, dispute raise,
dispute resolve (uphold or concede), dispute expiry — appends a
frozen snapshot of the subject's score to on-chain history, so a
frontend can chart reputation over time without indexing events:

- `scoreHistoryLength(subject, category)` — how many snapshots exist
  for one scope (`Category.Overall` for the overall score, or one
  specific category).
- `getScoreHistory(subject, category, offset, limit)` — one page of
  `{timestamp, average, count, effectiveWeight}` snapshots, oldest
  first, with the same paging semantics as the attestation pagers
  (`limit` clamps, an offset past the end returns an empty array).

Each change records an Overall snapshot, plus a category-scoped one
when the changed attestation belongs to a category — an attestation
in `Category.Overall` records one snapshot only. Snapshots freeze
the decayed score as it stood at that moment: a snapshot taken after
a 400-day warp shows the first attestation at quarter weight. A
revoke or a raised dispute appends a snapshot with the attestation
excluded (average 0 when it was the only one), and an upheld dispute
or an expiry appends one with the score restored. History grows by
one entry per state change, so page it on busy subjects — and note
that snapshots cost gas on every write (see `docs/gas-report.md`):
reputation-over-time is a feature, not a free lunch. One more
divergence is by design: a category-weight retune moves the live
overall score without appending a snapshot (the retune is a config
change, not a change to the subject), so the frozen history lags the
live score until the next state change touches that subject — the
same way decay ages a live score between changes.

### Score preview

Score history looks backwards; the preview views look forwards (or
backwards, for audit) — what a freelancer's score will be at a given
time, once today's attestations have aged:

- `getScoreAt(subject, when)` / `getScoreByCategoryAt(subject, category, when)`
  — the weighted average with decay measured against `when` instead of
  now. Passing the current block time returns exactly `getScore`.
- `getProfileAt(subject, when)` — the whole profile (overall + four
  categories) as of `when`, in one call.
- `tierOfAt(subject, when)` — the tier as of `when`, so a frontend can
  warn that a freelancer drops from Established to Emerging in N days
  unless they land fresh work.
- `decayFactorBpsAt(timestamp, when)` — the raw decay factor behind
  the previews (10000 / 5000 / 2500 bps by age tier).

Two semantics worth knowing: attestations created after `when` are
excluded (they did not exist yet), but revoked/disputed flags are read
as they stand now — a preview is a decay projection, not a full
historical reconstruction, so a revocation that happened after `when`
is not rewound. For a future `when` the result is exact, given the
records as they are. Previews are pure reads and cost about the same
as the live views (see `docs/gas-report.md`).

### Attestation evidence

A score is only as trustworthy as the work behind it, so an attestation
can point at supporting evidence — the content hash of the delivered
work, an invoice, a shipped artifact:

- `attestWithEvidence(subject, category, score, commentHash, evidenceHash)`
  — like `attest`, but stores `evidenceHash` on the record, readable via
  `attestation(id).evidenceHash`. Use a content hash (e.g. IPFS CID hash),
  never a URL: hashes survive link rot and stay verifiable.
- `setEvidence(id, evidenceHash)` — attach or correct evidence later
  (evidence often only exists once the work is delivered). Only the
  attester, only while the record is active; a revoked attestation is a
  frozen audit record and keeps its original evidence. Changing evidence
  never touches the score, the decay clock, or the score history.
- `attestBatchWithEvidence(inputs)` — batch migration with per-entry
  evidence, same atomicity as `attestBatch`.
- Plain `attest` / `attestBatch` re-attests leave previously attached
  evidence untouched; `attestWithEvidence` replaces it (passing zero
  clears it). Signed attestations carry no evidence field — the EIP-712
  type is unchanged — but the attester can attach it afterwards with
  `setEvidence`. Evidence survives dispute raise/resolve unchanged.

### Category reads and latest snapshot

Two read helpers for frontends that already know which slice they want:

- `getAttestationsByCategory(subject, category, offset, limit)` — one
  page of a subject's attestations in a single category, in creation
  order, with the same limit-clamping and empty-page-past-the-end
  semantics as the other paginated reads. Revoked and disputed records
  are included (check the flags). A re-attest updates in place, so a
  category never shows the same attester twice. Like the other
  unbounded views, it scans the subject's full history — call it
  off-chain via `eth_call`.
- `latestScoreSnapshot(subject, category)` — the most recent frozen
  snapshot for one scope plus an `exists` flag (`false` with an
  all-zero snapshot when there is no history). One call instead of
  paging `getScoreHistory` to its last entry. Frozen means frozen: after
  time passes the snapshot can differ from the live score (decay and
  expiry move the live score; the snapshot reports the score as it
  stood after the last change).

### Score proofs

A freelancer's live score is easy to read on-chain — but a screenshot of
it is easy to fake. A score proof is the registry's own certificate: the
owner issues one for a subject and any third party (a hiring platform, a
client checking a proposal) can verify the presented proof against the
registry instead of trusting the freelancer's word.

- `issueScoreProof(subject, validFor)` — owner only. Freezes the
  subject's live overall score, tier, and active-attestation count as
  they stand at issuance, valid for `validFor` (more than 0, at most
  `MAX_PROOF_VALIDITY` = 90 days, so a stale reputation cannot be
  presented as current forever). Re-issuing replaces the previous proof.
  A subject with no attestations gets a valid proof of average 0 /
  tier Unranked / count 0 — "no reputation yet" is itself a checkable
  claim.
- `scoreProofOf(subject)` — the latest issued proof plus an `exists`
  flag (`false` when never issued, or after a revocation). An expired
  proof is still returned; check `expiresAt`, or use the verifier.
- `verifyScoreProof(proof)` — `true` exactly when the proof matches the
  latest proof issued for its subject, field for field, and has not
  expired. A tampered average, tier, count, or timestamp fails, as does
  a proof for a subject who never received one. The check is against
  the frozen proof, not the live score: a freelancer's reputation
  moving after issuance does not invalidate the certificate until it
  expires.
- `revokeScoreProof(subject)` — owner only, for a certificate issued in
  error or after fraud is discovered. Only the certificate is
  withdrawn; the subject keeps their attestations and live score, and a
  new proof may be issued afterwards.

### Governance & safety

Two controls for the day something goes wrong — and for the day the
registry outgrows its deployer.

- **Emergency pause.** `pause()` / `unpause()` — owner only. While
  paused, no attestation can be created or updated (direct, batch, or
  signed — the guard sits in `_attest`, so every path is frozen by one
  check) and no evidence or score proof can be issued. Deliberately
  **not** blocked: revoking an attestation, and raising, resolving, or
  expiring a dispute — a pause must never trap a subject under a bad
  attestation. The owner's own admin controls (verify, strike, expiry)
  keep working, so the problem that caused the pause can be fixed
  while it is in force, and every read (scores, tiers, leaderboards,
  proofs) keeps working: pausing freezes writes, not the registry.
  Unpausing resumes exactly where things left off — a pause never
  rewrites records, scores, or the decay clock. A signed attestation
  submitted while paused reverts atomically, so the signer's nonce is
  not consumed.
- **Two-step ownership transfer.** `transferOwnership(newOwner)` —
  owner only, zero-address guarded — names a pending owner; nothing
  changes until `acceptOwnership()`, callable only by the pending
  address, moves every admin right at once. A typo cannot hand the
  registry to a dead address, and `cancelOwnershipTransfer()` lets the
  current owner abort before acceptance. Starting a second transfer
  overwrites the first. Transfers work while paused, so a compromised
  owner key can be rotated out from under a freeze.

### Attester delegation

A client does not have to sign every attestation themselves: they can
authorize a delegate — a platform's operations wallet, an assistant,
a DAO's review committee — to attest on their behalf.

- `setDelegate(delegate, expiresAt)` — the attester picks a delegate
  and an expiry (a unix timestamp, must be in the future). Re-setting
  extends or shortens the authority; `revokeDelegate(delegate)` ends
  it immediately. Self-delegation, the zero address, and a past expiry
  all revert. `isDelegate(attester, delegate)`,
  `delegateExpiry(attester, delegate)`, and `getDelegates(attester)`
  (active delegates only, in first-authorized order) expose the state.
- **On-behalf entry points.** `attestOnBehalf`,
  `attestWithEvidenceOnBehalf`, `attestBatchOnBehalf`,
  `attestBatchWithEvidenceOnBehalf`, and `setEvidenceOnBehalf` —
  each checks the delegate first (`NotDelegate` otherwise), then runs
  exactly the same logic as the direct call. The record is the
  attester's in every way: attester field, snapshot weight from the
  attester's reputation (the delegate's own reputation never matters),
  dispute ownership. A delegate's re-attest updates the attester's
  existing record, like a direct re-attest.
- **What a delegate cannot do.** Revoking an attestation and resolving
  a dispute stay with the attester — those are the sensitive actions,
  and a delegate must not be able to erase or settle the attester's
  record. And the usual guards still apply to the attester: a
  suspended attester's delegate cannot attest, a paused registry
  blocks delegate writes, and self-attestation through a delegate
  still reverts.
- **Signed attestations already cover relayers** — anyone may submit
  an attestation the attester signed off-chain. Delegation is the
  complement for the case where the attester does not want to sign
  each attestation at all: authorize once, and the delegate submits
  directly until the expiry lapses.

### Attestation requests

A freelancer does not have to wait to be noticed: they can ask a
specific client for a rating in a specific category — the outbound
half of the flow, for the client who worked with them and never got
around to attesting.

- `requestAttestation(attester, category, contextHash)` — the subject
  asks. `contextHash` ties the ask to off-chain context (a job id, a
  deliverable reference) without storing the details on-chain. The
  request stays answerable for `requestValidity` (30 days by default;
  the owner may retune it between 1 and 365 days with
  `setRequestValidity` — a retune only affects requests created after
  it). One open request per (subject, attester, category): a second
  ask while one is still open reverts, so a subject cannot spam the
  same attester with the same request. Requesting yourself or the zero
  address reverts, and requests are blocked while the registry is
  paused.
- `fulfillAttestationRequest(id, score, commentHash)` (and
  `fulfillAttestationRequestWithEvidence`) — only the attester named
  in the request may answer it, and only while it is open and
  unexpired. The rating goes through the same writer as every other
  attestation, so all the guards apply: pause, suspension,
  verified-only mode, score range, the daily rate limit (a fresh
  attestation consumes quota; updating an existing record is free),
  and a disputed existing record blocks the fulfilment. Fulfilling
  when you already have an active attestation for the same subject +
  category updates that record in place instead of creating a second
  one. On success the request is Fulfilled and the attestation records
  `requestId` / `fromRequest`, so the record's provenance is visible
  on-chain; a later plain re-attest never clears that link.
- `cancelAttestationRequest(id)` — the subject withdraws an open ask.
  Cancelling frees the (subject, attester, category) slot at once.
  An expired request cannot be cancelled — it is already dead, so
  the subject simply makes a fresh request — and cancelling still
  works while the registry is paused, like a revoke.
- **Delegates cannot fulfil requests.** The request names the attester
  personally, so a delegate's answer would not carry the attester's
  own response to it. A delegate can still attest directly via
  `attestOnBehalf`.
- **Reads.** `attestationRequest(id)` / `attestationRequestCount()`,
  `openRequestId(subject, attester, category)` — the pending ask for
  one triple, as `(exists, id)` (the flag exists because request id 0
  is a real request) — `isRequestExpired(id)`, and the paginated
  inbox/outbox views `getOpenRequestsForAttester` /
  `getOpenRequestsBySubject` (oldest first, fulfilled / cancelled /
  expired filtered out, empty page past the end).

### Example flow

```text
carol attests bob 90 (Overall)      -> bob average 90.00, weight now 3
dave  attests bob 90 (Overall)      -> bob average 90.00
bob   attests alice 60 (Overall)    -> weight 3 (bob is well-rated)
carol attests alice 90 (Overall)    -> weight 1
alice score = (60*3 + 90*1) / 4 = 67.50
```

### Invariant fuzz tests

`test/Invariant.t.sol` drives the registry through attest / revoke /
dispute / resolve / expire / escalate / owner-arbitrate / appeal /
appeal-arbitrate / request / fulfil / cancel cycles plus time warps (crossing the 90-day
and 365-day decay tiers and the 30-day dispute window) and owner strikes
/ strike-clearing, plus pause / unpause cycles and delegate set / revoke
cycles (about half the attestations are routed through an active
delegate when the attester has one), plus owner category-weight retunes
(biased toward the default 100 and toward 0, so the fuzz exercises both
the equal blend and full exclusion), with a guarded handler, so every handler call is
expected to succeed and a revert can never mask a broken invariant. Twenty
invariants hold across every run:
score bounds (and zero when empty), count matching active records,
category counts summing to the overall count, the weighted average
recomputed independently from the raw records, no duplicate active
(attester, category) keys, record ranges plus attestation totals, the
latest score-history snapshot matching the live score whenever no
time has passed since the last change touching that scope (a warp ages
every attestation, so snapshots drift from live scores by design after
one), the strike mirror matching the registry with `attesterWeight`
0 exactly while suspended and 1–3 otherwise, the attestation count
staying frozen while the registry is paused, and the delegation mirror
matching the registry with `isDelegate` true exactly while the mirrored
expiry is still in the future, and the escalation mirror matching the
registry with an escalated record always still disputed, and no
attester's `attestationsToday` ever exceeding `maxAttestationsPerDay`,
and the registry's ETH balance always equalling the outstanding
dispute bonds (bonded disputes are exercised by the fuzz handler,
which funds every actor and mirrors each posted bond), and the
category-weight mirror matching the registry with every weight in the
0–1000 range, and the overall average always lying between the lowest
and highest active attestation score (a weighted mean can never leave
that range, whatever the weights, decay, or snapshot weights do), and
the appeal mirror matching the registry with an appealed record always
still active (not revoked, not disputed), an appeal usable exactly once
per upheld resolution, and the appeal deadline agreeing with the stored
resolution time, and fulfilled requests always linking to a matching
attestation (same attester, subject, and category, flagged as from a
request) whose own link points back at a fulfilled request for the same
triple, with every open, unexpired request findable through
`openRequestId`, and the credibility mirror matching the registry with
the basis-points score exactly the upheld share (10000 with no ruled
dispute yet).
Baseline: 20 invariants × 256 runs × depth 100 — 25,600 handler calls
each, 0 reverts. See `docs/gas-report.md` for deployment and
per-function gas (deploy 9,825,202 gas, 44,367 bytes runtime).

### Run it

```sh
forge test          # 431 tests (411 unit + 20 invariants)
forge script script/Deploy.s.sol   # simulated deploy
```

## License

MIT — see [LICENSE](LICENSE).
