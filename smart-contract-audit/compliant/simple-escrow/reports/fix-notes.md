# Simple Escrow — Fix Notes

**Date:** 2026-03-18
**Source:** `original/simple_escrow.ak`
**Fixed:** `compliant/contracts/simple_escrow.ak`
**References:** `compliant/reports/code-review.md`, `compliant/reports/red-team-report.md`

---

## Changes Applied

### 1. Double Satisfaction Guard — `script_input_count == 1` (CRITICAL fix)

**Finding:** RT-01 / Code Review §1 — The original contract uses `list.any` to find an output paying the beneficiary/sender. When two escrow UTxOs are spent in the same transaction, both validator invocations find the **same** output, allowing an attacker to consume N escrows while paying only the value of the largest one.

**Fix:** After resolving `own_input`, we derive the script address and count how many transaction inputs originate from that address. We `expect` exactly 1.

```aiken
let script_address = own_input.output.address
let script_input_count =
  list.count(tx.inputs, fn(i) { i.output.address == script_address })
expect script_input_count == 1
```

**Why this works:** With only one script input per transaction, the validator executes exactly once. The `list.any` output check cannot be double-counted because there is no second invocation to share the output with. This is simpler and more robust than output-pinning approaches.

**Trade-off:** Users cannot batch-spend multiple escrow UTxOs in a single transaction (e.g., reclaiming 5 expired escrows at once). Each must be a separate TX. For a simple escrow contract, this is an acceptable cost — correctness over convenience.

### 2. `list.any` Output Matching — Retained (no change)

**Rationale:** With the `script_input_count == 1` guard in place, `list.any` is safe. There is only one validator invocation per TX, so a matching output can only satisfy one check. No distinctness issue exists.

---

## Findings NOT Fixed (documented)

| Finding | Severity | Reason Not Fixed |
|---------|----------|-----------------|
| Script credential as beneficiary/sender causes permanent lock (RT-05) | Medium | Datum construction concern — the on-chain validator cannot inspect how the datum was built off-chain. Would require adding credential-type checks, but `EscrowDatum` uses raw `ByteArray` for PKH fields. Recommend off-chain SDK validation. |
| Deadline dead zone at exact millisecond (RT-06) | Low | 1ms gap has no practical impact. Fixing would require changing from strict before/after to inclusive boundaries, which introduces its own edge cases. Documented as known behavior. |
| Zero-length secret_hash trivially claimable (RT-03) | Medium | Off-chain concern. The validator correctly enforces `blake2b_256(secret) == secret_hash` — if the hash is of an empty string, that's what the escrow creator chose. SDK should reject empty secrets. |
| Front-running via mempool (RT-02) | Informational | Already mitigated by beneficiary signature requirement. Attacker cannot front-run without the beneficiary's signing key. |

---

## Testing Expectations

The fixed contract should:
- ✅ Pass all original happy-path tests (Claim, Reclaim)
- ✅ **Reject** double-satisfaction attempts (two script inputs in one TX)
- ✅ Retain all existing authorization checks (secret, deadline, signatures, value)
