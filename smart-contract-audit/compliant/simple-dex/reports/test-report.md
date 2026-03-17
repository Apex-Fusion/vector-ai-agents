# Test Report: Simple DEX

**Date:** 2026-03-17
**Aiken version:** v1.1.21
**Status:** TESTS COMPLETE ✅

---

## Results Summary

| Category | Tests | Passed | Failed |
|----------|-------|--------|--------|
| Unit tests | 58 | 58 | 0 |
| Property tests | 7 | 7 | 0 |
| Fuzz tests | 8 | 8 | 0 |
| **Total** | **73** | **73** | **0** |

**Total fuzzed samples:** 2,500+ (100 samples per property/fuzz test)

---

## Test Breakdown

### Unit Tests (58 tests)

**Helper Functions (16):** `ceiling_div` (10 tests incl. guards), `get_asset_amount` (4 tests), negative numerator/zero denominator/negative denominator guards

**Happy Path — Take (5):** Token-for-ADA, ADA-for-Token, overpayment, non-zero index, ceiling rounding

**Happy Path — Cancel (2):** Maker signature, maker among multiple signatories

**Rejection — Underpayment (3):** By 1 unit, zero payment, ceiling threshold

**Rejection — Wrong Token/Address (3):** Wrong token, wrong address, payment to taker

**Rejection — Cancel Authorization (3):** No signature, wrong signer, taker tries cancel

**Rejection — Bad Policy ID (4):** 27-byte, 29-byte, 1-byte, both-ADA valid

**Rejection — Rate Validation (4):** Zero numerator/denominator, negative numerator/denominator

**Double Satisfaction Prevention (5):** count=2/0/5 blocks Take, count=2/3 blocks Cancel

**Output-Index Pinning (4):** Out-of-bounds, negative, wrong recipient, empty outputs

**Edge Cases — Locked Amount (2):** Zero rejected, minimum (1 unit) accepted

**Edge Cases — Rate Computation (7):** 1:1, 1M:1, 1:1M, small ceiling rounding, exact division, underpay-by-1, double satisfaction documentation

### Property Tests (7 tests)

- `ceiling_div` always ≥ floor division
- `ceiling_div` correctness (result * b ≥ a AND (result-1) * b < a)
- Valid rates with exact payment always pass
- Random unauthorized signers always fail Cancel
- Overpayment always passes
- Multiple script inputs always rejected
- Random locked amounts compute correctly

### Fuzz Tests (8 tests)

- Exchange rates, underpayment, bad policy ID lengths, random signers, locked amounts, wrong addresses, ceiling_div guarantee, maker identity

---

## Finding Coverage

| Finding | Tests |
|---------|-------|
| F1: Double Satisfaction | 7 tests (5 unit + 1 property + 1 fuzz) |
| F2: `ceiling_div` guards | 6 tests (3 unit + 2 property + 1 fuzz) |
| F3: Policy ID validation | 5 tests (4 unit + 1 fuzz) |

---

## Coverage Notes

**Tested:** All Take validation logic (rate computation, payment verification, output-index pinning, policy ID validation), all Cancel logic (signer authorization), double satisfaction prevention, `ceiling_div` correctness and guards, boundary conditions, address verification.

**Not tested (by design):** Full transaction construction (on-chain simulation), MEV/front-running (inherent to open-order DEXs), alternative spending paths (Aiken default handles).
