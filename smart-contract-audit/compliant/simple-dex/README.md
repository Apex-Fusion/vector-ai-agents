# Simple DEX — Compliant Version

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21 | **Status:** Audit-passed

## Purpose

A peer-to-peer limit order swap contract. A maker locks token A at the script address, specifying the desired token B and an exchange rate. A taker can fulfill the offer by paying the maker the correct amount of token B. The maker can cancel at any time.

This is the **audit-passed** version of the simple DEX contract, having gone through full security review, testing, and compliance verification.

## Design

**Limit order model:** Each swap offer is an independent UTxO. No shared liquidity pool, no AMM, no batching. This avoids eUTxO concurrency problems entirely.

## Use Cases

- ADA ↔ native token swaps
- Native token ↔ native token exchanges
- OTC trades with custom rates

## How It Works

1. **Create Offer:** Maker sends token A to the script address with `SwapDatum { maker, offered_asset, desired_asset, rate_numerator, rate_denominator }`.
2. **Take Offer:** Taker pays maker `ceil(locked_a × rate_denominator / rate_numerator)` of token B. Anyone can take (no signature required).
3. **Cancel:** Maker reclaims their offer. Maker signature required.

## Exchange Rate

```
required_token_b = ceil(offered_token_a × rate_denominator / rate_numerator)
```

Ceiling division rounds up, favoring the maker.

## Security Properties

- Single-script-input enforcement (`script_input_count == 1`) — prevents double satisfaction
- Output-index pinning for maker payment
- Safe `ceiling_div` with explicit guards (`a >= 0`, `b > 0`)
- Policy ID length validation (28 bytes or empty for ADA)
- Rate validation (both numerator and denominator must be positive)
- Maker signature required for Cancel

## Differences from Original

The compliant version maintains the same core logic with all security properties verified through comprehensive testing and audit.

## Structure

```
compliant/simple-dex/
├── simple_dex.ak        — the compliant contract
├── README.md            — this file
├── agent-notes/         — agentic guidance
├── tests/               — test results
├── reports/             — audit and review reports
└── tools/               — verification tooling
```
