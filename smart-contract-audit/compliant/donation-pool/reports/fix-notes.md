# Donation Pool — Fix Notes

**Date:** 2026-03-18
**Severity fixed:** Critical (double satisfaction + budget inflation)

---

## Vulnerability Summary

The original contract suffered from two related critical issues:

### 1. Double Satisfaction via `list.any`

Each validator invocation independently called `list.any(tx.outputs, ...)` to verify recipient payments. When two pool UTxOs (same admin) were spent in a single transaction with identical distribution redeemers, both invocations found the same outputs — satisfying both validators with a single set of recipient payments. The admin could drain two UTxOs while only paying recipients once.

**Attack example:**
- Two UTxOs: 10 ADA each (20 ADA total)
- Admin builds one TX spending both, with `Distribute { [Alice: 8 ADA] }`
- One output: 8 ADA to Alice
- Both validators check `list.any` → find Alice's 8 ADA output → ✅
- TX accepted: 20 ADA drained, only 8 ADA distributed, 12 ADA stolen

### 2. Budget Inflation via Multi-Input Summing

The `total_input_lovelace` check summed the lovelace across **all** script inputs in the transaction, not just the one being validated. With two 10 ADA UTxOs, each invocation saw a budget of 20 ADA — allowing a distribution of up to 20 ADA even though the admin only needed to provide 20 ADA in outputs for both UTxOs combined.

---

## Fix Applied

**Location:** After resolving `own_input` and `script_address`, before the distribution logic.

**Added (3 lines):**
```aiken
let script_input_count =
  list.count(tx.inputs, fn(i) { i.output.address == script_address })
expect script_input_count == 1
```

**Effect:**
1. **Double satisfaction prevented:** Only one UTxO from this script address is permitted per transaction. Each TX processes exactly one validator invocation, so `list.any` cannot be satisfied across two independent invocations.
2. **Budget check corrected:** With `script_input_count == 1`, `total_input_lovelace` always equals the single UTxO's value — no longer inflated by multi-input batching.
3. **All other logic preserved:** `admin_signed`, `no_duplicate_recipients`, `all_recipients_paid`, `change_datum_valid`, and the `all_same_admin` checks are unchanged.

**Note on redundant checks:** With `script_input_count == 1` enforced, `all_same_admin` is trivially satisfied (there is only one script input, so there is nothing to compare). It has been retained for defensive clarity — it costs nothing and documents intent.

---

## Files Changed

| File | Change |
|------|--------|
| `compliant/contracts/donation_pool.ak` | Added `script_input_count == 1` guard after `script_address` resolution |

## Files NOT Changed

All type definitions (`donation_types`), datum structures, redeemer shapes, and off-chain interfaces remain identical. This is a minimal, surgical fix.

---

## Test Cases to Add

1. **Double satisfaction blocked:** TX spending two pool UTxOs with same admin and same distribution → must fail at the second validator invocation
2. **Single UTxO distribution succeeds:** TX spending one UTxO, valid distribution → must pass
3. **Budget is per-UTxO:** Distribution total > single UTxO value must fail even if total across two UTxOs would have been sufficient
