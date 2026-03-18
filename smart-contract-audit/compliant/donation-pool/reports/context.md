# Donation Pool — Research Context

**Date:** 2026-03-18

---

## 1. Protocol Summary

A donation pool contract on Vector (Cardano-compatible eUTXO). Anyone can donate AP3X by sending to the script address with an inline datum naming the admin. The admin can distribute funds to recipients in batch.

## 2. Architecture

Single spend validator, no mint handler. Operations:
- **Donate:** Send AP3X to script address with `DonationDatum { admin }` — no validator logic (just locking)
- **Distribute:** Admin spends pool UTxOs, specifying `Distribute { distributions: List<Distribution> }` — each distribution has `recipient` (PKH) and `amount` (lovelace)

Types:
- `DonationDatum { admin: ByteArray }` — just an admin PKH
- `Distribution { recipient: ByteArray, amount: Int }`
- `DonationRedeemer = Distribute { distributions: List<Distribution> }`

## 3. Validation Logic

The Distribute handler checks:
1. Admin signed the TX
2. Distributions list is non-empty
3. All amounts are positive
4. No duplicate recipients
5. All script inputs share the same admin (cross-pool protection)
6. Total distributed ≤ total input lovelace
7. Each recipient has an output with ≥ their stated amount (`list.any`)
8. Change outputs at script address preserve the admin datum

## 4. Risk Surface

| Area | Risk | Notes |
|------|------|-------|
| **`list.any` on recipient outputs** | **Critical** | Same double satisfaction pattern as escrow — one output can satisfy multiple distributions if recipients overlap across different pool UTxOs |
| **No `script_input_count` guard** | **High** | Multiple pool UTxOs can be spent in one TX — the contract explicitly supports batch spending |
| **Cross-UTxO output sharing** | **Critical** | Validator runs once per spent UTxO, each invocation checks the SAME output list — a single output can satisfy multiple invocations |
| **Admin is fully trusted** | Medium | Admin can distribute to themselves — by design, but worth noting |
| **No admin rotation** | Low | Can't change admin without moving funds |
| **ADA-only** | Low | Native tokens not tracked in distribution amounts |

## 5. Key Difference from Escrow

The donation pool is MORE complex than the escrow because it **intentionally supports batch spending** (multiple pool UTxOs in one TX). The `all_same_admin` check ensures all inputs have the same admin. But the `list.any` output check runs independently per validator invocation — two UTxOs with the same recipient in their distribution lists can share one output.

## 6. Testnet Context

- 1 live UTxO: 10 AP3X, admin `b3cbfe28...`
- Admin wallet key available at `workspace-apex/testnet/wallets/donation-admin-20260316-4/`
