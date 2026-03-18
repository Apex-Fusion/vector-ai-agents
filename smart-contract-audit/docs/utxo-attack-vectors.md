# UTxO Attack Vectors for AI Agent Developers

**Audience:** Smart contract developers building on eUTXO chains (Cardano, Vector/ApexFusion)
**Based on:** Security audits of 5 Aiken smart contracts — an AI Agent Registry and 4 DeFi templates
**Last updated:** 2026-03-18

---

## Introduction

If you're building AI agents on an eUTXO chain like Vector or Cardano, you're working with a fundamentally different execution model than Ethereum. The bugs are different. The attack surfaces are different. And the intuitions you've built from Solidity don't transfer cleanly.

This document catalogs **10 concrete attack vectors** found during real security audits of Aiken smart contracts — including a production Agent Registry that manages on-chain identity NFTs for AI agents. Every vector described here was either exploitable in the original code or identified as a credible threat during red-team testing.

**Why this matters for AI agent builders specifically:**
- Agent identity NFTs are high-value targets — impersonation breaks trust in multi-agent systems
- Agents interact with contracts programmatically, often through SDKs that abstract away transaction construction. If the SDK is the only security layer, you have no security.
- Deposits, escrows, and payment channels that agents use are all vulnerable to the same eUTXO-specific patterns
- Unlike DeFi, agent identity contracts are long-lived — a single vulnerability can permanently lock an agent's on-chain identity

---

## The eUTXO Model — What's Different

If you're coming from Ethereum's account model, here's what changes everything:

### Account Model (Ethereum)
- Global mutable state: contracts have storage slots that anyone can read and modify (through the contract)
- Validators see the full contract state
- Transactions execute sequentially within a block
- One contract = one state

### eUTXO Model (Cardano/Vector)
- **No global state.** Each "state" is an independent UTxO (unspent transaction output) sitting at a script address
- **Validators are pure functions.** They see only the transaction that spends them — inputs, outputs, signatories, minting, validity range. Nothing else.
- **Each validator runs independently.** If a transaction spends two UTxOs at the same script address, the validator runs twice — once per input — and each invocation knows nothing about the other
- **UTxOs are consumed, not modified.** To "update" state, you consume the old UTxO and create a new one. The old one is gone forever.
- **Minting policies and spend validators are separate handlers**, even when they share a script hash

This independence is both the strength (natural concurrency, no reentrancy) and the weakness (validators can't coordinate, creating the attack vectors below).

### The Key Mental Model Shift

In Ethereum, you think: "What can a caller do to my contract's state?"

In eUTXO, you think: "What transaction can an attacker construct that my validator will accept?"

The attacker controls **everything** about the transaction — which UTxOs to include, how many outputs to create, what datums to attach, which redeemers to use. Your validator only gets to say yes or no to the final package. Every vector below exploits some gap between what the validator checks and what the attacker can construct.

---

## Attack Vector Catalog

### 1. Orphan Burn / Decoupled Handlers

**Severity: 🔴 Critical**

#### The Problem

In a multi-validator design (common for NFT-based contracts), the minting policy and the spend validator are separate handlers. They share a script hash but execute independently. If the `Burn` handler in the minting policy doesn't verify that the corresponding UTxO is also being spent, an attacker can burn an NFT without triggering the spend validator at all.

#### What Happens

The NFT is destroyed, but the UTxO remains at the script address with its deposit locked. No future operation can touch it:
- **Update** fails — no NFT to continue
- **Deregister** fails — no NFT to burn
- The deposit is permanently trapped

#### Real Example

In the audited registry contract, `validate_burn` originally checked only that one token was burned:

```aiken
// ❌ VULNERABLE — burn is not coupled to spend
fn validate_burn(policy_id: PolicyId, tx: Transaction) -> Bool {
  let tokens = assets.tokens(tx.mint, policy_id)
  let token_list = dict.to_pairs(tokens)
  when token_list is {
    [Pair(_name, qty)] -> qty == -1
    _ -> False
  }
}
```

An attacker could construct a transaction with just the `Burn` mint redeemer and no spend of any script UTxO. The validator would happily accept it.

#### Fixed Pattern

```aiken
// ✅ FIXED — burn requires a script UTxO to be spent in the same TX
fn validate_burn(policy_id: PolicyId, tx: Transaction) -> Bool {
  let tokens = assets.tokens(tx.mint, policy_id)
  let token_list = dict.to_pairs(tokens)
  let has_script_input =
    list.any(
      tx.inputs,
      fn(input) {
        input.output.address.payment_credential == Script(policy_id)
      },
    )
  when token_list is {
    [Pair(_name, qty)] -> qty == -1 && has_script_input
    _ -> False
  }
}
```

#### Key Takeaway

**Never assume off-chain coordination replaces on-chain enforcement.** If two handlers must execute together, the contract must enforce that coupling. "The SDK always builds the transaction correctly" is not a security model.

---

### 2. Double Satisfaction

**Severity: 🔴 Critical**

#### The Problem

This is the **canonical eUTXO vulnerability** — found in every single contract audited. It occurs when two validator invocations in the same transaction can be "satisfied" by a single output.

Since each validator runs independently and only checks that *some* output meets its requirements, one well-crafted output can satisfy multiple validators simultaneously. The attacker effectively gets two state transitions for the price of one output.

#### What Happens

An attacker who controls two UTxOs at the same script address (e.g., two registered agents) can:
1. Spend both UTxOs in one transaction with `Update` redeemer
2. Create only **one** continuing output with one deposit (instead of two)
3. Both validator invocations find that single output via `list.any` and accept
4. One deposit (10 AP3X) vanishes — effectively stolen from the contract

#### Vulnerable Pattern

```aiken
// ❌ VULNERABLE — list.any allows output sharing between validators
fn validate_update(datum: AgentDatum, own_utxo: OutputReference, tx: Transaction) -> Bool {
  let own_address = get_own_address(own_utxo, tx)
  let own_policy = get_policy_from_address(own_address)
  let input_nft_name = find_nft_name(own_utxo, own_policy, tx)
  //
  has_credential_signed(tx, datum.owner) && list.any(
    tx.outputs,
    fn(output) {
      output.address == own_address
        && has_inline_datum(output)
        && assets.quantity_of(output.value, own_policy, input_nft_name) == 1
        && lovelace_of(output.value) >= min_deposit_lovelace
    },
  )
}
```

#### Fixed Pattern

```aiken
// ✅ FIXED — exactly one output at script address allowed
fn validate_update(datum: AgentDatum, own_utxo: OutputReference, tx: Transaction) -> Bool {
  let own_address = get_own_address(own_utxo, tx)
  let own_policy = get_policy_from_address(own_address)
  let input_nft_name = find_nft_name(own_utxo, own_policy, tx)
  //
  let script_outputs =
    list.filter(tx.outputs, fn(output) { output.address == own_address })
  //
  has_credential_signed(tx, datum.owner) && when script_outputs is {
    [output] ->
      has_inline_datum(output)
        && assets.quantity_of(output.value, own_policy, input_nft_name) == 1
        && lovelace_of(output.value) >= min_deposit_lovelace
    _ -> False
  }
}
```

#### Defense Strategies (Ranked)

1. **Single-script-input constraint** — reject the transaction if more than one input comes from your script address. Simplest and most robust. Used in the audited vesting and DEX contracts:
   ```aiken
   let script_input_count =
     list.count(tx.inputs, fn(i) { i.output.address.payment_credential == Script(own_policy) })
   script_input_count == 1
   ```

2. **Singleton output enforcement** — filter outputs to your script address and require exactly one (as shown above). Used in the registry contract.

3. **Output-index pinning** — include the expected output index in the redeemer, then verify by position. **Necessary but not sufficient alone** — two inputs can specify the same index.

4. **NFT thread tokens** — each UTxO carries a unique NFT that must appear in exactly one output. Prevents sharing because NFTs can't be duplicated.

#### Key Takeaway

**If you use `list.any` to find a valid output, you have a double satisfaction vulnerability.** This was the single most common finding across all five audited contracts. Default to singleton output enforcement or single-script-input constraints.

---

### 3. Credential Type Confusion

**Severity: 🔴 High**

#### The Problem

Cardano credentials come in two types: `VerificationKey(hash)` (controlled by a private key) and `Script(hash)` (controlled by a smart contract). If your validator checks signatures using `tx.extra_signatories` but the credential is a `Script`, the check silently fails — scripts don't sign transactions, they execute.

#### What Happens

If an agent is registered with a `Script` credential as `owner`:
- The registration succeeds (no owner type check)
- Every subsequent operation (Update, Deregister) requires the owner's signature
- `has_credential_signed` returns `False` for script credentials
- The UTxO is **permanently locked** — the deposit is gone forever

This is both a self-harm vector (accidental) and an attack vector (tricking someone into signing a malicious transaction through an untrusted frontend).

#### Vulnerable Pattern

```aiken
// ❌ VULNERABLE — silently returns False for Script credentials
fn has_credential_signed(tx: Transaction, credential: Credential) -> Bool {
  when credential is {
    VerificationKey(vkh) -> list.has(tx.extra_signatories, vkh)
    Script(_) -> False  // <-- silently fails, no error
  }
}

// ❌ VULNERABLE — register doesn't check owner credential type
fn validate_register(seed, policy_id, tx) -> Bool {
  // ... checks output has inline datum, NFT, deposit ...
  // Does NOT check what type of credential is in datum.owner
  True
}
```

#### Fixed Pattern

```aiken
// ✅ FIXED — validate owner credential type before storing
fn validate_output_owner(output: Output, tx: Transaction) -> Bool {
  expect datum: AgentDatum = resolve_inline_datum(output)
  when datum.owner is {
    VerificationKey(vkh) -> list.has(tx.extra_signatories, vkh)
    Script(_) -> False  // Reject — script credentials can't operate the UTxO
  }
}

fn validate_register(seed, policy_id, tx) -> Bool {
  // ... existing checks ...
  // ✅ Now also validates owner credential type and signature
  && validate_output_owner(valid_output, tx)
}
```

The same check was added to `validate_update` to prevent transferring ownership to a script credential.

#### Key Takeaway

**Always validate credential types at the point of storage, not just at the point of use.** If your validator only handles `VerificationKey` in signature checks, block `Script` credentials from entering your datum in the first place.

---

### 4. Ghost UTxO Creation (`list.any` Abuse)

**Severity: 🟠 Medium**

#### The Problem

When a validator uses `list.any` to check that *at least one* output meets requirements, the transaction can include additional outputs at the script address that don't meet any requirements. These "ghost" UTxOs contain only ADA (no NFT, no valid datum) and are permanently unspendable.

#### What Happens

An attacker registers a valid agent while simultaneously creating N ghost UTxOs at the script address:
- Each ghost costs only the minimum ADA for a UTxO (~1-2 ADA)
- They permanently clutter the script address
- Indexers must process them, increasing query costs
- Users see confusing entries when browsing the registry
- The ghost UTxOs can never be cleaned up — there's no validator path to spend them

#### Vulnerable Pattern

```aiken
// ❌ VULNERABLE — accepts any number of outputs at script address
let valid = list.any(
  tx.outputs,
  fn(output) {
    output.address == script_address
      && has_inline_datum(output)
      && quantity_of(output.value, policy_id, nft_name) == 1
      && lovelace_of(output.value) >= min_deposit_lovelace
  },
)
```

#### Fixed Pattern

```aiken
// ✅ FIXED — exactly one output at script address
let script_outputs =
  list.filter(tx.outputs, fn(o) { o.address == script_address })
when script_outputs is {
  [output] ->
    has_inline_datum(output)
      && quantity_of(output.value, policy_id, nft_name) == 1
      && lovelace_of(output.value) >= min_deposit_lovelace
  _ -> False
}
```

#### Key Takeaway

**`list.any` is almost never what you want for output validation.** Filter, count, and match explicitly. One valid output among many is not the same as exactly one valid output.

---

### 5. Identity Spoofing (Missing Authorization)

**Severity: 🔴 High**

#### The Problem

If the registration endpoint doesn't require the claimed owner to sign the transaction, anyone can register agents under someone else's identity. In eUTXO, "anyone can build any transaction" — the only gatekeepers are validator checks and signature requirements.

#### What Happens

1. Attacker reads a prominent entity's verification key hash from the chain
2. Registers an agent with that entity's VKH as `owner` in the datum — no signature needed
3. The registry now shows a fake agent entry under the legitimate entity's identity
4. Off-chain tools, agent discovery protocols, and A2A communication can't distinguish real from fake
5. This scales: 100 fake registrations cost 1000 AP3X + fees

Combined with front-running (Vector #8), an attacker can race to register before the legitimate entity and claim the preferred name/endpoint.

#### Vulnerable Pattern

```aiken
// ❌ VULNERABLE — anyone can register, no owner signature required
fn validate_register(seed, policy_id, tx) -> Bool {
  let expected_name = compute_nft_name(seed)
  // Checks: seed consumed, NFT minted, output valid
  // Does NOT check: who signed the transaction
  // Does NOT check: owner in datum matches a signer
  seed_consumed && nft_correct && output_valid
}
```

#### Fixed Pattern

```aiken
// ✅ FIXED — owner must sign registration
fn validate_register(seed, policy_id, tx) -> Bool {
  let expected_name = compute_nft_name(seed)
  seed_consumed && nft_correct && output_valid
    && validate_output_owner(valid_output, tx)  // owner must sign
}
```

#### Key Takeaway

**Every operation that creates a binding between an identity and on-chain state must require that identity to authorize it.** This seems obvious in hindsight, but the original design assumed the SDK would always be the transaction builder — a dangerous assumption.

---

### 6. NFT Name Mismatch on Deregister

**Severity: 🟠 Medium**

#### The Problem

When deregistering an agent, the validator must verify that the NFT being burned is the *same* NFT held in the agent's UTxO. If it only checks "something under this policy was burned at quantity -1" without verifying the asset name, an owner with multiple registrations could burn the wrong NFT.

#### What Happens

1. Alice owns two agents: NFT-A and NFT-B, each in separate UTxOs
2. Alice deregisters Agent A but the burn targets NFT-B's asset name
3. Validator sees: owner signed ✅, something burned at -1 ✅ — accepts
4. NFT-B is destroyed but Agent B's UTxO still exists (orphan — deposit locked)
5. Agent A's UTxO still exists with NFT-A intact but was "deregistered"

This creates an inconsistent state: one orphaned UTxO and one improperly freed UTxO.

#### Vulnerable Pattern

```aiken
// ❌ VULNERABLE — doesn't check WHICH token is burned
fn validate_deregister(datum: AgentDatum, own_utxo: OutputReference, tx: Transaction) -> Bool {
  let own_policy = get_policy_from_address(get_own_address(own_utxo, tx))
  let tokens = assets.tokens(tx.mint, own_policy)
  let token_list = dict.to_pairs(tokens)
  has_credential_signed(tx, datum.owner) && when token_list is {
    [Pair(_name, qty)] -> qty == -1  // Any name accepted!
    _ -> False
  }
}
```

#### Fixed Pattern

```aiken
// ✅ FIXED — verifies the burned NFT matches the one in this UTxO
fn validate_deregister(datum: AgentDatum, own_utxo: OutputReference, tx: Transaction) -> Bool {
  let own_address = get_own_address(own_utxo, tx)
  let own_policy = get_policy_from_address(own_address)
  let input_nft_name = find_nft_name(own_utxo, own_policy, tx)
  let tokens = assets.tokens(tx.mint, own_policy)
  let token_list = dict.to_pairs(tokens)
  has_credential_signed(tx, datum.owner) && when token_list is {
    [Pair(name, qty)] -> qty == -1 && name == input_nft_name
    _ -> False
  }
}
```

#### Key Takeaway

**When burning tokens, always verify the asset name matches what you expect.** "A token was burned" is not the same as "*the right* token was burned."

---

### 7. Deposit Destination Hijacking

**Severity: 🟠 Medium**

#### The Problem

When an agent deregisters, the UTxO is consumed and the deposit should return to the owner. But if the validator doesn't enforce *where* the freed value goes, a malicious SDK or compromised frontend can redirect the deposit to an attacker's address. The owner signed the transaction (required for deregistration), but may not have inspected every output.

#### What Happens

In the audited registry contract, this was documented as **accepted behavior** — the owner is signing, so they're authorizing the transaction as constructed. However, for AI agents that deregister programmatically (through an SDK), the risk is real:

1. Compromised SDK builds a deregister transaction sending the deposit to an attacker address
2. Agent's signing key approves the transaction (the agent can't inspect outputs at the SDK level)
3. Deposit is gone — sent to the attacker, not the agent owner

This is particularly dangerous because AI agents are more likely than humans to auto-sign SDK-constructed transactions without manual inspection.

#### Mitigation

This was intentionally not fixed on-chain in the audited contract (it would add complexity and might conflict with legitimate use cases like sending deposits to a different wallet). The recommended defenses are:

1. **Off-chain validation** — the SDK should verify outputs before signing
2. **Datum-specified return address** — store the return address in the datum and enforce it on-chain during deregistration
3. **Multi-sig** — require a second signature for high-value operations

#### Key Takeaway

**For AI agents that auto-sign transactions, every output destination should be validated either on-chain or in a trusted verification layer.** Don't rely on the signer "checking" the transaction — automated agents don't read transaction outputs.

---

### 8. Front-Running and Concurrency Attacks

**Severity: 🟠 Medium**

#### The Problem

In eUTXO, transactions compete to consume UTxOs. If two transactions try to consume the same UTxO, only the first to be included in a block succeeds — the other is invalidated. This is generally a feature (natural concurrency), but it creates front-running opportunities.

#### What Happens

**Registration front-running:**
1. Alice broadcasts a register transaction using seed UTxO `X`
2. Attacker sees it in the mempool, extracts the seed reference
3. Attacker broadcasts their own registration consuming `X` with higher fees
4. Attacker's transaction lands first — Alice's is invalidated
5. If no owner signature is required (Vector #5), the attacker can register under Alice's identity

**DEX front-running (from the audited DEX contract):**
1. User places a swap order by creating a UTxO at the DEX address
2. Attacker sees the pending order and front-runs with a worse price
3. Market maker fills the attacker's order first, moving the price
4. User's order either fails or executes at a worse rate

#### Mitigation

- **Owner signature on registration** (already applied) prevents the identity theft half of front-running
- **eUTXO's natural ordering** means the attack is limited to denial-of-service (forcing retry) rather than state manipulation
- **Batching protocols** like concentrated liquidity or batch auctions can mitigate DEX front-running
- **Private mempools** or encrypted mempools (Cardano roadmap) are the long-term solution

#### Key Takeaway

**eUTXO front-running is real but different from Ethereum MEV.** The attacker can deny your transaction and possibly steal your setup (seed UTxO), but they can't manipulate your contract's internal state — because there is no shared mutable state. Ensure every transaction that creates identity bindings requires the identity owner's signature.

---

### 9. Datum Bloat / Economic Griefing

**Severity: 🟡 Low-Medium**

#### The Problem

If a contract accepts arbitrary-length data in datum fields without size constraints, an attacker can store disproportionately large data on-chain for a fixed cost. When the deposit or fee structure doesn't scale with datum size, the economics favor the attacker.

#### What Happens

1. Attacker registers an agent with megabytes of data in `description` or `capabilities`
2. Cost: 10 AP3X (fixed minimum deposit) + standard transaction fees
3. Result: Bloated chain state, expensive to query, potential DoS on indexers that iterate all registry UTxOs
4. Every off-chain tool that reads registry state must download and process the bloated datum

#### Vulnerable Pattern

```aiken
// ❌ VULNERABLE — no size limits on datum fields
type AgentDatum {
  name: ByteArray,           // could be megabytes
  description: ByteArray,    // could be megabytes
  endpoint: ByteArray,       // could be megabytes
  capabilities: List<ByteArray>,  // could be thousands of entries
  owner: Credential,
  registered_at: Int,
}

// Validator checks datum exists but not its size
has_inline_datum(output)  // ← only checks presence
```

#### Mitigation

**On-chain options:**
```aiken
// Option A: Hard byte limits per field
fn valid_datum_size(datum: AgentDatum) -> Bool {
  bytearray.length(datum.name) <= 64
    && bytearray.length(datum.description) <= 256
    && bytearray.length(datum.endpoint) <= 128
    && list.length(datum.capabilities) <= 20
}

// Option B: Deposit proportional to datum size (more complex)
let required_deposit = min_deposit + (datum_byte_size * cost_per_byte)
```

**Off-chain options:**
- Indexers should reject or quarantine UTxOs with oversized datums
- SDKs should enforce size limits before transaction construction

#### Key Takeaway

**Fixed deposits with unbounded data storage create an economic imbalance.** Either bound the data or scale the cost. For MVP/demo contracts, off-chain filtering is acceptable; for production, on-chain limits are recommended.

---

### 10. Staking Credential Injection

**Severity: 🟡 Low**

#### The Problem

Cardano addresses have two components: a payment credential and an optional staking credential. When a validator constructs the expected script address, it typically sets `stake_credential: None`. If the output check uses exact address equality, an attacker who tries to inject a staking credential will be correctly rejected.

But if the check only compares the payment credential (ignoring staking), an attacker can attach their own staking credential to UTxOs at the script address, potentially earning staking rewards on locked deposits.

#### What Happens

In the audited contracts, this was tested and found to be **correctly defended** — the registry uses exact address comparison including staking credential. However, simpler contracts (escrow, DEX) had partial defenses:

```aiken
// ✅ DEFENDED — full address comparison
output.address == Address {
  payment_credential: Script(policy_id),
  stake_credential: None,
}

// ⚠️ PARTIAL — only checks payment credential
output.address.payment_credential == Script(policy_id)
// Attacker can inject: stake_credential: Some(attacker_key)
```

#### Mitigation

Always compare full addresses, including the staking credential:

```aiken
fn script_address_from_policy(policy_id: PolicyId) -> Address {
  Address {
    payment_credential: Script(policy_id),
    stake_credential: None,
  }
}

// Use exact equality
output.address == script_address_from_policy(own_policy)
```

#### Key Takeaway

**Compare full addresses, not just payment credentials.** Staking credential injection is low severity but it's a free check to add and eliminates an entire class of economic leakage.

---

## Mitigation Guidelines

### Per-Vector Summary

| # | Vector | Primary Mitigation | Defense Level |
|---|--------|--------------------|---------------|
| 1 | Orphan Burn | Couple burn to spend — require script input in burn handler | On-chain (mandatory) |
| 2 | Double Satisfaction | Single-script-input constraint OR singleton output enforcement | On-chain (mandatory) |
| 3 | Credential Type Confusion | Validate credential type at point of storage (register + update) | On-chain (mandatory) |
| 4 | Ghost UTxO Creation | Replace `list.any` with `list.filter` + singleton match | On-chain (mandatory) |
| 5 | Identity Spoofing | Require owner signature on registration | On-chain (mandatory) |
| 6 | NFT Name Mismatch | Verify burned asset name matches UTxO's NFT name | On-chain (mandatory) |
| 7 | Deposit Destination Hijacking | SDK-level output validation; optionally enforce return address in datum | Off-chain (recommended) |
| 8 | Front-Running | Owner signature prevents impersonation; accept retry-based DoS as inherent | Design-level |
| 9 | Datum Bloat | Field size limits on-chain; deposit scaling; off-chain filtering | On-chain (recommended) |
| 10 | Staking Credential Injection | Full address comparison including stake credential | On-chain (recommended) |

### Universal Patterns

These patterns should be in every eUTXO contract:

1. **Never use `list.any` for output matching.** Use `list.filter` + explicit count.
2. **Enforce single-script-input** unless you have a specific batching design with NFT thread tokens.
3. **Validate credential types at storage time**, not just at use time.
4. **Couple related handlers.** If mint and spend must co-occur, enforce it in both directions.
5. **Check asset names explicitly.** "A token was burned" ≠ "the right token was burned."
6. **Compare full addresses.** Payment credential alone is not sufficient.
7. **Require authorization for identity-binding operations.** Registration, ownership transfer, deregistration.

---

## Quick Reference Table

| # | Vector | Severity | Impact | Mitigation | Aiken Pattern |
|---|--------|----------|--------|------------|---------------|
| 1 | Orphan Burn | 🔴 Critical | Permanent deposit lock; NFT destroyed but UTxO stranded | Require script input in burn handler | `list.any(tx.inputs, fn(i) { i.output.address.payment_credential == Script(policy_id) })` |
| 2 | Double Satisfaction | 🔴 Critical | Deposit theft; one output satisfies two validators | Single-script-input OR singleton output | `list.filter(tx.outputs, ...) \|> expect [single]` |
| 3 | Credential Type Confusion | 🔴 High | Permanent UTxO lock; unreachable owner | Block `Script` credentials in datum | `when datum.owner is { Script(_) -> False .. }` |
| 4 | Ghost UTxO Creation | 🟠 Medium | Permanently unspendable dust; indexer DoS | Singleton output enforcement | Replace `list.any` with `list.filter` + `[output] ->` |
| 5 | Identity Spoofing | 🔴 High | Registry pollution; fake agents under real identities | Owner signature on register | `validate_output_owner(output, tx)` |
| 6 | NFT Name Mismatch | 🟠 Medium | Wrong NFT burned; orphaned UTxO | Match burned name to input NFT | `name == input_nft_name` in burn check |
| 7 | Deposit Hijacking | 🟠 Medium | Deposit sent to attacker on deregister | SDK validation; optional on-chain return address | Off-chain or datum-enforced |
| 8 | Front-Running | 🟠 Medium | Registration DoS; identity races | Owner sig prevents impersonation | Design-level mitigation |
| 9 | Datum Bloat | 🟡 Low-Med | Chain bloat; indexer DoS; economic griefing | Field size limits; scaled deposits | `bytearray.length(field) <= MAX` |
| 10 | Staking Injection | 🟡 Low | Unauthorized staking rewards on locked funds | Full address comparison | `output.address == full_script_address` |

---

## Further Reading

### eUTXO Security Foundations
- [Cardano Plutus Documentation](https://plutus.readthedocs.io/) — Official Plutus smart contract documentation
- [Aiken Language Reference](https://aiken-lang.org/) — Aiken smart contract language for Cardano
- [CIP-31: Reference Inputs](https://cips.cardano.org/cip/CIP-0031) — Understand reference input attack surfaces
- [CIP-52: Smart Contract Security Audit Standards](https://cips.cardano.org/cip/CIP-0052) — Cardano's audit assurance levels

### Double Satisfaction Deep Dives
- [Cardano Double Satisfaction Attack (MLabs)](https://library.mlabs.city/common-plutus-security-vulnerabilities) — Canonical description of the vector
- The single-script-input pattern is documented across all four audited DeFi contracts — escrow, vesting, donation pool, and DEX

### Agent Identity on eUTXO
- [DID:Method Specification](https://www.w3.org/TR/did-core/) — W3C Decentralized Identifiers standard
- [ERC-5192 (Soulbound)](https://eips.ethereum.org/EIPS/eip-5192) — Ethereum's approach to soulbound tokens (contrast with eUTXO's structural soulbinding)

### Vector/ApexFusion Ecosystem
- [ApexFusion Documentation](https://docs.apexfusion.org/) — Vector chain architecture and tooling
- PyCardano + Ogmios — The SDK stack used for off-chain transaction building in the audited contracts

---

*This document is based on findings from security audits conducted in March 2026. All vulnerabilities described were identified and fixed in the audited contracts. The patterns and mitigations are applicable to any eUTXO smart contract development.*
