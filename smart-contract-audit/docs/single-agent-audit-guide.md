# Single-Agent Smart Contract Audit Guide

## Aiken / eUTxO Security Audit — Apex v2 Methodology

> **Purpose:** This document enables any capable AI agent (Claude, Codex, etc.) to perform a structured security audit of an Aiken smart contract targeting Cardano or a Cardano-based chain (e.g., Vector). Follow the steps sequentially. Each step has a clear input, action, and output.
>
> **Scope:** Aiken validators using Plutus V3 on eUTxO chains.
>
> **What you will learn from this guide:** A 5-phase audit methodology covering 10 check classes — 6 first-pass critical checks (double satisfaction, output-index pinning, cross-input consistency, integer arithmetic, token identity, and tautological datum validation) plus 4 full-scan categories (datum integrity, value preservation, authorization, and timing). You will learn to identify, test, verify fixes for, and report on each class.
>
> **No prior knowledge of the methodology's origin is required.** Everything you need is in this document.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Phase 1: Static Analysis](#2-phase-1-static-analysis)
3. [Phase 2: Test Writing](#3-phase-2-test-writing)
4. [Phase 3: Fix Verification](#4-phase-3-fix-verification)
5. [Phase 4: Testnet Verification (Optional)](#5-phase-4-testnet-verification-optional)
6. [Phase 5: Audit Report](#6-phase-5-audit-report)
7. [Appendix A: Severity Reference Table](#appendix-a-severity-reference-table)
8. [Appendix B: Common Aiken Pitfalls](#appendix-b-common-aiken-pitfalls)
9. [Appendix C: Audit Report Template](#appendix-c-audit-report-template)

---

## 1. Prerequisites

Before starting, ensure you have:

### Tools

| Tool | Purpose | Install |
|------|---------|---------|
| **Aiken CLI** ≥ v1.1.21 | Compile and test Aiken contracts | `curl -sSfL https://install.aiken-lang.org \| bash` |
| **File access** | Read the contract source code | Local filesystem or git clone |
| **Text editor / agent workspace** | Write findings, tests, and report | Any |

### Contract Source

You need the full Aiken project directory containing:
- `validators/*.ak` — the validator(s) under audit
- `lib/*.ak` — type definitions and helper functions
- `aiken.toml` — project configuration

Verify the project compiles:
```bash
cd <project-dir>
aiken build
aiken check  # run existing tests, if any
```

### Optional (for Phase 4)

- **PyCardano** or **cardano-cli** — for building and submitting transactions
- **Ogmios / Koios** — for querying chain state
- **Testnet access** — endpoint URLs for the target chain

### What You're Looking For

Your job is to find vulnerabilities — ways an attacker could steal funds, manipulate state, or violate the contract's intended behavior. You are adversarial. Assume the attacker knows everything about the contract and has unlimited resources to craft malicious transactions.

---

## 2. Phase 1: Static Analysis

This phase is pure code reading. No tests, no deployment. Read the contract and systematically check for known vulnerability classes.

### Step 1.1: Understand the Contract Intent

**Input:** Validator source code, type definitions, any documentation or comments.

**Action:**
1. Read every `.ak` file in `validators/` and `lib/`
2. Identify: What does this contract do? What are the redeemer actions? Who are the parties (maker/taker, admin/user, beneficiary/depositor)?
3. Map the UTxO flow: What goes in? What comes out? Who signs?
4. Document the datum fields — what state does each UTxO carry?
5. Document each redeemer action — what conditions must hold?

**Output:** A brief summary (5-15 lines) of the contract's purpose, parties, datum, redeemer actions, and expected UTxO flow. Write this down — you'll need it for the report.

**Why:** You can't find bugs in code you don't understand. The intent document is your reference for "what should happen" — deviations from it are findings.

---

### Step 1.2: First-Pass Critical Checks (MANDATORY — Do These Before Anything Else)

These checks catch the most common and most severe eUTxO vulnerabilities. They cover 10 check classes across first-pass critical analysis and full vulnerability scanning. The first-pass checks below are ordered by historical frequency and severity. **Do not skip any.**

#### Check 1: Double Satisfaction via `list.any` — CRITICAL CLASS

**What it is:** In eUTxO, when a transaction spends multiple UTxOs from the same script address, each UTxO's validator runs independently. If a validator uses `list.any(tx.outputs, ...)` to verify that some output meets a condition (e.g., "an output pays the beneficiary"), then two validators can both find the **same** output and both pass — even though only one payment was made.

**This is the #1 vulnerability in eUTxO contracts.** It has been found in 5 out of 5 consecutively audited contracts during development of this methodology.

**How to check:**
1. Search the validator for `list.any`, `list.filter`, `list.find`, or any iteration over `tx.outputs`
2. If found: does the validator enforce that only one script input exists in the transaction?
3. Look for this pattern (or equivalent):
   ```aiken
   let script_input_count =
     list.count(tx.inputs, fn(i) { i.output.address == script_address })
   expect script_input_count == 1
   ```
4. If this guard is **missing** and the validator iterates over outputs: **CRITICAL finding.**

**Vulnerable code example:**
```aiken
// ❌ VULNERABLE — both validators find the same output
let pays_beneficiary =
  list.any(tx.outputs, fn(o) {
    o.address.payment_credential == VerificationKey(d.beneficiary)
    && assets_gte(o.value, d.amount)
  })
expect pays_beneficiary
```

**Attack scenario:**
```
Transaction with 2 script inputs (both have same beneficiary):
  Input A (100 ADA): validator finds output[0] paying 100 ADA → PASS ✓
  Input B (100 ADA): validator finds output[0] paying 100 ADA → PASS ✓

  Attacker creates only ONE output paying 100 ADA.
  Attacker receives 200 ADA from both inputs, pays only 100 ADA.
  Profit: 100 ADA stolen.
```

**Safe code example:**
```aiken
// ✅ SAFE — only one script input allowed per transaction
let script_input_count =
  list.count(tx.inputs, fn(i) { i.output.address == script_address })
expect script_input_count == 1

// Now list.any is safe because there's only one validator instance
let pays_beneficiary =
  list.any(tx.outputs, fn(o) {
    o.address.payment_credential == VerificationKey(d.beneficiary)
    && assets_gte(o.value, d.amount)
  })
expect pays_beneficiary
```

**Why `script_input_count == 1` works:** Both validator instances see the same `tx.inputs`. If the count is 2, both validators abort. The attacker cannot satisfy one while failing the other — they share the same view. Geometrically impossible to exploit.

**Trade-off:** This prevents batching multiple script inputs in one transaction. For most contracts, this is acceptable. If batching is genuinely needed, each input must be paired to a unique output index with cross-input uniqueness enforcement.

---

#### Check 2: Output-Index Pinning Sufficiency — CRITICAL CLASS

**What it is:** Some contracts try to fix double satisfaction by having the redeemer specify which output index "belongs" to this input (e.g., `Take { maker_output_index: 1 }`). This is **insufficient alone** — two inputs can both specify `index: 0` and share the same output.

**How to check:**
1. Does the contract use output index pinning (redeemer contains an output index)?
2. If yes: is `script_input_count == 1` ALSO enforced?
3. If only index pinning without single-input enforcement: **CRITICAL finding.**

**Why index pinning alone fails:** Each validator runs independently and reads its own redeemer. Two redeemers can both specify `maker_output_index: 0`. There is no cross-input coordination.

---

#### Check 3: Cross-Input Admin/Ownership Consistency — HIGH CLASS

**What it is:** When a validator aggregates values or budgets from multiple script inputs, it must verify that ALL inputs belong to the same logical owner/admin/pool. Otherwise, an attacker can include their own low-value inputs to inflate a budget computed from the aggregate.

**How to check:**
1. Does the contract handle multiple script inputs in one transaction?
2. If yes: does it aggregate values, compute budgets, or combine resources from multiple inputs?
3. Are all inputs verified to share the same admin/owner/authority?
4. Look for: `list.all(script_inputs, fn(i) { datum(i).admin == expected_admin })`
5. If no consistency check: **HIGH finding.**

**Attack example:**
```
Pool A (admin=Admin, 100 ADA) — legitimate pool
Pool B (admin=Attacker,    10 ADA) — attacker's own pool

Attacker spends both in one TX, signs with his key.
Validator computes budget = 110 ADA from aggregate.
Attacker distributes 110 ADA, draining Admin's 100 ADA.
```

---

#### Check 4: Integer Arithmetic Edge Cases — HIGH CLASS

**What it is:** Aiken uses arbitrary-precision integers, but division is still integer division with truncation toward zero. Custom `ceiling_div` implementations are common and often buggy.

**How to check:**
1. Search for all division operations: `/`, `ceiling_div`, `floor_div`, any custom division
2. For each: what are the possible input ranges? Can `a` be negative? Can `b` be zero?
3. Aiken's built-in `math.ceil_div` has undefined behavior for negative numerators
4. Does the function have explicit guards (`expect a >= 0`, `expect b > 0`)?
5. If no guards on division with potentially unsafe inputs: **HIGH finding.**

**Vulnerable:**
```aiken
// ❌ No guards — unsafe for negative a
fn ceiling_div(a: Int, b: Int) -> Int {
  let q = a / b
  if q * b == a { q } else { q + 1 }
}
```

**Safe:**
```aiken
// ✅ Explicit preconditions
fn ceiling_div(a: Int, b: Int) -> Int {
  expect a >= 0
  expect b > 0
  let q = a / b
  if q * b == a { q } else { q + 1 }
}
```

---

#### Check 5: Token Identity Validation — MEDIUM CLASS

**What it is:** Native tokens on Cardano are identified by `(policy_id, asset_name)`. Policy IDs are always exactly 28 bytes (Blake2b-224). ADA uses empty bytes `#""`. If a validator accepts arbitrary-length byte arrays as policy IDs, confusion attacks become possible.

**How to check:**
1. Does the contract accept policy IDs from datum fields or parameters?
2. Is there length validation: `bytearray.length(policy_id) == 28 || policy_id == #""`?
3. If no validation: **MEDIUM finding.**

---

#### Check 6: Tautological Datum Validation — HIGH CLASS

**What it is:** When a contract updates its datum (state continuation), it must verify that certain fields are preserved from the **old** datum. A tautological check extracts a field from the **new** datum and compares it back against the new datum — this always passes, regardless of what the attacker put in the output datum. Any "preserved" field can be silently rewritten.

**How to check:**
1. Find all datum update / continuation validation functions
2. For each preservation check: identify where values are extracted — from `datum_old` (the input datum) or `datum_new` (the output datum)?
3. If any "preservation" check extracts from `datum_new` and compares back to `datum_new`: **HIGH finding**
4. Check fold-based validation of list fields — does it validate the full list or only the appended portion?

**Vulnerable code example:**
```aiken
// ❌ TAUTOLOGICAL — comparing datum_new against a struct built from its own fields
let beneficiary = datum_new.beneficiary
let total = datum_new.total
expect datum_new == SubscriptionDatum {
  beneficiary: beneficiary,   // extracted FROM datum_new — always matches
  total: total,               // extracted FROM datum_new — always matches
  last_claimed: new_timestamp,
}
// Attacker can change beneficiary and total to anything — check always passes
```

**Attack scenario:**
```
Original datum: { beneficiary: Beneficiary, total: 1000 ADA, last_claimed: t0 }

Attacker builds a transaction that updates the datum to:
  { beneficiary: Attacker, total: 1000 ADA, last_claimed: t1 }

The validator extracts beneficiary from the NEW datum (Attacker),
then checks datum_new.beneficiary == Attacker → True ✓

Attacker is now the beneficiary. Next claim sends funds to Attacker.
```

**Safe code example:**
```aiken
// ✅ CORRECT — compare new datum fields against the OLD datum (from spent input)
let beneficiary = datum_old.beneficiary   // from the INPUT, committed on-chain
let total = datum_old.total               // from the INPUT, committed on-chain
expect datum_new == SubscriptionDatum {
  beneficiary: beneficiary,   // must match the original — cannot be changed
  total: total,               // must match the original — cannot be changed
  last_claimed: new_timestamp,
}
```

**Why this works:** The old datum comes from the spent input, which is committed on-chain and cannot be forged by the transaction builder. By comparing new fields against old fields, the validator ensures genuine preservation.

**Applicability:** Any contract with datum continuation / state update logic. Particularly common in subscription, vesting, and escrow contracts where state evolves across transactions.

---

### Step 1.3: Full Vulnerability Scan

After the first-pass checks, systematically review the remaining categories:

#### 1.3.1: Datum Integrity
- Is the datum read from the **spent input** (safe) or from the transaction body / redeemer (unsafe)?
- Look for the `own_ref` pattern: `expect Some(own_input) = find_input(tx.inputs, own_oref)`
- If there's a continuation UTxO (script output that carries forward state), is its datum compared **field-by-field** against the expected values?
- Can a malicious datum on a change output alter future contract behavior?

**Safe pattern:**
```aiken
// Read datum from the spent input — cannot be substituted
expect Some(own_input) = list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
expect InlineDatum(raw_datum) = own_input.output.datum
expect datum: MyDatum = raw_datum
```

**Continuation datum verification:**
```aiken
// Full field comparison — not just hash
expect cont_datum.beneficiary == d.beneficiary
  && cont_datum.total == d.total
  && cont_datum.cliff == d.cliff
  && cont_datum.end == d.end
```

#### 1.3.2: Value Preservation
- Is the full input value accounted for in outputs?
- Is `assets_gte` (or multi-asset comparison) used, not just lovelace?
- For partial claims (e.g., vesting): is `locked - claimed == continuation_value` verified?
- Can native tokens be silently extracted?

#### 1.3.3: Authorization
- Is the correct key checked in `tx.extra_signatories`?
- Is the key taken from the **datum** (safe) or the **redeemer** (unsafe — attacker-controlled)?
- Could an attacker substitute their own key?

#### 1.3.4: Timing Logic (if applicable)
- Is `is_entirely_before` / `is_entirely_after` used instead of simple comparison?
- Is the lower bound extracted conservatively?
- Is a finite lower bound **required** (validator aborts if not present)?
- Is there a dead zone at the exact deadline millisecond?

#### 1.3.5: Staking Credentials
- When checking output addresses, is only the payment credential checked, or also the staking credential?
- If staking credential is unchecked: an attacker can redirect staking rewards. Usually **Low** severity.

#### 1.3.6: Edge Cases
- What happens with empty lists, zero amounts, or boundary values?
- Does the validator have a fallback `else` branch for unexpected redeemers?
- Is `own_ref` typed as `Data` requiring an unsafe runtime cast?

### Step 1.4: Document All Findings

**Output:** A findings table with the following columns:

| ID | Finding | Severity | Details |
|----|---------|----------|---------|
| F1 | [name] | Critical/High/Medium/Low/Info | [explanation + attack scenario if applicable] |

Use the [Severity Reference Table](#appendix-a-severity-reference-table) for classification.

---

## 3. Phase 2: Test Writing

Tests serve two purposes: (1) verify the contract works correctly for legitimate use, and (2) prove that discovered vulnerabilities are real or that fixes block them.

### Step 2.1: Behavioral Tests (Happy Path)

**Input:** Contract source + your intent summary from Step 1.1.

**Action:** Write tests that verify the contract works as intended for every redeemer action.

**Structure:**
```aiken
test happy_take() {
  // Setup: create a valid script UTxO with proper datum
  // Action: build a transaction that takes the offer legitimately
  // Assert: transaction validates successfully
}

test happy_cancel() {
  // Setup: create a valid script UTxO
  // Action: maker signs and reclaims
  // Assert: transaction validates successfully
}
```

**What to cover:**
- Each redeemer action succeeds with valid inputs
- Edge cases: minimum amounts, exact deadlines, boundary values
- Each datum field is used correctly

**Why:** If you can't show the contract works for legitimate use, you can't meaningfully test for attacks. These are your baseline.

### Step 2.2: Security Tests (Each Finding)

**Input:** Your findings table from Step 1.4.

**Action:** For each finding, write at least one test that demonstrates the vulnerability (or confirms it's blocked).

**Structure for exploit tests:**
```aiken
test exploit_double_satisfaction() fail {
  // Setup: create TWO script UTxOs with same beneficiary
  // Action: build a TX spending both, with only ONE output paying beneficiary
  // Expected: transaction FAILS (validator rejects via script_input_count check)
  // If this test passes (validator accepts): the vulnerability is real!
}
```

**Important:** In Aiken tests, use `test name() fail` to assert that a transaction should be rejected. If a `fail` test passes, it means the validator correctly rejected the malicious transaction. If it fails (validator accepted), the vulnerability is real.

**What to cover per finding:**
- **Critical/High:** At least 2 tests — one showing the attack fails, one showing the exact attack vector
- **Medium:** At least 1 test
- **Low/Info:** Optional but recommended

### Step 2.3: Fuzz Tests (If Time Permits)

**Input:** Contract validator functions.

**Action:** Write property-based tests with randomized inputs. Aiken supports property tests via the `fuzz` module.

**Key properties to fuzz:**
- Math functions produce correct results for all valid inputs
- Validators reject all invalid redeemers
- Authorization checks hold for random signatories
- Value calculations never produce negative results

```aiken
test prop_ceiling_div_always_gte_true_division(a via fuzzer.int(), b via fuzzer.int()) {
  if a >= 0 && b > 0 {
    let result = ceiling_div(a, b)
    result * b >= a  // ceiling is always >= true value
  } else {
    True  // skip invalid inputs
  }
}
```

### Step 2.4: Run All Tests

```bash
aiken check
```

**Output:** Full test results — all pass/fail with counts.

**If any exploit test shows the vulnerability is real (the `fail` test itself fails):** Stop. The contract has a confirmed vulnerability. Document it clearly and proceed to Phase 3.

---

## 4. Phase 3: Fix Verification

This phase applies only if findings were reported and fixes were implemented.

### Step 3.1: Review the Fix

**Input:** The modified contract source after fixes.

**Action:**
1. Read the diff between the original and fixed code
2. Verify the fix addresses the **root cause**, not just the symptom
3. Check that the fix doesn't introduce new issues
4. Re-run all first-pass checks (Step 1.2) on the fixed code

**Common fix patterns:**

| Vulnerability | Correct Fix | Incorrect Fix |
|--------------|-------------|---------------|
| Double satisfaction | `script_input_count == 1` | Output-index pinning alone |
| Cross-pool inflation | `all_same_admin` check on all inputs | Check only first input |
| Unsafe division | `expect a >= 0; expect b > 0` guards | Upstream validation only |
| Token identity | Length validation `== 28 \|\| == #""` | No validation |

### Step 3.2: Re-run Tests

```bash
aiken check
```

**Verify:**
1. All previous behavioral tests still pass (no regression)
2. All exploit tests now correctly reject attacks (the `fail` tests pass)
3. No new test failures

### Step 3.3: Additional Fix-Specific Tests

Write new tests specifically targeting the fix:

```aiken
test fix_blocks_double_satisfaction() fail {
  // The exact attack scenario from the finding
  // Should fail (be rejected) after fix
}

test fix_preserves_normal_operation() {
  // Normal operation still works after fix
}
```

### Step 3.4: Sign Off or Request Further Changes

**Output:** For each finding, document one of:
- **Fixed ✅** — the fix is correct and complete, tests confirm
- **Partially Fixed** — the fix addresses some but not all aspects
- **Not Fixed** — the vulnerability remains
- **Accepted** — the development team acknowledges the risk but won't fix (document their rationale)

---

## 5. Phase 4: Testnet Verification (Optional)

This phase deploys the contract to a testnet and attempts real on-chain exploitation. It's the strongest form of validation but requires chain access.

### Step 4.1: Deploy the Contract

**Input:** Compiled contract (from `aiken build`), testnet endpoints.

**Action:**
1. Build the contract: `aiken build` → produces `plutus.json`
2. Extract the compiled validator and compute the script address
3. Create a funding transaction to send test tokens to the script address with a valid datum
4. Submit and confirm on-chain

**Tools:** PyCardano or cardano-cli for transaction construction, Ogmios/Koios for chain queries.

### Step 4.2: Execute Normal Operations

Verify each redeemer action works on-chain:
- Submit legitimate transactions for each action (take, cancel, claim, etc.)
- Confirm they succeed

### Step 4.3: Attempt Exploits

For each finding from Phase 1:
1. Construct the exact attack transaction described in the finding
2. Submit it to the testnet
3. Document the result:
   - **TX rejected by validator:** Fix confirmed on-chain ✅
   - **TX accepted:** Vulnerability confirmed on-chain ❌ — escalate immediately

### Step 4.4: Document Results

Record each on-chain test with:
- Transaction hash (or rejection error)
- UTxO references used
- Expected vs. actual outcome

---

## 6. Phase 5: Audit Report

### Step 5.1: Compile the Report

Use the template in [Appendix C](#appendix-c-audit-report-template). Fill in every section.

### Step 5.2: Quality Checks

Before finalizing, verify:

- [ ] Every first-pass check (Step 1.2) has a documented result (finding or "clear")
- [ ] Every finding has a severity, status, and explanation
- [ ] Every Critical/High finding has at least one test proving it
- [ ] The test results section shows exact pass/fail counts
- [ ] The overall verdict is justified by the findings
- [ ] No false positives — each finding includes the actual vulnerable code

### Step 5.3: Deliver

The report is your deliverable. It should be understandable by a developer who didn't participate in the audit.

---

## Appendix A: Severity Reference Table

| Severity | Definition | Examples | Action Required |
|----------|-----------|---------|-----------------|
| **Critical** | Directly exploitable — funds can be drained on mainnet with no preconditions beyond crafting a transaction | Double satisfaction via `list.any`; insufficient output-index pinning | Must fix before deployment. Block deployment until resolved. |
| **High** | Exploitable under specific but realistic conditions, or attacker-controlled inputs can cause incorrect behavior | Cross-pool budget inflation; unsafe `ceiling_div` with no guards | Should fix before deployment. Document risk if accepted. |
| **Medium** | Design flaw that weakens security guarantees but is not directly fund-draining | Token identity confusion (wrong-length policy ID accepted); missing input validation | Recommended fix. Acceptable with documented rationale. |
| **Low** | Defense-in-depth gap; off-chain mitigations exist or exploitation requires unlikely conditions | Staking credential not validated; timing dead zone at exact millisecond | Optional fix. Note for future versions. |
| **Info** | Code style, best practice, or educational observation with no security impact | `own_ref` typed as `Data`; no `else` fallback branch; missing comments | No action required. Informational only. |

---

## Appendix B: Common Aiken Pitfalls

### B.1: The `list.any` Trap

**Frequency:** Found in 5/5 consecutively audited contracts during methodology development.

The eUTxO model means multiple validators run independently in the same transaction. Any use of `list.any(tx.outputs, ...)` to verify an output exists is a double-satisfaction vector unless guarded by `script_input_count == 1`.

**Rule of thumb:** If you see `list.any`, `list.filter`, or `list.find` operating on `tx.outputs` in a validator, it's **presumed vulnerable** until you find the single-input guard.

### B.2: `ceiling_div` and Integer Math

Aiken has no floating-point numbers. All math is integer. When contracts need ceiling division (common in exchange rate calculations), custom implementations often lack input guards.

Key points:
- Aiken's `/` truncates toward zero
- `ceiling_div(a, b)` should always have `expect a >= 0; expect b > 0`
- Rounding direction matters for security: round **against the user, in favor of the protocol**
- Example: exchange rates should round UP for the buyer (they pay slightly more), protecting the seller

### B.3: Token Identity Confusion

Cardano native tokens are identified by `(policy_id, asset_name)`:
- `policy_id` is always exactly 28 bytes (Blake2b-224 hash)
- Exception: ADA uses `policy_id = #""` (empty bytes)
- Any other length is invalid

Always validate: `bytearray.length(pid) == 28 || pid == #""`

### B.4: Staking Credential Leakage

When a validator checks "does this output pay address X?", it typically only checks the payment credential:
```aiken
output.address.payment_credential == VerificationKey(pkh)
```

This ignores the staking credential. An attacker can create an output that pays the right payment credential but attaches their own staking credential, redirecting staking rewards to themselves. Usually **Low** severity since funds are still accessible, but staking rewards are lost.

### B.5: Datum Source

The datum must come from the **spent input** (which is committed on-chain and cannot be forged), not from the transaction body or redeemer (which are attacker-controlled).

**Safe:**
```aiken
expect Some(own_input) = list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
expect InlineDatum(raw) = own_input.output.datum
expect d: MyDatum = raw
```

**Unsafe:** Accepting datum from a redeemer field or resolving it from `tx.datums`.

### B.6: Continuation Datum Hijacking

If a contract produces a "continuation UTxO" (output back to the script address carrying updated state), the datum on that output must be validated field-by-field. An attacker building the transaction can attach any datum they want to the output. If the validator doesn't check, the attacker can change the beneficiary, amount, admin, or any other field.

### B.7: Timing Pitfalls

- Use `is_entirely_before` / `is_entirely_after` for deadline checks (not simple `<` / `>`)
- Always require a **finite** lower bound: `expect Finite(lower) = tx.validity_range.lower_bound.bound_type`
- Be aware of dead zones: what happens at the exact deadline millisecond? Usually **Info** severity.

### B.8: Tautological Datum Validation

When a contract updates state via datum continuation, preservation checks must compare the **new** datum's fields against the **old** datum (from the spent input). A common mistake is extracting a field from the new datum and comparing it back to itself — this is a tautology that always passes.

**Red flag pattern:** `let x = datum_new.field; expect datum_new == Type { field: x, ... }`

**Correct pattern:** `let x = datum_old.field; expect datum_new == Type { field: x, ... }`

This applies especially to fold-based list validation — if only appended elements are validated while the full list is accepted unchecked, an attacker can modify historical entries.

---

## Appendix C: Audit Report Template

Copy and fill in this template for your final report.

```markdown
# [Contract Name] — Security Audit Report

> **Chain:** [Target chain] | **Language:** Aiken v[version] | **Audit Date:** [date]
> **Tests:** [X]/[Y] pass | **Status:** [APPROVED / CONDITIONAL / REJECTED]

---

## 1. Contract Summary

[2-5 sentences: what the contract does, who the parties are, what tokens/values are involved]

## 2. Audit Scope

- **Files reviewed:** [list all .ak files]
- **Lines of code:** [approximate]
- **Redeemer actions:** [list each action]
- **Methodology:** Static analysis → test writing → fix verification [→ testnet verification]

## 3. Findings Summary

| ID | Finding | Severity | Status |
|----|---------|----------|--------|
| F1 | [name] | Critical | Fixed ✅ / Accepted / Open |
| F2 | [name] | High | Fixed ✅ / Accepted / Open |
| ... | ... | ... | ... |

### Finding Detail: [F1 — Name]

**Severity:** Critical
**Status:** [Fixed ✅ / Accepted / Open]
**Location:** `validators/contract.ak`, line [N]

**Description:**
[What the vulnerability is]

**Attack Scenario:**
[Step-by-step attack description]

**Vulnerable Code:**
```aiken
[exact code snippet]
```

**Recommended Fix:**
```aiken
[fixed code snippet]
```

**Verification:** [Test name that confirms fix, or "not yet tested"]

[Repeat for each finding]

## 4. First-Pass Check Results

| Check | Result |
|-------|--------|
| Double Satisfaction (`list.any`) | ✅ Clear / ❌ Finding F[N] |
| Output-Index Pinning | ✅ Clear / ❌ Finding F[N] / N/A |
| Cross-Input Consistency | ✅ Clear / ❌ Finding F[N] / N/A |
| Integer Arithmetic | ✅ Clear / ❌ Finding F[N] / N/A |
| Token Identity Validation | ✅ Clear / ❌ Finding F[N] / N/A |
| Tautological Datum Validation | ✅ Clear / ❌ Finding F[N] / N/A |

## 5. Test Results

| Category | Tests | Pass | Fail |
|----------|-------|------|------|
| Behavioral (happy path) | [N] | [N] | [N] |
| Security (exploit) | [N] | [N] | [N] |
| Property / Fuzz | [N] | [N] | [N] |
| **Total** | **[N]** | **[N]** | **[N]** |

## 6. Testnet Results (if applicable)

| Test | TX Hash | Result |
|------|---------|--------|
| Normal [action] | `tx_hash` | ✅ Accepted |
| Exploit [description] | `tx_hash` or rejection | ✅ Rejected / ❌ Accepted |

## 7. Overall Verdict

**[APPROVED / CONDITIONAL / REJECTED]**

[2-5 sentences justifying the verdict. Reference specific findings and their resolution status.]

### Conditions (if CONDITIONAL):
- [ ] [Condition 1]
- [ ] [Condition 2]

---

*Audited by: [Agent/Auditor name]*
*Methodology: Apex v2 Single-Agent Audit*
*Date: [date]*
```

---

## Quick Reference: The Audit in 60 Seconds

1. **Read the contract.** Understand what it does.
2. **Check for `list.any` on `tx.outputs`.** If found without `script_input_count == 1`: Critical.
3. **Check output-index pinning.** If used without single-input guard: Critical.
4. **Check cross-input consistency.** Multiple inputs aggregated without ownership check: High.
5. **Check all division operations.** No guards on inputs: High.
6. **Check token identity validation.** No policy ID length check: Medium.
7. **Check datum continuation validation.** Fields compared against themselves (tautological): High.
8. **Review datum source, value preservation, authorization, timing.**
9. **Write tests** for every finding.
10. **Verify fixes** — re-run all checks on fixed code.
11. **Write the report.**

---

*Apex v2 Security Audit Methodology — 2026*
*Applicable to: Aiken contracts on Cardano, Vector, and compatible eUTxO chains*
