# eUTXO Security Patterns for Aiken Developers

A catalog of reusable security patterns for Aiken smart contracts on eUTXO chains (Cardano, Vector/ApexFusion, and derivatives). Each pattern addresses a real vulnerability class discovered during production audits. Copy-paste ready.

**Audience:** Aiken developers writing validators for eUTXO chains.
**Aiken version:** v1.1.x (Plutus V3 semantics).

---

## Introduction

eUTXO validators are pure functions — they return `True` or `False` for a given transaction context. This purity makes them auditable, but the interaction between multiple validators executing in the same transaction creates a unique attack surface absent from account-based chains.

The dominant vulnerability class is **double satisfaction**: two script inputs sharing one output to meet both validators' requirements. But the surface extends to orphaned burns, ghost UTxOs, credential confusion, and identity mismatches.

This document distills 10 defensive patterns from real audit findings across multiple contracts. Each pattern includes the vulnerable code it replaces, a copy-paste fix, and a testing strategy.

**Conventions:**
- `tx` refers to `Transaction` from `cardano/transaction`
- `assets` refers to `cardano/assets`
- `list` refers to `aiken/collection/list`
- Code examples use Aiken syntax

---

## Pattern Catalog

---

### Pattern 1: Singleton Output (replaces `list.any`)

**One-line:** Require exactly one output at the script address instead of checking if *any* output matches.

#### Problem

`list.any` on transaction outputs accepts the first matching output without constraining how many exist. An attacker can include additional outputs at the script address — ghost UTxOs with no NFT, or duplicate outputs that satisfy multiple inputs simultaneously.

#### Anti-Pattern (Vulnerable)

```aiken
// ❌ VULNERABLE: accepts ANY matching output, ignores extras
let valid_output =
  list.any(
    tx.outputs,
    fn(output) {
      and {
        output.address == script_address,
        has_inline_datum(output),
        assets.quantity_of(output.value, policy_id, expected_name) == 1,
        assets.lovelace_of(output.value) >= min_deposit,
      }
    },
  )
```

#### Pattern (Fixed)

```aiken
// ✅ SECURE: exactly one output at script address, and it must satisfy all checks
let script_outputs =
  list.filter(tx.outputs, fn(output) { output.address == script_address })

let valid_output =
  when script_outputs is {
    [output] ->
      and {
        has_inline_datum(output),
        assets.quantity_of(output.value, policy_id, expected_name) == 1,
        assets.lovelace_of(output.value) >= min_deposit,
      }
    _ -> False
  }
```

#### Complete Snippet

```aiken
use aiken/collection/list
use cardano/address.{Address}
use cardano/assets
use cardano/transaction.{InlineDatum, Output, Transaction}

/// Validate that exactly one output exists at `target_address` and it
/// satisfies all provided conditions. Returns False if zero or 2+ outputs exist.
pub fn validate_singleton_output(
  tx: Transaction,
  target_address: Address,
  policy_id: ByteArray,
  expected_name: ByteArray,
  min_deposit: Int,
) -> Bool {
  let script_outputs =
    list.filter(tx.outputs, fn(output) { output.address == target_address })

  when script_outputs is {
    [output] ->
      and {
        when output.datum is {
          InlineDatum(_) -> True
          _ -> False
        },
        assets.quantity_of(output.value, policy_id, expected_name) == 1,
        assets.lovelace_of(output.value) >= min_deposit,
      }
    _ -> False
  }
}
```

#### When to Use

- **Always** when checking for a continuing output at your own script address.
- **Always** when validating outputs during mint (registration) handlers.
- **Exception:** If your protocol explicitly supports batched operations at the same script address, you need Pattern 9 (output counting) instead.

#### Testing Strategy

1. **Happy path:** One valid output at script address → `True`.
2. **Ghost UTxO:** One valid output + one lovelace-only output at script address → `False`.
3. **Zero outputs:** No outputs at script address → `False`.
4. **Two valid outputs:** Two fully valid outputs at script address → `False`.

---

### Pattern 2: Burn-Spend Coupling

**One-line:** Require that a burn transaction also spends a UTxO at the script address, coupling the minting policy to the spend validator.

#### Problem

If the burn (minting policy) validator runs independently of the spend validator, an attacker can burn an identity NFT without going through the deregistration logic. The UTxO remains at the script address — permanently locked, with its deposit unrecoverable.

#### Anti-Pattern (Vulnerable)

```aiken
// ❌ VULNERABLE: burn fires independently, no coupling to spend
pub fn validate_burn(policy_id: PolicyId, tx: Transaction) -> Bool {
  let minted_tokens = assets.tokens(tx.mint, policy_id)
  when dict.to_pairs(minted_tokens) is {
    [Pair(_, qty)] -> qty == -1
    _ -> False
  }
}
```

#### Pattern (Fixed)

```aiken
// ✅ SECURE: burn requires a script input (spend validator must also execute)
pub fn validate_burn(policy_id: PolicyId, tx: Transaction) -> Bool {
  let minted_tokens = assets.tokens(tx.mint, policy_id)
  let burn_check =
    when dict.to_pairs(minted_tokens) is {
      [Pair(_, qty)] -> qty == -1
      _ -> False
    }

  // At least one input must be at the script address
  let has_script_input =
    list.any(
      tx.inputs,
      fn(input) {
        input.output.address.payment_credential == Script(policy_id)
      },
    )

  burn_check && has_script_input
}
```

#### Complete Snippet

```aiken
use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction}

/// Validate a burn: exactly one token burned AND a script-address input exists.
/// The script-address input triggers the spend validator, which handles
/// authorization, deposit return, and identity verification.
pub fn validate_burn_coupled(policy_id: PolicyId, tx: Transaction) -> Bool {
  let minted_tokens = assets.tokens(tx.mint, policy_id)

  let valid_burn =
    when dict.to_pairs(minted_tokens) is {
      [Pair(_, qty)] -> qty == -1
      _ -> False
    }

  let has_script_input =
    list.any(
      tx.inputs,
      fn(input) {
        input.output.address.payment_credential == Script(policy_id)
      },
    )

  valid_burn && has_script_input
}
```

#### When to Use

- **Always** when your minting policy has both mint and burn paths, and burns should only happen alongside specific spend logic (deregistration, closing, liquidation).
- **Not needed** if burn is the only operation (no associated spend validator) or if the burn path is purely permissionless by design.

#### Testing Strategy

1. **Happy path:** Burn with script-address input present → `True`.
2. **Orphan burn:** Burn with no inputs at script address → `False`.
3. **Unrelated inputs:** Burn with inputs at other addresses (not the script) → `False`.
4. **Coupling integrity:** Verify that when a script-address UTxO is included, the spend validator also executes (integration-level test).

---

### Pattern 3: Credential Type Guard

**One-line:** Explicitly reject `Script` credentials where only `VerificationKey` credentials are valid.

#### Problem

Aiken's `Credential` type has two variants: `VerificationKey(hash)` and `Script(hash)`. If a datum's `owner` field accepts either, but the validator only knows how to authorize via `extra_signatories` (which only works for verification keys), then setting `owner` to a `Script` credential makes the UTxO permanently unspendable. The deposit is locked forever.

#### Anti-Pattern (Vulnerable)

```aiken
// ❌ VULNERABLE: accepts any credential, but has_credential_signed
// silently returns False for Script credentials → permanent lock
pub fn has_credential_signed(tx: Transaction, credential: Credential) -> Bool {
  when credential is {
    VerificationKey(vkh) ->
      list.any(tx.extra_signatories, fn(s) { s == vkh })
    _ -> False  // Script credentials silently fail — UTxO becomes unspendable
  }
}

// Caller doesn't check credential type before storing in datum
```

#### Pattern (Fixed)

```aiken
// ✅ SECURE: reject Script credentials at the point of entry (registration/update)
fn validate_owner_credential(output: Output, tx: Transaction) -> Bool {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: AgentDatum = raw_datum
  when datum.owner is {
    VerificationKey(_) -> has_credential_signed(tx, datum.owner)
    Script(_) -> False  // Explicit rejection — not just "can't sign"
  }
}
```

#### Complete Snippet

```aiken
use cardano/address.{Credential, Script, VerificationKey}
use cardano/transaction.{InlineDatum, Output, Transaction}
use aiken/collection/list

/// Check that a credential is a VerificationKey (not Script).
/// Use at every entry point where a credential is stored in a datum.
pub fn is_verification_key(credential: Credential) -> Bool {
  when credential is {
    VerificationKey(_) -> True
    Script(_) -> False
  }
}

/// Check that a VerificationKey credential has signed the transaction.
/// Returns False for Script credentials (defense in depth).
pub fn has_vk_signed(tx: Transaction, credential: Credential) -> Bool {
  when credential is {
    VerificationKey(vkh) ->
      list.any(tx.extra_signatories, fn(s) { s == vkh })
    Script(_) -> False
  }
}

/// Gate: reject datum if owner is not a VerificationKey.
/// Call this during registration AND during ownership transfer (update).
pub fn require_vk_owner(output: Output, tx: Transaction) -> Bool {
  expect InlineDatum(raw_datum) = output.datum
  // Replace YourDatumType with your actual datum type
  expect datum: YourDatumType = raw_datum
  is_verification_key(datum.owner) && has_vk_signed(tx, datum.owner)
}
```

#### When to Use

- **Always** when storing a `Credential` in a datum that will later be used for `extra_signatories` authorization.
- **On both create and update paths** — blocking Script credentials at registration is not enough if an update can transfer ownership to a Script credential.
- **Not needed** if your protocol intentionally supports script-controlled ownership (multisig, DAO governance). In that case, you need a different authorization mechanism.

#### Testing Strategy

1. **VK owner registers:** `VerificationKey` credential + matching signature → `True`.
2. **Script owner registers:** `Script` credential → `False`.
3. **VK transfers to VK:** Update changes owner to new `VerificationKey` → `True`.
4. **VK transfers to Script:** Update changes owner to `Script` → `False`.

---

### Pattern 4: Owner Authorization on State Creation

**One-line:** Require the owner's signature when creating state that claims their identity.

#### Problem

If a mint/register handler does not require the owner to sign the transaction, anyone can create state entries (agent registrations, escrow contracts, vesting schedules) that claim arbitrary identities as owners. This pollutes the on-chain state with unauthorized entries.

#### Anti-Pattern (Vulnerable)

```aiken
// ❌ VULNERABLE: no owner signature check during registration
pub fn validate_register(seed: OutputReference, policy_id: PolicyId, tx: Transaction) -> Bool {
  let seed_consumed = list.any(tx.inputs, fn(input) { input.output_reference == seed })
  let correct_mint = ...
  // Output is checked for structure but NOT for owner authorization
  let valid_output =
    list.any(tx.outputs, fn(output) {
      and {
        output.address == script_address,
        has_inline_datum(output),
        assets.quantity_of(output.value, policy_id, expected_name) == 1,
        assets.lovelace_of(output.value) >= min_deposit,
      }
    })
  seed_consumed && correct_mint && valid_output
}
```

#### Pattern (Fixed)

```aiken
// ✅ SECURE: extract datum from output, verify owner signed
pub fn validate_register(seed: OutputReference, policy_id: PolicyId, tx: Transaction) -> Bool {
  let seed_consumed = list.any(tx.inputs, fn(input) { input.output_reference == seed })
  let correct_mint = ...
  let script_address = script_address_from_policy(policy_id)

  let script_outputs =
    list.filter(tx.outputs, fn(output) { output.address == script_address })

  let valid_output =
    when script_outputs is {
      [output] ->
        and {
          has_inline_datum(output),
          assets.quantity_of(output.value, policy_id, expected_name) == 1,
          assets.lovelace_of(output.value) >= min_deposit,
          validate_output_owner(output, tx),  // NEW: owner must sign
        }
      _ -> False
    }

  seed_consumed && correct_mint && valid_output
}

fn validate_output_owner(output: Output, tx: Transaction) -> Bool {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: YourDatumType = raw_datum
  when datum.owner is {
    VerificationKey(_) -> has_credential_signed(tx, datum.owner)
    Script(_) -> False
  }
}
```

#### Complete Snippet

```aiken
use aiken/collection/list
use cardano/address.{Credential, Script, VerificationKey}
use cardano/transaction.{InlineDatum, Output, Transaction}

/// Validate that the output's datum contains an owner who:
/// 1. Is a VerificationKey credential (not Script)
/// 2. Has signed this transaction
///
/// Call this in your mint/register handler after structural validation.
pub fn validate_output_owner(output: Output, tx: Transaction) -> Bool {
  expect InlineDatum(raw_datum) = output.datum
  // Replace with your datum type:
  expect datum: YourDatumType = raw_datum
  when datum.owner is {
    VerificationKey(vkh) ->
      list.any(tx.extra_signatories, fn(s) { s == vkh })
    Script(_) -> False
  }
}
```

#### When to Use

- **Always** when a mint handler creates state with an `owner` field.
- **Combines with** Pattern 3 (credential type guard) — this pattern adds the signature check on top.
- **Not needed** if the minting transaction is inherently self-authenticating (e.g., the seed UTxO is at the owner's address and consuming it proves ownership).

#### Testing Strategy

1. **Owner signs:** Registration with owner VKH in `extra_signatories` → `True`.
2. **Owner doesn't sign:** Registration without owner signature → `False`.
3. **Wrong signer:** Registration signed by a different key than the datum's owner → `False`.
4. **Attacker claims victim:** Attacker builds TX with victim's VKH as owner, attacker signs → `False`.

---

### Pattern 5: NFT Identity by Name (not just quantity)

**One-line:** When checking an NFT burn or transfer, verify both the asset name AND quantity — not just that "something was burned."

#### Problem

Under a single minting policy, multiple NFTs can exist with different asset names. If the burn/deregister validator only checks `qty == -1` without verifying *which* token was burned, an attacker with multiple registrations can burn the wrong NFT while deregistering.

#### Anti-Pattern (Vulnerable)

```aiken
// ❌ VULNERABLE: checks quantity but not which NFT was burned
pub fn validate_deregister(datum: AgentDatum, own_utxo: OutputReference, tx: Transaction) -> Bool {
  let owner_signed = has_credential_signed(tx, datum.owner)
  let own_policy = get_policy_from_address(get_own_address(tx.inputs, own_utxo))

  let minted_tokens = assets.tokens(tx.mint, own_policy)
  let nft_burned =
    when dict.to_pairs(minted_tokens) is {
      [Pair(_, qty)] -> qty == -1  // ← Only checks quantity!
      _ -> False
    }

  owner_signed && nft_burned
}
```

#### Pattern (Fixed)

```aiken
// ✅ SECURE: extracts the NFT name from the input and verifies it matches the burn
pub fn validate_deregister(datum: AgentDatum, own_utxo: OutputReference, tx: Transaction) -> Bool {
  let owner_signed = has_credential_signed(tx, datum.owner)
  let own_address = get_own_address(tx.inputs, own_utxo)
  let own_policy = get_policy_from_address(own_address)

  // Extract the specific NFT name from the UTxO being spent
  let input_value = get_own_value(tx.inputs, own_utxo)
  let input_nft_name = find_nft_name(input_value, own_policy)

  // Verify the burned token matches BY NAME
  let minted_tokens = assets.tokens(tx.mint, own_policy)
  let nft_burned =
    when dict.to_pairs(minted_tokens) is {
      [Pair(name, qty)] -> name == input_nft_name && qty == -1
      _ -> False
    }

  owner_signed && nft_burned
}
```

#### Complete Snippet

```aiken
use aiken/collection/dict
use aiken/collection/list
use cardano/assets
use cardano/transaction.{Input, OutputReference, Transaction}

/// Extract the NFT asset name for a given policy from a value.
/// Expects exactly one token with quantity 1 under the policy.
/// Panics (rejects TX) if the assumption is violated.
pub fn find_nft_name(value: assets.Value, policy_id: assets.PolicyId) -> ByteArray {
  let tokens = assets.tokens(value, policy_id)
  expect [Pair(name, 1)] = dict.to_pairs(tokens)
  name
}

/// Get the value locked in a specific input UTxO.
pub fn get_own_value(inputs: List<Input>, own_ref: OutputReference) -> assets.Value {
  expect Some(input) =
    list.find(inputs, fn(input) { input.output_reference == own_ref })
  input.output.value
}

/// Validate that the burned token matches the NFT in the spent UTxO.
pub fn validate_correct_burn(
  tx: Transaction,
  own_utxo: OutputReference,
  policy_id: assets.PolicyId,
) -> Bool {
  let input_value = get_own_value(tx.inputs, own_utxo)
  let input_nft_name = find_nft_name(input_value, policy_id)

  let minted_tokens = assets.tokens(tx.mint, policy_id)
  when dict.to_pairs(minted_tokens) is {
    [Pair(name, qty)] -> name == input_nft_name && qty == -1
    _ -> False
  }
}
```

#### When to Use

- **Always** when multiple NFTs can exist under the same minting policy.
- **Always** when a spend validator checks for a burn event.
- **Not needed** if the minting policy can only ever produce one NFT (but even then, defense-in-depth suggests checking).

#### Testing Strategy

1. **Correct burn:** Burn matches the NFT name in the spent UTxO → `True`.
2. **Wrong name burn:** Burn a different NFT name under the same policy → `False`.
3. **Multiple burns:** Two tokens burned in one TX — only one matches → `False` (singleton check on `dict.to_pairs`).

---

### Pattern 6: Deposit Return Enforcement

**One-line:** When closing or deregistering state, enforce that the deposit returns to the owner (or is explicitly authorized by the owner's signature).

#### Problem

When a UTxO with a locked deposit is consumed (deregistration, escrow release, vesting claim), the validator may check that the owner signed but not where the funds go. This allows the deposit to be sent anywhere the transaction builder chooses.

#### Design Decision: Enforce vs. Accept

This is a **design choice**, not always a vulnerability:

- **Enforce return:** Safer for users who may not inspect transaction details.
- **Accept owner signature:** Simpler, more flexible — owner authorizes the TX, so they control where funds go. Legitimate use cases include sending deposits to different wallets the owner controls.

#### Pattern: Enforce Return

```aiken
/// Enforce that the deposit is returned to the owner's address.
/// Use when users cannot be expected to verify transaction outputs.
pub fn validate_deposit_return(
  tx: Transaction,
  owner: Credential,
  min_return: Int,
) -> Bool {
  let owner_address = Address {
    payment_credential: owner,
    stake_credential: None,
  }

  list.any(
    tx.outputs,
    fn(output) {
      output.address == owner_address &&
      assets.lovelace_of(output.value) >= min_return
    },
  )
}
```

#### Pattern: Accept Signature (Explicit Non-Enforcement)

```aiken
/// Document the design decision: owner must sign, deposit destination is their choice.
/// This is NOT a vulnerability if the owner is a VerificationKey who signs.
pub fn validate_deregister(datum: YourDatum, tx: Transaction) -> Bool {
  // Owner signature is the authorization — they choose where funds go
  let owner_signed = has_credential_signed(tx, datum.owner)
  let nft_burned = validate_correct_burn(tx, ...)

  // NOTE: Deposit destination is NOT enforced. Owner's signature authorizes
  // any output configuration. This is a conscious design decision.
  owner_signed && nft_burned
}
```

#### When to Use

- **Enforce return** when the protocol handles deposits on behalf of users who may use wallets that auto-sign without showing outputs.
- **Accept signature** when the owner is sophisticated and the protocol values flexibility (e.g., sending remaining funds to a different wallet).
- **Document your choice** either way — this is one of the most common audit findings because intent is ambiguous.

#### Testing Strategy

1. **If enforcing:** Deposit returned to owner → `True`. Deposit sent elsewhere → `False`.
2. **If not enforcing:** Document a behavioral test that explicitly shows the non-enforcement and labels it as intended.

---

### Pattern 7: Datum Shape Validation

**One-line:** Validate datum structure and field constraints at the point of creation, not just at spend time.

#### Problem

In eUTXO, anyone can create a UTxO at any address with any datum. If your validator only checks datum structure when spending, malformed datums can accumulate at the script address. These "degenerate" UTxOs may be permanently unspendable or cause unexpected behavior.

#### Pattern

```aiken
use cardano/transaction.{InlineDatum, Output}

/// Validate that an output has an inline datum (not a hash or none).
/// Critical for Plutus V3 contracts — datum hash references add complexity
/// and are a source of datum substitution attacks.
pub fn has_inline_datum(output: Output) -> Bool {
  when output.datum is {
    InlineDatum(_) -> True
    _ -> False
  }
}

/// Validate datum shape during registration/creation.
/// Add your domain-specific constraints here.
pub fn validate_datum_shape(output: Output) -> Bool {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: YourDatumType = raw_datum

  and {
    // Type deserialization succeeded (implicit check via expect)
    // Add field-level validations:
    is_verification_key(datum.owner),
    // datum.amount > 0,
    // builtin.length_of_bytearray(datum.name) <= 64,
    True,
  }
}
```

#### When to Use

- **Always** require `InlineDatum` in Plutus V3 contracts — there is no reason to use datum hashes.
- **At creation points** (mint/register handlers): validate the datum's type deserializes correctly.
- **Field-level validation** is optional — consider whether on-chain enforcement is worth the execution cost vs. off-chain filtering by indexers.

#### Testing Strategy

1. **Valid datum:** Correct type, all fields within bounds → `True`.
2. **Non-inline datum:** Datum hash reference → `False`.
3. **No datum:** `NoDatum` → `False`.
4. **Malformed datum:** Datum that doesn't deserialize to expected type → TX panics (via `expect`).

---

### Pattern 8: Graceful Failure (replacing `expect` with `when`)

**One-line:** Use `when` expressions for controlled `False` returns instead of `expect` for uncontrolled panics.

#### Problem

Aiken's `expect` keyword panics (causes the transaction to fail with an unhelpful error) when the pattern doesn't match. While the end result (TX rejection) is the same, `expect` panics:
1. Give no diagnostic information about *why* the TX failed.
2. Cannot be composed — a panic short-circuits all validation.
3. Make testing harder — you can't assert `== False`, only that it panics.

#### Anti-Pattern

```aiken
// ❌ FRAGILE: panics on unexpected input, no diagnostic info
pub fn get_policy_from_address(addr: Address) -> PolicyId {
  expect Script(hash) = addr.payment_credential
  hash
}

pub fn find_nft_name(value: assets.Value, policy_id: PolicyId) -> ByteArray {
  let tokens = assets.tokens(value, policy_id)
  expect [Pair(name, 1)] = dict.to_pairs(tokens)
  name
}
```

#### Pattern (Graceful)

```aiken
// ✅ ROBUST: returns Option, caller decides how to handle
pub fn get_policy_from_address(addr: Address) -> Option<PolicyId> {
  when addr.payment_credential is {
    Script(hash) -> Some(hash)
    VerificationKey(_) -> None
  }
}

pub fn find_nft_name(value: assets.Value, policy_id: PolicyId) -> Option<ByteArray> {
  let tokens = assets.tokens(value, policy_id)
  when dict.to_pairs(tokens) is {
    [Pair(name, 1)] -> Some(name)
    _ -> None
  }
}
```

#### When to Use

- **Use `when`/`Option`** for inputs that could legitimately vary (user-supplied data, datum deserialization, output structure).
- **`expect` is acceptable** when the condition is a logical invariant that should never fail given prior checks — e.g., finding your own UTxO in `tx.inputs` after the ledger guarantees it's there.
- **Pragmatic rule:** If an `expect` panic would leave developers debugging with no information, replace it with `when`.

#### Testing Strategy

1. **Happy path:** Valid input → `Some(value)`.
2. **Invalid input:** Unexpected structure → `None` (not a panic).
3. **Composition:** Chain multiple `Option`-returning functions to verify graceful propagation.

---

### Pattern 9: Output Counting for Double Satisfaction Prevention

**One-line:** Count script inputs to enforce that only one script UTxO is spent per transaction, eliminating double satisfaction at the root.

#### Problem

Double satisfaction is the canonical eUTXO vulnerability. Two script inputs in the same transaction can share a single output to satisfy both validators. Output-index pinning (specifying which output index satisfies which input) is **necessary but not sufficient** — two inputs can specify the same index.

#### Pattern: Single Script Input

```aiken
use aiken/collection/list
use cardano/address.{Address, Script}
use cardano/transaction.{Transaction}

/// Count how many transaction inputs are at a specific script address.
pub fn count_script_inputs(tx: Transaction, script_address: Address) -> Int {
  list.foldl(
    tx.inputs,
    0,
    fn(input, count) {
      if input.output.address == script_address {
        count + 1
      } else {
        count
      }
    },
  )
}

/// Enforce single script input — the nuclear option for double satisfaction.
/// Place this check at the top of every spend validator.
pub fn require_single_script_input(tx: Transaction, own_address: Address) -> Bool {
  count_script_inputs(tx, own_address) == 1
}
```

#### Combined with Singleton Output (Belt and Suspenders)

```aiken
/// Full double-satisfaction defense: one input, one output.
pub fn validate_update(datum: YourDatum, own_utxo: OutputReference, tx: Transaction) -> Bool {
  let own_address = get_own_address(tx.inputs, own_utxo)

  // Defense layer 1: only one script input
  let single_input = count_script_inputs(tx, own_address) == 1

  // Defense layer 2: only one script output (Pattern 1)
  let script_outputs =
    list.filter(tx.outputs, fn(output) { output.address == own_address })
  let single_output =
    when script_outputs is {
      [output] -> validate_output(output, ...)
      _ -> False
    }

  single_input && single_output && has_credential_signed(tx, datum.owner)
}
```

#### When to Use

- **Prefer single-script-input** as the default for all spend validators. It's simple and eliminates the entire vulnerability class.
- **Trade-off:** Prevents batching multiple operations at the same script address in one TX. This is almost always the correct trade-off — batching is the attack vector.
- **Alternative:** If batching is required, use NFT thread tokens to pair inputs to outputs. This is more complex but allows safe batching.

#### Testing Strategy

1. **Single input:** One script input → `True`.
2. **Double input:** Two script inputs, one shared output → `False`.
3. **Double input, two outputs:** Two script inputs with separate outputs → still `False` (single-input check catches it regardless of output structure).

---

### Pattern 10: Staking Credential Normalization

**One-line:** When comparing addresses or constructing script addresses, account for the `stake_credential` field to prevent mismatches.

#### Problem

Cardano addresses have two parts: `payment_credential` and `stake_credential`. When a validator constructs the "expected" script address with `stake_credential: None`, but the actual on-chain UTxO has a staking credential attached, the address comparison fails. This can cause valid operations to be rejected — or worse, if only the payment credential is compared, UTxOs with different staking credentials may be incorrectly treated as equivalent.

#### Pattern

```aiken
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId}

/// Construct script address with explicit None stake credential.
/// IMPORTANT: This must match how UTxOs are actually created on-chain.
/// If your deployment uses staked script addresses, update accordingly.
pub fn script_address_from_policy(policy_id: PolicyId) -> Address {
  Address {
    payment_credential: Script(policy_id),
    stake_credential: None,
  }
}

/// Alternative: compare only payment credentials when stake credential
/// variation is expected. Use with caution — this weakens address matching.
pub fn same_payment_credential(a: Address, b: Address) -> Bool {
  a.payment_credential == b.payment_credential
}
```

#### When to Use

- **Always verify** that your address construction matches your deployment configuration.
- **Use full address comparison** (`==`) when you control both the address construction and the UTxO creation.
- **Use payment-credential-only comparison** only when UTxOs may legitimately have different staking credentials (rare).
- **Document your assumption** — auditors will flag `stake_credential: None` as a potential issue.

#### Testing Strategy

1. **Matching addresses:** Script address with `None` stake matches output → `True`.
2. **Staked address mismatch:** Output has a staking credential, validator expects `None` → `False` (catches deployment misconfiguration).
3. **Deployment verification:** Confirm the on-chain address format matches the validator's expected format.

---

## Anti-Pattern Gallery

A quick reference of what NOT to do, with explanations.

### ❌ 1. `list.any` for Output Matching

```aiken
// WRONG: accepts any matching output, allows ghost UTxOs and double satisfaction
list.any(tx.outputs, fn(output) { output.address == script_address && ... })
```

**Why it's wrong:** `list.any` finds *one* match and ignores all other outputs. Extra outputs at the script address go unchecked. Two script inputs can share one "valid" output.

**Fix:** Pattern 1 (singleton output) or Pattern 9 (single script input).

---

### ❌ 2. Uncoupled Burn

```aiken
// WRONG: burn validator runs independently of spend
pub fn validate_burn(policy_id: PolicyId, tx: Transaction) -> Bool {
  // Only checks mint field, no coupling to spend
  when dict.to_pairs(assets.tokens(tx.mint, policy_id)) is {
    [Pair(_, qty)] -> qty == -1
    _ -> False
  }
}
```

**Why it's wrong:** NFT can be destroyed while the UTxO (and its deposit) remains permanently locked.

**Fix:** Pattern 2 (burn-spend coupling).

---

### ❌ 3. Accepting Any Credential Type as Owner

```aiken
// WRONG: allows Script credentials that can never sign
let owner_signed = has_credential_signed(tx, datum.owner)
// If datum.owner is Script(_), this silently returns False forever
```

**Why it's wrong:** A `Script` credential as `owner` makes `has_credential_signed` always return `False`. The UTxO becomes permanently unspendable. Deposit is lost.

**Fix:** Pattern 3 (credential type guard) at registration AND update.

---

### ❌ 4. No Owner Signature on Registration

```aiken
// WRONG: anyone can register state claiming any identity
pub fn validate_register(...) -> Bool {
  seed_consumed && correct_mint && valid_output
  // No check that datum.owner actually signed!
}
```

**Why it's wrong:** Attacker creates entries with victim's VKH as owner. Pollutes registry, potential impersonation.

**Fix:** Pattern 4 (owner authorization on state creation).

---

### ❌ 5. Checking Only Burn Quantity, Not Name

```aiken
// WRONG: any NFT under the policy satisfies the burn check
when dict.to_pairs(minted_tokens) is {
  [Pair(_, qty)] -> qty == -1  // Doesn't check WHICH token was burned
  _ -> False
}
```

**Why it's wrong:** With multiple NFTs under one policy, the wrong one can be burned during deregistration.

**Fix:** Pattern 5 (NFT identity by name).

---

### ❌ 6. Output-Index Pinning as Sole Double-Sat Defense

```aiken
// INSUFFICIENT: two inputs can specify the same output index
let output = list.at(tx.outputs, redeemer.output_index)
// Output-index pinning prevents one input from using multiple outputs,
// but does NOT prevent two inputs from sharing one output.
```

**Why it's wrong:** Provides false confidence. Two validators both pointing to output index 0 will both be satisfied by the same output.

**Fix:** Pattern 9 (single script input) combined with output-index pinning.

---

### ❌ 7. Using `expect` Where `when` Suffices

```aiken
// FRAGILE: panics with no diagnostic on unexpected input
expect Script(hash) = addr.payment_credential
// If addr is a VerificationKey address, the TX fails with a cryptic error
```

**Why it's wrong:** Panics are untestable (can't assert `== False`), uncomposable, and give no information about the failure reason.

**Fix:** Pattern 8 (graceful failure with `when`/`Option`).

---

## Pattern Composition

Real validators combine multiple patterns. Here's how they fit together in a typical NFT-gated registry contract:

### Registration (Mint Handler)

```
Pattern 4: Owner Authorization     ─┐
Pattern 3: Credential Type Guard    │── validate_output_owner()
                                   ─┘
Pattern 1: Singleton Output        ─── list.filter + [output] match
Pattern 7: Datum Shape Validation  ─── has_inline_datum + expect datum
```

**Composition:**
```aiken
pub fn validate_register(seed: OutputReference, policy_id: PolicyId, tx: Transaction) -> Bool {
  let seed_consumed = list.any(tx.inputs, fn(i) { i.output_reference == seed })
  let correct_mint = validate_singleton_mint(tx, policy_id, derive_asset_name(seed))
  let script_address = script_address_from_policy(policy_id)

  // Pattern 1: Singleton output
  let script_outputs = list.filter(tx.outputs, fn(o) { o.address == script_address })
  let valid_output =
    when script_outputs is {
      [output] ->
        and {
          has_inline_datum(output),                                    // Pattern 7
          assets.quantity_of(output.value, policy_id, expected_name) == 1,
          assets.lovelace_of(output.value) >= min_deposit,
          validate_output_owner(output, tx),                          // Pattern 3 + 4
        }
      _ -> False
    }

  seed_consumed && correct_mint && valid_output
}
```

### Update (Spend Handler)

```
Pattern 9: Single Script Input     ─── count_script_inputs == 1
Pattern 1: Singleton Output        ─── list.filter + [output] match
Pattern 5: NFT Identity by Name   ─── find_nft_name + quantity check
Pattern 3: Credential Type Guard   ─── validate_new_owner_credential
Pattern 7: Datum Shape Validation  ─── has_inline_datum
```

### Deregistration (Spend + Mint)

```
Spend side:
  Pattern 5: NFT Identity by Name  ─── burned name matches input NFT
  Owner signature check

Mint side (burn):
  Pattern 2: Burn-Spend Coupling   ─── has_script_input
```

### Defense Layers

The patterns form concentric rings of defense:

```
┌─────────────────────────────────────────────────┐
│ Pattern 9: Single Script Input                   │ ← Eliminates double-sat
│ ┌─────────────────────────────────────────────┐ │
│ │ Pattern 1: Singleton Output                  │ │ ← Eliminates ghost UTxOs
│ │ ┌─────────────────────────────────────────┐ │ │
│ │ │ Pattern 7: Datum Shape Validation        │ │ │ ← Rejects malformed state
│ │ │ ┌─────────────────────────────────────┐ │ │ │
│ │ │ │ Pattern 3: Credential Type Guard    │ │ │ │ ← Prevents permanent lock
│ │ │ │ Pattern 4: Owner Authorization      │ │ │ │ ← Prevents impersonation
│ │ │ │ Pattern 5: NFT Identity by Name     │ │ │ │ ← Prevents wrong-burn
│ │ │ └─────────────────────────────────────┘ │ │ │
│ │ └─────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────┘ │
│ Pattern 2: Burn-Spend Coupling                   │ ← Cross-validator integrity
└─────────────────────────────────────────────────┘
```

---

## Testing Patterns

### Unit Testing Strategy

Aiken's built-in test harness (`aiken check`) supports pure function testing. Structure your tests in three tiers:

#### Tier 1: Individual Pattern Tests

Test each security pattern in isolation:

```aiken
test singleton_output_rejects_ghost_utxo() {
  let tx = Transaction {
    ..placeholder,
    outputs: [valid_output, ghost_output],  // Two outputs at script address
  }
  !validate_singleton_output(tx, script_address, policy_id, name, min_deposit)
}

test singleton_output_accepts_single_valid() {
  let tx = Transaction {
    ..placeholder,
    outputs: [valid_output, unrelated_output],  // One at script, one elsewhere
  }
  validate_singleton_output(tx, script_address, policy_id, name, min_deposit)
}
```

#### Tier 2: Exploit Tests

Name tests after the attack they prevent:

```aiken
test exploit_double_satisfaction_shared_output() {
  // Two script inputs, one shared output — must reject
  let tx = build_dual_update_tx(input_a, input_b, shared_output)
  !validate_update(datum_a, ref_a, tx) || !validate_update(datum_b, ref_b, tx)
}

test exploit_orphan_burn_no_spend() {
  // Burn without any script-address inputs — must reject
  let tx = Transaction { ..placeholder, mint: burn_value, inputs: [] }
  !validate_burn(policy_id, tx)
}

test exploit_script_credential_owner() {
  // Register with Script credential as owner — must reject
  let datum = AgentDatum { owner: Script(some_hash), .. }
  let tx = build_register_tx(datum)
  !validate_register(seed, policy_id, tx)
}
```

#### Tier 3: Behavioral Tests

Document intended behavior explicitly, especially non-obvious design decisions:

```aiken
test behavior_deposit_destination_not_enforced() {
  // Owner signs deregister, deposit goes to a third party — ALLOWED by design
  let tx = build_deregister_tx(owner_signs: True, deposit_to: third_party)
  validate_deregister(datum, own_utxo, tx)
  // This is a design decision, not a bug. Document it.
}
```

### Property Testing

Use Aiken's property tests for invariants:

```aiken
test prop_singleton_always_rejects_multiple(n: Int) via some_fuzzer() {
  // For any number of outputs > 1 at script address, validation fails
  let outputs = list.repeat(valid_output, n + 2)  // Always >= 2
  let tx = Transaction { ..placeholder, outputs: outputs }
  !validate_singleton_output(tx, script_address, ...)
}
```

### Test Naming Convention

Consistent naming makes test results scannable:

| Prefix | Purpose | Example |
|--------|---------|---------|
| `test_` | Happy path | `test_register_succeeds_with_valid_inputs` |
| `exploit_` | Attack vector | `exploit_orphan_burn_no_spend` |
| `behavior_` | Design decision | `behavior_deposit_return_not_enforced` |
| `reject_` | Rejection condition | `reject_register_without_owner_sig` |
| `prop_` | Property/invariant | `prop_singleton_rejects_multiple_outputs` |

### Coverage Checklist

For each pattern you implement, verify these test categories exist:

- [ ] Happy path (pattern correctly accepts valid input)
- [ ] Rejection path (pattern correctly rejects the attack it prevents)
- [ ] Edge case (boundary values, empty lists, zero quantities)
- [ ] Composition (pattern works correctly when combined with others)
- [ ] Exploit (named after the specific attack vector)

---

*Document derived from audit findings across multiple eUTXO smart contract templates. All code examples are in Aiken v1.1.x syntax targeting Plutus V3 semantics.*
