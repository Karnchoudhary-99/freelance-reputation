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

### Disputes

A freelancer who believes an attestation is unfair can challenge it:

- `disputeAttestation(id, reasonHash)` — only the subject, only while the
  attestation is active. While disputed, the attestation is excluded from
  every score (like a revocation, but reversible).
- `resolveDispute(id, uphold)` — only the attester. Upholding clears the
  dispute and refreshes the decay clock (a re-confirmation); conceding
  revokes the attestation, so the attester may attest again later.
- `expireDispute(id)` — only the subject, only after 30 days unanswered.
  This stops an attester from suppressing a score forever by ignoring the
  dispute. Expiry reinstates the attestation as-is — it does not refresh
  the decay clock.
- While a dispute is open, the attester cannot quietly overwrite the
  record with a fresh `attest` call; revoking it settles the dispute.

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
- `attesterStats(attester)` — `{given, active, revoked, disputed}`: the
  attester's track record. A client deciding whether to trust an
  endorsement can weigh the attester, not just the score.

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
reputation-over-time is a feature, not a free lunch.

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
dispute / resolve / expire cycles plus time warps (crossing the 90-day
and 365-day decay tiers and the 30-day dispute window) with a guarded
handler, so every handler call is expected to succeed and a revert can
never mask a broken invariant. Seven invariants hold across every run:
score bounds (and zero when empty), count matching active records,
category counts summing to the overall count, the weighted average
recomputed independently from the raw records, no duplicate active
(attester, category) keys, record ranges plus attestation totals, and
the latest score-history snapshot matching the live score whenever no
time has passed since the last change touching that scope (a warp ages
every attestation, so snapshots drift from live scores by design after
one). Baseline: 7 invariants × 256 runs × depth 100 — 25,600 handler calls
each, 0 reverts. See `docs/gas-report.md` for deployment and
per-function gas (deploy 3,306,783 gas, 15,299 bytes runtime).

### Run it

```sh
forge test          # 84 tests (77 unit + 7 invariants)
forge script script/Deploy.s.sol   # simulated deploy
```

## License

MIT — see [LICENSE](LICENSE).
