# Simple Escrow — Research Context

**Date:** 2026-03-18

---

## 1. Protocol Summary

The Simple Escrow is a hash-locked escrow contract on Vector (ApexFusion's Cardano-compatible eUTXO chain). It holds AP3X (native coin) with a secret-hash commitment, providing two spending paths:

- **Claim:** Beneficiary reveals the pre-image of the secret hash before a deadline
- **Reclaim:** Sender retrieves funds after the deadline passes

Use cases: atomic swaps, payment contingent on proof of knowledge, trustless two-party commitments.

## 2. Architecture

The contract is a single spend validator (no mint handler). It uses:
- **Inline datum** (`EscrowDatum`): beneficiary PKH, sender PKH, deadline (POSIX ms), secret_hash (blake2b_256 of the secret)
- **Typed redeemer** (`EscrowRedeemer`): `Claim { secret: ByteArray }` or `Reclaim`
- **Value preservation** via `assets_gte` — checks that the output to the recipient contains at least as much of every asset as was locked

No NFTs, no multi-validator, no minting policy. Pure spend-only.

## 3. Intended Functionality

### Claim Path
1. Secret hashes to `d.secret_hash` via blake2b_256
2. Transaction validity range is entirely before `d.deadline`
3. Beneficiary has signed the transaction
4. An output pays at least the locked value to the beneficiary

### Reclaim Path
1. Transaction validity range is entirely after `d.deadline`
2. Sender has signed the transaction
3. An output pays at least the locked value back to the sender

## 4. Known Limitations (from README)

The author explicitly documents these:
- **Double satisfaction:** "Two escrows with the same beneficiary can be drained with a single output." The README suggests "Production fix: add `script_input_count == 1`." The contract comments claim mitigation via per-input value checking, but the README contradicts this.
- **Secret revealed on-chain** after claim (inherent to hash-lock pattern)
- **No partial claims or mutual cancellation**
- **Dead zone at exact deadline millisecond** — `is_entirely_before` and `is_entirely_after` may both reject at the exact deadline

## 5. Risk Surface Mapping

| Area | Risk Level | Notes |
|------|-----------|-------|
| Double satisfaction | **Critical** | Author acknowledges it. `list.any` on outputs means one output can satisfy multiple validators. |
| `list.any` output matching | **High** | Both Claim and Reclaim use `list.any` to find a matching output — classic eUTXO double satisfaction vector |
| No `script_input_count` check | **High** | Multiple escrow UTxOs can be spent in one TX |
| Value preservation (`assets_gte`) | **Medium** | Checks value but not uniqueness — same output can "pay" multiple inputs |
| Deadline edge case | **Low** | Dead zone at exact millisecond, minor |
| Secret exposure | **Low** | Inherent to pattern, not a contract bug |
| No staking credential handling | **Low** | Script address has no stake credential |

## 6. eUTXO-Specific Considerations

- **No multi-validator coupling needed** — this is spend-only, so orphan burn / burn coupling doesn't apply
- **Double satisfaction IS the primary risk** — with `list.any`, spending 2 escrow UTxOs (both to the same beneficiary) in one TX allows one output to satisfy both validators
- **Front-running:** Secret is visible in the mempool once the Claim TX is broadcast. An attacker could extract the secret and submit their own Claim TX with higher fees (classic hash-lock front-running). This is inherent to the pattern.
- **Output index pinning** would be a stronger fix than `script_input_count == 1`

## 7. Testnet Deployment Context

- **Script Address:** `addr1wyy922hxs80kd4upzm95u393ktvkfhdvxsmg6mfklax2h7sglxqqe`
- **Live UTxOs:** 2 — one with 10 AP3X, one with 5 AP3X
- **Deploy wallet:** `addr1vx2gqpm6fsp4s99vm08zqwzmshcv7rpv28lk0xxakh3jc3cg9enml`
- **Beneficiary wallet:** `addr1v95yzmee529sw64q3sk3a26aykexgrwcl58w66kv3akxr6qz5t7gd`
- **Ogmios:** `https://ogmios.vector.testnet.apexfusion.org`
- **TX Submit:** `https://submit.vector.testnet.apexfusion.org/api/submit/tx`

Having 2 live escrow UTxOs at the same script address is particularly interesting for testing double satisfaction — the red team can attempt to drain both with a single output.
