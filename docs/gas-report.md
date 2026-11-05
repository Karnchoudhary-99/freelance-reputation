# Gas report — ReputationRegistry

Measured with `forge test --gas-report` (solc 0.8.24, optimizer on,
200 runs), from the unit suites in `test/ReputationRegistry.t.sol`,
`test/ScoreHistory.t.sol`, `test/ScorePreview.t.sol`,
`test/Evidence.t.sol`, `test/VerifiedAttesters.t.sol`, and
`test/AttestationExpiry.t.sol`.
Figures are from test calls, so first-write (cold storage) numbers are
the high end and repeat writes the low end; treat them as indicative,
not mainnet quotes.

## Deployment

| Metric | Value |
| --- | --- |
| Deployment cost | 3,823,180 gas |
| Runtime size | 17,298 bytes |

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

## Function costs (gas)

| Function | Min | Avg | Median | Max | Calls |
| --- | --- | --- | --- | --- | --- |
| `attest` | 22,317 | 366,199 | 386,055 | 520,967 | 106 |
| `attestWithEvidence` | 244,467 | 483,078 | 541,383 | 541,383 | 10 |
| `attestBatchWithEvidence` | 544,742 | 746,406 | 746,406 | 948,071 | 2 |
| `setEvidence` | 24,234 | 38,691 | 33,377 | 55,132 | 8 |
| `setVerifiedAttester` | 21,927 | 36,947 | 45,796 | 45,796 | 13 |
| `setExpiryDuration` | 21,686 | 26,707 | 27,754 | 27,766 | 15 |
| `disputeAttestation` | 26,222 | 103,062 | 102,690 | 191,562 | 19 |
| `revokeAttestation` | 23,678 | 75,552 | 80,471 | 151,371 | 12 |
| `resolveDispute` | 26,231 | 117,124 | 140,249 | 238,124 | 11 |
| `expireDispute` | 26,048 | 66,549 | 30,421 | 142,106 | 6 |
| `getScore` (view) | 3,289 | 18,625 | 16,652 | 30,366 | 43 |
| `getScoreByCategory` (view) | 23,421 | 24,821 | 24,816 | 26,232 | 4 |
| `getScoreHistory` (view) | 3,166 | 20,714 | 22,090 | 49,983 | 14 |
| `attesterWeight` (view) | 5,383 | 18,959 | 18,593 | 27,949 | 13 |
| `decayFactorBps` (view) | 553 | 680 | 728 | 742 | 7 |
| `decayFactorBpsAt` (view) | 636 | 755 | 805 | 825 | 6 |
| `getScoreAt` (view) | 10,074 | 17,117 | 16,592 | 25,839 | 15 |
| `getScoreByCategoryAt` (view) | 24,878 | 24,878 | 24,878 | 24,878 | 2 |
| `getProfileAt` (view) | 47,389 | 47,389 | 47,389 | 47,389 | 1 |
| `tierOfAt` (view) | 31,139 | 33,731 | 34,971 | 35,084 | 3 |
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
