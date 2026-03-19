> **⚠️ DEMO — NOT FOR PRODUCTION USE.** See repository root README for full disclaimer.

# Vesting — Deployment Guide

## Current Version

- **Validator:** `vesting.vesting.spend`
- **Script Hash:** `5e84a9e006c9b9514c90dd9eb2322471e5c952963bc6c667cec522ae`
- **Script Address (Vector testnet):** `addr1w90gf20qqmymj52vjrweav3jy3c7tj2jjcaud3n8emzj9ts6jnv3d`
- **Plutus Version:** V3
- **Status:** Audited (v2), secure — no code changes needed

## Datum

```
VestingDatum { beneficiary: ByteArray, total_vesting_amount: Int, cliff_time: Int, vesting_end_time: Int }
```

## Redeemer

```
Claim { beneficiary_index: Int, continuation_index: Int }
```

## Deployment

1. Use `plutus.json` in this folder
2. Derive script address or use the Vector testnet address above
3. Lock funds with inline `VestingDatum`

## Off-Chain Validation Requirements

- `total_vesting_amount > 0` (zero/negative = permanently unspendable)
- `vesting_end_time > cliff_time` (otherwise instant full vesting at cliff)
- `beneficiary` must be a VKH, not a script hash (script hash = permanent lock)

## Audit Evidence

See `compliant/vesting/reports/` for full audit trail.

## Version History

| Version | Script Hash | Network | Date | Status | Notes |
|---------|-------------|---------|------|--------|-------|
| **v1 (current)** | `5e84a9e006c9b9514c90dd9eb2322471e5c952963bc6c667cec522ae` | Testnet | 2026-03-16 | ✅ Secure | Has `script_input_count == 1` + output-index pinning. v2 audit confirmed no vulnerabilities. |
