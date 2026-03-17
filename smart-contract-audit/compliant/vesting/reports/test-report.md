# Test Report: Vesting

**Date:** 2026-03-17
**Aiken version:** v1.1.21
**Status:** TESTS COMPLETE ✅

---

## Results Summary

| Category | Tests | Passed | Failed |
|----------|-------|--------|--------|
| Unit tests | 37 | 37 | 0 |
| Property tests | 7 | 7 | 0 |
| Fuzz tests | 7 | 7 | 0 |
| **Total** | **51** | **51** | **0** |

---

## Test Breakdown

### Unit Tests (37 tests)

**Happy Path (7):** Full claim, partial claims (midpoint, quarter, exact end), overpayment, continuation overfunded, excess lovelace

**Rejection — Timing (3):** At exact cliff (0 vested), before cliff, well before cliff

**Rejection — Signature (2):** No signature, wrong signer

**Rejection — Beneficiary Payment (3):** Wrong address, insufficient payment, out-of-bounds index

**Continuation UTxO Enforcement (7):** No continuation, wrong address, insufficient value, no datum, altered beneficiary/cliff/end/total (datum hijacking defense)

**Output-Index Pinning (2):** Same indices rejected, out-of-bounds index

**Single Script Input — v3 Fix (3):** 2 inputs rejected, 3 inputs rejected, 0 inputs rejected (double satisfaction defense)

**Edge Cases — Vesting Computation (6):** Truncation conservative, full after end, zero at cliff, tiny after cliff, degenerate end=cliff, degenerate end<cliff

**Edge Cases — Degenerate Datums (2):** Zero total (unspendable), negative total (unspendable)

**Edge Cases — Excess Lovelace (2):** Requires continuation, full vesting with excess

### Property Tests (7 tests)

- Vested amount ∈ [0, total] for any time
- Monotonicity: vested(t1) ≤ vested(t2) for t1 ≤ t2
- Pre-cliff rejection: any time < cliff → past_cliff = False
- Post-end full vesting: any time ≥ end → vested = total
- Claimable capped by locked
- Must-remain non-negative
- Linear proportionality: vested = total × elapsed / duration

### Fuzz Tests (7 tests)

- Random amounts (1-10B) with full claim
- Valid time partial claims
- Pre-cliff always fails
- Wrong signer always rejected
- Wrong input count always rejected
- Random locked amounts with full vesting
- Random time values

---

## Finding Coverage

| Finding | Tested | Method |
|---------|--------|--------|
| F1-F2: Double satisfaction | ✅ | 4 dedicated tests + fuzz |
| F3: Excess lovelace | ✅ | 2 dedicated tests |
| F4: Integer truncation | ✅ | `vesting_truncation_conservative` |
| F5: Degenerate datums | ✅ | 4 dedicated tests |
| F6: Lower bound | ⚠️ | Documented; tested via cliff tests |

---

## Coverage Notes

**Tested:** All validator logic paths including happy paths, rejection conditions, boundary values, degenerate datums, excess lovelace, output-index pinning, single-script-input constraint, datum hijacking defense. Property and fuzz coverage for mathematical invariants.

**Not tested (by design):** Full transaction construction (requires on-chain simulation), timing attack via validity range manipulation (needs chain simulator), native token vesting (lovelace-only design).
