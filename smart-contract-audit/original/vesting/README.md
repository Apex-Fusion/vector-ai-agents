# Vesting — Original Contract

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21

## Purpose

Time-locked linear vesting of ADA. Funds are locked with a schedule defined by a cliff time and a vesting end time. Nothing is claimable before the cliff. Between cliff and end, the beneficiary can claim proportionally. After the end, all funds are claimable.

## Use Cases

- Employee/contributor token vesting
- Investor lockup periods
- DAO treasury release schedules
- Protocol founder allocations

## How It Works

1. **Lock:** Funder deposits ADA at the script address with an inline datum: `{ beneficiary, total_vesting_amount, cliff_time, vesting_end_time }`.
2. **Partial Claim:** Between cliff and end, beneficiary claims vested proportion. A continuation UTxO with the same datum holds remaining funds.
3. **Full Claim:** After `vesting_end_time`, beneficiary claims everything. No continuation needed.

## Vesting Formula

```
vested = total_vesting_amount × (current_time - cliff_time) / (vesting_end_time - cliff_time)
```

Uses the **lower bound** of the transaction validity range as `current_time` (conservative).

## Security Properties

- Single-script-input enforcement (`script_input_count == 1`) — prevents double satisfaction
- Output-index pinning — beneficiary and continuation outputs are specified by index
- Full datum field comparison on continuation UTxO — prevents datum hijacking
- Beneficiary signature required
- Conservative lower-bound timing

## Known Limitations

- No batched claims (single-script-input constraint)
- No cancellation/revocation mechanism
- Lovelace-only vesting
- Integer truncation rounds down (conservative)
- Degenerate datums (zero amount) create unspendable UTxOs

## File

- `vesting.ak` — the validator source code
