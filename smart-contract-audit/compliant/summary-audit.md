# Smart Contract Audit — Summary (v2 Update)

**Date:** 2026-03-18
**Methodology:** v2 — cold read, behavioral/exploit test split, live testnet exploitation
**Chain:** Vector Testnet (ApexFusion, Cardano-compatible eUTXO)

---

## Results Overview

| Contract | Critical | High | Medium | Low | Live Exploit | Fix Verified |
|----------|---------|------|--------|-----|-------------|-------------|
| **Simple Escrow** | 1 (double satisfaction) | — | — | 2 | ✅ TX `5ada16bb...` | ✅ Blocked on compliant |
| **Donation Pool** | 1 (double satisfaction + budget inflation) | — | — | 1 | ✅ TX `872a5537...` | ✅ Blocked on compliant |
| **Vesting** | — | — | — | 5 (all informational) | N/A — well-defended | N/A |
| **Simple DEX** | — | — | 1 (structural) | 4 (informational) | N/A — well-defended | N/A |

## Key Finding: Double Satisfaction via `list.any`

The dominant vulnerability across the contract set is **double satisfaction** caused by using `list.any` for output matching without a single-script-input guard.

**Root cause:** In eUTXO, when multiple UTxOs at the same script address are spent in one transaction, the validator runs once per input. Each invocation sees the same output list. `list.any` finds the first matching output — but provides no guarantee that each invocation finds a *different* output. One output satisfies all invocations.

**Fix:** `script_input_count == 1` — count inputs from the script address, require exactly one. Prevents multiple validator invocations in the same TX.

| Contract | Had `script_input_count`? | `list.any` in output matching? | Exploitable? |
|----------|--------------------------|-------------------------------|-------------|
| Simple Escrow | ❌ No | ✅ Yes | **Yes — proven on-chain** |
| Donation Pool | ❌ No | ✅ Yes | **Yes — proven on-chain** |
| Vesting | ✅ Yes | No (index pinning) | No |
| Simple DEX | ✅ Yes | No (index pinning) | No |

## Live Testnet Evidence

### Simple Escrow Attack
- **Attack TX:** `5ada16bbc96247c277711e1c9fde1e48749ad8f9b8eff78fca3340222250afcf`
- **Method:** Spent 2 escrow UTxOs (10 + 7 AP3X) with Reclaim, created ONE output (10 AP3X)
- **Stolen:** 7 AP3X
- **Fix verification:** Same attack against compliant contract → `ValidationTagMismatch` (script rejected)

### Donation Pool Attack
- **Attack TX:** `872a5537a9422bdf468ab83c041a3e743b697838b08777d48c5d8d24ce87fa86`
- **Method:** Spent 2 pool UTxOs (10 + 7 AP3X) with Distribute (8 AP3X to recipient), kept 9 AP3X
- **Stolen:** 9 AP3X (pool distributed 8, should have distributed 16)
- **Fix verification:** Same attack against compliant contract → `ValidationTagMismatch` (script rejected)

## Compliant Contract Hashes

| Contract | Original Hash | Compliant Hash | Changed? |
|----------|--------------|----------------|----------|
| Simple Escrow | `08552ae6...` | `6f1cc128...` | ✅ Yes (fix applied) |
| Donation Pool | `34c4cca4...` | `02335d39...` | ✅ Yes (fix applied) |
| Vesting | `5e84a9e0...` | `5e84a9e0...` | No (already secure) |
| Simple DEX | `a30e2317...` | `a30e2317...` | No (already secure) |

## Documentation

See `docs/` for comprehensive security documentation:
- UTxO Attack Vectors for AI Agent Developers
- UTxO Attack Surface Analysis
- Aiken Smart Contract Security Checklist
- eUTXO Security Patterns
- Smart Contract Audit Methodology
- Smart Contract Testing on Vector
