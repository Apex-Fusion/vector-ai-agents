# Donation Pool — Original Contract

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21

## Purpose

A pool contract where anyone can donate AP3X (by sending to the script address with an inline datum specifying the admin), and the admin can distribute funds to verified recipients in batch operations.

## Use Cases

- Community grants programs
- Charity pools with an accountable admin
- DAO fund distribution
- Retroactive public goods funding

## How It Works

1. **Donate:** Anyone sends ADA to the script address with an inline `DonationDatum { admin }`.
2. **Distribute:** The admin builds a transaction consuming pool UTxOs, specifying a list of `(recipient, amount)` distributions. Admin must sign. Change can return to the script with the same admin datum.

## Types

- **DonationDatum:** `{ admin: VerificationKeyHash }`
- **DonationRedeemer:** `Distribute { distributions: List<Distribution> }`
- **Distribution:** `{ recipient: VerificationKeyHash, amount: Int }`

## Security Properties

- Admin signature required for all distributions
- Same-admin enforcement across batched inputs (prevents cross-pool budget inflation)
- No duplicate recipients allowed
- Budget not exceeded check
- Per-recipient payment verification
- Change datum integrity preserved

## Known Limitations

- ADA-only tracking (native tokens not validated)
- Admin is fully trusted (can distribute to themselves)
- No admin key rotation mechanism
- No on-chain recipient allowlist

## File

- `donation_pool.ak` — the validator source code
