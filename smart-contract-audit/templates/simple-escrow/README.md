# Simple Escrow — Template

> **Chain:** Vector / Cardano | **Language:** Aiken v1.1.21 | **Status:** Template (adapt for your use case)

## What Is This?

A hash-locked escrow contract template. Lock ADA with a secret-hash commitment; the beneficiary claims by revealing the secret before a deadline, or the sender reclaims after.

This is a starting point — adapt it for your project. See `agent-notes/` for deployment guidance and modification tips.

## Quick Start

```bash
# Copy to your Aiken project
cp simple_escrow.ak your-project/validators/
# Also copy the types file from the Aiken stdlib or define your own EscrowDatum/EscrowRedeemer

aiken build
aiken check
```

## Security Notes

⚠️ **This template has a known double satisfaction vulnerability.** For production use, add:

```aiken
let script_input_count =
  list.count(tx.inputs, fn(i) { i.output.address == script_address })
expect script_input_count == 1
```

This one-line fix is proven in the vesting and DEX contracts. See `agent-notes/` for details.

## Structure

```
templates/simple-escrow/
├── simple_escrow.ak     — the contract source
├── README.md            — this file
└── agent-notes/         — agentic guidance for using this template
    ├── deployment.md
    ├── parameters.md
    ├── integration.md
    ├── modifications.md
    └── gotchas.md
```

## Related

- `original/simple-escrow/` — the unmodified contract
- `compliant/simple-escrow/` — audit-passed version with full test suite and reports
