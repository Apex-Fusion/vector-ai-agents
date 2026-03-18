# Simple DEX — Deployment Guide

## Current Version

- **Validator:** `simple_dex.simple_dex.spend`
- **Script Hash:** `a30e231785a7d097936cbd4e2638fa5c6e0c56051dbd257a04e10d93`
- **Script Address (Vector testnet):** `addr1wx3sugchsknap9undj75uf3clfwxurzkq5wm6ft6qnssmycxjl4lv`
- **Plutus Version:** V3
- **Status:** Audited (v2), secure — no code changes needed

## Datum

```
SwapDatum { maker: ByteArray, offered_asset: AssetClass, desired_asset: AssetClass, rate_numerator: Int, rate_denominator: Int }
AssetClass { policy_id: ByteArray, asset_name: ByteArray }
```

## Redeemer

```
Take { maker_output_index: Int } | Cancel
```

## Deployment

1. Use `plutus.json` in this folder
2. Derive script address or use the Vector testnet address above
3. Lock offered tokens with inline `SwapDatum`

## Off-Chain Validation Requirements

- `maker` must be a VKH, not a script hash
- `rate_numerator > 0` and `rate_denominator > 0`
- `policy_id` must be 28 bytes or empty (for ADA)

## Audit Evidence

See `compliant/simple-dex/reports/` for full audit trail.

## Version History

| Version | Script Hash | Network | Date | Status | Notes |
|---------|-------------|---------|------|--------|-------|
| **v1 (current)** | `a30e231785a7d097936cbd4e2638fa5c6e0c56051dbd257a04e10d93` | Testnet | 2026-03-16 | ✅ Secure | Has `script_input_count == 1` + output-index pinning. v2 audit confirmed secure (1 medium structural observation, not exploitable). |
