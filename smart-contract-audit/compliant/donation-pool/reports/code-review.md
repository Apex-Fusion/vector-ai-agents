# Donation Pool — Code Review (Cold Read)

**Date:** 2026-03-18

---

## Executive Summary

The contract is well-structured with extensive validation. The author clearly thought about double satisfaction (explicitly mentioned in comments, implemented `all_same_admin` and `no_duplicate_recipients` guards). However, the core `list.any` output matching vulnerability remains — and it's more subtle here than in the escrow because the contract **intentionally supports multi-UTxO spending**.

The fundamental issue: each validator invocation independently checks `list.any(tx.outputs, ...)` for its distribution recipients. When two UTxOs are spent in the same TX with the same distribution list, both validator invocations find the same outputs — the admin pays once but both pools are drained.

## Per-Function Analysis

### Distribute handler

**Check 1 — Admin signed:** ✅ Correct. `list.has(tx.extra_signatories, d.admin)`.

**Check 2 — Non-empty distributions:** ✅ Correct.

**Check 3 — All positive amounts:** ✅ Correct.

**Check 3b — No duplicate recipients:** ✅ Good mitigation attempt. Prevents a single output from satisfying two entries in the SAME distribution list. But does NOT prevent the same output satisfying the same entry across TWO validator invocations (different UTxOs).

**Check 4 — All same admin:** ✅ Prevents cross-pool attacks. But same admin + same distributions = double satisfaction still possible.

**Check 5 — Budget check:** `total_distributed <= total_input_lovelace` — this sums ALL script inputs' lovelace. So if two UTxOs have 10 AP3X each, the budget is 20 AP3X. But the distribution list is per-redeemer, not per-TX. Each validator invocation sees the same total input (20 AP3X) and checks its own distribution list against it. If both use the same list totaling 15 AP3X, both pass (15 ≤ 20). But the admin only creates 15 AP3X of outputs, pocketing 5 AP3X.

Wait — actually, each validator invocation checks `total_distributed <= total_input_lovelace` where `total_input_lovelace` is the sum of ALL script inputs. So two UTxOs of 10 AP3X = 20 AP3X total. If the admin distributes 18 AP3X, both invocations see 18 ≤ 20 ✅. But the actual outputs only pay 18 AP3X once. The admin drains 20 AP3X of pool funds while only distributing 18 AP3X. 2 AP3X stolen.

**Check 6 — `list.any` recipient payment:** 🔴 **CRITICAL.** Same pattern as escrow. Each invocation finds the same outputs via `list.any`. No distinctness guarantee.

**Check 7 — Change datum integrity:** ✅ Correct. Change outputs must preserve admin.

### `resolve_output_datum`

Uses `expect InlineDatum(raw) = output.datum` — panics if no inline datum. This is correct for script outputs (which should always have inline datums) but could cause issues if a non-datum output is somehow at the script address.

## Intent vs Implementation Divergences

| # | Intent | Implementation | Severity |
|---|--------|---------------|----------|
| 1 | "Each consumed pool UTxO independently verifies" | Each invocation sees the SAME output list — no independence | **Critical** |
| 2 | Budget check uses total of ALL inputs | Admin can distribute less than the total, pocketing the difference across UTxOs | **Critical** |
| 3 | No duplicate recipients prevents double-count | Only within one redeemer, not across multiple invocations | **Medium** |
| 4 | Admin is authenticated | No credential type validation — script hash as admin = permanent lock | **Medium** |

## Attack Scenario

**Setup:** Two donation pool UTxOs, each with 10 AP3X, same admin.

**Attack:**
1. Admin builds TX spending both UTxOs
2. Redeemer for both: `Distribute { distributions: [{ recipient: Alice, amount: 8_000_000 }] }`
3. TX outputs: one output of 8 AP3X to Alice, change of 12 AP3X to admin's wallet
4. Both validator invocations:
   - Admin signed? ✅
   - Budget: 8 AP3X ≤ 20 AP3X total input ✅
   - Alice paid ≥ 8 AP3X? `list.any` finds the 8 AP3X output ✅
5. TX accepted. Admin spent 20 AP3X of pool funds, paid Alice 8 AP3X, kept 12 AP3X.

**If each UTxO was processed independently:** Admin should only be able to distribute up to 10 AP3X per UTxO. The budget check inflates the allowance by summing all inputs.

## Inputs for Test Writer

1. **Double satisfaction — two pool UTxOs, same distribution, one output set** (Critical)
2. **Budget inflation — total_input_lovelace sums all script inputs** (Critical)
3. **Script credential as admin — permanent lock** (Medium)
4. **Admin distributes to self** (Behavioral — by design)
5. **Empty distribution list fails** (Behavioral)
6. **Duplicate recipients fail** (Behavioral)
7. **Negative amounts fail** (Behavioral)
8. **Wrong signer fails** (Behavioral)
9. **Change output with wrong admin fails** (Behavioral)
10. **Cross-admin batching fails** (Behavioral — all_same_admin check)
