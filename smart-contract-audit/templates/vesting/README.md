# Vesting — Template

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21 | **Status:** Template (adapt for your use case)

## What Is This?

A time-locked linear vesting contract template. Lock ADA with a cliff and end time; the beneficiary claims proportionally over time.

This contract has been hardened through 3 review rounds. It uses defense-in-depth with both single-script-input enforcement and output-index pinning.

## Quick Start

```bash
cp vesting.ak your-project/validators/
# Also need vesting_types.ak with VestingDatum and VestingRedeemer
aiken build
aiken check
```

## Security Notes

✅ This contract includes full double satisfaction protection:
- `script_input_count == 1` — prevents multi-input attacks
- Output-index pinning — prevents single-input self-satisfaction
- Full datum field comparison on continuation — prevents datum hijacking

## Structure

```
templates/vesting/
├── vesting.ak           — the contract source
├── README.md            — this file
└── agent-notes/         — agentic guidance
    ├── deployment.md
    ├── parameters.md
    ├── integration.md
    ├── modifications.md
    └── gotchas.md
```
