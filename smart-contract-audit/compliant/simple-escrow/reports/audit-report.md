# Simple Escrow — Security Audit Report (v2)

**Date:** 2026-03-18
**Methodology:** v2 — cold read, behavioral/exploit split, live testnet exploitation
**Chain:** Vector Testnet

---

## Executive Summary

The Simple Escrow contract has a **Critical double satisfaction vulnerability** that was **exploited on the live Vector testnet**. The fix (`script_input_count == 1`) was applied and **verified on-chain** — the same attack TX was rejected by the compliant contract.

## Scope

- Contract: `simple_escrow.ak` — hash-locked escrow with Claim/Reclaim paths
- Operations reviewed: Claim (secret reveal before deadline), Reclaim (sender recovery after deadline)
- Testnet deployment: `addr1wyy922hxs80kd4upzm95u393ktvkfhdvxsmg6mfklax2h7sglxqqe`

## Findings

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| ESC-01 | Double satisfaction via `list.any` output matching | **Critical** | ✅ Fixed — `script_input_count == 1` |
| ESC-02 | Empty secret hash trivially claimable | Medium | Informational — off-chain validation |
| ESC-03 | Script credential as beneficiary/sender | Low | Informational — off-chain validation |
| ESC-04 | Deadline dead zone (1ms) | Low | By design |
| ESC-05 | Front-running blocked by signature | Informational | Not exploitable |

## Critical Finding: Double Satisfaction (ESC-01)

### Description
The contract uses `list.any(tx.outputs, ...)` to verify that the beneficiary/sender receives payment. When two escrow UTxOs are spent in the same transaction, both validator invocations find the same output. The attacker pays once but drains both UTxOs.

### On-Chain Proof

**Exploit TX:** [`5ada16bbc96247c277711e1c9fde1e48749ad8f9b8eff78fca3340222250afcf`](https://vector.testnet.apexscan.org/en/transaction/5ada16bbc96247c277711e1c9fde1e48749ad8f9b8eff78fca3340222250afcf)
- Inputs: 2 escrow UTxOs (10 + 7 AP3X)
- Output: 1 payment of 10 AP3X
- Result: 7 AP3X stolen

**Fix verification:** Same attack against compliant contract → `ValidationTagMismatch` (script rejected by `script_input_count == 1` guard)

### Fix Applied
```aiken
let script_input_count =
  list.count(tx.inputs, fn(i) { i.output.address == script_address })
expect script_input_count == 1
```

## Functionality Verification

- 17 behavioral tests pass on compliant version
- 7 exploit tests confirm vulnerabilities exist on original
- All intended operations (Claim, Reclaim) work correctly with single UTxO
- Deadline enforcement, signature checks, value preservation all unchanged

## Compliant Contract

- **Original hash:** `08552ae681df66d78116cb4e44b1b2d964ddac34368d6d36ff4cabfa`
- **Compliant hash:** `6f1cc128d2fdfa7c215261fa75a620c921f755c37e1221bfc54cdd92`
- **Compiled blueprint:** `deploy/simple-escrow/plutus.json`

## Recommendation

Deploy the compliant contract. Original contract UTxOs at the old script address should be drained (Claim/Reclaim individually) and new escrows created at the compliant address.
