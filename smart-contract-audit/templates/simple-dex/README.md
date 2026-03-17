# Simple DEX — Template

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21 | **Status:** Template (adapt for your use case)

## What Is This?

A peer-to-peer limit order swap contract template. Makers lock tokens with an exchange rate; takers fulfill offers by paying the required amount.

This contract avoids eUTxO concurrency issues entirely — each offer is an independent UTxO.

## Quick Start

```bash
cp simple_dex.ak your-project/validators/
# Also need dex_types.ak with SwapDatum, SwapRedeemer, AssetClass
aiken build
aiken check
```

## Security Notes

✅ Key protections:
- `script_input_count == 1` — prevents double satisfaction
- Safe `ceiling_div` with explicit guards
- Policy ID length validation (28 bytes or empty for ADA)
- Rate validation (both positive)

## Structure

```
templates/simple-dex/
├── simple_dex.ak        — the contract source
├── README.md            — this file
└── agent-notes/         — agentic guidance
    ├── deployment.md
    ├── parameters.md
    ├── integration.md
    ├── modifications.md
    └── gotchas.md
```
