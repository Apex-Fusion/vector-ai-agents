# Test Report: Donation Pool

**Date:** 2026-03-17
**Aiken version:** v1.1.21
**Status:** TESTS COMPLETE ✅

---

## Results Summary

| Category | Tests | Passed | Failed |
|----------|-------|--------|--------|
| Unit tests | 38 | 38 | 0 |
| Property tests | 4 | 4 | 0 |
| Fuzz tests | 7 | 7 | 0 |
| **Total** | **49** | **49** | **0** |

**Total fuzzed samples:** 1,100 (100 samples per property/fuzz test)

---

## Test Breakdown

### Unit Tests (38 tests)

**Happy Path (8):** Single recipient, multiple recipients (2, 3), with change, exact budget, overpayment, batched same-admin inputs, same-admin double satisfaction (acceptable per trust model)

**Unauthorized Attempts (4):** No signature, wrong signer, attacker signer, recipient-as-signer

**Empty/Invalid Distributions (5):** Empty list, zero amount, negative amount, mixed zero, mixed negative

**Incorrect Payments (4):** Underpayment, wrong recipient, no outputs, partial payment

**Over-Distribution (2):** Single over-budget, multiple over-budget

**Same-Admin Enforcement — F1 (3):** Different admin batched, cross-pool budget inflation attack, three inputs one different admin

**Duplicate Recipient Rejection — F2 (3):** Duplicate recipient, under-delivery attack, triple duplicate

**Datum Hijacking on Change (3):** Wrong admin on change, classic datum hijack, mixed valid/hijacked

**Value Preservation & Edge Cases (6):** Exact budget, valid change, minimum amount, admin-as-recipient, extra signatories, multiple valid changes

### Property Tests (4 tests)

- Valid amount always passes, wrong signer always fails, over-budget always fails, underpayment always fails

### Fuzz Tests (7 tests)

- Random valid amounts, non-positive rejected, random recipients, wrong admin, mismatched admin in batch, two-way splits, underpayment delta

---

## Finding Coverage

| Finding | Tested | Method |
|---------|--------|--------|
| F1: Same-admin enforcement | ✅ | 3 dedicated tests + fuzz |
| F2: Duplicate recipients | ✅ | 3 dedicated tests |
| F3: Native tokens | ⚠️ | Documented only |
| F4-F5: Info findings | N/A | No functional impact |

---

## Coverage Notes

**Tested:** All 8 validator checks exercised independently and in combination. Same-admin enforcement, duplicate recipient rejection, datum hijacking, redeemer manipulation, missing signer checks, value preservation.

**Not tested (by design):** Full transaction context (on-chain simulation), native token handling (ADA-only design), min-UTxO enforcement (ledger-level), timing attacks (N/A — no time-based logic).
