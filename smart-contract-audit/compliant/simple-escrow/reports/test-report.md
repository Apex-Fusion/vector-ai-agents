# Test Report: Simple Escrow

**Date:** 2026-03-17
**Aiken version:** v1.1.21
**Status:** TESTS COMPLETE ✅

---

## Results Summary

| Category | Tests | Passed | Failed |
|----------|-------|--------|--------|
| Unit tests | 27 | 27 | 0 |
| Property tests | 4 | 4 | 0 |
| Fuzz tests | 6 | 6 | 0 |
| **Total** | **37** | **37** | **0** |

**Total fuzzed samples:** 1,027 (100 samples per property/fuzz test)

---

## Test Breakdown

### Unit Tests (27 tests)

**Happy Path:** `claim_happy_path`, `claim_overpayment`, `reclaim_happy_path`

**Rejection — Secret:** `claim_wrong_secret`, `claim_empty_secret`

**Rejection — Signer:** `claim_wrong_signer`, `claim_sender_signs_instead`, `claim_no_signatories`, `reclaim_wrong_signer`, `reclaim_beneficiary_signs_instead`

**Rejection — Timing:** `claim_after_deadline`, `reclaim_before_deadline`, `claim_at_exact_deadline` (F3), `reclaim_at_exact_deadline` (F3)

**Rejection — Output:** `claim_paid_to_wrong_address`, `reclaim_paid_to_wrong_address`, `claim_insufficient_value`, `reclaim_insufficient_value`, `claim_zero_value`, `claim_no_outputs`

**Helper — `assets_gte`:** `assets_gte_zero_zero`, `assets_gte_positive_zero`, `assets_gte_zero_positive`, `assets_gte_equal`, `assets_gte_greater`, `assets_gte_lesser`

**Vulnerability Documentation:** `double_satisfaction_vulnerability_documented` (F1)

### Property Tests (4 tests)

- `prop_any_secret_claim_works` — Random valid secrets always pass Claim
- `prop_wrong_secret_hash_fails` — Random different bytearrays produce different hashes
- `prop_assets_gte_reflexive` — Any value ≥ itself
- `prop_assets_gte_monotonic` — Larger lovelace ≥ smaller lovelace

### Fuzz Tests (6 tests)

- `fuzz_random_secret_rejects` — Random secrets rejected on claim
- `fuzz_secret_hash_mismatch` — Random hashes in datum don't match correct secret
- `fuzz_deadline_claim_valid` / `fuzz_deadline_reclaim_valid` — Deadline enforcement
- `fuzz_underpayment_fails` — Underpayment always rejected
- `fuzz_wrong_signer_fails` — Wrong signers always rejected

---

## Finding Coverage

| Finding | Severity | Tested | Notes |
|---------|----------|--------|-------|
| F1: Double Satisfaction | Medium | ✅ | Confirmed: single output satisfies two validators when value_A ≥ value_B |
| F2: Staking Credential | Low | ⚠️ | Cannot test at unit level — requires full address comparison |
| F3: Dead Zone | Info | ✅ | Both Claim and Reclaim fail at exact deadline point |
| F4: Data typing | Info | N/A | Style issue |

---

## Coverage Notes

**Tested:** Claim path (secret, deadline, signer, output), Reclaim path (deadline, signer, output), `assets_gte` helper, double satisfaction documentation, property invariants, fuzz coverage.

**Not tested (by design):** Full transaction context (requires on-chain simulation), staking credential attack (requires full address comparison), multi-asset escrows (ADA-only design), datum absence path (runtime-enforced).
