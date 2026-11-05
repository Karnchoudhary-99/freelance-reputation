# Gas report — ReputationRegistry

Measured with `forge test --gas-report` (solc 0.8.24, optimizer on,
200 runs), from the unit suites in `test/ReputationRegistry.t.sol`
and `test/ScoreHistory.t.sol`.
Figures are from test calls, so first-write (cold storage) numbers are
the high end and repeat writes the low end; treat them as indicative,
not mainnet quotes.

## Deployment

| Metric | Value |
| --- | --- |
| Deployment cost | 3,158,579 gas |
| Runtime size | 14,614 bytes |

Score history added ~307k gas to deployment (+1,419 bytes): the
`_scoreHistory` mapping, the `ScoreSnapshot` struct, and the
`_recordSnapshot` helper plus its two view functions.

## Function costs (gas)

| Function | Min | Avg | Median | Max | Calls |
| --- | --- | --- | --- | --- | --- |
| `attest` | 22,333 | 339,955 | 378,421 | 512,354 | 60 |
| `disputeAttestation` | 26,133 | 98,801 | 99,820 | 187,884 | 15 |
| `revokeAttestation` | 23,677 | 68,181 | 79,300 | 148,392 | 8 |
| `resolveDispute` | 26,200 | 93,947 | 99,107 | 145,465 | 8 |
| `expireDispute` | 26,092 | 65,588 | 30,465 | 139,136 | 6 |
| `getScore` (view) | 3,078 | 17,783 | 21,695 | 26,540 | 25 |
| `getScoreByCategory` (view) | 19,625 | 20,979 | 20,983 | 22,327 | 4 |
| `getScoreHistory` (view) | 3,188 | 20,736 | 22,112 | 50,005 | 14 |
| `attesterWeight` (view) | 2,979 | 15,671 | 14,967 | 21,877 | 7 |
| `decayFactorBps` (view) | 421 | 544 | 574 | 575 | 6 |
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
- **Invariant fuzz baseline:** `test/Invariant.t.sol` runs 6 invariants
  × 256 runs × depth 100 (25,600 handler calls each, 0 reverts). The
  `.gas-snapshot` file tracks unit-test gas per test as a regression
  baseline; re-run `forge snapshot` after contract changes and diff it.
