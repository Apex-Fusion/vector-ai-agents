# Security Audit Report: Vesting

**Version:** 1.0
**Date:** 2026-03-17
**Chain:** Vector Testnet (Cardano-based UTxO L2)
**Language:** Aiken v1.1.21

> ⚠️ DEMO — NOT FOR PRODUCTION
> This contract has not undergone a formal third-party security audit.
> Use on mainnet at your own risk.

---

## 1. Executive Summary

The Vesting contract implements time-locked linear vesting of ADA with cliff and proportional release schedule. This contract underwent the most rigorous review cycle in the project — three review rounds to resolve a critical double satisfaction vulnerability. The initial version used global output scanning (vulnerable), v2 added output-index pinning (still vulnerable — two inputs can share indices), and v3 added a single-script-input constraint that fully eliminates the attack. All 51 tests pass. Red team testing (10 exploit attempts) found **zero vulnerabilities** — every vector was fully defended. The contract demonstrates defense-in-depth with output-index pinning AND single-input enforcement. **Approved for demo deployment.**

---

## 2. Findings

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| F1 | Double satisfaction — beneficiary payment check is global (v1) | Critical | **Fixed (v3)** ✅ |
| F2 | Double satisfaction — continuation UTxO check is global (v1) | Critical | **Fixed (v3)** ✅ |
| F3 | `total_vesting_amount` vs actual locked value mismatch — 2-TX withdrawal | Low | Accepted (safe edge case) |
| F4 | Integer division truncation is conservative (intended) | Info | Accepted (by design) |
| F5 | Degenerate datum parameters not validated on-chain | Info | Accepted (documented in types) |
| F6 | Inclusive lower bound not explicitly checked | Low | Accepted (documented assumption) |

### Critical Fix: Double Satisfaction (F1, F2)

**Problem (v1):** The beneficiary payment and continuation UTxO checks used global scanning across all transaction outputs. Two vesting inputs in the same transaction could share outputs, enabling value extraction.

**Insufficient fix (v2):** Output-index pinning was added (`beneficiary_index`, `continuation_index`) but proved insufficient. In eUTxO, each validator runs independently — two inputs can specify identical indices in their redeemers with no cross-input coordination.

**Final fix (v3):**
```aiken
let script_input_count =
  list.count(tx.inputs, fn(i) { i.output.address == script_address })
expect script_input_count == 1
```

**Defense-in-depth:** The contract now has TWO layers of double-satisfaction protection:
1. Single-script-input constraint (prevents multi-input attacks entirely)
2. Output-index pinning with `beneficiary_index != continuation_index` (prevents single-input self-satisfaction)

### Other Findings

**F3 (Low):** If UTxO holds more lovelace than `total_vesting_amount`, the excess requires a second claim after full vesting. Not exploitable, mildly inefficient.

**F4 (Info):** Integer truncation in vesting calculation rounds down (conservative — beneficiary receives slightly less). Intentional behavior.

**F5 (Info):** `total_vesting_amount <= 0` creates permanently unspendable UTxOs. `vesting_end_time <= cliff_time` results in immediate full vesting. Documented as off-chain validation responsibility.

**F6 (Low):** Lower bound assumed inclusive (standard for Cardano). If exclusive, time off by 1ms in conservative direction.

---

## 3. Code Review Summary

### Review History

| Round | Status | Key Issue |
|-------|--------|-----------|
| v1 (Initial) | ❌ NEEDS_REVISION | Critical: global output scanning enables double satisfaction |
| v2 (Re-review) | ❌ NEEDS_REVISION | Critical: output-index pinning alone insufficient — two inputs can share indices |
| v3 (Re-review) | ✅ APPROVED | Single-script-input constraint eliminates the attack entirely |

**Final review decision:** APPROVED ✅

---

## 4. Test Results

| Test Category | Tests Run | Passed | Failed |
|---------------|-----------|--------|--------|
| Unit tests    | 37        | 37     | 0      |
| Property tests| 7         | 7      | 0      |
| Fuzz tests    | 7         | 7      | 0      |
| **Total**     | **51**    | **51** | **0**  |

### Finding Coverage

| Finding | Tested | Method |
|---------|--------|--------|
| F1-F2: Double satisfaction | ✅ | 4 dedicated tests + fuzz |
| F3: Excess lovelace | ✅ | 2 dedicated tests |
| F4: Integer truncation | ✅ | `vesting_truncation_conservative` |
| F5: Degenerate datums | ✅ | 4 dedicated tests |
| F6: Lower bound | ⚠️ | Documented; tested via cliff tests |

---

## 5. Attack Vector Assessment

| # | Attack Vector | Tested | Result | Notes |
|---|---------------|--------|--------|-------|
| 1 | Double satisfaction | ✅ Yes | PASS | Single-script-input constraint (v3) + output-index pinning. Defense-in-depth. |
| 2 | Datum hijacking | ✅ Yes | PASS | Continuation datum fully field-compared (all 4 fields). 5 dedicated tests. |
| 3 | Reference input manipulation | ✅ Yes | PASS (N/A) | No reference inputs used. |
| 4 | Minting policy bypass | ✅ Yes | PASS (N/A) | No minting logic. |
| 5 | Alternative spending paths | ✅ Yes | PASS | Single redeemer variant (`Claim`). No other handlers. |
| 6 | Redeemer manipulation | ✅ Yes | PASS | Index fields select outputs but cannot inflate claimable. Vested amount computed from on-chain state. |
| 7 | Timing attacks (slot-based) | ⚠️ Partial | PASS (partial) | Conservative lower-bound extraction. Full testing needs chain simulator. |
| 8 | MEV / front-running | ❌ Not tested | UNTESTABLE | Requires mempool simulation — POST-LAUNCH |

---

## 6. Red Team Findings

**Date:** 2026-03-17
**Attempts:** 10 | **Defended:** 10 | **Partially Defended:** 0 | **Vulnerable:** 0

The vesting contract proved to be the most thoroughly hardened of all four contracts. All 10 exploit attempts were fully defended. No vulnerabilities found.

| # | Attempt | Vector | Result | Notes |
|---|---------|--------|--------|-------|
| 1 | Double Satisfaction (multi-input) | Double Satisfaction | DEFENDED | `script_input_count == 1` — both validators abort on count=2 |
| 2 | Claim Without Beneficiary | Missing Signer Checks | DEFENDED | Beneficiary PKH required in `extra_signatories` |
| 3 | Claim Before Cliff | Timing Attacks | DEFENDED | Conservative lower-bound extraction rejects early claims |
| 4 | Wide Validity Range | Timing Attacks | DEFENDED | Ledger enforces `valid_from` — no time travel possible |
| 5 | Datum Hijacking (continuation) | Datum Hijacking | DEFENDED | Full field-by-field comparison (all 4 fields) on continuation datum |
| 6 | Invalid Output Indices | Redeemer Manipulation | DEFENDED | `list.at` returns `None` → `expect` aborts |
| 7 | Same Index for Both Outputs | Redeemer Manipulation | DEFENDED | `beneficiary_index != continuation_index` enforced |
| 8 | Over-Extraction | Value Manipulation | DEFENDED | Vested amount computed deterministically from on-chain state |
| 9 | Wrong Redeemer Constructor | Alt. Spending Paths | DEFENDED | Single-variant `Claim` — type system rejects unknown constructors |
| 10 | Degenerate Datum (zero amount) | Edge Case | Permanent lock (defended) | Validator correctly rejects — UTxO unspendable but not exploitable |

**Confirmed vulnerabilities:** None

---

## 7. Known Limitations

1. **No batched claims:** The single-script-input constraint means each vesting claim requires its own transaction.
2. **Lovelace-only vesting:** Native tokens locked alongside ADA are not proportionally vested.
3. **Minimum UTxO:** Partial claims must leave enough lovelace for min-UTxO. Off-chain code must handle this.
4. **No cancellation/revocation:** Once funds are locked, only the beneficiary can claim.
5. **Excess lovelace beyond `total_vesting_amount`:** Requires a second claim transaction after full vesting.
6. **Degenerate datums:** `total_vesting_amount <= 0` creates permanently unspendable UTxOs.
7. **Integer truncation:** Vested amount rounds down (conservative — beneficiary receives slightly less).

---

## 8. Overall Verdict

**APPROVED FOR DEMO** ✅

The Vesting contract is the most thoroughly reviewed contract in this audit, having undergone three review rounds to resolve a critical double satisfaction vulnerability. The final v3 implementation uses defense-in-depth (single-script-input + output-index pinning) and is sound. All 51 tests pass. Ready for demo deployment.

---

## 9. Recommendations

1. **[High — Production]** Consider adding a revocation/cancellation mechanism with sender key.
2. **[Medium — Production]** Add native token proportional vesting for multi-asset support.
3. **[Medium — Production]** Implement min-UTxO awareness in off-chain tooling.
4. **[Low — Production]** Consider explicit `is_inclusive` check on lower bound for defense-in-depth.
5. **[Low — UX]** Clamp `claimable = locked_lovelace` when fully vested to avoid 2-TX withdrawal.
6. **[Info]** Add off-chain datum validation to reject `total_vesting_amount <= 0` before UTxO creation.
