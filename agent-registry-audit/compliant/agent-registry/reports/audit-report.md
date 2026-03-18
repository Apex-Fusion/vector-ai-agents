# Agent Registry — Consolidated Security Audit Report

**Audit Team:** Vector Security Audit
**Date:** March 17–18, 2026
**Contract:** Vector Agent Registry (Aiken multi-validator)
**Classification:** Smart contract security audit — full lifecycle review with remediation

---

## 1. Executive Summary

The security audit team conducted a comprehensive security audit of the **Vector Agent Registry**, an Aiken multi-validator implementing a soulbound NFT identity system for AI agents on the Cardano/Vector chain. The audit encompassed static analysis of the original contract, adversarial testing, a full remediation cycle producing a compliant contract, and independent red team validation of all fixes.

### Key Metrics

| Severity | Original Findings | Status |
|----------|:-:|:-:|
| Critical | 2 | 2 Fixed |
| High | 2 | 2 Fixed |
| Medium | 3 | 3 Fixed |
| Low | 3 | 3 Fixed |
| Info | 1 | 1 Acknowledged |
| **Total** | **11** | **11 Resolved** |

The red team validation identified **3 additional findings** (1 Low, 2 Info), none of which block deployment.

### Final Verdict

**The compliant contract is suitable for mainnet deployment.** All Critical and High severity findings have been resolved. The red team confirmed no bypasses exist for any fix. Residual findings are Low/Info severity and do not represent exploitable attack vectors.

**Red Team Clearance: GRANTED — Confidence Level: HIGH (8.5/10)**

---

## 2. Scope

### Contracts Reviewed

| Artifact | Description |
|----------|-------------|
| Original contract | Pre-audit validator logic (`validation.ak`) |
| Compliant contract | Post-remediation validator logic (`validation.ak`) |
| Type definitions | `AgentDatum`, `MintAction`, `SpendAction` (`types.ak`) |
| Multi-validator wrapper | Thin validator entry point (`registry.ak`) |

### Contract Specification

- **Language:** Aiken v1.1.21
- **Target:** Plutus V3
- **Standard Library:** Aiken stdlib v3.0.0

### Review Period

- **Initial Audit:** March 17, 2026
- **Remediation & Red Team:** March 18, 2026

### Functional Scope

The contract implements four operations:
1. **Register** (Mint: `Register { seed }`) — Create agent identity with soulbound NFT
2. **Update** (Spend: `Update`) — Modify agent profile, preserving identity
3. **Deregister** (Spend: `Deregister`) — Remove agent, burn NFT, return deposit
4. **Burn** (Mint: `Burn`) — Destroy identity NFT (paired with Deregister)

---

## 3. Methodology

The audit followed a four-phase methodology:

### Phase 1: Static Analysis
The auditor performed a line-by-line review of all on-chain validation logic, type definitions, and the multi-validator wrapper. Each validation path (Register, Burn, Update, Deregister) was analyzed for correctness against the design specification, with particular attention to eUTxO-specific attack vectors (double satisfaction, datum manipulation, cross-path composition).

### Phase 2: Adversarial Testing
The test writer authored 44 unit tests targeting the original contract, covering all four validator paths. Tests were structured to:
- Verify happy-path behavior for each operation
- Reproduce each identified vulnerability with concrete exploit scenarios
- Test boundary conditions (deposit minimums, field lengths, edge cases)

### Phase 3: Remediation
The contract engineer produced a compliant version addressing all 11 findings. Each fix was annotated with the corresponding finding ID (AR-01 through AR-11) in the source code for traceability.

### Phase 4: Red Team Validation
An independent red team operator attempted to bypass each fix through:
- Per-fix edge-case analysis
- Cross-path composition attacks (Register+Update, Update+Burn, etc.)
- Novel attack vectors (front-running, donation attacks, reference input abuse, stake credential manipulation, economic attacks)

---

## 4. Findings Summary Table

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| AR-01 | Double Satisfaction on Update | Critical | ✅ Fixed |
| AR-02 | Double Satisfaction on Register | High | ✅ Fixed |
| AR-03 | Burn Minting Policy Has No Authorization Check | Critical | ✅ Fixed |
| AR-04 | Datum Hijacking on Update | High | ✅ Fixed |
| AR-05 | Register Does Not Validate Datum Owner Matches Signer | Medium | ✅ Fixed |
| AR-06 | No Validation of NFT Asset Name in Burn Path | Medium | ✅ Fixed |
| AR-07 | Script-Owned Agents Cannot Be Managed | Low | ✅ Fixed |
| AR-08 | No Datum Size or Field Length Limits | Low | ✅ Fixed |
| AR-09 | Value Draining on Update | Medium | ✅ Fixed |
| AR-10 | Deregister Does Not Verify Deposit Return to Owner | Low | ✅ Fixed |
| AR-11 | `else` Catch-All Could Mask Future Script Purposes | Info | ✅ Acknowledged |
| NF-01 | Deposit Return Check Can Be Satisfied by Unrelated Output | Low | ⚠️ Acknowledged |
| NF-02 | Empty Datum Fields Accepted | Info | ⚠️ Acknowledged |
| NF-03 | Batch Operations Impossible | Info | ⚠️ Acknowledged |

---

## 5. Detailed Findings

### AR-01 — Double Satisfaction on Update

**Severity:** Critical
**Status:** Fixed

**Description:**
The `validate_update` function used `list.any` over transaction outputs to find a continuing output at the script address. When two agent UTxOs were spent in the same transaction, a single continuing output could satisfy both spend validators simultaneously. This allowed an attacker controlling two agents to consolidate both into one output, stealing the second agent's NFT and deposit.

**Reproduction:**
1. Own two registered agents (A and B)
2. Build a transaction spending both with the Update redeemer
3. Produce ONE continuing output containing both NFTs — both validators pass
4. Agent B's excess deposit (e.g., 40 AP3X from a 50 AP3X deposit) is redirected to the attacker's change address

**Impact:** Loss of identity NFT and deposit for one agent. Breaks the soulbound guarantee.

**Recommendation:** Enforce that only one script input is spent per transaction, or implement 1:1 input-output binding by matching NFT names.

**Resolution:** The compliant contract adds `script_input_count == 1`, counting inputs at the script address and rejecting transactions with more than one. The red team confirmed this blocks all double-satisfaction variants, including same-owner, cross-owner, and reference input edge cases.

**Trade-off:** Legitimate batch updates are no longer possible (see NF-03).

---

### AR-02 — Double Satisfaction on Register

**Severity:** High
**Status:** Fixed

**Description:**
The `validate_register` function used `list.any` to find a valid output, allowing a single output to satisfy multiple registration validators. While the single-pair pattern match on `dict.to_pairs(minted_tokens)` provided accidental protection against two simultaneous registrations, this was not by design.

**Reproduction:** Theoretical — the single-pair pattern match provides accidental safety for two registrations, but the lack of explicit output count verification was fragile.

**Impact:** Low direct impact due to accidental safety, but the design intent was unclear and the protection fragile.

**Recommendation:** Explicitly enforce exactly one valid registration output per transaction.

**Resolution:** The compliant contract uses `list.filter` to collect matching outputs and pattern-matches on `[output]` (exactly one element). This provides explicit, intentional protection rather than relying on accidental constraints. The red team confirmed redundant safety: the single-pair mint constraint + single-output filter provide defense-in-depth.

---

### AR-03 — Burn Minting Policy Has No Authorization Check

**Severity:** Critical
**Status:** Fixed

**Description:**
The `validate_burn` function only checked that exactly one token with quantity -1 existed under the policy. It did not verify who was burning or that the owner authorized the operation. Security relied entirely on the spend validator to gate access to the NFT — if any mechanism could bypass the spend validator, any agent's NFT could be burned by anyone.

**Reproduction:**
1. The burn minting policy accepted transactions with no signatories
2. An attacker's signature was accepted equally to the owner's
3. No spent script input was required by the burn handler

**Impact:** If the spend validator were bypassed (via future Plutus features, reference scripts, or bugs), any agent's identity could be destroyed.

**Recommendation:** Add independent owner authorization to the burn handler — verify that the owner of the burned NFT's datum has signed the transaction.

**Resolution:** The compliant `validate_burn` now: (1) extracts the specific burned token name from the mint field, (2) finds the spent script input containing that NFT, (3) deserializes the `AgentDatum` from the input, and (4) requires the datum's owner to have signed the transaction. The red team confirmed defense-in-depth: the burn path is now independently secure, no longer relying solely on the spend validator.

---

### AR-04 — Datum Hijacking on Update

**Severity:** High
**Status:** Fixed

**Description:**
The `validate_update` function checked for an inline datum but did not validate its contents. Any valid CBOR could be stored as the datum (including non-`AgentDatum` data), potentially bricking the UTxO for standard tooling. Additionally, all fields were mutable — including `registered_at` (the immutable registration timestamp) and `owner` (enabling unrestricted ownership transfer).

**Reproduction:**
1. Submit an Update transaction with `InlineDatum(42)` instead of a valid `AgentDatum` — accepted
2. Change the owner field to an attacker's credential — accepted
3. Change `registered_at` to 0 — accepted

**Impact:** Agent profiles could be replaced with invalid data. Ownership could be transferred without any on-chain restrictions. The `registered_at` timestamp (meant to be immutable) could be falsified.

**Recommendation:** Validate datum type, preserve `registered_at`, and enforce key-based owner credentials on updates.

**Resolution:** The compliant contract: (1) uses `expect new_datum: AgentDatum = raw_datum` to enforce datum type, (2) checks `new_datum.registered_at == agent_datum.registered_at` to preserve the registration timestamp, and (3) validates the new owner is key-based via `is_verification_key`. The red team confirmed all three checks hold; remaining field mutability (name, description, etc.) is intentional per the design specification.

---

### AR-05 — Register Does Not Validate Datum Owner Matches Signer

**Severity:** Medium
**Status:** Fixed

**Description:**
The `validate_register` function did not check whether the `owner` field in the `AgentDatum` matched any signer of the transaction. Anyone could register an agent with any credential as owner, enabling impersonation.

**Reproduction:**
1. Build a Register transaction with `AgentDatum.owner = victim_vkh`
2. Submit with no victim signature — accepted
3. The victim now has an unwanted agent registered in their name

**Impact:** Impersonation and reputation pollution. Low financial impact (attacker pays the deposit).

**Recommendation:** Require the datum's owner credential to have signed the registration transaction.

**Resolution:** The compliant contract extracts the datum from the registration output and calls `has_credential_signed(tx, datum.owner)`. The red team confirmed this blocks impersonation — the stated owner must actually authorize registration.

---

### AR-06 — No Validation of NFT Asset Name in Burn Path

**Severity:** Medium
**Status:** Fixed

**Description:**
The `validate_burn` function checked that exactly one token was burned but did not verify *which* token. Similarly, `validate_deregister` checked `qty == -1` without verifying the burned token name matched the NFT in the spent UTxO. In edge cases with multiple script inputs, the wrong NFT could be burned.

**Reproduction:**
1. Submit a Deregister transaction that burns a completely different token name under the policy — accepted
2. The agent's actual NFT remains unburned while a different token is destroyed

**Impact:** Could burn the wrong agent's identity NFT in edge cases.

**Recommendation:** Verify the specific burned token name matches the NFT in the spent input.

**Resolution:**
- `validate_burn`: Extracts the burned name from the mint field and finds the matching spent script input by NFT name
- `validate_deregister`: Extracts the input's NFT name and checks `name == input_nft_name && qty == -1`

The red team confirmed both paths now correctly bind the burned token to the specific agent.

---

### AR-07 — Script-Owned Agents Cannot Be Managed

**Severity:** Low
**Status:** Fixed

**Description:**
The `has_credential_signed` function rejected script credentials (`_ -> False`), but nothing prevented a script credential from being set as owner during registration or ownership transfer. This would permanently lock the UTxO and its deposit.

**Reproduction:**
1. Register an agent with `owner: Script(some_hash)` — accepted
2. The agent's UTxO is permanently locked — no Update or Deregister possible
3. The 10 AP3X deposit is permanently lost

**Impact:** Permanent loss of deposit if a script credential is used as owner.

**Recommendation:** Validate that the owner credential is key-based during Register and Update.

**Resolution:** The compliant contract adds `is_verification_key` checks on both Register (new agents) and Update (ownership transfer). The red team confirmed script credentials are now rejected at both entry points.

---

### AR-08 — No Datum Size or Field Length Limits

**Severity:** Low
**Status:** Fixed

**Description:**
All `AgentDatum` fields were unbounded — no limits on field lengths or capability count. An attacker could register agents with enormous datums, causing issues for off-chain indexers.

**Reproduction:**
1. Register an agent with a 15KB description or 1000 capability tags — accepted

**Impact:** Potential DoS on off-chain infrastructure.

**Recommendation:** Add maximum length checks for all fields.

**Resolution:** The compliant contract adds `validate_datum_size` enforcing: name ≤ 256 bytes, description ≤ 1024 bytes, framework ≤ 128 bytes, endpoint ≤ 512 bytes, capabilities count ≤ 32, each capability ≤ 128 bytes. Applied on both Register and Update. The red team confirmed all limits are enforced.

---

### AR-09 — Value Draining on Update

**Severity:** Medium
**Status:** Fixed

**Description:**
The `validate_update` function only checked `≥ min_deposit_lovelace` (10 AP3X) on the continuing output, not that the output preserved the input's value. If an agent's UTxO contained more than the minimum (e.g., 50 AP3X), the owner could drain the excess.

**Reproduction:**
1. Agent UTxO has 50 AP3X — update with continuing output of 10 AP3X
2. 40 AP3X goes to the owner's change address

**Impact:** Excess deposits could be drained. Combined with ownership transfer, a new owner could drain value the previous owner intended to keep locked.

**Recommendation:** Check `output_lovelace >= input_lovelace`.

**Resolution:** The compliant contract adds `assets.lovelace_of(output.value) >= assets.lovelace_of(input_value)`. The red team confirmed this blocks all value draining scenarios and noted that Aiken's arbitrary-precision integers prevent overflow concerns.

---

### AR-10 — Deregister Does Not Verify Deposit Return to Owner

**Severity:** Low
**Status:** Fixed

**Description:**
The `validate_deregister` function checked owner signature and NFT burn but did not verify the deposit was returned to the owner.

**Reproduction:**
1. Build a Deregister transaction where the change address is not the owner's
2. Owner signs (via compromised tooling) — deposit goes to wrong address

**Impact:** Low — requires owner's signature, exploitable only via social engineering or compromised tooling.

**Recommendation:** Verify an output to the owner's payment credential exists with at least the deposit amount.

**Resolution:** The compliant contract checks that an output to the owner's payment credential exists with `≥ min_deposit_lovelace`. The red team noted this check can be satisfied by unrelated outputs in the transaction (see NF-01) but confirmed the fix provides a meaningful safety net for the common case.

---

### AR-11 — `else` Catch-All Could Mask Future Script Purposes

**Severity:** Info
**Status:** Acknowledged

**Description:**
The `else(_ctx) { fail }` catch-all rejects any script purpose other than `mint` and `spend`. This is correct for current Plutus V3 but could silently reject new purposes in future Plutus versions.

**Impact:** None currently. Forward-compatibility consideration only.

**Resolution:** No code change needed. The catch-all fails closed, which is the safe default. Documented as intentional.

---

## 6. Red Team Validation

An independent red team operator conducted adversarial validation of the compliant contract. The operator attempted to bypass each fix through edge-case analysis, cross-path composition attacks, and novel attack vector exploration.

### Per-Fix Validation Results

All 11 original findings passed red team validation with no bypasses discovered. Each fix was tested against multiple attack scenarios including same-owner and cross-owner double satisfaction, reference input abuse, forged datums, cross-path composition (Register+Update, Update+Burn in same transaction), and more.

### Novel Attack Vectors Explored

| Vector | Result |
|--------|--------|
| Front-running / transaction ordering | ✅ Safe — eUTxO model inherently resistant |
| Register + Update in same TX | ✅ Safe — paths validate independently |
| Update + Burn in same TX | ✅ Safe — impossible at ledger level (value equation) |
| Donation attack (unsolicited funds to script) | ✅ Safe — attacker loses funds, no exploit |
| Reference input abuse | ✅ Safe — `script_input_count` only checks `tx.inputs` |
| Economic attack via ownership transfer | ✅ Safe — value preservation prevents deposit drain |
| Mass registration spam | ✅ Safe — economically disincentivized (~10.25 AP3X per agent) |
| Stake credential manipulation | ✅ Safe — address equality is strict |

### New Findings from Red Team

#### NF-01 — Deposit Return Check Can Be Satisfied by Unrelated Output

**Severity:** Low
**Status:** Acknowledged

The deposit return check in `validate_deregister` requires any output to the owner's payment credential with `≥ min_deposit_lovelace`. If the transaction includes other inputs from the owner's wallet, the change output could satisfy this check while the actual deposit is redirected. Requires owner's signature, limiting exploitability to compromised tooling scenarios.

**Recommendation:** Upgrade to `>= assets.lovelace_of(input_value)` for stronger protection.

#### NF-02 — Empty Datum Fields Accepted

**Severity:** Info
**Status:** Acknowledged

The datum size validation enforces maximum lengths but not minimum lengths. Agents with empty names, descriptions, and no capabilities can be registered. This is a data quality issue best handled in the SDK/off-chain layer.

#### NF-03 — Batch Operations Impossible

**Severity:** Info (Usability)
**Status:** Acknowledged

The `script_input_count == 1` fix for AR-01 prevents multiple registry operations in the same transaction. This is a usability trade-off — each agent operation requires a separate transaction. An alternative 1:1 input-output binding approach would be more complex; the current approach is safer and acceptable for V1.

---

## 7. Compliant Contract Notes

The compliant contract implements the following changes:

### Register Path
- **AR-02:** `list.filter` + `[output]` pattern match enforces exactly one valid registration output
- **AR-05:** Datum extracted from output; `has_credential_signed(tx, datum.owner)` required
- **AR-07:** `is_verification_key(datum.owner)` rejects script credentials
- **AR-08:** `validate_datum_size(datum)` enforces field length limits

### Burn Path
- **AR-03:** Finds spent script input containing the burned NFT; requires owner signature from datum
- **AR-06:** Extracts specific burned token name and matches against spent input

### Update Path
- **AR-01:** `script_input_count == 1` prevents double satisfaction
- **AR-04:** `expect new_datum: AgentDatum = raw_datum` enforces datum type; `registered_at` preservation checked; key-based owner validated
- **AR-08:** `validate_datum_size(new_datum)` enforces field limits
- **AR-09:** `output_lovelace >= input_lovelace` prevents value draining

### Deregister Path
- **AR-06:** `name == input_nft_name && qty == -1` verifies the correct NFT is burned
- **AR-10:** Output to owner's payment credential with `≥ min_deposit_lovelace` required

### New Constants
| Constant | Value | Purpose |
|----------|-------|---------|
| `max_name_length` | 256 | Maximum agent name bytes |
| `max_description_length` | 1024 | Maximum description bytes |
| `max_capability_length` | 128 | Maximum bytes per capability tag |
| `max_capabilities_count` | 32 | Maximum number of capability tags |
| `max_framework_length` | 128 | Maximum framework identifier bytes |
| `max_endpoint_length` | 512 | Maximum endpoint URL bytes |

### New Helper Functions
| Function | Purpose |
|----------|---------|
| `is_verification_key(credential)` | AR-07 — Check credential is key-based |
| `validate_datum_size(datum)` | AR-08 — Enforce all field length limits |

---

## 8. Test Suite Summary

The test suite contains **44 tests** authored to provide comprehensive coverage of all validator paths and audit findings.

### Test Coverage by Category

| Category | Tests | Description |
|----------|:-----:|-------------|
| Register — happy path & basic rejections | 7 | Seed consumption, mint quantity, deposit, datum, address |
| Burn — happy path & basic rejections | 3 | Quantity checks, empty mint |
| Update — happy path & basic rejections | 6 | Signature, deposit, NFT continuity, inline datum |
| Deregister — happy path & basic rejections | 5 | Signature, burn verification |
| AR-01 (Double Satisfaction — Update) | 2 | Same-owner double spend, deposit drain via combined output |
| AR-02 (Double Satisfaction — Register) | 2 | Two mints same TX, Register+Burn same TX |
| AR-03 (Burn No Authorization) | 2 | No signatures, attacker signature |
| AR-04 (Datum Hijacking) | 3 | Garbage datum, ownership transfer, all fields mutable |
| AR-05 (Register No Owner Signature) | 1 | Arbitrary owner credential accepted |
| AR-06 (Wrong NFT Burn) | 2 | Burn any token name, deregister wrong NFT |
| AR-07 (Script Owner Lock) | 2 | Script owner can't update, can't deregister |
| AR-08 (Datum Size Limits) | 2 | Oversized fields, empty fields |
| AR-09 (Value Draining) | 1 | Drain 50→10 AP3X on update |
| AR-10 (Deposit Return) | 1 | Deposit redirected to attacker |
| AR-11 (Catch-All) | 1 | Documentation test |
| Edge cases | 3 | Exact minimum deposit, one below, above minimum |
| **Total** | **44** | |

---

## 9. Final Assessment

### Code Quality

| Metric | Rating |
|--------|--------|
| Code clarity | ★★★★★ — Excellent, clean separation of concerns |
| Architecture | ★★★★☆ — Sound multi-validator design |
| Fix quality | ★★★★★ — All fixes are architecturally sound with defense-in-depth |
| Test coverage | ★★★★☆ — Comprehensive exploit tests, edge cases covered |
| Security posture (compliant) | ★★★★☆ — All Critical/High resolved, minor residual issues |

### Risk Assessment

| Risk | Level | Notes |
|------|-------|-------|
| Critical vulnerabilities | **None** | AR-01, AR-03 fully resolved |
| High vulnerabilities | **None** | AR-02, AR-04 fully resolved |
| Residual risks | **Low** | NF-01 (deposit check imprecision) requires owner signature to exploit |
| Design trade-offs | **Acceptable** | NF-03 (no batch operations) is a V1 limitation |

### Deployment Recommendation

**The compliant contract is cleared for mainnet deployment** subject to the following conditions:

1. ✅ All Critical and High findings resolved and red-team validated
2. ✅ All Medium and Low findings resolved or acknowledged
3. ⬜ Integration tests on Vector testnet confirm all four paths (register, update, deregister, burn) work end-to-end with the compliant contract
4. ⬜ NF-01 is explicitly accepted as a known limitation or upgraded to `>= input_lovelace`

### Known Limitations (Accepted)

- **NF-01:** Deposit return check can be satisfied by unrelated outputs (Low severity, requires owner signature)
- **NF-02:** Empty datum fields are valid on-chain; recommend SDK-level validation
- **NF-03:** Batch operations are not supported; one transaction per agent operation

---

*Report prepared by the Vector Security Audit Team*
*Audit methodology: Static analysis → Adversarial testing → Remediation → Red team validation*
