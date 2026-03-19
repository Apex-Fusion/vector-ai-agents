# Smart Contract Audit Checklist — Explicit Doctrine

*Last updated: 2026-03-19*
*This checklist codifies patterns found in 5/5 audited contracts + extended audit pass (4 contracts × 10 classes). Always run in order.*

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

### 6. ⚠️ Arbitrary Datum Injection (Datum Pollution) — LOW-MEDIUM CLASS

**Status:** Found in donation-pool (EXT-F1), vesting (EXT-F2)

**The Pattern:**
```aiken
// Script accepts typed datum via auto-deserialization
spend(
  datum: Option<DonationDatum>,  // Fails on garbage datum
  redeemer: Redeemer,
  own_ref: OutputReference,
  tx: Transaction,
) { ... }
```

**Why it fails:** In eUTxO, **anyone can send a UTxO to any script address with any datum**. If an attacker sends a UTxO with a garbage datum (not the expected type), Aiken's typed datum parameter will fail to deserialize when anyone tries to spend it. The garbage UTxO becomes permanently unspendable via this validator. While it doesn't directly threaten legitimate UTxOs, it pollutes the script address with dust and requires off-chain filtering logic.

**The Fix:**
No on-chain fix exists — this is inherent to the eUTxO model. The mitigation is **off-chain awareness**:
```
// Off-chain: always filter UTxOs at the script address
// Attempt datum deserialization before including in TX
let valid_utxos = script_utxos.filter(u => deserializes_as::<ExpectedDatum>(u.datum))
```

**First-pass check protocol:**
1. Does the contract produce continuation or change outputs at the script address?
2. Does the contract ever batch-process multiple script UTxOs (e.g., `list.filter` over inputs at script address)?
3. If batch processing: is there a risk that a garbage-datum UTxO gets included and crashes the TX?
4. If `script_input_count == 1`: impact is minimal (garbage UTxOs are simply skipped individually)
5. If batch processing without datum pre-filtering: **MEDIUM finding** — document off-chain filtering requirement
6. If no continuation outputs at all: **N/A** — no script-address UTxOs to pollute

---

### 7. ⚠️ Continuation Output Value Leakage — HIGH CLASS

**Status:** Found in donation-pool (EXT-F3)

**The Pattern:**
```aiken
// DANGEROUS — checks budget ceiling but not value preservation
let distribution_within_budget = total_distributed <= total_input_lovelace
// Missing: no check that undistributed value is preserved as change
```

**Why it fails:** A contract that produces continuation/change outputs at the script address may validate the datum on those outputs but fail to enforce **value preservation**. The authorized party (e.g., admin) can distribute a small amount and let the remainder leak to an arbitrary address — effectively extracting undistributed funds without explicit authorization.

**The Fix:**
```aiken
// SAFE — enforce value preservation across continuation outputs
let total_change = list.foldl(change_outputs, 0, fn(o, acc) { acc + lovelace_of(o.value) })
expect total_distributed + total_change >= total_input_lovelace
```

**First-pass check protocol:**
1. Does the contract produce continuation or change outputs at the script address?
2. If yes: is the **value** of those outputs validated, not just the datum?
3. Specifically: does the sum of (distributed + change at script) account for the total input value?
4. If datum-only validation on change: **HIGH finding** — value can leak to arbitrary outputs
5. If no continuation outputs: **N/A**

---

### 8. ⚠️ UTxO Fragmentation (Unbounded Continuation Outputs) — MEDIUM CLASS

**Status:** Found in donation-pool (EXT-F4)

**The Pattern:**
```aiken
// DANGEROUS — no limit on number of change outputs
let change_outputs =
  list.filter(tx.outputs, fn(output) { output.address == script_address })
// Validates datum on each, but no count limit
let change_datum_valid = list.all(change_outputs, fn(output) { ... })
```

**Why it fails:** If a contract allows unbounded continuation outputs at the script address, an authorized party can fragment protocol state across many small UTxOs. Each fragment requires a separate transaction to consolidate, increasing operational cost and complexity. In extreme cases, fragmentation can make the protocol economically unviable (each UTxO requires min-ADA).

**The Fix:**
```aiken
// SAFE — bound continuation output count
let change_outputs =
  list.filter(tx.outputs, fn(output) { output.address == script_address })
expect list.length(change_outputs) <= 1  // Or the expected count for the protocol
```

**First-pass check protocol:**
1. Does the contract produce continuation or change outputs at the script address?
2. If yes: is the **count** of those outputs bounded?
3. If `script_input_count == 1` with a single pinned continuation: **Safe** (fragmentation impossible)
4. If `list.filter` over outputs at script address with no count limit: **MEDIUM finding**
5. Consider whether fragmentation is externally triggerable or admin-only (admin-only lowers severity to Low)
6. If no continuation outputs: **N/A**

---

### 9. ⚠️ Value Comparison Asymmetry (≥ vs ==) — HIGH CLASS

**Status:** Found in donation-pool (EXT-F5), pattern checked across all 4 contracts

**The Pattern:**
```aiken
// POTENTIALLY DANGEROUS — ≥ allows token stuffing on script outputs
expect lovelace_of(change_output.value) >= required_amount
// Missing: no check on native token composition of the output
```

**Why it fails:** Using `>=` (greater-than-or-equal) for value comparisons on outputs **returning to the script address** allows an attacker (or authorized party) to stuff arbitrary native tokens into those outputs. Since validators typically only track lovelace via `lovelace_of`, stuffed tokens become permanently locked — they satisfy the value check but are invisible to the spending logic. On PKH outputs (payments to wallets), `>=` is safe because the recipient can freely spend the extra tokens.

**The Fix:**
```aiken
// SAFE — validate value composition on script-bound outputs
// Option A: Ensure only ADA
expect list.length(assets.policies(change_output.value)) <= 1

// Option B: Exact value match
expect change_output.value == expected_value

// Note: ≥ is FINE for PKH-bound outputs (recipient can spend extras)
```

**First-pass check protocol:**
1. Identify all value comparisons using `>=`, `assets_gte`, or `lovelace_of(...) >=`
2. For each: does the compared output go to a **script address** or a **PKH address**?
3. If script address + `>=` with no token composition check: **HIGH finding** — tokens can be trapped
4. If PKH address + `>=`: **Safe** — recipient controls the output
5. If exact `==` comparison on script outputs: **Safe**
6. Check both lovelace and native token dimensions separately

---

## General Analysis (After First-Pass Clears)

Once the above 9 checks are complete and documented (finding or clear), proceed with:

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

---

## Applicability Matrix

Use this matrix to skip non-applicable checks based on contract architecture. This is the foundation for the "skip non-applicable checks" system — if a cell is N/A, the check can be safely skipped for that architecture type.

| Exploit Class | Single-validator spend | Multi-validator | Minting policy | Withdraw-zero / forwarding | Staking |
|---|---|---|---|---|---|
| EC-01: Double Satisfaction (`list.any`) | ✅ Always check | ✅ Always check | ⚠️ Check if present | ✅ Always check | N/A Not applicable |
| EC-02: Cross-Input Admin Consistency | ⚠️ Check if present | ✅ Always check | N/A Not applicable | ✅ Always check | N/A Not applicable |
| EC-03: Output-Index Pinning Sufficiency | ✅ Always check | ✅ Always check | N/A Not applicable | ⚠️ Check if present | N/A Not applicable |
| EC-04: Integer Arithmetic Edge Cases | ✅ Always check | ✅ Always check | ✅ Always check | ✅ Always check | ✅ Always check |
| EC-05: Token Identity Validation | ✅ Always check | ✅ Always check | ✅ Always check | ✅ Always check | ⚠️ Check if present |
| EC-07: Arbitrary Datum Injection | ⚠️ Check if present | ✅ Always check | N/A Not applicable | ✅ Always check | N/A Not applicable |
| EC-08: Continuation Value Leakage | ⚠️ Check if present | ✅ Always check | N/A Not applicable | ✅ Always check | N/A Not applicable |
| EC-10: UTxO Fragmentation | ⚠️ Check if present | ✅ Always check | N/A Not applicable | ✅ Always check | N/A Not applicable |
| EC-11: Value Comparison Asymmetry | ✅ Always check | ✅ Always check | ⚠️ Check if present | ✅ Always check | ⚠️ Check if present |

**Legend:**
- ✅ **Always check** — This exploit class is relevant regardless of specific features
- ⚠️ **Check if present** — Only relevant if the contract has continuation outputs, multi-input spending, or the relevant feature
- **N/A Not applicable** — Architecturally impossible for this contract type

**Usage:** Before running the checklist, classify the contract's architecture type(s). A contract may span multiple columns (e.g., a multi-validator protocol with a minting policy). If ANY applicable column shows ✅ or ⚠️, run the check.

---

## Check 10: Tautological Datum Validation — HIGH CLASS

**Status:** Found in payment-subscription (PSA-01). New pattern — not in original 9.

**The Pattern:**
```aiken
// DANGEROUS — comparing datum against struct built from its own fields
let value_new = extract_field(datum_new)
expect datum_new == DatumType { ..., field: value_new }
// This always passes — value_new comes FROM datum_new
```

**Why it fails:** When validating that an updated datum preserves certain fields from the *previous* state, extracting values from the *new* datum and comparing against itself is a tautology. The check always passes regardless of what the new datum contains. An attacker can rewrite any "preserved" field to any value.

**The Fix:**
```aiken
// CORRECT — compare new datum fields against OLD datum
let value_old = extract_field(datum_old)  // from the INPUT datum, before update
expect datum_new == DatumType { ..., field: value_old }
// Now it actually verifies the field was preserved
```

**First-pass check protocol:**
1. Find all datum update/continuation validation functions
2. For each: identify where values are extracted — from `datum_old` (input) or `datum_new` (output)?
3. If any "preservation" check extracts from `datum_new` and compares back to `datum_new`: **HIGH finding**
4. Check fold-based validation of list fields — does it validate the full list or only the appended portion?

**Applicability:** Any contract with datum continuation / state update logic.
