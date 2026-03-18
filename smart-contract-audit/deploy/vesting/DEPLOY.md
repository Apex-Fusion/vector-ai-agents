# Vesting — Deployment Guide

## Contract

- **Validator:** `vesting.vesting.spend`
- **Script Hash:** `5e84a9e006c9b9514c90dd9eb2322471e5c952963bc6c667cec522ae`
- **Script Address (Vector testnet):** `addr1w90gf20qqmymj52vjrweav3jy3c7tj2jjcaud3n8emzj9ts6jnv3d`
- **Plutus Version:** V3
- **Status:** Audited (v2 methodology), compliant

## Datum

```
VestingDatum { beneficiary, total_vesting_amount, cliff_time, vesting_end_time }
```

## Redeemer

```
Claim { beneficiary_index, continuation_index }
```

## Deployment

1. Use `plutus.json` in this folder — it contains the compiled, audited validator
2. Derive the script address from the script hash (or use the address above for Vector testnet)
3. Create a transaction sending funds to the script address with an inline datum

## Audit Evidence

See `compliant/vesting/reports/` for full audit trail.
