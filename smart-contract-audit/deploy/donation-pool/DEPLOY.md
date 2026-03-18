# Donation Pool — Deployment Guide

## Contract

- **Validator:** `donation_pool.donation_pool.spend`
- **Script Hash:** `02335d390f81065a41fd323e05eb0adc35b12944d851cb3a7cc4f3c6`
- **Script Address (Vector testnet):** `addr1wyprxhfep7qsvkjpl5erup0tptwrtvffgnv9rje60nz083skt3wk5`
- **Plutus Version:** V3
- **Status:** Audited (v2 methodology), compliant

## Datum

```
DonationDatum { admin }
```

## Redeemer

```
Distribute { distributions: List<Distribution> }
```

## Deployment

1. Use `plutus.json` in this folder — it contains the compiled, audited validator
2. Derive the script address from the script hash (or use the address above for Vector testnet)
3. Create a transaction sending funds to the script address with an inline datum

## Audit Evidence

See `compliant/donation-pool/reports/` for full audit trail.
