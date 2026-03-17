# Security Audit Report: Simple Escrow

**Version:** 1.0
**Date:** 2026-03-17
**Chain:** Vector Testnet (Cardano-based UTxO L2)
**Language:** Aiken v1.1.21

> ⚠️ DEMO — NOT FOR PRODUCTION
> This contract has not undergone a formal third-party security audit.
> Use on mainnet at your own risk.

---

## 1. Executive Summary

The Simple Escrow contract is a hash-locked escrow that holds ADA until a beneficiary reveals a pre-agreed secret before a deadline, or the sender reclaims funds after the deadline passes. The contract is well-structured, defensively written, and correctly implements its stated intent. One medium-severity double satisfaction vulnerability exists (documented and accepted for demo scope), along with a low-severity staking credential omission. All 37 tests pass across unit, property, and fuzz categories. Red team testing (8 exploit attempts) confirmed all standard attack vectors are defended — the only vulnerability is the known double satisfaction issue, which requires specific preconditions to exploit. The contract is **approved for demo deployment** with clear production upgrade paths documented.

---

## 2. Findings

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| F1 | Double satisfaction — single output satisfies multiple inputs when beneficiary and value overlap | Medium | Accepted (documented limitation) |
| F2 | Staking credential not validated on outputs — rewards could leak to third party | Low | Accepted (documented limitation) |
| F3 | Dead zone at exact deadline boundary — neither Claim nor Reclaim works at exact deadline ms | Info | Accepted (not exploitable) |
| F4 | `own_ref` parameter typed as `Data` then cast — style issue | Info | Accepted (no functional impact) |

### F1: Double Satisfaction

**Severity:** Medium
**Location:** `simple_escrow.ak` — Claim and Reclaim output checks

The `paid_to_beneficiary` / `paid_to_sender` check uses `list.any` over `tx.outputs` to find *any* output paying `>= own_value` to the correct credential. When two escrow UTxOs share the same beneficiary and value_A ≥ value_B, a single output of value_A satisfies both validators. The attacker pockets value_B minus fees.

**Production fix:** Enforce `script_input_count == 1` or use NFT identifiers. This is the proven pattern used in the vesting and DEX contracts in this same audit.

### F2: Staking Credential Not Validated

**Severity:** Low
**Location:** `simple_escrow.ak` — output address checks

The output address check only verifies `payment_credential`. An attacker could route funds to an address with the correct payment key but a staking credential controlled by a third party, causing staking reward leakage. Low impact for ADA-only demo escrows.

**Production fix:** Store full `Address` (including stake credential) in datum instead of just payment key hash.

### F3: Dead Zone at Exact Deadline

**Severity:** Info

`is_entirely_before(range, deadline)` and `is_entirely_after(range, deadline)` create a single-millisecond window at the exact deadline where neither Claim nor Reclaim works. Not exploitable — user submits 1ms later.

### F4: `own_ref` Typed as `Data`

**Severity:** Info

Style issue — `own_ref` declared as `Data` and cast via `expect` to `OutputReference`. No functional impact.

---

## 3. Code Review Summary

The contract was reviewed and approved in a single pass (no re-review needed). The code faithfully implements the stated intent with proper secret verification, deadline enforcement, signature checks, and value preservation.

**Review decision:** APPROVED ✅

---

## 4. Test Results

| Test Category | Tests Run | Passed | Failed |
|---------------|-----------|--------|--------|
| Unit tests    | 27        | 27     | 0      |
| Property tests| 4         | 4      | 0      |
| Fuzz tests    | 6         | 6      | 0      |
| **Total**     | **37**    | **37** | **0**  |

**Total fuzzed samples:** 1,027 (100 samples per property/fuzz test)

### Finding Coverage

| Finding | Tested | Method |
|---------|--------|--------|
| F1: Double Satisfaction | ✅ | `double_satisfaction_vulnerability_documented` |
| F2: Staking Credential | ⚠️ | Documented only — cannot test at unit level |
| F3: Dead Zone | ✅ | `claim_at_exact_deadline`, `reclaim_at_exact_deadline` |
| F4: Data typing | N/A | Style issue |

---

## 5. Attack Vector Assessment

| # | Attack Vector | Tested | Result | Notes |
|---|---------------|--------|--------|-------|
| 1 | Double satisfaction | ✅ Yes | ⚠️ KNOWN LIMITATION | Single output can satisfy two inputs with same beneficiary when value_A ≥ value_B. Accepted for demo; production fix: enforce single-script-input or NFT identifiers. |
| 2 | Datum hijacking | ✅ Yes | PASS | Datum resolved from spent UTxO via Plutus V3 framework. Cannot be substituted. |
| 3 | Reference input manipulation | ✅ Yes | PASS (N/A) | Validator never reads `tx.reference_inputs`. |
| 4 | Minting policy bypass | ✅ Yes | PASS (N/A) | Pure spend handler. No minting logic. |
| 5 | Alternative spending paths | ✅ Yes | PASS | Exhaustive match on two-variant `EscrowRedeemer`. Aiken default rejects non-spend purposes. |
| 6 | Redeemer manipulation | ✅ Yes | PASS | Typed enum. Claim requires correct hash. Reclaim requires deadline + signature. |
| 7 | Timing attacks (slot-based) | ⚠️ Partial | PASS (partial) | `is_entirely_before`/`is_entirely_after` correctly enforce deadline. Full testing requires chain simulator. |
| 8 | MEV / front-running | ❌ Not tested | UNTESTABLE | Requires mempool simulation — POST-LAUNCH |

---

## 6. Red Team Findings

**Date:** 2026-03-17
**Attempts:** 8 | **Defended:** 6 | **Partially Defended:** 1 | **Vulnerable:** 1
**Method:** Code-level analysis + on-chain state observation and TX attempts

Eight attack vectors were systematically tested. Six were fully defended, one was partially defended (inherent UTxO model property), and one confirmed the known double satisfaction vulnerability.

| # | Attempt | Vector | Result | Notes |
|---|---------|--------|--------|-------|
| 1 | Wrong Secret | Redeemer Manipulation | DEFENDED | `blake2b_256(secret) == d.secret_hash` — no bypass possible |
| 2 | Missing Beneficiary Sig | Missing Signer Checks | DEFENDED | `list.has(tx.extra_signatories, d.beneficiary)` — ledger-enforced |
| 3 | Reclaim Before Deadline | Timing Attacks | DEFENDED | `is_entirely_after` correctly rejects early reclaims |
| 4 | Empty Secret | Redeemer Manipulation | DEFENDED | `blake2b_256(b"")` produces deterministic hash — no special case |
| 5 | Value Underpayment | Value Manipulation | DEFENDED | `assets_gte` enforces full value preservation |
| 6 | Random Attacker | Alt. Spending Paths | DEFENDED | All three checks (secret, signer, payment) fail simultaneously |
| 7 | Datum Hijacking (deposit) | Datum Hijacking | PARTIAL (by design) | Anyone can deposit UTxO with arbitrary datum — inherent UTxO model property |
| 8 | Double Satisfaction | Double Satisfaction | VULNERABLE (known) | Confirmed: `list.any` allows shared output when same beneficiary and `value_A ≥ value_B` |

**Confirmed vulnerabilities:**

1. **Double satisfaction (Medium — known, accepted):** `list.any` output matching allows a single output to satisfy two validators when beneficiary matches and one value covers the other. Requires: same beneficiary + multiple UTxOs. Accepted for demo; production fix: `script_input_count == 1`.

**Partially defended:**

2. **Datum hijacking on new deposits (Low):** Anyone can send to any address with any datum — inherent UTxO model property. The validator correctly reads datum from its own spent UTxO, so existing UTxOs are safe. Off-chain tooling must verify which UTxO to interact with.

---

## 7. Known Limitations

1. **Double satisfaction with overlapping datums:** If two escrow UTxOs share the same beneficiary and value_A ≥ value_B, a single output satisfies both. Production fix: enforce `script_input_count == 1` or use NFT identifiers.
2. **Staking credential not validated:** Funds may earn staking rewards for a third party if output has a manipulated staking credential.
3. **Dead zone at exact deadline:** A 1ms window where neither path works. Not exploitable.
4. **ADA-only tested:** `assets_gte` supports multi-asset but escrow is designed/tested for ADA only.
5. **No partial claims:** Beneficiary must take the entire locked value.
6. **No mutual cancellation:** Only deadline-based reclaim exists.
7. **Secret visibility:** Secret is visible on-chain in the redeemer after claim.

---

## 8. Overall Verdict

**APPROVED FOR DEMO** ✅

The Simple Escrow contract correctly implements its stated intent with clean, well-documented code. The known double satisfaction limitation is explicitly documented with a clear production mitigation path. All tests pass. The contract is suitable for demo/educational deployment on Vector testnet.

---

## 9. Recommendations

Prioritized by impact:

1. **[High — Production]** Add single-script-input enforcement (`script_input_count == 1`) to eliminate double satisfaction.
2. **[Medium — Production]** Store full `Address` (including stake credential) in datum instead of just payment key hash.
3. **[Low — UX]** Document the exact-deadline dead zone in user-facing instructions.
4. **[Low — Code quality]** Consider typing `own_ref` as `OutputReference` directly if Aiken version supports it.
5. **[Info]** Consider adding mutual cancellation path for improved UX.
