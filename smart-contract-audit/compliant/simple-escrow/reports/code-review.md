# Simple Escrow — Code Review (Cold Read)

**Date:** 2026-03-18
**Source:** `original/simple_escrow.ak`
**Reference:** `original/README.md`

---

## Executive Summary

The contract is compact (121 lines) and well-structured. The two spending paths (Claim and Reclaim) are clearly separated with appropriate authorization checks (signatures, secret verification, deadline enforcement). The `assets_gte` helper for value preservation is correctly implemented.

However, the contract has a **critical double satisfaction vulnerability** that the author acknowledges in the README but does NOT fix in the code. The code comments claim mitigation ("defends against double satisfaction: each input's value must be accounted for in a distinct output"), but this claim is incorrect — `list.any` does not guarantee distinct outputs across multiple validator invocations.

Additionally, there are several medium-severity gaps around output matching, credential type validation, and deadline edge cases.

---

## Per-Function Analysis

### `spend` handler — Claim path

**What it checks:**
1. Secret hashes to `d.secret_hash` via `blake2b_256`
2. Validity range is entirely before `d.deadline` via `interval.is_entirely_before`
3. Beneficiary signed (`list.has(tx.extra_signatories, d.beneficiary)`)
4. An output pays at least locked value to beneficiary (`list.any` + `assets_gte`)

**Gaps:**

- **`list.any` for output matching (CRITICAL).** The check `list.any(tx.outputs, fn(output) { ... })` finds *any* output that satisfies the condition. If two escrow UTxOs have the same beneficiary, spending both in one TX requires only ONE output that covers the value of the LARGER escrow. The smaller escrow's value requirement is automatically satisfied by the same output. Net result: attacker drains both UTxOs while paying only the max, pocketing the difference.

  The code comment says "each input's value must be accounted for in a distinct output" — this is **false**. `list.any` provides no distinctness guarantee. Two validator calls in the same TX will both find the same output.

- **No credential type validation on `d.beneficiary`.** The beneficiary is checked via `VerificationKey(d.beneficiary)` when matching the output address, and `list.has(tx.extra_signatories, d.beneficiary)` for signature. If the datum stored a script hash instead of a VKH, the `extra_signatories` check would fail (scripts don't appear in signatories), making the escrow permanently unclaimable. The reclaim path (sender) has the same issue.

- **No datum validation.** The contract doesn't validate that `d.secret_hash` is non-empty, that `d.deadline` is positive, or that `d.beneficiary != d.sender`. A zero-length secret_hash would be trivially claimable by anyone providing an empty byte string.

### `spend` handler — Reclaim path

**What it checks:**
1. Validity range is entirely after `d.deadline` via `interval.is_entirely_after`
2. Sender signed
3. An output pays at least locked value to sender (`list.any` + `assets_gte`)

**Gaps:**

- **Same `list.any` double satisfaction vulnerability** as Claim path — two reclaims in one TX can share one output.

- **Deadline dead zone.** If `is_entirely_before(range, deadline)` requires `upper < deadline` and `is_entirely_after(range, deadline)` requires `lower > deadline`, then a TX with `lower == deadline` fails both checks. This creates a brief window where neither Claim nor Reclaim is valid. The impact is minimal (wait one millisecond), but it means there's no atomic deadline boundary.

### `assets_gte` helper

**Correct.** Flattens the reference value, checks each (policy, name, qty) entry against the candidate. This properly handles multi-asset values and is not vulnerable to token smuggling (checking >= for every asset in the locked value).

One edge case: if the locked value contains zero-quantity tokens (shouldn't happen in practice but theoretically possible), the check would pass trivially for those entries. Not exploitable.

### `else` handler

Not explicitly defined. Aiken's default for validators without an `else` handler is to fail, which is correct.

---

## Intent vs Implementation Divergences

| # | README/Comments Say | Actual Implementation | Severity |
|---|-------------------|---------------------|----------|
| 1 | "Mitigated by requiring the output pays to the correct beneficiary/sender address AND the value is at least the input value" | `list.any` finds any matching output — no distinctness guarantee | **Critical** — direct contradiction |
| 2 | "Production fix: add script_input_count == 1" | Fix not applied — no script input counting | **Critical** — acknowledged but unfixed |
| 3 | Implicit: datum fields should be valid | No validation of secret_hash, deadline, or sender/beneficiary | **Medium** |
| 4 | "Dead zone at exact deadline millisecond" | Both `is_entirely_before` and `is_entirely_after` reject at exact deadline | **Low** — acknowledged |
| 5 | Implicit: credential should be key-based | No credential type validation for beneficiary or sender | **Medium** |

---

## eUTXO-Specific Risks

### Double Satisfaction (Critical)
The contract's primary vulnerability. Two escrow UTxOs with the same beneficiary can be spent in one TX. Both validator calls use `list.any` to find a matching output. The same output satisfies both. If escrow A has 10 AP3X and escrow B has 5 AP3X, the attacker creates one output with 10 AP3X to the beneficiary. Both validators pass (10 >= 10, 10 >= 5). The attacker pockets 5 AP3X.

**With 2 live UTxOs on testnet (10 + 5 AP3X), this is directly testable.**

### Front-Running (Medium)
When a Claim TX is broadcast, the secret is visible in the mempool. An attacker can:
1. See the secret in the pending TX
2. Submit their own Claim TX with the same secret and higher fees
3. Their TX lands first, stealing the funds

This is inherent to the hash-lock pattern and cannot be fixed on-chain alone. Off-chain solutions include commit-reveal schemes or encrypted mempools.

### Ghost UTxO Potential (Low)
The contract doesn't create outputs at the script address (no continuation UTxO), so ghost UTxO creation is not a risk here.

---

## Test Gap Analysis

The contract has no test file included in the submission. The following areas need full test coverage:

| Gap | Risk Level |
|-----|------------|
| Double satisfaction — two Claim spends, one output | Critical |
| Double satisfaction — two Reclaim spends, one output | Critical |
| Double satisfaction — one Claim + one Reclaim in same TX | Critical |
| Empty secret_hash in datum (trivially claimable) | Medium |
| Deadline dead zone (exact millisecond) | Low |
| Script credential as beneficiary (permanent lock) | Medium |
| Script credential as sender (permanent reclaim lock) | Medium |
| Beneficiary == sender in datum | Low |
| Value preservation — multi-asset escrow | Medium |
| Claim after deadline (should fail) | Behavioral |
| Reclaim before deadline (should fail) | Behavioral |
| Wrong secret (should fail) | Behavioral |
| Wrong signer on Claim (should fail) | Behavioral |
| Wrong signer on Reclaim (should fail) | Behavioral |

---

## Inputs for Test Writer (numbered list)

1. **Double satisfaction — two Claims, one output (CRITICAL).** Construct a TX spending two escrow UTxOs (same beneficiary) with Claim redeemer, providing one output with value >= max(input_a, input_b). Verify it passes on the original (proving the vulnerability). Behavioral test: should FAIL on compliant.

2. **Double satisfaction — two Reclaims, one output.** Same pattern for Reclaim path with two UTxOs from the same sender.

3. **Double satisfaction — mixed Claim + Reclaim.** Spend two UTxOs in one TX: one with Claim, one with Reclaim. If beneficiary and sender are different, this is legitimate. If they're the same person, one output could satisfy both. Test both cases.

4. **Empty secret_hash.** Create an escrow with `secret_hash = blake2b_256("")`. Verify that providing `secret = ""` successfully claims. Behavioral documentation: contract accepts trivially claimable escrows.

5. **Script credential as beneficiary.** Create datum with a script hash as beneficiary. Verify Claim fails (extra_signatories won't contain a script hash). Document: escrow becomes permanently unclaimable.

6. **Script credential as sender.** Same for sender — Reclaim path permanently blocked.

7. **Deadline dead zone.** Set validity range lower bound == deadline, upper bound == deadline + 1ms. Verify both `is_entirely_before` and `is_entirely_after` reject.

8. **Claim after deadline (should fail).** Set validity range entirely after deadline. Verify Claim rejects.

9. **Reclaim before deadline (should fail).** Set validity range entirely before deadline. Verify Reclaim rejects.

10. **Wrong secret.** Provide incorrect secret. Verify Claim rejects.

11. **Wrong signer on Claim.** Someone other than beneficiary signs. Verify Claim rejects.

12. **Wrong signer on Reclaim.** Someone other than sender signs. Verify Reclaim rejects.

13. **Successful Claim (happy path).** Correct secret, before deadline, beneficiary signs, output pays correct amount.

14. **Successful Reclaim (happy path).** After deadline, sender signs, output pays correct amount.

15. **Value preservation — exact amount.** Output pays exactly the locked amount (boundary).

16. **Value preservation — less than locked.** Output pays less. Verify rejection.

17. **Front-running simulation.** Two Claim TXs with the same secret but different signers. Both should pass independently (the contract can't prevent front-running — document this as inherent limitation).
