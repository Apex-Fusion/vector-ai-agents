# Smart Contract Audit Checklist — Explicit Doctrine

*Last updated: 2026-03-19*
*This checklist codifies patterns found in 5/5 audited contracts. Always run in order.*

---

## Pre-Analysis: First-Pass Checks (Run Before Everything Else)

These checks must happen before general analysis. They are not optional.

### 1. ⚠️ Double Satisfaction via `list.any` — CRITICAL CLASS

**Status:** Found in 5/5 audited contracts (simple-escrow, vesting, simple-dex × 2, donation-pool variant)

**The Pattern:**
```aiken
// DANGEROUS — vulnerable to double satisfaction
list.any(tx.outputs, fn(o) { o.address == beneficiary && o.value >= amount })
```

**Why it fails:** In eUTxO, multiple script inputs in a single TX each run their validator independently. If two inputs share a beneficiary address, both validators call `list.any` over `tx.outputs` and can find the **same output** — meaning attacker pays once, drains two UTxOs.

**The Fix:**
```aiken
// SAFE — input-output pairing enforced
let script_input_count =
  list.count(tx.inputs, fn(i) { i.output.address == script_address })
expect script_input_count == 1
```

**First-pass check protocol:**
1. Search for any use of `list.any`, `list.filter`, or iteration over `tx.outputs`
2. If found: does the validator pair inputs to outputs by index or enforce `script_input_count == 1`?
3. If no pairing: **CRITICAL finding, document immediately, halt general analysis, flag for the contract author**
4. If `script_input_count == 1` is present: verify it applies to the correct address (script's own address, not datum field)

---

### 2. Cross-Input Admin/Ownership Consistency — HIGH CLASS

**Status:** Found in donation-pool (DON-F1)

**The Pattern:**
```aiken
// DANGEROUS — checks only first input's admin
let admin = inputs |> list.head |> datum.admin
// ... uses this admin for all inputs without verifying consistency
```

**Why it fails:** When multiple script inputs are spent in one TX, each may have different datums (different admins, different pools). A validator that extracts admin from one input and applies it to all creates cross-pool attacks.

**First-pass check:**
1. Does the contract handle batch input spending?
2. If yes: are all datums checked for consistency across inputs (e.g., `list.all` with `all_same` predicate)?
3. If no consistency check: **HIGH finding**

---

### 3. Output-Index Pinning Sufficiency — CRITICAL CLASS

**Status:** Found in vesting v2 (VES-F1/F2 partial fix)

**The Pattern:**
```aiken
// INSUFFICIENT — two inputs can pin to same index
expect output_index == expected_index
// Missing: enforcement that each input maps to a unique output index
```

**Why it fails:** If two inputs both pin to index 0, they both pass — but there's only one output at index 0. This is a subtler form of double satisfaction.

**The fix:**
```aiken
// CORRECT — block multi-input spending entirely
let script_input_count =
  list.count(tx.inputs, fn(i) { i.output.address == script_address })
expect script_input_count == 1
// If multi-input IS intended, enforce unique index assignment per input
```

**First-pass check:**
1. Does the contract use output index pinning?
2. If yes: is `script_input_count == 1` enforced OR are unique indices guaranteed across inputs?
3. If neither: **CRITICAL finding**

---

### 4. Integer Arithmetic Edge Cases — HIGH CLASS

**Status:** Found in simple-dex (DEX-F2: `ceiling_div` with negative numerators)

**First-pass check:**
1. Identify all division operations (integer div, ceiling div, floor div)
2. Are they used with values that could be negative?
3. Aiken's `math.ceil_div` has undefined/wrong behavior for negative numerators
4. Any custom division helper: verify behavior at 0, negative, and overflow-adjacent values
5. If unsafe: **HIGH finding**

---

### 5. Token Identity Validation — MEDIUM CLASS

**Status:** Found in simple-dex (DEX-F3)

**First-pass check:**
1. Does the contract accept token policy IDs as parameters or datum fields?
2. Is there validation that policy IDs are the correct length (28 bytes / 56 hex chars)?
3. Empty string "" or zero-length bytearray matches ADA — can attacker substitute ADA for a token?
4. If no length validation: **MEDIUM finding**

---

## General Analysis (After First-Pass Clears)

Once the above 5 checks are complete and documented (finding or clear), proceed with:

1. **Datum validation** — are all datum fields validated on-chain, or trusted from off-chain?
2. **Staking credential handling** — are output addresses checked with staking credentials?
3. **Deadline/timing logic** — inclusive vs exclusive bounds, dead zones at exact milliseconds
4. **Redeemer validation** — can redeemers be omitted, substituted, or fuzzed?
5. **Native token tracking** — are ADA-only checks missing native token extraction risks?
6. **Fallback/else branches** — does the validator have a safe fallback for unexpected redeemers?
7. **`own_ref` typing** — is `own_ref` typed as `Data` requiring unsafe runtime cast?

---

## Finding Severity Reference

| Severity | Definition | Examples |
|----------|-----------|---------|
| Critical | Directly exploitable — funds drainable on mainnet | Double satisfaction via `list.any`, index pinning insufficient |
| High | Exploitable under specific conditions or attacker-controlled inputs | Cross-pool admin bypass, unsafe division |
| Medium | Design flaw that weakens guarantees but not directly drainable | Token identity confusion, missing validation |
| Low | Defense-in-depth gap, off-chain mitigations exist | Staking credential not checked, dead zone |
| Info | Style, best practice, or educational note | `own_ref as Data`, no `else` branch |

---

## Naming Convention in Audit Documents

**Rule: Use role-derived names only. No personal names (including placeholders like Alice/Bob/Eve).**

Role-based names carry meaning directly and eliminate ambiguity:

| Instead of | Use |
|------------|-----|
| Alice | Admin, Beneficiary, Sender, Recipient |
| Bob | Attacker, Adversary |
| Eve | Eavesdropper (or Attacker if active) |
| Carol | Validator, Deployer, Operator |

**Why:** "Attacker spends both inputs" conveys the threat model immediately. "Bob spends both inputs" requires the reader to recall which placeholder is adversarial. Role names also prevent accidental personal name leakage in public documents (the sanitization scan catches first names — role names are always safe).

This applies to: audit reports, code comments, test names, documentation examples.

---

## Doctrine Summary

**Core principle:** Every Aiken validator that iterates over `tx.outputs` with `list.any` or similar is **presumed vulnerable to double satisfaction** until proven otherwise. The proof must be one of:
- `script_input_count == 1` enforced for the script's own address
- Output-index pinning with guaranteed uniqueness across all script inputs

This is not a "common issue" — it is the **baseline assumption** for eUTxO validators. Found in 5 consecutive contracts. The correct answer is always `script_input_count == 1` unless the contract explicitly needs multi-input support, in which case unique index pairing must be formally verified.

---

*Patterns are living doctrine — update when new vulnerability classes are confirmed across 2+ contracts.*
