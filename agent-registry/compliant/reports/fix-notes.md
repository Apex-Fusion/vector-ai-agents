# the security engineer — Security Fix Notes

**Date:** 2026-03-18
**Scope:** All findings from the code reviewer code review + the red team red team report
**Files modified:** `validation.ak` (primary), `types.ak` (unchanged), `validators/registry.ak` (unchanged)

---

## Fixes Applied

### 1. [CRITICAL] Burn coupled to Deregister (AR-ORPHAN-BURN)

**Function:** `validate_burn`
**Fix:** Added check that at least one transaction input has `payment_credential == Script(policy_id)` — i.e., an agent UTxO at the script address is being spent in the same TX.
**Reasoning:** Without this coupling, `Burn` could fire independently of `Deregister`, destroying the NFT while the UTxO (and its deposit) remains permanently locked. The fix ensures burn can only happen when the spend validator is also executing on an agent UTxO.
**Exploit tests blocked:** `exploit_orphan_burn_no_spend`, `exploit_orphan_burn_with_unrelated_inputs`

### 2. [CRITICAL] Double satisfaction on dual Update (RT-DS)

**Function:** `validate_update`
**Fix:** Replaced `list.any` output matching with `list.filter` + exact count check. Now requires **exactly one** output at the script address, and that single output must satisfy all conditions.
**Reasoning:** With `list.any`, two simultaneous Update spends could share one continuing output, effectively stealing one deposit. Enforcing exactly one script output per TX eliminates double satisfaction entirely.
**Exploit tests blocked:** `exploit_ghost_utxo_update_succeeds` (also prevents the dual-update deposit extraction described in RT-DS)

### 3. [HIGH] Register requires owner signature (AR-NO-OWNER-AUTH)

**Function:** `validate_register`
**Fix:** Added `validate_output_owner` helper that extracts the `AgentDatum` from the output, reads `owner`, and calls `has_credential_signed(tx, owner)`.
**Reasoning:** Without owner signature, anyone can register agents claiming arbitrary VKHs as owners, polluting the registry with fake entries under legitimate identities.
**Exploit tests blocked:** `exploit_register_without_owner_signature`, `exploit_register_attacker_signs_victim_as_owner`

### 4. [HIGH] Register validates owner credential type (AR-SCRIPT-OWNER)

**Function:** `validate_register` → `validate_output_owner`
**Fix:** The `validate_output_owner` helper explicitly checks `datum.owner` is `VerificationKey`. If it's `Script`, registration is rejected.
**Reasoning:** A `Script` credential as owner makes the UTxO permanently unspendable since `has_credential_signed` always returns `False` for script credentials. Blocking at registration prevents deposit loss.
**Exploit tests blocked:** `exploit_script_credential_owner_register_succeeds`

### 5. [HIGH] Update validates new owner credential type (AR-TRANSFER-LOCK)

**Function:** `validate_update`
**Fix:** Added `validate_new_owner_credential` helper that extracts the output datum and rejects `Script` credentials as the new owner.
**Reasoning:** D7 intentionally allows key-to-key ownership transfer. But transferring to a Script credential permanently locks the UTxO. The fix preserves D7 while guarding against the lock.
**Exploit tests blocked:** `exploit_update_transfers_to_script_credential`

### 6. [MEDIUM] Deregister verifies burned NFT name matches UTxO's NFT (AR-NFT-NAME-MISMATCH)

**Function:** `validate_deregister`
**Fix:** Now extracts `input_nft_name` from the spent UTxO's value using `find_nft_name`, and checks that the burned token's name matches.
**Reasoning:** Original only checked `qty == -1` under the policy without verifying which token name was burned. With multiple registered agents (multiple NFTs under the same policy), an owner could burn the wrong NFT.
**Exploit tests blocked:** `exploit_deregister_burns_wrong_nft_name`

### 7. [MEDIUM] Limit outputs at script address — Register (AR-GHOST-UTXO)

**Function:** `validate_register`
**Fix:** Replaced `list.any` with `list.filter` + pattern match on singleton list. Exactly one output at script address allowed.
**Reasoning:** `list.any` accepts one valid output among many — ghost UTxOs (lovelace-only, no NFT) can be created alongside. These are permanently unspendable and clutter the script address.
**Exploit tests blocked:** `exploit_ghost_utxo_register_succeeds`

---

## Findings NOT Fixed (Out of Scope / Low Priority)

### Datum field size limits (RT-03)
**Severity:** Low-Medium
**Decision:** Not fixed. Adding byte-length limits on `name`, `description`, `endpoint`, `capabilities` would require type changes or hardcoded constants. The 10 AP3X deposit provides some economic deterrent. This is better handled off-chain by indexers.

### Deposit return enforcement on Deregister (AR-DEPOSIT-DESTINATION)
**Severity:** Medium (economic, not security)
**Decision:** Not fixed. The owner must sign the deregister TX, so they are authorizing where the deposit goes. Enforcing deposit return would add complexity and may conflict with legitimate use cases (e.g., owner sending deposit to a different wallet they control). The behavioral test `behavior_deregister_deposit_destination_not_enforced` explicitly documents this as intended behavior.

### `expect`-based panics in helpers (code quality)
**Decision:** Not fixed. `get_policy_from_address`, `find_nft_name`, `get_own_address`, and `get_own_value` use `expect` which panics on unexpected input. In practice, these are only called on UTxOs that are being spent (guaranteed to be in inputs) at script addresses (guaranteed to have Script credential). Converting to clean `False` returns would improve robustness but is a code quality enhancement, not a security fix.

---

## Mutually Exclusive Cases (Behavioral Test Conflicts)

The following behavioral tests document **current behavior that IS the vulnerability**. The security fixes intentionally change this behavior. These tests will need to be updated to include the new security requirements:

### Conflict 1: Register behavioral tests vs. Owner Signature Requirement

**Affected tests:**
- `behavior_register_with_empty_name`
- `behavior_register_with_empty_endpoint`
- `behavior_register_with_empty_capabilities`
- `behavior_register_with_zero_registered_at`
- `behavior_register_with_negative_registered_at`
- `behavior_register_accepts_large_deposit`
- `behavior_register_with_many_capabilities`

**Issue:** All seven tests construct register TXs without `extra_signatories`. The datum uses `owner: VerificationKey(test_owner_vkh)` but `test_owner_vkh` is not in the TX signatories. With the owner signature fix (Fix #3), these tests will fail.

**Resolution:** These tests need `extra_signatories: [test_owner_vkh]` added to their transaction construction. The behavioral property they test (empty fields accepted, large deposits accepted, etc.) is orthogonal to the signature requirement — they just need the TX to be properly constructed.

### Conflict 2: Burn behavioral test vs. Burn-Deregister Coupling

**Affected test:**
- `behavior_burn_accepts_any_nft_name_with_correct_quantity`

**Issue:** This test calls `validate_burn` with `tx = Transaction { ..placeholder, mint: mint_value }` — no inputs at all. With the burn coupling fix (Fix #1), this test will fail because there's no script input.

**Resolution:** This test documents behavior that is itself the vulnerability (orphan burn). The compliant version intentionally disallows standalone burns. This behavioral test should be removed or rewritten to test burn-with-deregister instead.

---

## Summary

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | Orphan burn (burn without deregister) | Critical | ✅ Fixed |
| 2 | Double satisfaction (dual update) | Critical | ✅ Fixed |
| 3 | No owner signature on register | High | ✅ Fixed |
| 4 | Script credential as owner (register) | High | ✅ Fixed |
| 5 | Script credential as owner (update transfer) | High | ✅ Fixed |
| 6 | NFT name mismatch on deregister | Medium | ✅ Fixed |
| 7 | Ghost UTxO creation (register) | Medium | ✅ Fixed |
| 8 | Ghost UTxO creation (update) | Medium | ✅ Fixed (same mechanism as #2) |
| 9 | Datum field size limits | Low-Medium | ⏭️ Not fixed (off-chain concern) |
| 10 | Deposit return on deregister | Medium | ⏭️ Not fixed (by design, owner signs) |
| 11 | `expect` panics in helpers | Low | ⏭️ Not fixed (code quality) |
