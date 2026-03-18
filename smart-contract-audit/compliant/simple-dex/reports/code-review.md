# Simple DEX — Code Review (Cold Read)

**Date:** 2026-03-18

---

## Executive Summary

The Simple DEX is well-defended. It has `script_input_count == 1`, output-index pinning via the `maker_output_index` redeemer field, rate validation (no division by zero), policy ID length checks, and ceiling division favoring the maker. The code comments are extensive and accurate.

No Critical or High findings. One Medium finding around the Take path's lack of value conservation check. Low/Informational findings around credential types and edge cases.

## Security Controls (Confirmed Working)

| Control | Implementation | Status |
|---------|---------------|--------|
| Double satisfaction | `script_input_count == 1` | ✅ Solid |
| Output pinning | `maker_output_index` in redeemer | ✅ Solid |
| Rate validation | `rate_numerator > 0`, `rate_denominator > 0` | ✅ Solid |
| Policy ID validation | Length check: 28 bytes or empty (ADA) | ✅ Solid |
| Rounding | Ceiling division favors maker | ✅ Solid |
| Cancel auth | Maker signature required | ✅ Solid |
| Take auth | No signature needed (open offer, by design) | ✅ Correct |

## Findings

### DEX-01: No Value Conservation Check on Take (Medium)

When a taker fills an offer, the validator checks:
- Maker receives `>= required_b` of the desired token ✅
- Output is at the maker's PKH address ✅

But it does NOT check:
- Where the locked token A goes (the taker should receive it, but the validator doesn't enforce this)

In practice, the taker constructs the TX and naturally takes the locked tokens as part of the TX change. But a malicious TX builder (or confused SDK) could send the locked tokens somewhere else. The taker is the TX builder, so this is self-harm — they'd only be hurting themselves. But it means the validator doesn't guarantee the taker receives the offered tokens.

**Impact:** Low practical risk — taker is the TX builder. But the contract doesn't enforce the intended swap semantics end-to-end.

**Severity:** Medium (structural gap, not exploitable by third party)

### DEX-02: Script Credential as Maker (Low)

Same pattern as other contracts. `d.maker` checked via `list.has(tx.extra_signatories, d.maker)` for Cancel, and `VerificationKey(d.maker)` for payment verification on Take.

If a script hash is used as maker:
- Cancel is permanently blocked (can't sign with script)
- Take still works (taker doesn't need maker signature), but payment goes to a `VerificationKey(script_hash)` address — which is a different address than `Script(script_hash)`. The maker would never receive the payment.

**Impact:** Offer is effectively a donation — taker gets the locked tokens, payment goes to an unreachable address.

**Severity:** Low — off-chain datum validation concern.

### DEX-03: Taker Can Overpay (Informational)

The check is `maker_received >= required_b`. A taker can overpay — the validator accepts it. This is correct behavior (no reason to prevent generosity), but worth documenting.

### DEX-04: `expect` Panics in `ceiling_div` (Informational)

```
expect a >= 0
expect b > 0
```

These should never trigger given the prior `rate_numerator > 0` and `rate_denominator > 0` checks, but they produce runtime errors rather than clean `False` returns.

### DEX-05: ADA-for-ADA Swap (Informational)

Nothing prevents `offered_asset == desired_asset` (including both being ADA). This creates a valid but economically nonsensical swap (trading ADA for ADA at some rate). Not a vulnerability — just a degenerate case.

## Verdict

**No live testnet exploit possible.** The `script_input_count == 1` + output-index pinning combination prevents double satisfaction. DEX-01 (no value conservation) is a structural observation but not exploitable by a third party.

**Recommendation:** No code changes required. The DEX-01 finding is worth discussing with the protocol team — adding a check that the taker receives the locked tokens would make the contract's swap semantics complete, but it's not a security issue since the taker controls the TX.
