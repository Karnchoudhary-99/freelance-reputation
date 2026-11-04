# Freelance Reputation Protocol

Portable on-chain reputation for freelancers — ratings and endorsements
that travel with the worker, not the platform.

## Roadmap

- [x] Project scaffold (README roadmap, license, gitignore)
- [x] Reputation registry (attestations, weighted scores, revocation)
- [x] Decay + dispute handling
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

### Example flow

```text
carol attests bob 90 (Overall)      -> bob average 90.00, weight now 3
dave  attests bob 90 (Overall)      -> bob average 90.00
bob   attests alice 60 (Overall)    -> weight 3 (bob is well-rated)
carol attests alice 90 (Overall)    -> weight 1
alice score = (60*3 + 90*1) / 4 = 67.50
```

### Run it

```sh
forge test          # 22 tests
forge script script/Deploy.s.sol   # simulated deploy
```

## License

MIT — see [LICENSE](LICENSE).
