# UTxO Attack Surface Analysis

**Version:** 1.0
**Date:** 2026-03-18
**Scope:** eUTXO smart contracts on Cardano-compatible chains (Plutus V3 / Aiken)
**Based on:** Security audit findings across five production-targeted contracts
**Audience:** Security researchers, smart contract auditors, advanced eUTXO developers

---

## Executive Summary

The extended UTxO (eUTXO) model — used by Cardano, Vector/ApexFusion, and related chains — presents a fundamentally different attack surface from account-based systems like Ethereum. Where Solidity auditors worry about reentrancy, storage collisions, and delegatecall proxies, eUTXO auditors must contend with double satisfaction, orphan minting, redeemer combinatorics, and the semantic gap between on-chain validators and off-chain transaction construction.

This document systematically catalogs the attack surfaces unique to eUTXO smart contracts, drawn from real audit findings across five contracts (an NFT-based identity registry, a vesting contract, an escrow, a donation pool, and a simple DEX). Every vulnerability class described here was either confirmed exploitable or required explicit defensive code during those audits.

**Key findings:**

- **Double satisfaction** is the dominant eUTXO vulnerability class, appearing in every audited contract. It has no direct analogue in account-model systems.
- **Mint–spend handler decoupling** creates an entire category of orphan-state attacks unique to multi-validator architectures.
- **`list.any` / `list.filter` semantics** are the root cause of most output-matching vulnerabilities — the difference between "at least one valid output exists" and "exactly the right outputs exist" is where attackers live.
- **Off-chain transaction construction** is part of the trusted computing base in ways that have no Ethereum equivalent. The validator is only half the security model.

---

## Scope

This analysis covers the attack surface of smart contracts deployed on eUTXO chains running Plutus V3, with specific reference to contracts written in Aiken v1.1.x. The analysis is grounded in findings from:

- A multi-validator NFT identity registry (mint + spend handlers, soulbound NFT semantics)
- Four spend-only validators: escrow, donation pool, vesting, and DEX

**In scope:**
- Transaction-level attack surfaces (inputs, outputs, mint field, redeemers)
- Validator logic vulnerabilities (pattern matching, list operations, datum handling)
- Multi-validator interaction surfaces (handler coupling, policy identity)
- Economic attack vectors (deposit manipulation, dust, front-running)
- Off-chain attack surfaces (SDK trust, datum construction, UTxO querying)

**Out of scope:**
- Plutus Core / UPLC interpreter bugs
- Cardano ledger-level vulnerabilities
- Network-layer attacks (eclipse, Sybil)
- Formal verification methods

---

## eUTXO Architectural Properties

Before cataloging attacks, it is essential to understand five architectural properties of eUTXO that create unique attack surfaces not present in account-based models.

### Property 1: Validators Are Pure Functions Over Transactions

An eUTXO validator receives a snapshot of the entire transaction (all inputs, outputs, mint field, signatories, validity range) and returns a boolean. It has no mutable state, no storage slots, no `msg.sender`. The validator's *only* job is to say "yes" or "no" to the transaction as a whole.

**Security implication:** The attacker controls the *entire transaction structure*. They choose which UTxOs to consume, what outputs to create, what values to put in redeemers, and what to include in the mint field. The validator must defend against all possible transaction shapes, not just the ones the SDK would construct.

### Property 2: Each Validator Runs Independently

When a transaction spends multiple script UTxOs, each validator runs in isolation. Validator A cannot see Validator B's decision. Both see the same transaction, but each makes an independent yes/no decision.

**Security implication:** If Validator A checks for condition X on the outputs and Validator B also checks for condition X, a single output satisfying X can make *both* validators pass — even if the protocol intended each input to have its own dedicated output. This is the root of double satisfaction.

### Property 3: The Mint Field Is Global

The `mint` field of a transaction is a single map from policy IDs to token names to quantities. Every minting policy referenced in this field fires and must approve. But the mint field is shared — all policies see the same mint map.

**Security implication:** If a multi-validator uses the same policy ID for both minting and spending, and the mint handler's checks are weak, an attacker can include mint operations alongside spend operations in ways the protocol designer never intended.

### Property 4: UTxOs Are Created by Transactions, Not Contracts

Any transaction can create an output at any address — including a script address — with any datum. The validator at that address only fires when the UTxO is *spent*, not when it is *created*. There is no constructor, no `receive()` function, no creation-time validation.

**Security implication:** Attackers can deposit garbage UTxOs at script addresses. These UTxOs may be unspendable (locking the attached value permanently) or may contain malicious datums that confuse off-chain indexers.

### Property 5: Off-Chain Code Constructs, On-Chain Code Validates

The on-chain validator is reactive — it can only reject bad transactions, never initiate good ones. All transaction construction happens off-chain (in SDKs, wallets, dApps). The validator sees only the finished product.

**Security implication:** If the off-chain SDK is compromised, misconfigured, or simply buggy, it may construct transactions that are technically valid (pass the validator) but economically harmful (send deposits to the wrong address, use wrong datum fields). The validator cannot protect users from bad-but-valid transactions unless it explicitly encodes economic invariants.

---

## Attack Surface Categories

### Transaction-Level Surfaces

#### Input Selection and Consumption

**Threat model:** Attacker constructs a transaction that selects script inputs in combinations the protocol did not anticipate.

**Attack 1: Double Satisfaction via Multi-Input Spending**

When a transaction spends two or more UTxOs from the same script address, each validator invocation runs independently against the same transaction context. If the validator uses `list.any` or `list.find` to locate a "continuing output," both invocations may latch onto the *same* output.

*Concrete scenario (from audit):*
An owner controls two agent UTxOs (Agent A and Agent B), each holding a 10 AP3X deposit and an identity NFT. They construct a single transaction that:
1. Spends both UTxOs with `Update` redeemer
2. Creates only *one* continuing output with 10 AP3X and Agent A's NFT

Both validator invocations fire. Both call `list.any(tx.outputs, fn(o) { ... })`. Both find the single valid output. Both return `True`. Result: 10 AP3X is effectively extracted — Agent B's deposit vanishes, and the transaction is valid.

**Severity: Critical.** This was confirmed exploitable in every audited contract that used `list.any` for output matching.

**Canonical defense:** Enforce `script_input_count == 1` — restrict the transaction to spending at most one UTxO from this script address. This was applied to three of four audited contracts. Alternatively, use output-index pinning (redeemer specifies which output index corresponds to this input) *combined with* uniqueness checks, though this alone proved insufficient.

**Attack 2: Cross-Script Input Confusion**

When multiple scripts share similar validation logic, an attacker may include inputs from different scripts in the same transaction, hoping that one script's continuing output satisfies another script's checks.

*Assessed during audit:* Not exploitable in the audited contracts because each script has a unique hash (and therefore unique payment credential). Address equality checks inherently separate scripts. However, this becomes relevant when scripts use parameterized addresses or reference inputs from other scripts.

#### Output Creation and Validation

**Threat model:** Attacker creates outputs at the script address that the validator doesn't expect, or structures valid outputs in ways that exploit loose matching.

**Attack 3: Ghost UTxO Creation**

During a legitimate operation (register, update, deposit), the attacker includes additional outputs at the script address beyond what the protocol expects. If the validator only checks "at least one valid output exists" (via `list.any`), it ignores the extras.

*Concrete scenario (from audit):*
A registration transaction creates two outputs at the registry address:
- Output A: Valid — has the NFT, inline datum, ≥10 AP3X deposit ✓
- Output B: Invalid — has only 2 ADA, no NFT, no datum

`validate_register` uses `list.any` and finds Output A. Transaction succeeds. Output B is now permanently locked at the script address — any attempt to spend it triggers the validator, which panics on `expect Some(agent_datum) = datum` (no datum present) or `find_nft_name` (no NFT present).

**Severity: Medium.** No funds are stolen from other users, but the attacker creates permanent UTxO pollution at the script address, increasing indexer costs and potentially confusing off-chain tools.

**Defense:** Use `list.filter` to collect all outputs at the script address, then require exactly the expected count:
```
let script_outputs = list.filter(tx.outputs, fn(o) { o.address == script_address })
when script_outputs is {
  [output] -> // validate the single output
  _ -> False
}
```

**Attack 4: Staking Credential Variant Ghost UTxOs**

A refinement of Attack 3 that bypasses the `list.filter` defense. The Cardano ledger triggers spend validators based on *payment credential only*, but `Address` struct equality in Aiken includes the staking credential. An attacker creates outputs with the correct payment credential but a non-canonical staking credential:

```
Address {
  payment_credential: Script(policy_id),
  stake_credential: Some(Inline(VerificationKey(attacker_key)))
}
```

These outputs escape the filter (different `Address` struct) but are still locked by the validator (same payment credential). They are permanently unspendable.

**Severity: Low.** Each ghost costs the attacker real funds (minimum UTxO value, permanently lost). The attack is economically self-penalizing and the impact is limited to UTxO set bloat. Indexers can filter by payment credential rather than full address.

**Defense:** Filter by `output.address.payment_credential == Script(policy_id)` rather than exact address equality.

#### Mint Field Manipulation

**Threat model:** Attacker crafts the transaction's mint field to invoke minting policies in unexpected combinations or bypass weak mint-handler checks.

**Attack 5: Orphan Burn (Mint Without Corresponding Spend)**

In multi-validator contracts where a mint handler and a spend handler coordinate (e.g., "burn the NFT" must accompany "deregister the agent"), the coupling is often only enforced in the *spend* handler. The *mint* handler may have minimal checks — it validates that some token is being burned but doesn't verify that the corresponding UTxO is being spent.

*Concrete scenario (from audit):*
The `Burn` mint redeemer only checked `quantity == -1` for any token under the policy. An attacker could construct a transaction invoking only the mint handler with `Burn` redeemer — no script UTxOs spent. The NFT is destroyed, but the registry UTxO remains at the script address with its deposit locked. The UTxO can never be spent again (no NFT to satisfy `find_nft_name`, which panics on empty token map).

**Severity: Critical.** Permanent fund locking. In the audited contract, the orphan burn was self-inflicted (only the NFT holder could burn their own NFT), but the deposit loss was irrecoverable.

**Defense:** The burn handler must verify that a script input is being spent in the same transaction:
```
fn has_script_input(tx, policy_id) -> Bool {
  list.any(tx.inputs, fn(input) {
    input.output.address.payment_credential == Script(policy_id)
  })
}
```

**Attack 6: Register + Burn in Single Transaction**

If the same policy handles both `Register` (mint +1) and `Burn` (mint -1) redeemers, can both fire in a single transaction? In Plutus, each policy gets one redeemer per transaction. However, the net effect in the mint field may show two token names — one with +1, one with -1.

The defense against this emerges from strict token-counting: if `validate_register` uses `expect [Pair(name, qty)] = dict.to_pairs(minted_tokens)` (requiring exactly one pair), and `validate_burn` does the same, then a mint field with two pairs fails both checks.

**Severity: High (if undefended).** An attacker could register their own agent while simultaneously destroying another agent's NFT.

**Defense:** Both mint handlers must require exactly one entry in `dict.to_pairs(minted_tokens)` — this is inherently mutual exclusion.

#### Redeemer Combinatorics

**Threat model:** Attacker supplies redeemer values that exercise code paths the developer didn't consider, or combines redeemers across multiple inputs/policies in a single transaction.

**Attack 7: Output-Index Pinning Collision**

Several contracts use redeemers that specify an output index (e.g., `Cancel { beneficiary_index: 2 }`). This pins the validator's output check to a specific index. However, when two script inputs in the same transaction both specify the same output index in their redeemers, both validators check the same output — re-enabling double satisfaction even with index pinning.

*Concrete scenario (from audit):*
Two vesting UTxOs are spent in one transaction. Both redeemers specify `continuation_index: 0`. Both validators check `tx.outputs[0]`. If `tx.outputs[0]` satisfies both validators' requirements, the attacker extracts the difference between the two inputs' values and the single output's value.

**Severity: Critical (when output-index pinning is the sole defense).** This was the key insight: output-index pinning is *necessary but not sufficient*. It must be combined with single-script-input enforcement.

**Defense:** `script_input_count == 1` eliminates the possibility of redeemer collision across inputs.

**Attack 8: Redeemer Type Confusion**

In Aiken, redeemers are typed ADTs deserialized from CBOR. The Aiken type system prevents structural confusion within a well-typed contract. However, if a contract accepts a raw `Data` redeemer and manually interprets it, type confusion attacks become possible — an attacker could craft CBOR that deserializes into an unintended variant.

**Severity: Low (in Aiken).** Aiken's typed redeemers provide strong defense. This is primarily a concern in raw Plutus or PlutusTx contracts.

---

### Validator-Level Surfaces

#### `list.any` / `list.filter` Semantics

**Threat model:** The validator's output-matching logic accepts a transaction as valid when the protocol invariants are not actually satisfied.

The distinction between `list.any` ("at least one element satisfies the predicate") and `list.filter` + count ("exactly N elements satisfy the predicate") is the single most important semantic distinction in eUTXO validator security.

**`list.any` is dangerous for output matching.** It answers "does a valid output exist?" when the security question is "are *all* outputs valid?" or "does *exactly one* valid output exist?"

| Pattern | Semantics | Safe for output matching? |
|---------|-----------|--------------------------|
| `list.any(outputs, pred)` | ∃ output satisfying pred | ❌ No — allows ghost UTxOs and double satisfaction |
| `list.find(outputs, pred)` | First output satisfying pred | ❌ No — same issue as `list.any` |
| `list.filter(outputs, pred)` + `[x] -> ...` | Exactly one output satisfying pred | ✅ Yes — prevents ghost UTxOs |
| `list.filter(outputs, pred)` + `[x] -> ...` + `script_input_count == 1` | Exactly one output, exactly one input | ✅✅ Yes — prevents double satisfaction |

**Audit finding:** `list.any` was used for output matching in the initial version of *every* audited contract. It was replaced with `list.filter` + singleton matching in all compliant versions.

#### `expect`-Based Panics vs Clean Failures

**Threat model:** Attacker crafts input state that causes a validator to panic (`expect` failure) rather than return `False`. In Plutus, both result in transaction rejection — but the failure modes differ in debuggability and in how they interact with multi-validator transactions.

Aiken's `expect` keyword performs an irrefutable pattern match: if the pattern doesn't match, the script terminates with an error (consuming the full execution budget). Common `expect` patterns and their risk:

| Pattern | Panics when | Risk level |
|---------|-------------|------------|
| `expect Some(datum) = datum_opt` | UTxO has no inline datum | Medium — unspendable UTxO |
| `expect Script(hash) = credential` | Credential is a verification key | Low — would only occur with key-hash addresses |
| `expect [Pair(name, 1)] = dict.to_pairs(tokens)` | 0 or 2+ tokens under policy | Medium — malformed UTxO causes panic |
| `expect Some(input) = list.find(inputs, ...)` | Input not found | Low — should be impossible in valid execution |

**Security distinction:** `expect` failures are **fail-closed** — the transaction is rejected. This is the safe direction. The concern is not that attackers can exploit panics to *approve* bad transactions, but that panics can make UTxOs *permanently unspendable* if an adversary creates a UTxO with unexpected structure at the script address.

*Concrete scenario (from audit):*
A UTxO is created at the registry address with no inline datum (just ADA, no datum hash, no inline datum). Any attempt to spend this UTxO triggers `expect Some(agent_datum) = datum`, which panics. The ADA in this UTxO is permanently locked. This is a dust/griefing attack — the attacker pays the minimum UTxO cost to permanently pollute the script address.

**Defense:** Accept that `expect` panics are fail-closed (safe) and focus defense on preventing the creation of malformed UTxOs at script addresses (see Ghost UTxO attacks above).

#### Credential Type Handling

**Threat model:** Attacker registers or transfers ownership to a credential type that the validator cannot authorize, permanently locking the associated UTxO and deposit.

In Cardano, credentials come in two types:
- `VerificationKey(hash)` — authorized via `extra_signatories` (key signature in transaction)
- `Script(hash)` — authorized via script execution (the referenced script must be invoked in the transaction)

If a validator only handles `VerificationKey` in its signature-checking logic:

```aiken
fn has_credential_signed(tx, credential) -> Bool {
  when credential is {
    VerificationKey(vkh) -> list.has(tx.extra_signatories, vkh)
    Script(_) -> False  // silent rejection
  }
}
```

Then any UTxO with a `Script` credential as owner is permanently frozen — the owner can never authorize an Update or Deregister.

**Attack chain (from audit):**
1. Attacker tricks a target into signing a registration transaction with `owner: Script(some_hash)` in the datum (social engineering via malicious dApp front-end)
2. Registration succeeds — the validator doesn't check owner credential type at registration time
3. The UTxO is now permanently locked — Update and Deregister both require owner authorization, which always returns `False` for script credentials
4. The 10 AP3X deposit is permanently lost

**Severity: High.** Permanent fund locking via social engineering.

**Defense:** Validate the owner credential type at registration and update time:
```aiken
fn validate_output_owner(tx, output) -> Bool {
  expect datum: AgentDatum = get_inline_datum(output)
  when datum.owner is {
    VerificationKey(vkh) -> list.has(tx.extra_signatories, vkh)
    Script(_) -> False
  }
}
```

#### Datum Validation Gaps

**Threat model:** Attacker stores malformed, oversized, or adversarial data in on-chain datums, exploiting the gap between what the validator accepts and what off-chain systems expect.

eUTXO validators typically check datum *presence* (is there an inline datum?) but not datum *content* (are the fields valid?). This is a deliberate trade-off — on-chain execution is expensive, and complex validation consumes execution budget.

**Attack surface areas:**

| Datum field | Attack | Impact |
|-------------|--------|--------|
| String fields (name, endpoint, description) | Extremely large values (megabytes) | Chain bloat, indexer DoS, increased storage costs |
| String fields | Empty values (`""`) | Confusing UI, broken integrations |
| String fields | Binary/control characters | XSS in web frontends, log injection |
| Timestamp fields | Zero, negative, or far-future values | Broken ordering, incorrect time displays |
| Credential fields | Script credential in owner field | Permanent UTxO lock (see above) |
| List fields (capabilities) | Empty list, duplicate entries, thousands of entries | Index bloat, UI confusion |

*Concrete finding (from audit):*
The agent registry accepted arbitrary bytes in all string fields with no size limits. An attacker could register with a multi-megabyte `description` field for only 10 AP3X — the deposit doesn't scale with datum size. This enables economically cheap chain bloat.

**Severity: Low-Medium.** No direct fund theft, but enables ecosystem-level griefing. With owner signature requirements, the attacker can only bloat their own registrations (not others').

**Defense trade-offs:**
- On-chain byte length limits are possible but consume execution budget
- Deposit proportional to datum size creates economic alignment
- Off-chain indexers should impose their own size limits regardless

---

### Multi-Validator Surfaces

#### Handler Coupling (Mint ↔ Spend)

**Threat model:** Attacker invokes one handler of a multi-validator without the other, creating inconsistent state.

In Aiken/Plutus V3, a multi-validator exports multiple handlers (e.g., `mint` and `spend`) that share a script hash. The key architectural property is:

```
policy_id == script_hash == payment_credential_of_script_address
```

This allows each handler to reference the other's domain (the mint handler can construct the script address; the spend handler can check the mint field). However, **the handlers are not automatically coupled** — a transaction can invoke the mint handler without spending any script UTxOs, or spend script UTxOs without touching the mint field.

**Coupling requirements (from audit):**

| Operation | Required coupling | Defense |
|-----------|-------------------|---------|
| Register (mint) | Must create output at script address | Enforced by `list.filter` on outputs |
| Burn (mint) | Must be accompanied by a spend (Deregister) | Must be explicitly checked — `has_script_input(tx, policy_id)` |
| Update (spend) | Must continue NFT in output | Enforced by NFT quantity check on output |
| Deregister (spend) | Must burn NFT in mint field | Enforced by checking `mint` field for -1 quantity |

The critical insight: **Burn → Spend coupling must be explicitly enforced.** The mint handler fires based on the mint field alone; it has no inherent awareness of whether a script UTxO is being spent. If the developer assumes "the off-chain SDK always pairs Burn with Deregister," they leave the orphan burn attack open.

#### Policy ID Identity Assumptions

**Threat model:** Attacker exploits the validator's assumptions about its own policy ID to manipulate cross-handler checks.

In Plutus V3, the `policy_id` parameter in the mint handler is provided by the ledger — it is the script's own hash. This is a trusted value. However, in the spend handler, the policy ID must be *derived* from the UTxO's address:

```aiken
fn get_policy_from_address(addr: Address) -> PolicyId {
  expect Script(hash) = addr.payment_credential
  hash
}
```

This pattern assumes the UTxO is at a script address (not a key address). The `expect` ensures this — if the UTxO is somehow at a key address, the validator panics. In practice, the Plutus runtime only invokes spend validators for script-address UTxOs, so this is safe.

**Subtle risk:** If a future protocol upgrade changed how validators are triggered, or if a contract used a hardcoded policy ID instead of deriving it from the address, the identity assumption could break. Currently assessed as a non-issue for Plutus V3.

#### Double Satisfaction Across Handlers

**Threat model:** A single output satisfies validation checks from multiple independent validator invocations within the same transaction.

This is the generalized form of the double satisfaction attack. It occurs whenever:
1. Two or more validator invocations examine the same output set
2. Each invocation checks for "at least one valid output" (via `list.any`)
3. A single output satisfies both validators' predicates

**Taxonomy of double satisfaction scenarios:**

| Scenario | Same script? | Same redeemer? | Example |
|----------|-------------|----------------|---------|
| Same-script, same-redeemer | Yes | Yes | Two Update spends sharing one continuing output |
| Same-script, different-redeemer | Yes | No | One Update + one Deregister where Update's output also "satisfies" Deregister |
| Cross-script | No | N/A | Escrow output satisfying both Escrow and DEX validators |

**Defense hierarchy (from least to most robust):**

1. **Output-index pinning** — Redeemer specifies which output index to check. *Insufficient alone* — two inputs can specify the same index.
2. **Output-index pinning + uniqueness** — Verify no two inputs share an output index. Better, but requires custom logic.
3. **Single-script-input constraint** — `script_input_count == 1`. Simple and effective. The canonical defense for same-script double satisfaction.
4. **NFT thread tokens** — Each UTxO carries a unique NFT that must appear in its dedicated continuing output. The strongest defense, at the cost of minting complexity.

**Audit finding:** Single-script-input constraint was adopted in three of four audited contracts. The one that didn't (Simple Escrow) retained a known double satisfaction vulnerability, accepted for demo scope.

---

### Economic Surfaces

#### Deposit Manipulation

**Threat model:** Attacker extracts, reduces, or redirects economic deposits through valid-but-unintended transactions.

**Attack 9: Deposit Extraction via Double Satisfaction**

As described in Attack 1 — when two UTxOs are spent via double satisfaction and only one continuing output is created, the difference in deposits is effectively extracted. If each UTxO held 10 AP3X and the continuing output holds 10 AP3X, the attacker gains 10 AP3X minus fees.

**Attack 10: Deposit Redirection on Deregister**

When a deregistration transaction burns the NFT and releases the deposit, the validator may not enforce *where* the deposit goes. If the validator only checks "NFT is burned" and "owner signed," the deposit can be sent to any address. In a well-behaved SDK, it goes to the owner. In a malicious SDK (or compromised key scenario), it goes to the attacker.

*Audit finding:* All audited contracts that had deposits (registry, escrow) did not enforce deposit destination on-chain. The rationale: the owner is signing, so they authorize the transaction. This is acceptable if key compromise is out of scope, but it means the on-chain contract doesn't protect users from bad off-chain tooling.

**Severity: Medium.** The owner must sign, limiting this to key compromise or malicious SDK scenarios.

#### Dust and Bloat Attacks

**Threat model:** Attacker creates many small or malformed UTxOs at a script address to degrade performance, increase costs for legitimate users, or permanently lock small amounts of value.

**Attack 11: Datum Bloat**

Create registrations with extremely large datums (megabytes of data in string fields). The minimum deposit doesn't scale with datum size, so the cost is fixed regardless of how much chain storage is consumed.

**Attack 12: UTxO Pollution**

Create many small UTxOs at the script address (via ghost UTxO attack or direct sends). Each UTxO must be processed by indexers querying the script address. At scale, this degrades query performance for all users of the protocol.

**Attack 13: Unspendable UTxO Locking**

Send ADA to a script address with no datum, a datum hash (not inline), or a malformed datum. The spend validator will panic on any attempt to spend these UTxOs, permanently locking the attached value. The attacker pays the minimum UTxO cost (~1-2 ADA) per ghost.

**Defense:** These attacks are partially inherent to the eUTXO model (Property 4 — anyone can create outputs at any address). Mitigations include:
- Restricting script output count per transaction (prevents batch ghost creation during legitimate operations)
- Economic friction via deposits proportional to data size
- Off-chain indexer filtering (ignore UTxOs without expected NFT or datum structure)
- Accepting the residual risk as a known limitation of the model

#### Front-Running in the Mempool

**Threat model:** Attacker observes pending transactions in the mempool and submits competing transactions to extract value or grief legitimate users.

**eUTXO-specific dynamics:**

Unlike account-model front-running (where the attacker replicates the victim's call with higher gas), eUTXO front-running centers on *UTxO consumption*. Two transactions cannot spend the same UTxO — so front-running means consuming the UTxO the victim intended to use.

**Attack 14: Registration Front-Running**

1. Alice broadcasts a registration transaction consuming seed UTxO `X`
2. Attacker sees the pending transaction, extracts seed `X`
3. Attacker submits a competing registration using the same seed `X` with higher fees
4. Attacker's transaction is confirmed first; Alice's transaction fails (seed already consumed)

Without owner signature requirements, the attacker could also impersonate Alice by using her VKH as the datum owner. With owner signature requirements, the attacker can only register under their own identity — reducing this from an impersonation attack to a griefing attack.

**Attack 15: DEX Order Front-Running (MEV)**

In a DEX contract, an attacker can observe pending swap transactions and:
- Consume the same liquidity UTxO with a more favorable trade
- Place orders that will be filled before the victim's order, moving the price

This is the eUTXO equivalent of MEV (Maximal Extractable Value). Unlike Ethereum MEV, eUTXO MEV is constrained by the deterministic UTxO selection — the attacker must consume specific UTxOs, not just replay function calls.

**Severity: Medium to High (DEX contracts), Low (registry/escrow/vesting).** MEV is a fundamental challenge for on-chain DEXes regardless of execution model. Current mitigation: none available — requires mempool privacy or batch auctions.

**Status:** Front-running and MEV attacks were marked UNTESTABLE across all audited contracts due to the absence of mempool simulation infrastructure.

---

### Off-Chain Surfaces

#### SDK Trust Assumptions

**Threat model:** The off-chain SDK enforces security properties that the on-chain validator does not. Attacker bypasses the SDK by constructing raw transactions.

This is the most architecturally significant attack surface category for eUTXO systems. In account-model systems, the smart contract *is* the security boundary — the front-end is just a convenience layer. In eUTXO systems, the SDK is part of the trusted computing base.

**Properties commonly enforced only off-chain (from audit):**

| Property | On-chain? | Off-chain? | Risk if bypassed |
|----------|-----------|------------|------------------|
| Spend limits (per-TX, daily) | ❌ | ✅ (SDK) | Unlimited spending with compromised key |
| Audit logging | ❌ | ✅ (SDK) | No accountability trail |
| Datum field validation (format, length) | ❌ | ✅ (SDK) | Malformed on-chain data |
| Deposit return destination | ❌ | ✅ (SDK) | Deposit sent to wrong address |
| Owner consent on transfer | ❌ | ✅ (SDK) | Unwanted ownership transfer |
| CBOR encoding correctness | ❌ | ✅ (SDK) | NFT name derivation failure |

**Key finding from audit:** Spend policies (per-transaction limits, daily limits, allow/blocklists) were implemented entirely in the Python SDK with zero on-chain enforcement. Any party who constructed raw transactions directly — bypassing the SDK — faced no spend restrictions. The design justification was that the SDK controls signing keys, but key exfiltration eliminates this control.

**Defense:** Move critical security properties on-chain wherever execution budget allows. For properties that must remain off-chain, document the trust boundary explicitly and ensure key management is robust.

#### Datum Construction Attacks

**Threat model:** Attacker manipulates the datum attached to a newly created UTxO to store malicious or misleading data.

Since the on-chain validator typically doesn't validate datum *content* (only datum *presence*), datum construction is an off-chain concern with on-chain consequences.

**Attack 16: Identity Pollution**

Without owner signature requirements at registration, an attacker could create registry entries with arbitrary owner fields, names, and metadata. This pollutes the on-chain registry with fake entries that off-chain tools display alongside legitimate ones.

*Concrete scenario (from audit):*
An attacker registers 100 agents using public VKHs of known entities (exchanges, protocol teams) as owner fields. Off-chain indexers show these entities as "registered agents" when they never authorized any registration. This is a reputational attack against the registry's value as a directory service.

**Defense:** Require owner signature on registration — the datum's owner field must correspond to a signer on the transaction. This was implemented in the compliant version and effectively eliminates identity pollution.

**Attack 17: CBOR Encoding Divergence**

For contracts where datum content feeds into cryptographic computations (e.g., NFT asset name = hash of CBOR-serialized seed), any difference between the off-chain SDK's CBOR encoding and the on-chain Plutus CBOR encoding will produce different hashes. This doesn't enable attacks per se, but it causes silent registration failures that are extremely difficult to debug.

*Audit finding:* 17 parity tests confirmed byte-exact CBOR encoding between PyCardano and Aiken. The parity held across all tested cases, but was noted as fragile — any SDK update that changes CBOR encoding conventions would silently break NFT name derivation.

#### UTxO Set Querying and Indexing

**Threat model:** Off-chain tools query the UTxO set at a script address and make assumptions about the data they find.

**Attack 18: Indexer Confusion via Garbage UTxOs**

If an indexer queries all UTxOs at a script address and assumes each one is a valid protocol entry, ghost UTxOs and datum-less UTxOs will cause crashes, incorrect displays, or resource exhaustion.

**Attack 19: State Inconsistency via Concurrent Queries**

UTxO set queries are point-in-time snapshots. Between the query and the transaction submission, the UTxO set may change (another user consumed a UTxO). This causes transaction failures, not security vulnerabilities, but it degrades user experience and creates opportunities for griefing (an attacker repeatedly consumes the UTxO a victim is trying to interact with).

**Defense:**
- Indexers must filter UTxOs by expected structure (has NFT under policy, has valid inline datum)
- Transaction builders must handle UTxO contention gracefully (retry with fresh query)
- Never trust datum content from on-chain without validation

---

## Severity Matrix

| ID | Attack | Category | Severity | eUTXO-Specific? | Confirmed in Audit? |
|----|--------|----------|----------|-----------------|---------------------|
| 1 | Double satisfaction (multi-input) | Transaction | **Critical** | ✅ Yes | ✅ All 4 contracts |
| 5 | Orphan burn (mint without spend) | Multi-Validator | **Critical** | ✅ Yes | ✅ Registry |
| 7 | Output-index pinning collision | Transaction | **Critical** | ✅ Yes | ✅ Vesting, DEX |
| 6 | Register + Burn in single TX | Multi-Validator | **High** | ✅ Yes | ✅ Registry |
| — | Script credential owner lock | Validator | **High** | Partial | ✅ Registry |
| 14 | Registration front-running | Economic | **Medium** | ✅ Yes | ✅ Registry |
| 10 | Deposit redirection | Economic | **Medium** | No | ✅ Registry, Escrow |
| 3 | Ghost UTxO creation | Transaction | **Medium** | ✅ Yes | ✅ Registry |
| 15 | DEX MEV | Economic | **Medium-High** | Partial | ⚠️ Untestable |
| — | Datum validation gaps | Validator | **Low-Medium** | No | ✅ Registry |
| 11 | Datum bloat | Economic | **Low-Medium** | No | ✅ Registry |
| 4 | Staking credential variant ghost | Transaction | **Low** | ✅ Yes | ✅ Registry |
| 13 | Unspendable UTxO locking | Economic | **Low** | ✅ Yes | ✅ All contracts |
| 8 | Redeemer type confusion | Transaction | **Low** | Partial | Not exploitable (Aiken) |
| 16 | Identity pollution | Off-Chain | **Medium** | No | ✅ Registry |
| 17 | CBOR encoding divergence | Off-Chain | **Low** | ✅ Yes | Verified safe |
| 18 | Indexer confusion | Off-Chain | **Low** | ✅ Yes | Documented |
| 19 | State inconsistency | Off-Chain | **Low** | ✅ Yes | Inherent |

---

## Comparison with Account-Model Attack Surfaces

| Attack Class | eUTXO | Account Model (EVM) | Notes |
|-------------|-------|---------------------|-------|
| **Reentrancy** | ❌ Not possible | ✅ Classic vulnerability | eUTXO validators are pure functions — no external calls, no state changes during execution |
| **Double satisfaction** | ✅ Dominant vulnerability | ❌ Not applicable | Account model executes calls sequentially; no parallel validator invocation |
| **Front-running / MEV** | ⚠️ Constrained (UTxO-specific) | ✅ Major concern | eUTXO: must consume specific UTxOs. EVM: can replay arbitrary function calls |
| **Storage collision** | ❌ Not possible | ✅ Proxy/delegatecall risk | eUTXO has no persistent storage — state lives in UTxOs |
| **Integer overflow** | ❌ Not applicable (arbitrary precision) | ✅ Historic concern | Plutus uses arbitrary-precision integers; Solidity <0.8 had fixed-width overflow |
| **Access control** | ⚠️ Signature-based only | ✅ `msg.sender` + modifiers | eUTXO: checked via `extra_signatories`. No equivalent of `msg.sender` — *any* party can construct a transaction |
| **Oracle manipulation** | ⚠️ Reference input risks | ✅ Price oracle attacks | eUTXO: reference inputs can be substituted. EVM: oracle return values can be manipulated via flash loans |
| **Denial of service** | ⚠️ UTxO pollution | ✅ Gas griefing, storage bloat | eUTXO: anyone can create outputs at script addresses. EVM: contracts can reject incoming calls |
| **Flash loans** | ❌ Not possible | ✅ Major DeFi attack vector | eUTXO transactions are atomic and deterministic — no mid-transaction borrowing |
| **Tx construction attacks** | ✅ Major concern | ❌ Not applicable | eUTXO: attacker controls full TX structure. EVM: contract enforces logic regardless of calldata |
| **Soulbound enforcement** | ✅ Structural (validator controls all movement) | ⚠️ Requires ERC-5192 hooks | eUTXO: NFT at script address can only move via validator. EVM: transfer hooks can be bypassed |
| **Concurrent access** | ✅ Natural isolation (one UTxO per TX) | ⚠️ Requires locks/mutexes | eUTXO: each UTxO is an independent state unit. EVM: shared storage requires reentrancy guards |

**Key insight:** eUTXO eliminates entire vulnerability classes (reentrancy, flash loans, storage collisions) but introduces new ones (double satisfaction, orphan minting, ghost UTxOs) that have no direct EVM analogues. Security auditors transitioning from EVM to eUTXO must recalibrate their mental models entirely.

---

## Conclusion

The eUTXO attack surface is architecturally distinct from account-model systems. It is not inherently more or less secure — it is *differently* secure, with a different set of invariants to maintain and a different set of assumptions to validate.

**The three most important lessons from this audit series:**

1. **Validators defend; they do not construct.** The on-chain validator is a gatekeeper, not an architect. It can reject bad transactions but cannot force good ones. Every property that matters must be encoded as a rejection condition. If the validator doesn't check it, it isn't enforced.

2. **Independent validator invocation is the root of double satisfaction.** Every time two validators examine the same output set, double satisfaction is possible. The canonical defense — single-script-input constraint — is simple, effective, and should be the default pattern for all eUTXO contracts until a compelling reason exists to allow multiple script inputs.

3. **The trust boundary includes the SDK.** In eUTXO systems, off-chain code is not just a convenience layer — it is part of the security model. Properties enforced only off-chain (spend limits, datum validation, deposit routing) evaporate if the SDK is bypassed. Security-critical properties belong on-chain; everything else should be documented as an explicit trust assumption.

For security researchers approaching eUTXO contracts: start with the output-matching logic. Check what `list.any` is doing. Count the script inputs. Verify handler coupling. These three checks will surface the majority of eUTXO-specific vulnerabilities.

For developers building on eUTXO: adopt `list.filter` + singleton matching, enforce `script_input_count == 1` as default, couple your mint and spend handlers explicitly, and validate credential types at every state transition. These patterns, applied consistently, eliminate the critical and high-severity findings documented in this analysis.

---

*This document is based on findings from security audits of five Aiken/Plutus V3 smart contracts deployed on a Cardano-compatible chain. All findings have been anonymized. The vulnerabilities described were identified, confirmed, and — where applicable — remediated during the audit process.*
