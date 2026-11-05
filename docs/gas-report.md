# Gas report — ReputationRegistry

Measured with `forge test --gas-report` (solc 0.8.24, optimizer on,
200 runs), from the unit suites in `test/ReputationRegistry.t.sol`,
`test/ScoreHistory.t.sol`, `test/ScorePreview.t.sol`,
`test/Evidence.t.sol`, and `test/VerifiedAttesters.t.sol`.
Figures are from test calls, so first-write (cold storage) numbers are
the high end and repeat writes the low end; treat them as indicative,
not mainnet quotes.

## Deployment

| Metric | Value |
| --- | --- |
| Deployment cost | 3,646,848 gas |
| Runtime size | 16,586 bytes |

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

## Function costs (gas)

| Function | Min | Avg | Median | Max | Calls |
| --- | --- | --- | --- | --- | --- |
| `attest` | 22,317 | 361,828 | 383,446 | 517,746 | 91 |
| `attestWithEvidence` | 241,201 | 479,812 | 538,117 | 538,117 | 10 |
| `attestBatchWithEvidence` | 541,559 | 742,001 | 742,001 | 942,443 | 2 |
| `setEvidence` | 24,189 | 38,646 | 33,332 | 55,087 | 8 |
| `setVerifiedAttester` | 21,949 | 36,967 | 45,815 | 45,815 | 13 |
| `disputeAttestation` | 26,244 | 103,936 | 100,101 | 188,361 | 17 |
| `revokeAttestation` | 23,700 | 74,889 | 80,493 | 148,781 | 11 |
| `resolveDispute` | 26,231 | 113,122 | 128,687 | 234,900 | 10 |
| `expireDispute` | 26,048 | 65,678 | 30,421 | 139,494 | 6 |
| `getScore` (view) | 3,315 | 17,282 | 18,897 | 27,168 | 32 |
| `getScoreByCategory` (view) | 20,201 | 21,601 | 21,596 | 23,012 | 4 |
| `getScoreHistory` (view) | 3,166 | 20,714 | 22,090 | 49,983 | 14 |
| `attesterWeight` (view) | 5,390 | 16,922 | 16,100 | 24,732 | 13 |
| `decayFactorBps` (view) | 579 | 706 | 754 | 768 | 7 |
| `decayFactorBpsAt` (view) | 658 | 777 | 827 | 847 | 6 |
| `getScoreAt` (view) | 10,078 | 15,530 | 13,996 | 22,619 | 13 |
| `getScoreByCategoryAt` (view) | 21,698 | 21,698 | 21,698 | 21,698 | 2 |
| `getProfileAt` (view) | 39,269 | 39,269 | 39,269 | 39,269 | 1 |
| `tierOfAt` (view) | 27,941 | 30,125 | 31,161 | 31,274 | 3 |
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
