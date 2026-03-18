# Donation Pool — Deployment Guide

## Current Version (Compliant)

- **Validator:** `donation_pool.donation_pool.spend`
- **Script Hash:** `02335d390f81065a41fd323e05eb0adc35b12944d851cb3a7cc4f3c6`
- **Script Address (Vector testnet):** `addr1wyprxhfep7qsvkjpl5erup0tptwrtvffgnv9rje60nz083skt3wk5`
- **Plutus Version:** V3
- **Status:** Audited (v2), compliant, fix verified on-chain
- **Fix applied:** `script_input_count == 1` (prevents double satisfaction + budget inflation)

## Datum

```
DonationDatum { admin: ByteArray }
```

## Redeemer

```
Distribute { distributions: List<Distribution> }
Distribution { recipient: ByteArray, amount: Int }
```

## Deployment

1. Use `plutus.json` in this folder
2. Derive script address or use the Vector testnet address above
3. Lock funds with inline `DonationDatum`

## Audit Evidence

See `compliant/donation-pool/reports/` for full audit trail.

## Version History

| Version | Script Hash | Network | Date | Status | Notes |
|---------|-------------|---------|------|--------|-------|
| **v2 (current)** | `02335d390f81065a41fd323e05eb0adc35b12944d851cb3a7cc4f3c6` | Testnet | 2026-03-18 | ✅ Compliant | `script_input_count == 1` fix applied |
| v1 (original) | `34c4cca4ad65b2afc84da89ed7b579220c4d4e9c3ed2631d9425a8dc` | Testnet | 2026-03-16 | ⚠️ Outdated | **VULNERABLE:** double satisfaction via `list.any` + budget inflation — exploit TX `872a5537a9422bdf468ab83c041a3e743b697838b08777d48c5d8d24ce87fa86` |
