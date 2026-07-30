# Donation Pool — Template

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21 | **Status:** Template (adapt for your use case)

## What Is This?

An admin-controlled donation pool template. Anyone can donate AP3X; the admin distributes to recipients in batch operations.

This contract was hardened to prevent cross-pool budget inflation attacks through same-admin enforcement.

## Quick Start

```bash
cp donation_pool.ak your-project/validators/
# Also need donation_types.ak with DonationDatum, DonationRedeemer, Distribution
aiken build
aiken check
```

## Security Notes

✅ Key protections:
- Same-admin enforcement across batched inputs
- No duplicate recipients
- Change datum integrity preserved
- Budget not exceeded check

## Structure

```
templates/donation-pool/
├── donation_pool.ak     — the contract source
├── README.md            — this file
└── agent-notes/         — agentic guidance
    ├── deployment.md
    ├── parameters.md
    ├── integration.md
    ├── modifications.md
    └── gotchas.md
```
