# the research analyst Research Context — Agent Registry Audit
**Prepared by:** the research analyst (Research & Knowledge Agent, Apex Audit Team)
**Audit target:** Vector Agent Registry (`agent-registry`) — Aiken/Cardano smart contract
**Source:** `/original/` — reviewed DESIGN.md, TESTS.md, types.ak, validation.ak, registry.ak
**Date:** March 18, 2026

---

## 1. Protocol Summary

### What it is
The **Vector Agent Registry** is an on-chain registry contract that allows AI agents to publish verifiable identity profiles on the **Vector** blockchain — a Cardano-compatible chain operated by the ApexFusion project. Each registered agent gets a unique **NFT-based decentralized identifier (DID)** in the format `did:vector:agent:{policyId}:{assetName}`.

### What problem it solves
In multi-agent AI systems, agents need discoverable, tamper-resistant identities. Centralized registries are single points of failure. This contract provides:
- **On-chain identity verification** — no one can forge or impersonate a registered agent
- **Stable DID** — the identity survives profile updates (agent name, endpoint, capabilities can change; the DID does not)
- **Soulbound semantics** — the NFT never moves to a personal wallet; it lives under validator control for its entire lifecycle
- **Economic accountability** — a minimum 10 AP3X deposit creates skin-in-the-game for registrants

### Chain/ecosystem
- **Chain:** Vector testnet (ApexFusion), a Cardano-compatible EVM-optional chain
- **Runtime:** Plutus V3 (Cardano's smart contract VM)
- **Language:** Aiken v1.1.21, stdlib v3.0.0
- **Native coin:** AP3X (like ADA on Cardano), smallest unit is DFM (like lovelace), 6 decimal places
- **Network quirk:** Vector testnet uses `networkId: Mainnet` and `networkMagic: 764824073`. Addresses begin with `addr1` (not `addr_test1`). This is atypical and relevant for off-chain integration.
- **Off-chain SDK:** Python (PyCardano + Ogmios), with `AgentRegistry` client and `AgentWalletManager`

---

## 2. Architecture Overview

### Multi-Validator Design

The registry is implemented as a **single Aiken multi-validator** — one script file (`validators/registry.ak`) that exports two handler types:

| Handler | Purpose | Redeemer type |
|---------|---------|---------------|
| `mint` | Controls NFT creation (Register) and destruction (Burn) | `MintAction` |
| `spend` | Controls UTxO state transitions (Update, Deregister) | `SpendAction` |

**Critical property:** Both handlers share the same script hash. Therefore:
```
policy_id == script_hash == payment_credential_of_registry_address
```

This is the keystone of the architecture. The spend validator can verify NFT presence using `policy_id` (its own ID), without any cross-script references or oracle lookups. The mint policy can construct the correct registry address using the same `policy_id`.

### Code Organization (Day 2 Refactor — D8)

The actual validation logic lives in `lib/agent_registry/validation.ak`, **not** in `validators/registry.ak`. The validator file is a thin wrapper that imports and delegates. This was done because Aiken validator blocks cannot be called from test blocks — extraction enables unit testing of every path.

```
validators/registry.ak       ← thin wrapper (imports + delegates)
lib/agent_registry/
  types.ak                   ← AgentDatum, MintAction, SpendAction
  validation.ak              ← validate_register, validate_burn,
                                validate_update, validate_deregister,
                                + public helper functions
```

### eUTXO Model — How Registration Works

Each registered agent occupies **one UTxO** at the registry script address. That UTxO contains:
1. An **inline `AgentDatum`** — the agent's profile (name, capabilities, endpoint, owner, etc.)
2. The **identity NFT** — one token under `policy_id` with the agent's unique asset name
3. **≥10 AP3X** in lovelace — the minimum deposit

When an agent is updated, the old UTxO is consumed and a **new UTxO** is created at the same address. The NFT moves from old to new; the datum is replaced. When deregistered, the UTxO is consumed and the NFT is burned in the same transaction. No UTxO remains.

### Soulbound NFT Guarantee

ERC-5192 on Ethereum reaches soulbound semantics through transfer hooks; this implementation achieves them structurally:
- NFTs are minted **directly into the script address** — they never touch a user wallet
- The spend validator physically controls all movement
- Deregistration is the only exit path, and it requires burning, not transferring

---

## 3. Key Design Decisions (D1–D11) with Audit Relevance

### D1: Multi-validator with NFT identity
**Summary:** One script serves as both minting policy and spend validator. Each agent gets a unique NFT minted at registration.

**Audit relevance:** The shared `policy_id == script_hash` invariant must hold for all internal cross-checks to be correct. An auditor should verify that no code path uses a hardcoded hash or an externally supplied policy ID that could diverge from the actual script hash. In `validation.ak`, `policy_id` is passed down from the mint handler — verify it originates from the Plutus context (it does: `validator registry { mint(redeemer, policy_id, tx)` — `policy_id` is a Plutus V3 native parameter, not user-supplied).

---

### D2: Stable DID via NFT
**Summary:** `did:vector:agent:{policy_id}:{asset_name}` — the asset name is derived once at registration from a consumed seed UTxO. The DID is immutable for the lifetime of the registration.

**Audit relevance:** DID stability depends on NFT asset name being enforced on-chain. On Update, the validator checks that the **same NFT** is present in the continuing output (by `quantity_of(...) == 1`), which preserves the asset name. If NFT continuity enforcement had a bug, a bad actor could replace the NFT with a different one (changing the DID). This is a high-priority check area.

---

### D3: Minimum 10 AP3X deposit enforced on-chain
**Summary:** Both `validate_register` and `validate_update` check `lovelace_of(output.value) >= 10_000_000`. The deposit is returned on deregistration.

**Audit relevance:** The enforcement is present in both mint and spend paths. Auditors should verify:
- Deregistration does NOT recheck the deposit (it burns the NFT; the UTxO value is freed to whoever the TX sends it to — this is by design)
- The constant `min_deposit_lovelace = 10_000_000` is in `validation.ak` (accessible to both handlers)
- No path allows bypassing this via token counting tricks or multi-output attacks (e.g., can a TX split the value across two outputs, each below the minimum, while still satisfying `list.any`?)

---

### D4: Key-based ownership only (no scripts)
**Summary:** `has_credential_signed` only handles `VerificationKey(vkh)` — it returns `False` for any script credential.

**Audit relevance:** Script-based agents cannot register or update — this is a **silent exclusion**. If a smart contract wallet or multi-sig attempts to register, the transaction will fail on-chain without a descriptive error. The `else(_ctx) { fail @"Unsupported script purpose" }` clause only applies to unexpected script purposes, not to script-owned agents. This is not a bug but auditors should verify no panic/incomplete pattern match occurs in `has_credential_signed`.

---

### D5: Spend limits enforced off-chain only ⚠️
**Summary:** `SpendPolicy` (per-transaction limit, daily limit, allow/blocklist) lives entirely in the Python SDK (`AgentWalletManager`). There is **zero on-chain enforcement** of spend limits.

**Audit relevance:** This is the most significant trust-model gap in the system. The on-chain contract has no knowledge of spend policies. Any party who constructs a raw transaction directly (bypassing the SDK) faces no on-chain spend restriction. The design justification is that the SDK controls signing keys — but:
- Key exfiltration or compromise eliminates this control
- Other wallet software could be used
- The "audit log" is also in the SDK and provides no on-chain proof

This is **in-scope for the on-chain audit only as a documentation of absence** — not a validator bug, but a systemic risk the audit report should call out clearly.

---

### D6: Inline datums, Plutus V3
**Summary:** All agent UTxOs use inline datums. The contract targets Plutus V3.

**Audit relevance:**
- Inline datums are required by the spend validator: `expect Some(agent_datum) = datum` in `registry.ak`. If a UTxO somehow has a datum hash instead of an inline datum, the spend validator will fail with an expectation error (not a graceful `False`). Any UTxO at the script address with a non-inline datum becomes unspendable (a potential locked-fund vector if an adversary creates such a UTxO — see risk surface section).
- Plutus V3 provides `ScriptContext` enhancements. Auditors should confirm no Plutus V2 patterns are being used that behave differently under V3 (particularly around `mint` field structure and `extra_signatories`).

---

### D7: Update does not validate datum shape or owner field preservation ⚠️
**Summary:** On Update, the validator checks: owner signed, continuing output has inline datum + same NFT + ≥10 AP3X. It does **NOT** check the datum structure or that specific fields (like `owner`) are preserved.

**Audit relevance:** By design, this enables ownership transfer — the signing owner can put any new `owner` credential in the new datum. However:
- There is **no on-chain validation of datum field types or ranges** (e.g., `registered_at` could be set to a negative number, `name` could be empty bytes, `endpoint` could be arbitrary binary)
- The `owner` in the new datum is not checked against anything — an Update could silently change ownership to an uncontrolled address
- After transfer, the old owner has no recourse; the new datum owner has full control
- Off-chain indexers consume and display datum content without on-chain schema guarantees

This is a **medium risk** design choice. It enables legitimate ownership transfer but creates a trust gap between on-chain state and what the off-chain SDK shows users.

---

### D8: Validation extracted to library
**Summary:** Core logic lives in `validation.ak`, not in `registry.ak`. The validator is a thin wrapper.

**Audit relevance:** Positive for auditability — each function can be reviewed and tested in isolation. Auditors should confirm that the thin wrapper passes parameters correctly and does not introduce any logic of its own (it doesn't — it's pure delegation). The contract hash changed from `c8d23d01...` to `5dd51189...` during this refactor; the on-chain behavior is stated to be identical.

---

### D9: CBOR parity between Python and Aiken verified
**Summary:** 17 tests confirm that PyCardano's `PlutusData` CBOR encoding is byte-exact with Aiken's `cbor.serialise()`. This is critical because the NFT asset name = `blake2b_256(CBOR(seed_OutputReference))` — a single byte difference would produce a different hash, causing registration failures.

**Audit relevance:** The parity was proven on-chain (a successful testnet register TX validates end-to-end). Key finding: PyCardano uses indefinite-length arrays for non-empty constructors and definite-length empty arrays for empty constructors — this matches Plutus convention. Auditors reviewing off-chain should be satisfied by this evidence, but should note that the parity was tested against specific PyCardano behavior — any SDK change that alters CBOR encoding would silently break NFT name derivation.

---

### D10: Vector testnet uses mainnet network ID
**Summary:** Vector testnet uses `Network.MAINNET` despite being a testnet. Addresses start with `addr1`.

**Audit relevance:** Primarily an off-chain integration concern. On-chain, the validator does not check network IDs directly. However, any address comparison logic (like `output.address == script_address`) must construct the address with the correct network byte, or comparisons will fail. The `script_address_from_policy` function in `validation.ak` constructs an `Address` struct without explicitly setting a network byte — in Cardano/Plutus V3, the network tag is part of the serialized address format but the `Address` type in the script context carries `payment_credential` and `stake_credential` only. Comparison works correctly because both sides of the `==` compare the same structural type. This is fine on-chain; the off-chain SDK must handle the network byte correctly (and D10 confirms it does).

---

### D11: Full lifecycle verified on testnet
**Summary:** All three on-chain operations (Register, Update, Deregister) were successfully executed on the Vector testnet. Two bugs were found and fixed in the SDK during this testing.

**Audit relevance:** Testnet confirmation proves the CBOR parity, fee mechanics, and validator logic all work end-to-end. The two bugs fixed during testing (`UTxOSelectionException` from missing `add_input_address`, and `RawCBOR` datum parsing) were in the Python SDK, not the on-chain validator. The on-chain validator itself passed without modification.

---

## 4. Intended Functionality — Four Operations

### Operation 1: Register
**Trigger:** Mint handler with `Register { seed }` redeemer

**Stated invariants (all must hold):**
1. `seed` OutputReference is consumed as a TX input
2. Exactly one NFT minted under `policy_id` with asset name = `blake2b_256(cbor.serialise(seed))`
3. Exactly one output at the script address containing:
   - An inline datum (any datum — structure not validated)
   - The minted NFT (quantity = 1)
   - ≥ 10,000,000 lovelace (10 AP3X)

**What is NOT checked:**
- Datum content (no required fields, no type checks)
- Who initiated the TX (anyone can register anyone's agent — caller is not restricted)
- Multiple NFTs in a single TX (the check is `list.any` on outputs — what about multiple mints in one TX? See risk surface)

---

### Operation 2: Update
**Trigger:** Spend handler with `Update` redeemer

**Stated invariants (all must hold):**
1. `agent_datum.owner` has signed the TX (checked via `extra_signatories`)
2. A continuing output exists at the same script address containing:
   - An inline datum (any datum)
   - The same identity NFT by name and quantity (1)
   - ≥ 10,000,000 lovelace

**What is NOT checked:**
- New datum content or field preservation
- That the `owner` field in the new datum matches the signer
- Number of continuing outputs (uses `list.any` — could there be multiple outputs?)

---

### Operation 3: Deregister
**Trigger:** Spend handler with `Deregister` redeemer

**Stated invariants (all must hold):**
1. `agent_datum.owner` has signed the TX
2. Exactly one NFT burned under `own_policy` (quantity = -1 in mint field)

**What is NOT checked:**
- Where the AP3X deposit goes (any address, no restriction)
- That *this specific agent's* NFT is burned vs. some other NFT under the same policy (the check is `qty == -1` for **any** token under the policy — see risk surface for potential concern)

---

### Operation 4: Burn
**Trigger:** Mint handler with `Burn` redeemer

**Stated invariants (all must hold):**
1. Exactly one token burned (quantity = -1) under this policy

**What is NOT checked:**
- Which specific NFT asset name is burned
- Whether the corresponding script UTxO was spent (minting policy can fire independently of spend validator)
- Whether the owner of the agent authorized the burn

**⚠️ Critical note:** The `Burn` mint redeemer and the `Deregister` spend redeemer are **separate validators** that are coordinated off-chain. A deregistration transaction must invoke both. However, the mint `Burn` handler can theoretically be invoked **without** a spend of any script UTxO — this would be an "orphan burn" that destroys an NFT without consuming the registry UTxO. If such a condition is possible, the registry UTxO would remain locked with its deposit (the NFT is gone but the UTxO is stranded).

---

## 5. Known Gaps and Out-of-Scope Items

The authors explicitly documented the following exclusions:

| Feature | Status | Authors' Reason |
|---------|--------|-----------------|
| On-chain messaging (Cardano label 674) | Out of scope | "Nice-to-have per sprint plan" |
| Reputation score | Out of scope | "Nice-to-have; depends on external system" |
| Script-based ownership | Not yet implemented | "Can be added by extending validator" |
| On-chain spend limits | Not yet implemented | "Off-chain enforcement is sufficient for MVP" |
| Datum structure validation | By design excluded | "On-chain: too expensive; off-chain indexer handles" |

**Implications for audit scope:**
- Do not flag absence of reputation scoring or label 674 messaging as findings
- Script-based ownership: Flag that script credentials will silently fail (not panic), which may be surprising to integrators
- On-chain spend limits: Flag the trust model gap (documented in D5 above) — this should appear in the audit report as a risk acknowledgment
- Datum structure: Flag that the contract accepts arbitrary bytes in all string fields — off-chain indexers may display malformed or adversarial data

---

## 6. Audit-Relevant Context

### eUTXO Model Specifics

**Concurrency:** In an eUTXO model, two transactions cannot spend the same UTxO in the same block. This means the registry has **no concurrency issue** at the individual agent level — each agent's UTxO is independent. However, if multiple agents try to register using the **same seed UTxO** simultaneously, only one TX will succeed (the first to be confirmed). This is the intended spam prevention.

**`list.any` semantics:** The Aiken `list.any` function returns true if at least one element satisfies the predicate. Used in `validate_register` (checking outputs) and `validate_update`. Auditors must consider whether multiple matching outputs in a single TX could lead to unexpected behavior. For instance: can a TX produce two outputs at the script address, both with the NFT, each with 5 AP3X (below the minimum individually)? No — `quantity_of(...) == 1` would only match if an output has exactly one NFT, but the total minted is one — so splitting the NFT across two outputs is impossible. However, the deposit check is per-output, not global, which is correct design.

**Datum access in Plutus V3:** The spend handler receives `datum: Option<AgentDatum>` — for inline datums this is `Some(parsed_datum)`. If no inline datum is present, it's `None`. The validator uses `expect Some(agent_datum) = datum`, which causes a script failure (not just `False`) if datum is `None`. This means:
- UTxOs at the script address without inline datums will **fail to spend under Update or Deregister** — they are effectively locked
- An adversary could create such UTxOs by sending ADA to the script address with no datum, locking the funds
- This is standard Cardano validator behavior but worth noting for the audit

### Plutus V3 Context

Plutus V3 introduced several changes from V2:
- The `Transaction` type's `mint` field now uses a `Value` type (not `MintedValue`) — relevant for `assets.tokens(tx.mint, policy_id)`
- `extra_signatories` is the correct field for checking VKH signatures (not `signatures`)
- Multi-validator support is native in Plutus V3 (vs. workarounds in V2)
- The `else(_ctx) { fail ... }` clause handles withdrawal and other script purposes — this is defensive programming

### Aiken Language Patterns

**`expect` keyword:** Used for pattern matches that must succeed. Failure causes a script error (not `False`). Appearances in `validation.ak`:
- `expect Some(agent_datum) = datum` — spend handler entry
- `expect Some(input) = list.find(...)` — `get_own_address`, `get_own_value`
- `expect Script(hash) = addr.payment_credential` — `get_policy_from_address`
- `expect [Pair(name, 1)] = dict.to_pairs(tokens)` — `find_nft_name`

Each `expect` is a potential failure path. Auditors should consider what state could cause them to fail and whether that state is reachable by an adversary.

**`and { ... }` blocks:** Aiken's shorthand for logical AND with multiple conditions. All conditions are evaluated (no short-circuit in the source, though UPLC may optimize). Not a security concern but relevant for understanding logic flow.

**No recursion or loops in the contract** — all iteration is via `list.any`, `list.find`, `dict.to_pairs`. Execution time is bounded.

### NFT Asset Name Derivation

```
asset_name = blake2b_256(cbor.serialise(OutputReference { tx_id, output_index }))
```

The CBOR encoding follows Plutus convention (constructor tag 121 for index 0, indefinite-length arrays for non-empty constructors). Because the seed UTxO is consumed in the same TX, uniqueness is guaranteed by the UTXO model (no UTxO can be consumed twice). Collision resistance comes from blake2b_256.

### Off-Chain SDK Architecture

The Python SDK (`vector_agent/`) mirrors the on-chain types and provides:
- `AgentRegistry` — transaction builder using PyCardano + Ogmios
- `AgentWalletManager` — wraps registry with spend policy enforcement and audit logging
- `SpendPolicy` — off-chain spend limits (NOT on-chain)
- `AuditEntry` — off-chain audit records (NOT on-chain)

The SDK is **not part of the on-chain audit scope** but informs the trust model. The audit should note where the SDK enforces properties that the contract does not.

---

## 7. Risk Surface Summary

This section maps the highest-risk areas based on design analysis. These are not findings — they are areas where the code reviewer (code reviewer) and the test writer (test writer) should focus attention.

### 🔴 High Risk: Orphan Burn / NFT-UTxO Decoupling
**Location:** Interaction between mint `Burn` handler and spend `Deregister` handler

**Concern:** The mint `Burn` redeemer only requires `qty == -1` for any token under the policy. It does **not** require a corresponding spend of a registry UTxO. If a TX fires the mint `Burn` redeemer without spending the agent's UTxO, the NFT is burned but the UTxO remains at the script address with its deposit — permanently locked (no NFT to continue with on Update, no NFT to burn on Deregister).

**Severity factor:** Requires an attacker to know the NFT asset name and construct a malicious TX. But anyone can read on-chain state, so asset names are public.

**the code reviewer should verify:** Can a burn TX omit the corresponding UTxO spend? What does `validate_burn` check? It only checks `qty == -1` — it does NOT verify that the burning NFT's UTxO was consumed.

---

### 🔴 High Risk: Absent Datum Shape Validation
**Location:** `validate_register`, `validate_update` — both accept any inline datum

**Concern:** The contract places no constraints on `AgentDatum` field contents. Adversarial or malformed data can be stored:
- `endpoint` could be empty, excessively long, or contain binary garbage
- `registered_at` could be set to 0, negative, or future epoch
- `capabilities` could be an empty list, duplicated, or contain arbitrary bytes
- `owner` in new datum after Update could be changed to any credential without restriction

**Severity factor:** While no on-chain funds are at direct risk from bad datum content, downstream indexers, off-chain tools, and A2A protocol implementations that trust on-chain data could be affected. Denial-of-service against off-chain systems via malformed datum is feasible.

---

### 🟠 Medium Risk: list.any for Output Matching
**Location:** `validate_register` (outputs), `validate_update` (outputs)

**Concern:** Using `list.any` means the first valid output satisfies the check. If a TX produces multiple outputs at the script address, only one needs to satisfy all conditions. This could allow:
- A TX that registers one valid agent UTxO and also sends ADA (below minimum) to the script address without a datum, creating an unspendable UTxO
- A TX that updates an agent while also creating a decoy output at the script address

**Severity factor:** The NFT quantity constraint (`quantity_of(...) == 1`) limits damage — you can't split the NFT. But ADA-only UTxOs at the script address would be locked (no NFT to update or deregister with).

---

### 🟠 Medium Risk: Unconstrained Ownership Transfer
**Location:** `validate_update` — D7

**Concern:** An Update TX can change the `owner` field in the new datum to any credential. The original owner must sign, but after the TX confirms, the new owner has exclusive control. There is no two-phase confirmation or timeout. If the original owner's key is compromised, the attacker can:
1. Sign an Update TX that transfers ownership to an attacker-controlled address
2. Register new keys; the original owner has no recovery mechanism

**Severity factor:** This is by design (D7), but has no on-chain mitigations and no recovery path.

---

### 🟡 Low-Medium Risk: Script Credential Silent Failure
**Location:** `has_credential_signed` — D4

**Concern:** Script credentials always return `False` from `has_credential_signed`. A smart contract wallet or multi-sig attempting to own an agent will silently fail to update or deregister — with no on-chain error message distinguishing "wrong owner" from "script ownership not supported." Funds (10 AP3X) would be locked if such a wallet registered (though this would also fail at registration time — wait, actually `validate_register` does NOT check the datum's `owner` field at all, so a script credential COULD be placed in the datum during registration... and then that agent could never be updated or deregistered, locking the deposit).

**the code reviewer should verify:** Does `validate_register` check the `owner` field type? Answer from code: **No.** This means a TX could register an agent with a script credential as owner — the registration succeeds, but the agent is permanently frozen (no Update, no Deregister possible), and the 10 AP3X deposit is locked forever.

---

### 🟡 Low Risk: No Multi-Registration Guard in a Single TX
**Location:** `validate_register` — `list.any` on outputs, single NFT mint check

**Concern:** The mint check verifies exactly one NFT is minted (`[Pair(name, qty)] -> name == expected_name && qty == 1`). Can a TX register multiple agents? It would need to use multiple mint redeemers — but in Cardano, each policy can only have one redeemer per TX. So only one `Register` redeemer can fire per TX. Multiple registrations require multiple transactions. This is likely not a vulnerability but should be confirmed.

---

### 🟡 Low Risk: expect Failure Paths
**Location:** Multiple `expect` calls in `validation.ak`

**Concern:** Several `expect` calls could panic if the state is unexpected:
- `get_own_address`: `expect Some(input) = list.find(...)` — fails if `own_utxo` not in inputs (should be impossible in valid Plutus execution, but defensive analysis warranted)
- `find_nft_name`: `expect [Pair(name, 1)] = dict.to_pairs(tokens)` — fails if the input has zero or multiple tokens under the policy. An input UTxO at the script address without any NFT (e.g., accidentally created) would panic the validator rather than returning `False`

---

### 🟢 Well-Mitigated: Replay / Double-Spend
eUTXO model provides this for free. Each UTxO can only be consumed once; the NFT asset name uses the consumed UTxO as entropy.

### 🟢 Well-Mitigated: NFT Theft
The spend validator requires owner signature for all state transitions. The NFT never leaves the script address. A valid theft would require key compromise.

### 🟢 Well-Mitigated: CBOR Encoding Mismatch
Extensively tested (D9) and confirmed on-chain. Low residual risk.

---

## Appendix: Quick Reference for the code reviewer and the test writer

### Contract Hash
`5dd5118943d5aa7329696181252a6565a27dbf2c6de92b02a6aae361`
(Re-read from `plutus.json` at runtime — changes on recompilation)

### Key Constants
| Constant | Value | Location |
|----------|-------|----------|
| `min_deposit_lovelace` | `10_000_000` | `validation.ak` |
| Min deposit (AP3X) | 10 AP3X | Derived |

### Validator Entry Points (registry.ak)
```
validator registry {
  mint(redeemer: MintAction, policy_id: PolicyId, tx: Transaction)
    → Register { seed } → validate_register(seed, policy_id, tx)
    → Burn            → validate_burn(policy_id, tx)

  spend(datum: Option<AgentDatum>, redeemer: SpendAction, own_utxo, tx)
    → Update     → validate_update(agent_datum, own_utxo, tx)
    → Deregister → validate_deregister(agent_datum, own_utxo, tx)

  else(_ctx) → fail "Unsupported script purpose"
}
```

### Test Distribution
| Suite | Count | Type |
|-------|-------|------|
| Aiken unit tests | 30 | On-chain logic, all paths |
| Python offline tests | 96 | Off-chain SDK |
| Python integration tests | 15 | Live testnet |
| **Total** | **141** | All passing ✅ |

### Coverage Gaps (per TESTS.md)
- Error paths in TX building (insufficient funds, wrong collateral) — not tested
- No negative test for script-credential-as-owner locking deposit
- No test for orphan burn (Burn redeemer without corresponding Deregister spend)
- No fuzz testing of datum field contents

---

*This document is the primary context source for the Apex audit. the code reviewer: use Sections 2, 3, 4, and 7 as your review framework. the test writer: use Sections 4, 5, 6, and 7 to identify test gaps and adversarial scenarios to cover.*
