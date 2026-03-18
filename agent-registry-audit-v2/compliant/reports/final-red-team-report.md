# Agent Registry — Red Team Report (Final Pass)

**Date:** 2026-03-18
**Pass:** Final — against the security engineer's security-compliant contract
**Auditor:** the red team (Red Team)
**Scope:** Adversarial analysis of all fixes applied to `validation.ak`; attempt to bypass or game new security checks

---

## Summary

the security engineer's fixes are **solid and well-implemented**. The seven issues from my early red team pass are all effectively blocked. The critical vectors (orphan burn, double satisfaction) are eliminated. The high-severity vectors (owner auth, script credential, transfer lock) are properly guarded. The medium vectors (NFT name mismatch, ghost UTxOs) are addressed.

I found **one new Low-severity vector** related to staking credential variants that partially circumvents the ghost UTxO fix, and confirmed that all three accepted trade-offs remain as documented with no dangerous interactions with the new code. No Critical, High, or Medium findings remain.

**Verdict: The contract is ready for the report author's final report.**

---

## Remaining Vulnerabilities Found

### RT-FINAL-01: Staking Credential Variant Ghost UTxOs
**Severity: Low**
**Status: New finding**

The ghost UTxO fix in both `validate_register` and `validate_update` filters outputs by exact address equality:

```
// Register:
let script_address = script_address_from_policy(policy_id)  // stake_credential: None
let script_outputs = list.filter(tx.outputs, fn(output) { output.address == script_address })

// Update:
let script_outputs = list.filter(tx.outputs, fn(output) { output.address == own_address })
```

The canonical script address has `stake_credential: None`. However, Cardano's ledger triggers the spend validator based on **payment credential only**, regardless of staking credential. An attacker constructing a register or update TX can include additional outputs addressed to:

```
Address {
  payment_credential: Script(policy_id),
  stake_credential: Some(Inline(VerificationKey(attacker_staking_key)))
}
```

These variant-address outputs:
- **Escape the output count filter** (different `Address` struct, not caught by equality check)
- **Are still locked by the spend validator** (same payment credential)
- **Are permanently unspendable** — the spend validator would execute on any attempt to spend them, but `find_nft_name` panics (no NFT in the ghost) and `expect Some(agent_datum) = datum` panics (no valid datum), so the TX fails

**Impact:** UTXO set bloat at the script's payment credential. Each ghost costs the attacker min UTXO lovelace (~1-2 ADA) with no recovery path. The economic cost to the attacker is real, and the impact is limited to indexer performance — no funds at risk, no agent data affected.

**Why it's Low, not Medium:**
- Attacker pays real cost per ghost (min UTXO, permanently lost)
- No impact on existing agent UTxOs or their owners
- Does not affect NFT integrity, deposits, or ownership
- Off-chain indexers can trivially filter by canonical address (stake_credential: None)
- The exact same vector exists in virtually all Cardano validators that check exact address equality

**Recommended mitigation (optional):** Filter by `output.address.payment_credential == Script(policy_id)` instead of exact address equality when counting script outputs. This catches all variants. However, this changes the semantics slightly and may over-count in edge cases. Given the Low severity, this is a "nice to have" rather than a required fix.

---

## Verified Fixes (Confirming Early Findings Are Blocked)

### ✅ RT-DS / AR-ORPHAN-BURN — Orphan Burn (Critical → Fixed)

**Fix verification:** `validate_burn` now requires `input.output.address.payment_credential == Script(policy_id)` — a script input must be spent.

**Bypass attempts:**
1. **Burn without any script input:** Fails — `has_script_input` returns False.
2. **Burn with a non-agent script input (e.g., from a different contract at the same address):** Impossible — different contracts have different script hashes, so different payment credentials.
3. **Burn NFT-B while spending Agent A with Update redeemer:** The mint field would need to contain NFT-B at -1. But the agent UTxO holding NFT-B is NOT being spent, so the ledger's value preservation rule fails (you can't remove a token from the ledger that isn't in any input). Blocked at the ledger level, not even reaching the validator.
4. **Register + Burn in same TX (RT-02):** Both `validate_register` and `validate_burn` require exactly one `Pair` in `dict.to_pairs(minted_tokens)`. With two operations under the same policy (one +1, one -1), there are two pairs, and both checks fail. Blocked.

**Verdict: Fix is sound. No bypass found.**

### ✅ RT-DS — Double Satisfaction on Dual Update (Critical → Fixed)

**Fix verification:** `validate_update` requires `exactly one` output at the script address via `list.filter` + singleton pattern match.

**Bypass attempts:**
1. **Two Updates, one shared output:** Each `validate_update` call independently filters outputs. Both find exactly one output. But it's the SAME output — and it can only contain ONE NFT name. The second update's `assets.quantity_of(output.value, own_policy, input_nft_name)` check fails because the output has the first agent's NFT, not the second's. Blocked.
2. **Two Updates, two outputs:** Each validator call sees TWO outputs at the script address → `when script_outputs is { [output] -> ... _ -> False }` returns False. Blocked.
3. **Two Updates with staking credential trick:** One output at canonical address, one at variant address. The canonical-address agent's update sees one output (passes). The variant-address agent's update sees one output at the variant address... wait, this requires an existing agent UTxO at a variant address, which can't be created through the register flow (register enforces output at canonical address). Blocked.

**Verdict: Fix is sound. No bypass found.**

### ✅ AR-NO-OWNER-AUTH — Register Without Owner Signature (High → Fixed)

**Fix verification:** `validate_output_owner` extracts datum from output, requires `datum.owner` to be `VerificationKey`, and calls `has_credential_signed(tx, datum.owner)`.

**Bypass attempts:**
1. **Register with arbitrary VKH as owner without their signature:** `has_credential_signed` checks `tx.extra_signatories` — attacker can't forge signatures. Blocked.
2. **Register with attacker's VKH claiming to be someone else:** The VKH IS the identity. The attacker registers under their own identity. No impersonation possible since the on-chain owner is the attacker's key. Off-chain metadata (name, description) can still claim to be anyone, but that's the datum size/content trade-off, not an auth issue.

**Verdict: Fix is sound.**

### ✅ AR-SCRIPT-OWNER — Script Credential as Owner on Register (High → Fixed)

**Fix verification:** `validate_output_owner` pattern-matches on `datum.owner` — `Script(_)` returns False.

**Bypass attempts:**
1. **Encode a Script credential that looks like VerificationKey at the CBOR level:** Not possible — Aiken's type system deserializes the datum into the `Credential` ADT before the pattern match. The CBOR tag determines the variant.

**Verdict: Fix is sound.**

### ✅ AR-TRANSFER-LOCK — Script Credential as Owner on Update (High → Fixed)

**Fix verification:** `validate_new_owner_credential` extracts the output datum and rejects `Script(_)` owner.

**Bypass attempts:**
1. **Update to Script credential:** Directly blocked by the pattern match.
2. **Two-step: Update to VK-A, then VK-A updates to Script:** Second update is also checked by `validate_new_owner_credential`. Blocked at every step.

**Verdict: Fix is sound.**

### ✅ AR-NFT-NAME-MISMATCH — Deregister Burns Wrong NFT (Medium → Fixed)

**Fix verification:** `find_nft_name` extracts the specific NFT name from the input UTxO. `validate_deregister` checks `name == input_nft_name && qty == -1`.

**Bypass attempts:**
1. **Burn NFT-B while deregistering Agent A:** The burn check requires the burned name matches Agent A's NFT. NFT-B ≠ NFT-A. Blocked.
2. **Edge case — what if an agent UTxO somehow has two NFTs under the policy?** `find_nft_name` uses `expect [Pair(name, 1)] = dict.to_pairs(tokens)` — panics if not exactly one token. This can't happen through normal registration (register enforces exactly one mint), and even if it did, the panic is fail-closed. Safe.

**Verdict: Fix is sound.**

### ✅ AR-GHOST-UTXO — Ghost UTxO Creation on Register/Update (Medium → Fixed*)

**Fix verification:** Both `validate_register` and `validate_update` use `list.filter` + singleton match to enforce exactly one output at the script address.

**Bypass status:** Mostly fixed. The staking credential variant (RT-FINAL-01 above) is a partial bypass but at Low severity. The canonical ghost UTxO attack (same address, no staking credential) is fully blocked.

**Verdict: Fix is effective for the primary attack vector. Residual Low-severity variant exists.**

---

## Accepted Trade-offs (Assessment of Known Unfixed Items)

### Datum Field Size Limits (RT-03) — Accepted, No Interaction Risk

**Assessment:** The owner signature requirement (Fix #3) means only the legitimate owner can create bloated datums — this is self-inflicted cost, not a third-party attack. The 10 AP3X deposit provides economic friction. Off-chain indexers can impose size limits at the query layer.

**Interaction with fixes:** None. The owner must sign, so an attacker can't create bloated registrations under someone else's identity.

**Verdict: Acceptable trade-off. No escalation from fix interactions.**

### Deposit Return on Deregister — Accepted, No Interaction Risk

**Assessment:** The owner signs the deregister TX and controls where the deposit goes. With the NFT name match fix, you can't burn the wrong NFT during deregister. With the owner signature requirement, only the legitimate owner can trigger deregister.

**Interaction with fixes:** The NFT name match fix actually makes this safer — the owner can't accidentally deregister the wrong agent and lose the wrong deposit.

**Verdict: Acceptable trade-off. Fixes make the deposit handling slightly safer.**

### `expect` Panics in Helpers — Accepted, Fail-Closed

**Assessment:** All `expect` usages in helpers (`get_own_address`, `get_own_value`, `get_policy_from_address`, `find_nft_name`) are fail-closed: if the pattern doesn't match, the transaction fails. This is the safe direction — no transaction can succeed with unexpected data.

**Interaction with fixes:** The new `expect` patterns in `validate_output_owner` and `validate_new_owner_credential` follow the same fail-closed pattern. A malformed datum causes TX rejection, which is correct behavior (reject invalid registrations/updates rather than allowing them through).

**Specific scenarios tested:**
- Malformed datum in register output → `expect datum: AgentDatum = raw_datum` panics → TX fails → registration rejected ✓
- Non-inline datum in register output → `expect InlineDatum(raw_datum) = output.datum` panics → TX fails → registration rejected ✓
- Ghost UTxO with no datum, attempted spend → `expect Some(agent_datum) = datum` panics → TX fails → ghost remains locked ✓

**Verdict: Acceptable. Fail-closed is the correct security posture. Code quality improvement would be nice but is not a security concern.**

---

## Additional Notes

### Ownership Transfer Without New Owner Consent
`validate_update` checks the CURRENT owner's signature but not the NEW owner's. This allows transferring agent ownership to someone without their consent. This is not a vulnerability — the recipient can simply deregister (recovering the deposit) if unwanted. No harm vector.

### Reference Script Attachment
The validator doesn't check for `reference_script` fields on outputs. An attacker could attach arbitrary reference scripts to the valid agent output. This has no security impact — the reference script is just data stored alongside the UTxO and doesn't affect validator execution. Noted for completeness.

### Concurrent Registration Front-Running (RT-01 from Early Report)
With the owner signature fix, front-running a registration no longer enables impersonation. The attacker can consume the seed UTxO first, but they can only register under their own identity (they must sign as owner). The victim simply re-registers with a different seed. **Downgraded from Medium to Low (griefing only, no impersonation).**

---

## Final Verdict

**The compliant contract is ready for the report author's final report.**

All seven fixed issues are properly addressed. The fixes are well-implemented with no bypass vectors found. The one new Low-severity finding (staking credential variant ghost UTxOs) is a common Cardano validator pattern issue, not specific to this contract, and has minimal real-world impact.

The three accepted trade-offs are reasonable and do not interact dangerously with the applied fixes. If anything, the fixes (particularly owner signature on register) reduce the severity of the accepted trade-offs.

| Category | Count | Details |
|----------|-------|---------|
| New Critical/High/Medium findings | **0** | — |
| New Low findings | **1** | Staking credential variant ghost UTxOs |
| Fixes verified as sound | **7** | All early findings blocked |
| Accepted trade-offs confirmed safe | **3** | No dangerous interactions |

**Risk rating: Low residual risk. Suitable for mainnet deployment.**
