# Vesting — Code Review (Cold Read)

**Date:** 2026-03-18

---

## Executive Summary

This is the **most defensively written** contract in the set. The author applied lessons from the escrow and donation pool: `script_input_count == 1`, output-index pinning, datum continuity checks, and conservative timing. The primary double satisfaction vector is fully mitigated.

No Critical or High severity findings. All issues are Low or Informational — primarily around degenerate datum handling and `expect`-based panics.

## Security Controls (Confirmed Working)

| Control | Implementation | Status |
|---------|---------------|--------|
| Double satisfaction | `script_input_count == 1` | ✅ Solid |
| Output pinning | Redeemer carries `beneficiary_index`, `continuation_index` | ✅ Solid |
| Index collision | `beneficiary_index != continuation_index` enforced | ✅ Solid |
| Datum hijacking | Continuation datum must match all 4 fields exactly | ✅ Solid |
| Timing | Lower bound of validity range (conservative) | ✅ Solid |
| Value preservation | `beneficiary_paid + continuation >= locked_lovelace` | ✅ Solid |
| Authorization | Beneficiary must sign | ✅ Solid |

## Findings

### V-01: Degenerate Datum — Permanent Lock (Low)

If `total_vesting_amount <= 0`, the `claimable` computation produces 0 or negative. The validator then checks `if claimable <= 0 { False }` — which means the transaction ALWAYS fails. The UTxO is permanently unspendable.

**Impact:** Funds locked forever. This is a datum construction issue (off-chain), not a validator bug. The validator correctly refuses invalid claims, but there's no on-chain escape hatch for badly-constructed datums.

**Severity:** Low — requires off-chain validation to prevent, not an on-chain exploit.

### V-02: Script Credential as Beneficiary (Low)

`d.beneficiary` is checked via `list.has(tx.extra_signatories, d.beneficiary)`. If a script hash is stored as beneficiary, `extra_signatories` will never contain it → permanent lock.

Same pattern as escrow and donation pool. Not exploitable by a third party (requires constructing a bad datum), but funds are irrecoverable.

**Severity:** Low — same assessment as escrow.

### V-03: `get_lower_bound` Expect Panic (Informational)

```
fn get_lower_bound(tx: Transaction) -> Int {
  expect Finite(t) = tx.validity_range.lower_bound.bound_type
  t
}
```

If the TX has no finite lower bound (e.g., `NegInf`), this panics with an `expect` failure. The TX would fail validation, which is the correct behavior — but it produces a runtime error rather than a clean `False`.

**Severity:** Informational — correct behavior, code quality suggestion.

### V-04: Integer Division Truncation (Informational)

Linear interpolation: `total * elapsed / duration`. Integer division truncates (rounds down), slightly favoring the contract over the beneficiary. The difference is negligible for most schedules.

**Severity:** Informational — by design, documented.

### V-05: No Cancellation/Revocation Mechanism (Informational)

Once funds are locked, only the beneficiary can claim. The funder has no recourse to cancel. This is a design decision, not a vulnerability, but worth documenting for users.

**Severity:** Informational — design choice.

## Test Gaps

The existing 37 tests in v1 are comprehensive. For the v2 behavioral/exploit split:

**Behavioral:**
- Happy path partial claim
- Happy path full claim (after vesting_end)
- Claim before cliff fails
- Wrong signer fails
- Underpayment fails
- Datum hijacking on continuation fails
- Index collision fails

**Exploit:**
- V-01: Degenerate datum (total_vesting_amount = 0) → permanently locked
- V-02: Script credential as beneficiary → claim always fails

## Verdict

**No live testnet exploit possible.** The contract is well-defended. The findings are all Low/Informational and relate to datum construction safety, not validator logic flaws. The `script_input_count == 1` + output-index pinning combination is the strongest anti-double-satisfaction pattern in the set.

**Recommendation:** No code changes needed. Document V-01 and V-02 as off-chain validation requirements for SDK developers.
