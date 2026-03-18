# Agent Registry — Code Review (Delta Review)

**Reviewer:** the code reviewer
**Date:** 2026-03-18
**Scope:** Delta review of the security engineer's security fixes against original `validation.ak`
**Input:** `iskra-fix-notes.md`, diff between original and compliant `validation.ak`

---

## Summary

the security engineer made 7 targeted fixes across 4 functions (`validate_register`, `validate_burn`, `validate_update`, `validate_deregister`) and introduced 2 new helper functions (`validate_output_owner`, `validate_new_owner_credential`). All fixes address real vulnerabilities identified in the prior audit rounds.

**Verdict: All fixes are sound. No new logic errors, exploitable paths, or unintended side effects introduced.**

The changes are minimal and surgical — each fix does exactly what it needs to and nothing more. The two new helpers are clean, and the `list.any` → `list.filter` + singleton pattern is applied consistently across Register and Update.

---

## Fix-by-Fix Assessment

### Fix 1 — Burn-Deregister Coupling (`validate_burn`)

**Change:** Added `has_script_input` check requiring at least one TX input with `payment_credential == Script(policy_id)`.

**Assessment: ✅ Sound.**

- **Can it be gamed with a fake UTxO at the script address?** No. If an attacker creates a UTxO at the script address (anyone can send to any address), the spend validator also executes on that input. The spend validator requires either:
  - **Update:** owner signature + valid continuing output with correct NFT — fake UTxO without the right NFT panics at `find_nft_name` (`expect [Pair(name, 1)]`)
  - **Deregister:** owner signature + correct NFT burned — name mismatch check (Fix 6) prevents burning a different agent's NFT
- The `expect` panic in `find_nft_name` acts as an implicit guard: a UTxO without exactly one NFT under the policy at the script address cannot satisfy either spend path.
- **Sufficient coupling:** The burn validator doesn't need to verify *which* agent UTxO is being spent — that's the spend validator's job. It only needs to confirm the spend validator is actually executing, which `Script(policy_id)` input guarantees.

### Fix 2 — Double Satisfaction Prevention (`validate_update`)

**Change:** Replaced `list.any` with `list.filter` + singleton match on `script_outputs`.

**Assessment: ✅ Sound.**

- Eliminates double satisfaction completely — two Update spends in one TX would each independently require exactly one output at the script address, which is impossible to satisfy for both simultaneously.
- **Behavioral trade-off:** Batching multiple agent updates in a single TX is no longer possible. This is a deliberate and justified sacrifice — batching was the attack vector.
- No interaction issues with other validation paths. Register also uses the singleton pattern now, so the approach is consistent.

### Fix 3 — Owner Signature on Register (`validate_output_owner`)

**Change:** New helper extracts `AgentDatum` from output, calls `has_credential_signed(tx, datum.owner)`.

**Assessment: ✅ Sound.**

- **`expect` safety:** The `expect InlineDatum(raw_datum) = output.datum` is safe because `has_inline_datum(output)` is evaluated first in the `and {}` block, which short-circuits in Aiken. The `expect` is only reached when the datum is confirmed inline.
- **`expect datum: AgentDatum = raw_datum`:** If the datum doesn't deserialize to `AgentDatum`, the TX panics and fails — correct behavior (reject garbage datums at registration).
- Properly reuses `has_credential_signed`, which already returns `False` for non-VK credentials, but the explicit `Script(_) -> False` branch (Fix 4) makes the rejection reason clearer and prevents any future changes to `has_credential_signed` from weakening this check.

### Fix 4 — Script Credential Rejection on Register (`validate_output_owner`)

**Change:** Explicit `when datum.owner is { VerificationKey(_) -> ..., Script(_) -> False }` pattern.

**Assessment: ✅ Sound.**

- The match is exhaustive over `Credential` variants (VK and Script). No missing branches.
- Defence-in-depth: even though `has_credential_signed` returns `False` for `Script` credentials, the explicit rejection prevents a class of future bugs if `has_credential_signed` were ever modified.

### Fix 5 — Script Credential Rejection on Update (`validate_new_owner_credential`)

**Change:** New helper extracts output datum and rejects `Script` owner credentials.

**Assessment: ✅ Sound, with one design note.**

- Same `expect` safety as Fix 3 — `has_inline_datum` guards the path.
- **Design observation:** This helper checks the credential *type* but does NOT require the new owner to have signed. This is correct for D7 (ownership transfer) — the current owner authorizes the transfer; the new owner accepts implicitly. A malicious current owner could transfer to an arbitrary VKH, but they'd only be hurting themselves (losing control of their own agent). The new owner simply inherits control.
- **No gap:** The new owner will need to sign future Update/Deregister TXs, so transferring to a VKH you don't control is self-sabotage, not an attack vector.

### Fix 6 — NFT Name Matching on Deregister (`validate_deregister`)

**Change:** Extracts `input_nft_name` from the spent UTxO's value using `find_nft_name`, then checks the burned token's name matches.

**Assessment: ✅ Sound.**

- The original only checked `qty == -1` without verifying *which* token was burned. With multiple agents under the same policy, this allowed burning a different agent's NFT.
- `find_nft_name` uses `expect [Pair(name, 1)]` — panics if the UTxO doesn't have exactly one token with qty 1 under the policy. This is correct: a valid agent UTxO should always have exactly one identity NFT.
- Combined with Fix 1 (burn coupling), this creates a tight chain: burn must accompany a spend, and the spend verifies the correct NFT is burned.

### Fix 7 — Singleton Output on Register (`validate_register`)

**Change:** Replaced `list.any` with `list.filter` + singleton match, same pattern as Fix 2.

**Assessment: ✅ Sound.**

- Prevents ghost UTxO creation during registration.
- Consistent with the Update approach (Fix 2), making the codebase predictable.

---

## New Issues Introduced (if any)

**None identified.** Specific concerns investigated and cleared:

1. **Batching restriction (Fix 2/7):** Both Register and Update now reject TXs with multiple outputs at the script address. This prevents batching multiple registrations or updates in one TX. This is a design trade-off, not a bug — and the correct one given the vulnerability class.

2. **`expect` panics in new helpers:** Both `validate_output_owner` and `validate_new_owner_credential` use `expect` for datum extraction. These are safe due to Aiken's `and {}` short-circuit evaluation guaranteeing `has_inline_datum` runs first. If datum deserialization fails (malformed datum), the panic correctly rejects the TX.

3. **Burn coupling bypass via crafted UTxOs:** Investigated whether an attacker could send a specially crafted UTxO to the script address to satisfy the burn coupling without a real deregister. Conclusion: not possible — the spend validator executes on all script-address inputs, and `find_nft_name`'s `expect` panics on UTxOs without exactly one policy token.

---

## Inputs for the test writer's Final Sweep (anything to recheck)

1. **Confirm Aiken `and {}` short-circuit semantics.** The safety of `expect` in `validate_output_owner` and `validate_new_owner_credential` depends on `and {}` short-circuiting (not evaluating later expressions when an earlier one is `False`). This is the documented Aiken behavior, but the test writer should verify this against the specific Aiken version used in the project.

2. **Batching restriction scope.** The singleton output constraint in `validate_update` means only one agent can be updated per TX. If the protocol ever needs batched updates (e.g., for a multi-agent management tool), this would need to be revisited with a different double-sat prevention mechanism (e.g., checking input-output pairing by NFT name). Not a current issue — just a forward-looking note.

3. **Pre-existing `expect` panics in helpers.** the security engineer explicitly called out `get_policy_from_address`, `find_nft_name`, `get_own_address`, and `get_own_value` as using `expect` that panics on unexpected input. These are pre-existing (not introduced by the fixes) and are safe in the current call paths, but the test writer may want to note them in the final report as code quality observations.

4. **`script_address_from_policy` assumes `stake_credential: None`.** Pre-existing, not introduced by the security engineer. If the actual deployment uses a staked script address, the address comparison in `validate_register` and `validate_update` would fail to match. the test writer should confirm the deployment address matches this assumption.

5. **Deregister deposit destination still not enforced.** the security engineer explicitly chose not to fix this (owner must sign, so they control where deposit goes). the test writer should confirm this is acceptable for the final report — it's a conscious design decision, not an oversight.

---

*Delta review complete. the security engineer's fixes are clean, targeted, and introduce no new attack surface. Ready for the test writer's final sweep.*
