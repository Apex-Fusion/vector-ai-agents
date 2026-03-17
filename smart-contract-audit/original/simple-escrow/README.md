# Simple Escrow — Original Contract

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21

## Purpose

A hash-locked escrow that holds ADA with a secret-hash commitment. The beneficiary can claim by revealing the correct secret before a deadline. If the deadline passes unclaimed, the sender can reclaim.

## Use Cases

- Atomic swaps (reveal-secret pattern)
- Payment contingent on proof of knowledge
- Trustless two-party commitments

## How It Works

1. **Lock:** Sender deposits ADA at the script address with an inline datum containing: beneficiary PKH, sender PKH, deadline (POSIX ms), and `blake2b_256(secret)`.
2. **Claim:** Beneficiary reveals the secret pre-image before the deadline. Must sign the transaction and receive at least the locked value.
3. **Reclaim:** Sender takes back funds after the deadline passes. Must sign the transaction and receive at least the locked value.

## Types

- **EscrowDatum:** `{ beneficiary, sender, deadline, secret_hash }`
- **EscrowRedeemer:** `Claim { secret }` | `Reclaim`

## Security Properties

- Secret verification via `blake2b_256`
- Deadline enforcement via `is_entirely_before` / `is_entirely_after`
- Signature requirement for both paths
- Value preservation via multi-asset `assets_gte` check

## Known Limitations

- **Double satisfaction:** Two escrows with the same beneficiary can be drained with a single output. Production fix: add `script_input_count == 1`.
- Secret revealed on-chain after claim
- No partial claims or mutual cancellation
- Dead zone at exact deadline millisecond

## File

- `simple_escrow.ak` — the validator source code
