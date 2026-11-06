# Gas report — ReputationRegistry

Measured with `forge test --gas-report` (solc 0.8.24, optimizer on,
200 runs), from the unit suites in `test/ReputationRegistry.t.sol`,
`test/ScoreHistory.t.sol`, `test/ScorePreview.t.sol`,
`test/Evidence.t.sol`, `test/VerifiedAttesters.t.sol`,
`test/AttestationExpiry.t.sol`, `test/CategoryReads.t.sol`, and
`test/AttesterStrikes.t.sol`, `test/ScoreProofs.t.sol`.
Figures are from test calls, so first-write (cold storage) numbers are
the high end and repeat writes the low end; treat them as indicative,
not mainnet quotes.

## Deployment

| Metric | Value |
| --- | --- |
| Deployment cost | 4,688,594 gas |
| Runtime size | 21,659 bytes |

Score history added ~307k gas to deployment (+1,419 bytes): the
`_scoreHistory` mapping, the `ScoreSnapshot` struct, and the
`_recordSnapshot` helper plus its two view functions.

Score preview added ~148k gas to deployment (+685 bytes): the
`_scoreAt` time parameterization (one extra `createdAt` comparison
per record) plus five view functions (`getScoreAt`,
`getScoreByCategoryAt`, `getProfileAt`, `tierOfAt`,
`decayFactorBpsAt`). Writes are unaffected — previews are pure
reads over the existing records.

Attestation evidence added ~219k gas to deployment (+741 bytes):
one extra `bytes32` slot on the `Attestation` struct (cold-write cost
on first attestation), the `attestWithEvidence` /
`attestBatchWithEvidence` entry points, and `setEvidence` plus its
event. `attestWithEvidence` costs about the same as `attest` (same
writes plus one extra slot); `setEvidence` is a single-slot update
(~39k gas avg).

Verified attesters added ~122k gas to deployment (+546 bytes): the
immutable `owner`, the `_verifiedAttesters` mapping, the
`setVerifiedAttester` / `isVerifiedAttester` pair plus its event, and
the +1 branch in `attesterWeight`. `setVerifiedAttester` is a
single-slot update (~37k gas avg); `attest`'s average rises slightly
(357,290 → 361,828) because `_attest` reads the verification flag on
every call.

Attestation expiry added ~176k gas to deployment (+712 bytes): the
`expiryDuration` slot, the `setExpiryDuration` / `expiresAt` /
`isExpired` views plus the `ExpiryDurationUpdated` event, the
`AttestationExpired` guard on disputes, and the expiry check inside
`_scoreAt`. `setExpiryDuration` is a single-slot update (~27k gas
avg). Every score read now pays one extra expiry check per record
(`_isExpiredAt` reads the duration and compares timestamps), so
`attest`'s average rises again (361,828 → 366,199) and the
category-scoped reads move by a few thousand gas; the check is pure
arithmetic on already-loaded records, so the cost stays linear in
attestation count with no new storage writes.

Category reads + latest snapshot added ~269k gas to deployment
(+1,240 bytes): two pure view functions, so no write path changes —
`attest`'s average moves only because the new tests add calls with a
different shape (366,199 → 376,036 across the wider call mix).
`getAttestationsByCategory` averages ~36k gas (it scans the subject's
full history twice: once to count, once to collect the page);
`latestScoreSnapshot` is a single storage read at ~11k gas. Both are
views for off-chain `eth_call`, not transaction inputs.

Score proofs added ~410k gas to deployment (+1,913 bytes): the
`ScoreProof` struct and its two mappings, `issueScoreProof` /
`scoreProofOf` / `verifyScoreProof` / `revokeScoreProof` plus two
events. The deployment jump is larger than the last few features
because a proof freezes a full score (average, tier, count, two
timestamps) in two mappings — `issueScoreProof` averages ~128k gas
in the test suite (it reads the subject's full history to compute
the live score, then writes the proof; first issue on a fresh
subject is the high end at ~193k); `revokeScoreProof` is a
two-slot reset (~34k gas avg). `verifyScoreProof` (~9k gas avg)
and `scoreProofOf` (~14k gas) are pure reads, views for off-chain
`eth_call`.

Attester strikes & suspension added ~187k gas to deployment
(+1,208 bytes): the `_strikes` mapping, `strikeAttester` /
`clearStrikes` / `strikes` / `isSuspended` plus two events, the
`AttesterSuspended` guard in `_attest`, the strike deduction in
`attesterWeight`, and the two extra `AttesterStats` fields.
`strikeAttester` is a single-slot update (~35k gas avg, first strike
in a test ~46k); `clearStrikes` is a single-slot reset (~22k gas
avg). Every `attest` now pays one extra storage read for the
suspension check — the average barely moves (376,036 → 373,236)
because the new strike tests add cheap re-attest calls to the mix;
the per-call cost of the check itself is a cold/warm SLOAD, not a
write. Suspended attestations revert before any state change, so a
blocked call costs only the 21k-gas base plus the checks.

## Function costs (gas)

| Function | Min | Avg | Median | Max | Calls |
| --- | --- | --- | --- | --- | --- |
| `attest` | 22,339 | 373,236 | 388,692 | 523,600 | 143 |
| `attestWithEvidence` | 247,078 | 485,689 | 543,994 | 543,994 | 10 |
| `attestBatchWithEvidence` | 547,375 | 749,345 | 749,345 | 951,315 | 2 |
| `setEvidence` | 24,256 | 38,713 | 33,399 | 55,154 | 8 |
| `setVerifiedAttester` | 21,949 | 38,149 | 45,818 | 45,818 | 15 |
| `strikeAttester` | 21,677 | 35,135 | 28,697 | 45,797 | 43 |
| `clearStrikes` | 21,697 | 22,433 | 21,902 | 23,333 | 5 |
| `setExpiryDuration` | 21,708 | 26,729 | 27,776 | 27,788 | 15 |
| `disputeAttestation` | 26,178 | 112,460 | 102,642 | 245,994 | 21 |
| `revokeAttestation` | 23,678 | 89,316 | 80,473 | 272,153 | 15 |
| `resolveDispute` | 26,275 | 127,249 | 140,289 | 238,172 | 12 |
| `expireDispute` | 26,070 | 66,570 | 30,443 | 142,124 | 6 |
| `getScore` (view) | 3,307 | 18,616 | 16,507 | 30,384 | 48 |
| `getScoreByCategory` (view) | 23,352 | 24,996 | 24,747 | 26,163 | 5 |
| `getScoreHistory` (view) | 3,161 | 20,744 | 22,123 | 50,073 | 14 |
| `getAttestationsByCategory` (view) | 3,007 | 36,093 | 41,530 | 57,246 | 10 |
| `latestScoreSnapshot` (view) | 3,193 | 10,633 | 12,122 | 12,122 | 6 |
| `attesterWeight` (view) | 2,654 | 18,582 | 20,958 | 30,314 | 24 |
| `attesterStats` (view) | 5,368 | 10,083 | 12,441 | 12,441 | 3 |
| `decayFactorBps` (view) | 619 | 746 | 794 | 808 | 7 |
| `decayFactorBpsAt` (view) | 614 | 733 | 783 | 803 | 6 |
| `getScoreAt` (view) | 10,096 | 17,139 | 16,614 | 25,861 | 15 |
| `getScoreByCategoryAt` (view) | 24,874 | 24,874 | 24,874 | 24,874 | 2 |
| `getProfileAt` (view) | 47,411 | 47,411 | 47,411 | 47,411 | 1 |
| `tierOfAt` (view) | 31,117 | 33,709 | 34,949 | 35,062 | 3 |
| `getLeaderboard` (view) | 3,134 | 38,865 | 40,049 | 60,143 | 13 |
| `getLeaderboardByCategory` (view) | 37,573 | 71,266 | 70,875 | 128,670 | 6 |

## Score history cost

Every state-changing call now pays for its snapshots: `attest`
recomputes the subject's overall score plus the touched category's
score and appends one or two `ScoreSnapshot` structs (cold storage
on the first snapshot per subject/category). That roughly doubles
`attest`'s average in these tests (147,883 → 339,955 gas) and lifts
the dispute/revoke calls by a similar absolute amount; the max
`attest` figure (512,354) reflects cold snapshot storage plus the
score recomputation over a subject's growing attestation list on
each snapshot. Reads stay cheap: `getScoreHistory`
costs about the same as the other paginated views and scales with
the page size, not with the subject's total history.
| `getSubjectsByTier` (view) | 43,910 | 171,066 | 207,085 | 207,858 | 9 |

## Reading the numbers

- **First attestation is the expensive one** (~192k gas): it allocates a
  new record and appends to the subject's list. Re-attesting an existing
  record is a storage update (~22k gas), which is the common path for
  repeat clients.
- **Score reads scale linearly** with the subject's attestation count:
  `getScore` scans every record for the subject. That is fine for a
  reputation profile (tens to low hundreds of attestations) but is a
  known trade-off versus maintaining running totals on-chain — reads
  are free off-chain via `eth_call`, and the scan keeps writes cheap
  and the accounting auditable.
- **Batch attestation costs one transaction, not N:** the unit test
  batching three fresh attestations costs 527,100 gas total, in line
  with three first-attestations (~192k each) minus the repeated
  per-transaction overhead a caller would pay for three separate
  calls. Updating an existing record inside a batch stays at the
  ~22k storage-update price.
- **Dispute operations are cheap and flat** (26–80k gas): they flip
  flags on one record rather than rewriting score state, which is why
  disputing never needs to touch other attestations.
- **Leaderboard reads scale with the subject set:** `getLeaderboard`
  measured 3–60k gas on the small boards in the test suite (up to 3
  subjects); it scans every registered subject, so on a busy registry
  it is a view for off-chain `eth_call`, not a transaction input.
- **Discovery views cost more than the overall board:** a category
  board scores every subject twice (once for the category average,
  once for the overall tier on each row), and the tier directory
  scores every subject's full history — 44–208k gas in the test
  suite, where the tier test registers 6 subjects with up to 10
  attestations each. Same conclusion: views for off-chain reads,
  not transaction inputs.
- **Score previews cost about the same as the live reads:** the
  preview views run the same scan with decay measured against the
  target time, so `getScoreAt` tracks `getScore` (~15.5k gas avg on
  the small subjects in the test suite) and `getProfileAt` /
  `tierOfAt` cost one extra scan per scope (~30–39k gas). The only
  added per-record work is the `createdAt <= when` check, which is
  why write costs did not move.
- **Evidence is one extra storage slot:** attaching evidence at
  attestation time costs no more than a plain attestation on the
  same path (the extra `bytes32` is written in the same cold slot
  allocation); `setEvidence` afterwards is a single-slot update
  (~39k gas). Evidence never triggers a snapshot or score
  recomputation, so it stays off the expensive paths.
  × 256 runs × depth 100 (25,600 handler calls each, 0 reverts). The
  `.gas-snapshot` file tracks unit-test gas per test as a regression
  baseline; re-run `forge snapshot` after contract changes and diff it.
