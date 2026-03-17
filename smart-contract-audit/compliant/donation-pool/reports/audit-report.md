# Security Audit Report: Donation Pool

**Version:** 1.0
**Date:** 2026-03-17
**Chain:** Vector Testnet (Cardano-based UTxO L2)
**Language:** Aiken v1.1.21

> ⚠️ DEMO — NOT FOR PRODUCTION
> This contract has not undergone a formal third-party security audit.
> Use on mainnet at your own risk.

---

## 1. Executive Summary

The Donation Pool contract allows anyone to donate ADA to a pool controlled by an administrator, who can then distribute funds to verified recipients. After an initial review that identified a high-severity cross-pool budget inflation vulnerability and a low-severity duplicate recipient issue, both were fixed and verified in re-review. The contract now enforces same-admin consistency across batched inputs and rejects duplicate recipients. All 49 tests pass across unit (38), property (4), and fuzz (7) categories. Red team testing (10 exploit attempts) confirmed all external attacker vectors are fully blocked — remaining partial defenses involve inherent UTxO model properties and the admin trust model. **Approved for demo deployment.**

---

## 2. Findings

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| F1 | Missing same-admin enforcement on batched script inputs — cross-pool budget inflation | High | **Fixed** ✅ |
| F2 | Duplicate recipients allow single output to satisfy multiple entries | Low | **Fixed** ✅ |
| F3 | Native token extraction not validated (lovelace-only tracking) | Info | Accepted (documented limitation) |
| F4 | `own_ref` parameter typed as `Data` with runtime cast | Info | Accepted (standard pattern) |
| F5 | No `else` fallback on validator | Info | Accepted (Aiken default rejects) |

### F1: Cross-Pool Budget Inflation (Fixed)

**Severity:** High

The code claimed to enforce same-admin across batched inputs but never performed the check. This enabled a cross-pool budget inflation attack: Admin A could inflate `total_input_lovelace` using Admin B's funds when both signed the same transaction.

**Fix:** `all_same_admin` check iterating all script inputs and verifying each datum's admin matches the current input's admin.

### F2: Duplicate Recipients (Fixed)

**Severity:** Low

Same recipient listed twice in a distribution could be satisfied by a single output, enabling the admin to under-deliver while appearing to distribute the full budget.

**Fix:** `no_duplicate_recipients` check using `list.unique` on recipient key hashes.

### F3: Native Token Extraction

**Severity:** Info

The contract only tracks lovelace. Native tokens accidentally sent to the pool can be extracted by the admin alongside valid distributions. Acceptable for ADA-only demo pool.

---

## 3. Code Review Summary

### Review History

| Round | Status | Key Issue |
|-------|--------|-----------|
| Initial | ❌ NEEDS_REVISION | High: missing same-admin enforcement on batched inputs |
| Re-review | ✅ APPROVED | Both findings correctly addressed |

The final `and` block includes all 8 validator checks:
1. `admin_signed` — admin authorization
2. `has_distributions` — non-empty distribution list
3. `all_positive` — positive amounts
4. `no_duplicate_recipients` — unique recipients **(post-review fix)**
5. `all_same_admin` — same admin across batched inputs **(post-review fix)**
6. `distribution_within_budget` — sum ≤ total input
7. `all_recipients_paid` — outputs match distributions
8. `change_datum_valid` — change preserves admin

**Final review decision:** APPROVED ✅

---

## 4. Test Results

| Test Category | Tests Run | Passed | Failed |
|---------------|-----------|--------|--------|
| Unit tests    | 38        | 38     | 0      |
| Property tests| 4         | 4      | 0      |
| Fuzz tests    | 7         | 7      | 0      |
| **Total**     | **49**    | **49** | **0**  |

**Total fuzzed samples:** 1,100 (100 samples per property/fuzz test)

### Finding Coverage

| Finding | Tested | Method |
|---------|--------|--------|
| F1: Same-admin enforcement | ✅ | 3 dedicated tests + fuzz test |
| F2: Duplicate recipients | ✅ | 3 dedicated tests |
| F3: Native tokens | ⚠️ | Documented only |
| F4-F5: Info findings | N/A | No functional impact |

---

## 5. Attack Vector Assessment

| # | Attack Vector | Tested | Result | Notes |
|---|---------------|--------|--------|-------|
| 1 | Double satisfaction | ✅ Yes | PASS | `all_same_admin` prevents cross-admin budget inflation. `no_duplicate_recipients` prevents single-output multi-entry satisfaction. Same-admin double satisfaction acceptable per trust model. |
| 2 | Datum hijacking | ✅ Yes | PASS | Own input datum via `output_reference`. Change outputs validated via `change_datum_valid`. |
| 3 | Reference input manipulation | ✅ Yes | PASS (N/A) | Validator never reads `tx.reference_inputs`. |
| 4 | Minting policy bypass | ✅ Yes | PASS (N/A) | Pure spending validator. |
| 5 | Alternative spending paths | ✅ Yes | PASS | Single redeemer variant (`Distribute`). Exhaustive matching. |
| 6 | Redeemer manipulation | ✅ Yes | PASS | Empty → rejected. Zero/negative → rejected. Inflated → rejected by budget check. |
| 7 | Timing attacks (slot-based) | N/A | N/A | No time-based logic in this contract. |
| 8 | MEV / front-running | ❌ Not tested | UNTESTABLE | Requires mempool simulation — POST-LAUNCH |

---

## 6. Red Team Findings

**Date:** 2026-03-17
**Attempts:** 10 | **Defended:** 7 | **Partially Defended:** 3 | **Vulnerable:** 0

Ten attack vectors were tested. Seven were fully defended, three were partially defended (all acceptable per design or trust model). No exploitable vulnerabilities were found.

| # | Attempt | Vector | Result | Notes |
|---|---------|--------|--------|-------|
| 1 | Unauthorized Distribution | Missing Signer Checks | DEFENDED | Admin signature required; ledger-enforced |
| 2 | Empty Distribution List | Redeemer Manipulation | DEFENDED | `!list.is_empty(distributions)` rejects |
| 3 | Zero/Negative Amounts | Redeemer Manipulation | DEFENDED | `dist.amount > 0` enforced for all entries |
| 4 | Duplicate Recipients | Double Satisfaction (redeemer) | DEFENDED | `no_duplicate_recipients` check blocks |
| 5 | Cross-Pool Budget Inflation | Double Satisfaction + Data Mod | DEFENDED | `all_same_admin` check blocks |
| 6 | Datum Hijack on Change | Datum Hijacking | DEFENDED | `change_datum_valid` enforces same admin |
| 7 | Over-Distribution | Value Manipulation | DEFENDED | Budget check + ledger value preservation |
| 8 | Malicious Datum Deposit | Datum Hijacking | PARTIAL (by design) | Inherent UTxO model property |
| 9 | Native Token Extraction | Value Manipulation | PARTIAL (admin only) | Lovelace-only tracking — documented limitation |
| 10 | Same-Admin Double Satisfaction | Double Satisfaction | PARTIAL (admin only) | Acceptable per trust model — admin is authorized |

**Confirmed vulnerabilities:** None

---

## 7. Known Limitations

1. **ADA-only tracking:** Native tokens sent to the pool can be extracted by the admin. Production fix: use full multi-asset value comparison.
2. **No on-chain recipient verification:** Recipients are verified off-chain by the admin.
3. **Single admin, no rotation:** Admin is fixed per UTxO datum at donation time.
4. **Min-UTxO not enforced:** Invalid outputs would be rejected by ledger rules.
5. **Same-admin double satisfaction is acceptable:** The admin controls the redeemer and is the authorized spender.

---

## 8. Overall Verdict

**APPROVED FOR DEMO** ✅

The Donation Pool contract correctly implements its stated intent after two review rounds. The critical cross-pool budget inflation vulnerability was properly fixed and verified. All 8 validator checks are present and correctly ordered. Suitable for demo deployment on Vector testnet.

---

## 9. Recommendations

1. **[High — Production]** Add multi-asset value tracking to prevent native token extraction.
2. **[Medium — Production]** Consider on-chain recipient allowlist for higher trust guarantees.
3. **[Medium — Production]** Implement admin key rotation mechanism.
4. **[Low — UX]** Add min-UTxO enforcement in off-chain tooling.
