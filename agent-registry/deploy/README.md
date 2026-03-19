# Agent Registry — Compliant Deployment Files

Security-audited, compliant versions of the Agent Registry smart contracts ready for Vector/Cardano mainnet deployment.

## Files

| File | Description |
|------|-------------|
| `registry.ak` | Multi-validator entry point |
| `types.ak` | On-chain type definitions |
| `validation.ak` | Validation logic — all security fixes applied |

## Security Status

All 11 findings resolved (2 Critical, 2 High, 3 Medium, 3 Low, 1 Info acknowledged).
Full verification in `../compliant/reports/final-red-team-report.md`.

## On-Chain Constants

| Constant | Value |
|----------|-------|
| `min_deposit_lovelace` | `10_000_000` (10 AP3X) |
| `max_name_length` | `256` bytes |
| `max_description_length` | `1024` bytes |
| `max_capability_length` | `128` bytes |
| `max_capabilities_count` | `32` tags |
| `max_framework_length` | `128` bytes |
| `max_endpoint_length` | `512` bytes |

## Testnet

Testnet deployment TX hashes and script addresses are recorded in `../compliant/reports/deployment-validation.md`.

## Build

Place files in an Aiken project as:
- `validators/registry.ak`
- `lib/agent_registry/types.ak`
- `lib/agent_registry/validation.ak`

Then run `aiken build`.
