# Gas report — ReputationRegistry

Measured with `forge test --gas-report` (solc 0.8.24, optimizer on,
200 runs), from the unit suites in `test/ReputationRegistry.t.sol`,
`test/ScoreHistory.t.sol`, `test/ScorePreview.t.sol`,
`test/Evidence.t.sol`, `test/VerifiedAttesters.t.sol`,
`test/AttestationExpiry.t.sol`, `test/CategoryReads.t.sol`, and
`test/AttesterStrikes.t.sol`, `test/ScoreProofs.t.sol`,
`test/Governance.t.sol`, `test/Delegation.t.sol`,
`test/DisputeEscalation.t.sol`, `test/BatchReads.t.sol`, and
`test/LeaderboardOptOut.t.sol`.
Figures are from test calls, so first-write (cold storage) numbers are
the high end and repeat writes the low end; treat them as indicative,
not mainnet quotes.

## Deployment

| Metric | Value |
| --- | --- |
| Deployment cost | 5,972,774 gas |
| Runtime size | 27,247 bytes |

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

Governance & safety added ~210k gas to deployment (+623 bytes): the
mutable `owner` plus `pendingOwner` and `paused` slots, the
`pause` / `unpause` / `transferOwnership` / `acceptOwnership` /
`cancelOwnershipTransfer` functions plus five events, and the
`RegistryPaused` guard in `_attest` (plus `setEvidence` and
`issueScoreProof`). The governance calls are all single-slot writes:
`pause` averages ~42k gas (first pause in a test ~47k cold),
`unpause` ~25k, `transferOwnership` ~38k (first ~48k cold),
`acceptOwnership` ~27k, `cancelOwnershipTransfer` ~25k. The pause
guard costs `attest` one extra SLOAD per call — its average barely
moves across the wider call mix — and a reverted call while paused
costs only the 21k-gas base plus the checks, since `_attest` reverts
before any state change (and a signed attestation reverts before its
nonce is consumed, because the whole transaction rolls back).

Attester delegation added ~473k gas to deployment (+2,511 bytes):
the `_delegateExpiry` / `_delegateList` mappings, the five
on-behalf entry points, and the delegate views. The size jump is
larger than the last few features because five new external
functions each carry a full attestation path (the on-behalf
functions delegate to `_attest`, so they duplicate its call frame
rather than sharing it). `setDelegate` is a first-set cold write
plus a list push (~91k gas max, ~22k when re-setting an existing
delegate); `revokeDelegate` is a single-slot reset (~26k gas avg).
`attestOnBehalf` costs the same as a direct `attest` on the same
path (~217k gas avg in the delegation suite, 25k on a re-attest)
plus one SLOAD for the delegate check —
the delegation itself is nearly free at call time. The views are
cheap reads: `isDelegate` ~2.8k gas, `getDelegates` ~11.5k gas
avg (it scans the attester's delegate list twice).

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

Dispute escalation added ~254k gas to deployment (+1,173 bytes):
one extra `bool` slot on the `Attestation` struct (packed with the
existing flags, but the struct grows a slot on first write), the
`escalateDispute` / `resolveDisputeAsOwner` entry points, the
`isDisputeEscalated` view, and two events. `escalateDispute` is a
single-slot flag flip (~35k gas avg, ~38k on the first escalation
in a test); `resolveDisputeAsOwner` mirrors the attester's
`resolveDispute` (~87k gas avg — the uphold path records a snapshot
and refreshes the decay clock, the concede path revokes and clears
the active key, so the two paths bracket the average). Escalation
itself records no snapshot and touches no score, which is why it
stays cheap; the owner-arbitration cost is paid only when a dispute
actually reaches arbitration.

Batch reads added ~275k gas to deployment (+947 bytes): three pure
view functions (`getScores`, `getProfiles`, `getTiers`) — no new
storage, no writes, so write costs do not move at all. As views
they are off-chain reads, but the test suite still measures them:
on 4-subject inputs `getScores` averages ~34k gas and `getTiers`
~34k (one score scan per subject), while `getProfiles` averages
~64k (five scans per subject — overall plus one per category).
Cost grows linearly with the input list and with each subject's
attestation count, so frontends should keep batches small on a
busy registry.

Leaderboard opt-out added ~72k gas to deployment (+334 bytes): one
`mapping(address => bool)` plus the `setLeaderboardOptOut` /
`isLeaderboardOptedOut` pair and one event. `setLeaderboardOptOut`
is a single-slot write (~38k gas avg, ~45k on the first opt-out in
a test). The listing check itself is one cold/warm SLOAD per subject
inside the leaderboard and tier-directory scans, so board reads
grow by a negligible amount; scores, tiers, and attestations are
untouched because opt-out never enters the scoring path.

## Function costs (gas)

| Function | Min | Avg | Median | Max | Calls |
| --- | --- | --- | --- | --- | --- |
| `attest` | 22,339 | 373,236 | 388,692 | 523,600 | 143 |
| `attestOnBehalf` | 25,322 | 216,962 | 159,408 | 437,370 | 11 |
| `attestWithEvidenceOnBehalf` | 433,590 | 433,590 | 433,590 | 433,590 | 1 |
| `attestBatchOnBehalf` | 998,860 | 998,860 | 998,860 | 998,860 | 1 |
| `attestBatchWithEvidenceOnBehalf` | 435,065 | 435,065 | 435,065 | 435,065 | 1 |
| `setEvidenceOnBehalf` | 42,639 | 42,639 | 42,639 | 42,639 | 1 |
| `setDelegate` | 21,843 | 78,383 | 90,766 | 90,766 | 23 |
| `revokeDelegate` | 23,741 | 24,741 | 24,741 | 25,741 | 4 |
| `isDelegate` (view) | 2,814 | 2,814 | 2,814 | 2,814 | 5 |
| `getDelegates` (view) | 8,619 | 11,470 | 9,315 | 15,478 | 7 |
| `delegateExpiry` (view) | 2,790 | 2,790 | 2,790 | 2,790 | 3 |
| `attestWithEvidence` | 247,078 | 485,689 | 543,994 | 543,994 | 10 |
| `attestBatchWithEvidence` | 547,375 | 749,345 | 749,345 | 951,315 | 2 |
| `setEvidence` | 24,256 | 38,713 | 33,399 | 55,154 | 8 |
| `setVerifiedAttester` | 21,949 | 38,149 | 45,818 | 45,818 | 15 |
| `strikeAttester` | 21,677 | 35,135 | 28,697 | 45,797 | 43 |
| `clearStrikes` | 21,697 | 22,433 | 21,902 | 23,333 | 5 |
| `setExpiryDuration` | 21,708 | 26,729 | 27,776 | 27,788 | 15 |
| `pause` | 23,472 | 42,377 | 46,857 | 46,857 | 19 |
| `unpause` | 23,494 | 24,849 | 24,964 | 25,634 | 7 |
| `transferOwnership` | 23,879 | 38,275 | 47,898 | 47,898 | 11 |
| `acceptOwnership` | 23,455 | 26,676 | 25,876 | 33,098 | 6 |
| `cancelOwnershipTransfer` | 23,517 | 24,898 | 25,525 | 25,652 | 3 |
| `disputeAttestation` | 26,178 | 112,460 | 102,642 | 245,994 | 21 |
| `revokeAttestation` | 23,678 | 89,316 | 80,473 | 272,153 | 15 |
| `resolveDispute` | 26,275 | 127,249 | 140,289 | 238,172 | 12 |
| `expireDispute` | 26,070 | 66,570 | 30,443 | 142,124 | 6 |
| `escalateDispute` | 23,700 | 35,265 | 37,722 | 37,722 | 25 |
| `resolveDisputeAsOwner` | 23,910 | 87,403 | 85,530 | 149,668 | 12 |
| `isDisputeEscalated` (view) | 2,457 | 4,347 | 4,820 | 4,820 | 5 |
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
- **Invariant fuzz baseline:** 11 invariants × 256 runs × depth 100
  (25,600 handler calls each, 0 reverts). The
  `.gas-snapshot` file tracks unit-test gas per test as a regression
  baseline; re-run `forge snapshot` after contract changes and diff it.
