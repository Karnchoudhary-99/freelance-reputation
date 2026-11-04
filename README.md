# Freelance Reputation Protocol

Portable on-chain reputation for freelancers — ratings and endorsements
that travel with the worker, not the platform.

## Roadmap

- [x] Project scaffold (README roadmap, license, gitignore)
- [x] Reputation registry (attestations, weighted scores, revocation)
- [ ] Decay + dispute handling
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
  average scaled by 100 (8750 == 87.50), plus attestation count and total
  weight. `getAttestations(subject)` returns all records, revoked included.

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
forge test          # 9 tests
forge script script/Deploy.s.sol   # simulated deploy
```

## License

MIT — see [LICENSE](LICENSE).
