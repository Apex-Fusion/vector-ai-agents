# Simple Escrow — Deployment Guide

## Contract

- **Validator:** `simple_escrow.simple_escrow.spend`
- **Script Hash:** `6f1cc128d2fdfa7c215261fa75a620c921f755c37e1221bfc54cdd92`
- **Script Address (Vector testnet):** `addr1w9h3esfg6t7l5lpp2fsl5adxyryjra64cdlpygdlc4xdmysltkk07`
- **Plutus Version:** V3
- **Status:** Audited (v2 methodology), compliant

## Datum

```
EscrowDatum { beneficiary, sender, deadline, secret_hash }
```

## Redeemer

```
Claim { secret } | Reclaim
```

## Deployment

1. Use `plutus.json` in this folder — it contains the compiled, audited validator
2. Derive the script address from the script hash (or use the address above for Vector testnet)
3. Create a transaction sending funds to the script address with an inline datum

## Audit Evidence

See `compliant/simple-escrow/reports/` for full audit trail.
