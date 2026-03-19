# Agent Registry — Deployment Guide

## Current Version (Compliant)

- **Validator:** `registry.registry.spend` (multi-validator: mint + spend + else)
- **Script Hash:** `be1a0a2912da180757ed3cd61b56bb8eab0188c19dc3c0e3912d2c01`
- **Script Address (Vector testnet):** `addr1wxlp5z3fztdpsp6ha57dvx6khw82kqvgcxwu8s8rjykjcqghprf42`
- **Plutus Version:** V3
- **Status:** Audited (v2), compliant — not yet deployed to testnet
- **Fixes applied:** 11 findings resolved (2 Critical, 2 High, 3 Medium, 3 Low, 1 Info)

## Datum

```
AgentDatum {
  owner: ByteArray,          // PKH of agent owner
  name: ByteArray,           // Agent name (max 256 bytes)
  description: ByteArray,    // Agent description (max 1024 bytes)
  capabilities: List<ByteArray>, // Capability tags (max 32, each max 128 bytes)
  framework: ByteArray,      // Framework identifier (max 128 bytes)
  endpoint: ByteArray,       // Agent endpoint URL (max 512 bytes)
  registered_at: Int,        // POSIX timestamp — immutable after registration
  deposit: Int               // Lovelace deposit (min 10_000_000)
}
```

## Redeemer

```
Register | Update | Deregister
```

## On-Chain Constants

| Constant | Value |
|----------|-------|
| `min_deposit_lovelace` | `10_000_000` (10 AP3X) |
| `max_name_length` | `256` bytes |
| `max_description_length` | `1024` bytes |
| `max_capability_length` | `128` bytes |
| `max_capabilities_count` | `32` |
| `max_framework_length` | `128` bytes |
| `max_endpoint_length` | `512` bytes |

## Deployment

1. Use `plutus.json` in this folder
2. Derive script address from hash or use the Vector testnet address above
3. The script hash serves as both the minting policy ID and the payment credential
4. No parameterization needed — the contract is self-referencing

## Audit Evidence

See `../../compliant/reports/` for full audit trail:
- `audit-report.md` — all 11 findings with reproductions and resolutions
- `final-red-team-report.md` — red team validation (0 bypasses found)
- `test-report.md` — full test suite results

## Version History

| Version | Script Hash | Network | Date | Status | Notes |
|---------|-------------|---------|------|--------|-------|
| **v2 (current)** | `be1a0a2912da180757ed3cd61b56bb8eab0188c19dc3c0e3912d2c01` | — | 2026-03-18 | ✅ Compliant | All 11 findings resolved |
| v1 (original) | See `../../original/contracts/agent-registry/plutus.json` | — | — | ⚠️ Vulnerable | 11 security findings — do not deploy |
