# Simple DEX — Original Contract

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21

## Purpose

A peer-to-peer limit order swap contract. A maker locks token A at the script address, specifying the desired token B and an exchange rate. A taker can fulfill the offer by paying the maker the correct amount of token B. The maker can cancel at any time.

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

## Known Limitations

- All-or-nothing fills (no partial fills)
- No expiration on offers
- Single cancel per transaction
- MEV/front-running inherent to open-order DEXs
- Staking credential not enforced on maker payment

## File

- `simple_dex.ak` — the validator source code
