# Simple Dex — Deployment Guide

## Contract

- **Validator:** `simple_dex.simple_dex.spend`
- **Script Hash:** `a30e231785a7d097936cbd4e2638fa5c6e0c56051dbd257a04e10d93`
- **Script Address (Vector testnet):** `addr1wx3sugchsknap9undj75uf3clfwxurzkq5wm6ft6qnssmycxjl4lv`
- **Plutus Version:** V3
- **Status:** Audited (v2 methodology), compliant

## Datum

```
SwapDatum { maker, offered_asset, desired_asset, rate_numerator, rate_denominator }
```

## Redeemer

```
Take { maker_output_index } | Cancel
```

## Deployment

1. Use `plutus.json` in this folder — it contains the compiled, audited validator
2. Derive the script address from the script hash (or use the address above for Vector testnet)
3. Create a transaction sending funds to the script address with an inline datum

## Audit Evidence

See `compliant/simple-dex/reports/` for full audit trail.
