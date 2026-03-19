> **⚠️ DEMO — NOT FOR PRODUCTION USE.** See repository root README for full disclaimer.

# Simple Escrow — Deployment Guide

## Current Version (Compliant)

- **Validator:** `simple_escrow.simple_escrow.spend`
- **Script Hash:** `6f1cc128d2fdfa7c215261fa75a620c921f755c37e1221bfc54cdd92`
- **Script Address (Vector testnet):** `addr1w9h3esfg6t7l5lpp2fsl5adxyryjra64cdlpygdlc4xdmysltkk07`
- **Plutus Version:** V3
- **Status:** Audited (v2), compliant, fix verified on-chain
- **Fix applied:** `script_input_count == 1` (prevents double satisfaction)

## Datum

```
EscrowDatum { beneficiary: ByteArray, sender: ByteArray, deadline: Int, secret_hash: ByteArray }
```

## Redeemer

```
Claim { secret: ByteArray } | Reclaim
```

## Deployment

1. Use `plutus.json` in this folder
2. Derive script address or use the Vector testnet address above
3. Lock funds with inline `EscrowDatum`

## Audit Evidence

See `compliant/simple-escrow/reports/` for full audit trail.

## Version History

| Version | Script Hash | Network | Date | Status | Notes |
|---------|-------------|---------|------|--------|-------|
| **v2 (current)** | `6f1cc128d2fdfa7c215261fa75a620c921f755c37e1221bfc54cdd92` | Testnet | 2026-03-18 | ✅ Compliant | `script_input_count == 1` fix applied |
| v1 (original) | `08552ae681df66d78116cb4e44b1b2d964ddac34368d6d36ff4cabfa` | Testnet | 2026-03-16 | ⚠️ Outdated | **VULNERABLE:** double satisfaction via `list.any` — exploit TX `5ada16bbc96247c277711e1c9fde1e48749ad8f9b8eff78fca3340222250afcf` |
