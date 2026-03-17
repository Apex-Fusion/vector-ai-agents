# Simple Escrow — Compliant Version

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21 | **Status:** Audit-passed

## Purpose

A hash-locked escrow that holds ADA with a secret-hash commitment. The beneficiary can claim by revealing the correct secret before a deadline. If the deadline passes unclaimed, the sender can reclaim.

This is the **audit-passed** version of the simple escrow contract, having gone through full security review, testing, and compliance verification.

## Use Cases

- Atomic swaps (reveal-secret pattern)
- Payment contingent on proof of knowledge
- Trustless two-party commitments

## How It Works

1. **Lock:** Sender deposits ADA at the script address with an inline datum containing: beneficiary PKH, sender PKH, deadline (POSIX ms), and `blake2b_256(secret)`.
2. **Claim:** Beneficiary reveals the secret pre-image before the deadline. Must sign the transaction and receive at least the locked value.
3. **Reclaim:** Sender takes back funds after the deadline passes. Must sign the transaction and receive at least the locked value.

## Security Properties

- Secret verification via `blake2b_256`
- Deadline enforcement via `is_entirely_before` / `is_entirely_after`
- Signature requirement for both paths
- Multi-asset value preservation via `assets_gte` check
- Output payment verification prevents value extraction

## Differences from Original

The compliant version maintains the same core logic as the original, with all security properties verified through testing and audit.

## Structure

```
compliant/simple-escrow/
├── simple_escrow.ak     — the compliant contract
├── README.md            — this file
├── agent-notes/         — agentic guidance
├── tests/               — test results
├── reports/             — audit and review reports
└── tools/               — verification tooling
```
