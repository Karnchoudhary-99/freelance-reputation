# Gas report — ReputationRegistry

Measured with `forge test --gas-report` (solc 0.8.24, optimizer on,
200 runs), from the unit suite in `test/ReputationRegistry.t.sol`.
Figures are from test calls, so first-write (cold storage) numbers are
the high end and repeat writes the low end; treat them as indicative,
not mainnet quotes.

## Deployment

| Metric | Value |
| --- | --- |
| Deployment cost | 1,724,969 gas |
| Runtime size | 7,760 bytes |

## Function costs (gas)

| Function | Min | Avg | Median | Max | Calls |
| --- | --- | --- | --- | --- | --- |
| `attest` | 22,229 | 147,883 | 171,736 | 191,672 | 41 |
| `disputeAttestation` | 26,154 | 53,556 | 59,976 | 79,948 | 12 |
| `revokeAttestation` | 23,609 | 33,950 | 38,499 | 40,499 | 7 |
| `resolveDispute` | 26,221 | 34,513 | 37,514 | 39,163 | 6 |
| `expireDispute` | 25,958 | 30,527 | 30,331 | 37,912 | 5 |
| `getScore` (view) | 3,095 | 18,333 | 21,712 | 26,557 | 21 |
| `getScoreByCategory` (view) | 19,585 | 20,939 | 20,943 | 22,287 | 4 |
| `attesterWeight` (view) | 2,956 | 15,648 | 14,944 | 21,854 | 7 |
| `decayFactorBps` (view) | 443 | 566 | 596 | 597 | 6 |
| `getLeaderboard` (view) | 3,059 | 36,357 | 32,682 | 59,948 | 10 |

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
- **Invariant fuzz baseline:** `test/Invariant.t.sol` runs 6 invariants
  × 256 runs × depth 100 (25,600 handler calls each, 0 reverts). The
  `.gas-snapshot` file tracks unit-test gas per test as a regression
  baseline; re-run `forge snapshot` after contract changes and diff it.
