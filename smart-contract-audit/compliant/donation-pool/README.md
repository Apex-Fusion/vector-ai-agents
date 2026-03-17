# Donation Pool — Compliant Version

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21 | **Status:** Audit-passed

## Purpose

A pool contract where anyone can donate ADA (by sending to the script address with an inline datum specifying the admin), and the admin can distribute funds to verified recipients in batch operations.

This is the **audit-passed** version of the donation pool contract, having gone through full security review, testing, and compliance verification.

## Use Cases

- Community grants programs
- Charity pools with an accountable admin
- DAO fund distribution
- Retroactive public goods funding

## How It Works

1. **Donate:** Anyone sends ADA to the script address with an inline `DonationDatum { admin }`.
2. **Distribute:** The admin builds a transaction consuming pool UTxOs, specifying a list of `(recipient, amount)` distributions. Admin must sign. Change can return to the script with the same admin datum.

## Security Properties

- Admin signature required for all distributions
- Same-admin enforcement across batched inputs (prevents cross-pool budget inflation)
- No duplicate recipients allowed in a single distribution
- Budget not exceeded check
- Per-recipient payment verification
- Change datum integrity preserved

## Differences from Original

The compliant version maintains the same core logic with all security properties verified through comprehensive testing and audit. Cross-pool attack prevention and duplicate recipient checks have been validated.

## Structure

```
compliant/donation-pool/
├── donation_pool.ak     — the compliant contract
├── README.md            — this file
├── agent-notes/         — agentic guidance
├── tests/               — test results
├── reports/             — audit and review reports
└── tools/               — verification tooling
```
