# Vesting — Compliant Version

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21 | **Status:** Audit-passed

## Purpose

Time-locked linear vesting of ADA. Funds are locked with a schedule defined by a cliff time and a vesting end time. Nothing is claimable before the cliff. Between cliff and end, the beneficiary can claim proportionally. After the end, all funds are claimable.

This is the **audit-passed** version of the vesting contract, having gone through full security review, testing, and compliance verification.

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

## Differences from Original

The compliant version includes enhanced double satisfaction protection and has been verified through comprehensive testing and audit.

## Structure

```
compliant/vesting/
├── vesting.ak           — the compliant contract
├── README.md            — this file
├── agent-notes/         — agentic guidance
├── tests/               — test results
├── reports/             — audit and review reports
└── tools/               — verification tooling
```
