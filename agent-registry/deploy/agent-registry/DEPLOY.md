# Agent Registry — Deployment Guide

## Current Version (Compliant)

- **Validator:** `registry.registry.spend` (multi-validator: mint + spend + else)
- **Script Hash:** `be1a0a2912da180757ed3cd61b56bb8eab0188c19dc3c0e3912d2c01`
- **Script Address (Vector testnet):** `addr1wxlp5z3fztdpsp6ha57dvx6khw82kqvgcxwu8s8rjykjcqghprf42`
- **Plutus Version:** V3
- **Status:** Audited (v2), compliant, deployed and verified on testnet
- **Fixes applied:** 11 findings resolved (2 Critical, 2 High, 3 Medium, 3 Low, 1 Info)

## Datum

```
AgentDatum {
  owner: Credential,
  name: ByteArray,
  description: ByteArray,
  capabilities: List<ByteArray>,
  framework: ByteArray,
  endpoint: ByteArray,
  registered_at: Int
}
```

## Redeemer

**Mint:** `Register { seed: OutputReference }` | `Burn`
**Spend:** `Update` | `Deregister`

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
2. Derive script address or use the Vector testnet address above
3. The script hash serves as both the minting policy ID and the payment credential
4. Asset name derivation: `blake2b_256(cbor_indefinite(OutputReference(seed)))`

**⚠️ Conway CBOR Note:** The Conway ledger uses indefinite-length CBOR arrays for
Plutus Data constructors. Off-chain asset name derivation must use `9F...FF` encoding,
not definite-length `82`. See testnet proof docs for details.

## Audit Evidence

See `../../compliant/reports/` for full audit trail.

## Testnet Proof

| Test | Result | TX Hash |
|------|--------|---------|
| Registration | ✅ Deployed | `9ccd924359267692aa6a698609a19280ca7a70fad51f2fb4f1a78e2c5758d79d` |
| AR-01 double satisfaction attack | ✅ Blocked | Evaluated & rejected by validator |
| AR-03 unauthorized burn attack | ✅ Blocked | Evaluated & rejected by validator |
| Legitimate Update | ✅ Passed | `4f2c31c48f16ac8f8e3b8b97fd972f7e05b1bb2032c64ac6acaa22f10de8352f` |

## Version History

| Version | Script Hash | Network | Date | Status | Notes |
|---------|-------------|---------|------|--------|-------|
| **v2 (current)** | `be1a0a2912da180757ed3cd61b56bb8eab0188c19dc3c0e3912d2c01` | Vector testnet | 2026-03-19 | ✅ Compliant | All 11 findings resolved, on-chain verified |
| v1 (original) | See `../../original/` | — | — | ⚠️ Vulnerable | 11 security findings — do not deploy |
