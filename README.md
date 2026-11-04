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

### Attester reads

- `getAttestationsByAttester(attester, offset, limit)` — paginated audit
  view of what one client has endorsed, with the same empty-page
  semantics as the subject-side pagination. Updates do not add records,
  so the index counts attestations, not writes.
- `attesterStats(attester)` — `{given, active, revoked, disputed}`: the
  attester's track record. A client deciding whether to trust an
  endorsement can weigh the attester, not just the score.

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
never mask a broken invariant. Six invariants hold across every run:
score bounds (and zero when empty), count matching active records,
category counts summing to the overall count, the weighted average
recomputed independently from the raw records, no duplicate active
(attester, category) keys, and record ranges plus attestation totals.
Baseline: 6 invariants × 256 runs × depth 100 — 25,600 handler calls
each, 0 reverts. See `docs/gas-report.md` for deployment and
per-function gas (deploy 1,724,969 gas, 7,760 bytes runtime).

### Run it

```sh
forge test          # 33 tests (27 unit + 6 invariants)
forge script script/Deploy.s.sol   # simulated deploy
```

## License

MIT — see [LICENSE](LICENSE).
