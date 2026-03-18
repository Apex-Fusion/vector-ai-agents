# Simple Escrow — Code Review (Delta Review)

**Date:** 2026-03-18
**Scope:** Review only what changed in the security fix

---

## Summary

One fix applied: `script_input_count == 1` guard. The fix is **sound** — minimal, targeted, and correctly eliminates the double satisfaction vector without affecting any other contract behavior.

## Fix Assessment

### script_input_count == 1

**What changed:**
```aiken
let script_address = own_input.output.address
let script_input_count =
  list.count(tx.inputs, fn(i) { i.output.address == script_address })
expect script_input_count == 1
```

**Assessment:**
- ✅ Correctly derives the script address from the own input (not hardcoded)
- ✅ Uses `list.count` which is straightforward and not gameable
- ✅ `expect script_input_count == 1` causes validation failure (not panic) if count != 1
- ✅ Placed before the Claim/Reclaim branch — applies to both paths
- ✅ `list.any` output matching is now safe — only one validator invocation per TX

**Trade-off:** Batch spending of multiple escrows in one TX is no longer possible. Each escrow requires its own transaction. This is the correct trade-off — security over convenience.

## New Issues Introduced

**None.** The fix adds a single constraint and doesn't modify any existing logic. All behavioral properties should be preserved:
- Claim with correct secret, before deadline, beneficiary signed → still works
- Reclaim after deadline, sender signed → still works
- All rejection cases → still rejected for the same reasons

## Edge Cases Checked

- **Single escrow spend:** `script_input_count == 1` → passes ✅
- **Two escrow spends:** `script_input_count == 2` → fails via `expect` ✅
- **Zero escrow inputs (shouldn't happen):** The spend validator only fires when the UTxO is being spent, so count is always >= 1
- **Staking credential variant:** An input at `Script(hash) + Some(staking_key)` has a different address than `Script(hash) + None`. If two inputs differ only by staking credential, `list.count` would see them as different addresses. In practice, escrow UTxOs are created at the bare script address (no staking credential), so this is not exploitable.

## Verdict

Fix is clean. Ready for build verification and final red team.
