/// Core validation logic for the Vector Agent Registry.
///
/// Extracted from the multi-validator so that each validation path
/// can be unit-tested independently via `aiken check`.
///
/// [SECURITY] Security-hardened version. All fixes documented inline.

use aiken/cbor
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use cardano/address.{Address, Credential, Script, VerificationKey}
use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction}
use agent_registry/types.{AgentDatum}

// ──────────────────────────────────────────────────────────────────────
// Configuration
// ──────────────────────────────────────────────────────────────────────

/// Minimum AP3X deposit: 10 AP3X = 10_000_000 DFM.
pub const min_deposit_lovelace: Int = 10_000_000

// ──────────────────────────────────────────────────────────────────────
// Mint validation
// ──────────────────────────────────────────────────────────────────────

/// Validate an agent registration (mint handler, Register redeemer).
///
/// Checks:
///   1. The seed UTxO is consumed in the transaction
///   2. Exactly one NFT is minted with the correct asset name
///   3. An output exists at the script address with the NFT, inline datum, and ≥10 AP3X
///   4. [FIX] Owner must have signed the transaction (AR-NO-OWNER-AUTH)
///   5. [FIX] Owner credential must be VerificationKey, not Script (AR-SCRIPT-OWNER)
///   6. [FIX] Exactly one output at script address (AR-GHOST-UTXO)
pub fn validate_register(
  seed: OutputReference,
  policy_id: PolicyId,
  tx: Transaction,
) -> Bool {
  // 1. Seed UTxO must be consumed
  let seed_consumed =
    list.any(tx.inputs, fn(input) { input.output_reference == seed })

  // 2. Derive the expected asset name and check mint field
  let expected_name = derive_asset_name(seed)
  let minted_tokens = assets.tokens(tx.mint, policy_id)
  let correct_mint =
    when dict.to_pairs(minted_tokens) is {
      [Pair(name, qty)] -> name == expected_name && qty == 1
      _ -> False
    }

  // 3. Valid output at script address
  let script_address = script_address_from_policy(policy_id)

  // [FIX] Collect ALL outputs at script address — must be exactly one
  let script_outputs =
    list.filter(tx.outputs, fn(output) { output.address == script_address })

  let valid_output =
    when script_outputs is {
      [output] ->
        and {
          has_inline_datum(output),
          assets.quantity_of(output.value, policy_id, expected_name) == 1,
          assets.lovelace_of(output.value) >= min_deposit_lovelace,
          // [FIX] Extract datum and validate owner
          validate_output_owner(output, tx),
        }
      _ -> False
    }

  and {
    seed_consumed,
    correct_mint,
    valid_output,
  }
}

/// [FIX] Helper: extract AgentDatum from output, validate owner is VK and signed.
/// Used by validate_register to enforce owner signature and credential type.
fn validate_output_owner(output: Output, tx: Transaction) -> Bool {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: AgentDatum = raw_datum
  // Owner must be a VerificationKey credential (not Script)
  when datum.owner is {
    VerificationKey(_) -> has_credential_signed(tx, datum.owner)
    Script(_) -> False
  }
}

/// Validate an NFT burn (mint handler, Burn redeemer).
///
/// Checks:
///   1. Exactly one NFT is burned (quantity == -1) under this policy.
///   2. [FIX] A corresponding agent UTxO at the script address is being
///      spent in this transaction (AR-ORPHAN-BURN). This couples burn to deregister.
pub fn validate_burn(policy_id: PolicyId, tx: Transaction) -> Bool {
  let minted_tokens = assets.tokens(tx.mint, policy_id)
  let burn_check =
    when dict.to_pairs(minted_tokens) is {
      [Pair(_, qty)] -> qty == -1
      _ -> False
    }

  // [FIX] Verify that at least one input is at the script address
  // (i.e., an agent UTxO is being spent — coupling burn to deregister)
  let has_script_input =
    list.any(
      tx.inputs,
      fn(input) {
        input.output.address.payment_credential == Script(policy_id)
      },
    )

  burn_check && has_script_input
}

// ──────────────────────────────────────────────────────────────────────
// Spend validation
// ──────────────────────────────────────────────────────────────────────

/// Validate an agent profile update (spend handler, Update redeemer).
///
/// Checks:
///   1. Owner signed the transaction
///   2. [FIX] Exactly one output at script address (AR-GHOST-UTXO, AR-DOUBLE-SAT)
///   3. That single output has: inline datum, same NFT, ≥10 AP3X deposit
///   4. [FIX] New owner must be VerificationKey (AR-TRANSFER-LOCK)
pub fn validate_update(
  agent_datum: AgentDatum,
  own_utxo: OutputReference,
  tx: Transaction,
) -> Bool {
  let owner_signed = has_credential_signed(tx, agent_datum.owner)
  let own_address = get_own_address(tx.inputs, own_utxo)
  let own_policy = get_policy_from_address(own_address)
  let input_value = get_own_value(tx.inputs, own_utxo)
  let input_nft_name = find_nft_name(input_value, own_policy)

  // [FIX] Instead of list.any, collect all outputs at script address.
  // Require exactly one — prevents double satisfaction and ghost UTxOs.
  let script_outputs =
    list.filter(tx.outputs, fn(output) { output.address == own_address })

  let has_valid_continuing_output =
    when script_outputs is {
      [output] ->
        and {
          has_inline_datum(output),
          assets.quantity_of(output.value, own_policy, input_nft_name) == 1,
          assets.lovelace_of(output.value) >= min_deposit_lovelace,
          // [FIX] Validate new owner credential type
          validate_new_owner_credential(output),
        }
      _ -> False
    }

  owner_signed && has_valid_continuing_output
}

/// [FIX] Helper: validate that the new datum's owner is a VerificationKey.
/// Prevents ownership transfer to Script credentials (permanently locking UTxO).
fn validate_new_owner_credential(output: Output) -> Bool {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: AgentDatum = raw_datum
  when datum.owner is {
    VerificationKey(_) -> True
    Script(_) -> False
  }
}

/// Validate an agent deregistration (spend handler, Deregister redeemer).
///
/// Checks:
///   1. Owner signed the transaction
///   2. The identity NFT is burned in this transaction
///   3. [FIX] The burned NFT name matches the one in this UTxO (AR-NFT-NAME-MISMATCH)
pub fn validate_deregister(
  agent_datum: AgentDatum,
  own_utxo: OutputReference,
  tx: Transaction,
) -> Bool {
  let owner_signed = has_credential_signed(tx, agent_datum.owner)
  let own_address = get_own_address(tx.inputs, own_utxo)
  let own_policy = get_policy_from_address(own_address)

  // [FIX] Extract the specific NFT name from the input UTxO
  let input_value = get_own_value(tx.inputs, own_utxo)
  let input_nft_name = find_nft_name(input_value, own_policy)

  // [FIX] Verify the burned token matches the input's NFT name
  let minted_tokens = assets.tokens(tx.mint, own_policy)
  let nft_burned =
    when dict.to_pairs(minted_tokens) is {
      [Pair(name, qty)] -> name == input_nft_name && qty == -1
      _ -> False
    }

  owner_signed && nft_burned
}

// ──────────────────────────────────────────────────────────────────────
// Helper functions (public for testing)
// ──────────────────────────────────────────────────────────────────────

/// Derive a unique NFT asset name from a seed UTxO reference.
pub fn derive_asset_name(seed: OutputReference) -> ByteArray {
  crypto.blake2b_256(cbor.serialise(seed))
}

/// Construct the script address from the policy ID.
pub fn script_address_from_policy(policy_id: PolicyId) -> Address {
  Address {
    payment_credential: Script(policy_id),
    stake_credential: None,
  }
}

/// Check if a credential has signed the transaction (key-based only).
pub fn has_credential_signed(tx: Transaction, credential: Credential) -> Bool {
  when credential is {
    VerificationKey(vkh) ->
      list.any(tx.extra_signatories, fn(s) { s == vkh })
    _ -> False
  }
}

/// Find the address of a specific UTxO in the transaction inputs.
pub fn get_own_address(
  inputs: List<Input>,
  own_ref: OutputReference,
) -> Address {
  expect Some(input) =
    list.find(inputs, fn(input) { input.output_reference == own_ref })
  input.output.address
}

/// Get the value of a specific UTxO in the transaction inputs.
pub fn get_own_value(
  inputs: List<Input>,
  own_ref: OutputReference,
) -> assets.Value {
  expect Some(input) =
    list.find(inputs, fn(input) { input.output_reference == own_ref })
  input.output.value
}

/// Extract the script hash (policy ID) from a script address.
pub fn get_policy_from_address(addr: Address) -> PolicyId {
  expect Script(hash) = addr.payment_credential
  hash
}

/// Find the NFT asset name for our policy in a given value.
pub fn find_nft_name(value: assets.Value, policy_id: PolicyId) -> ByteArray {
  let tokens = assets.tokens(value, policy_id)
  expect [Pair(name, 1)] = dict.to_pairs(tokens)
  name
}

/// Check that an output has an inline datum.
pub fn has_inline_datum(output: Output) -> Bool {
  when output.datum is {
    InlineDatum(_) -> True
    _ -> False
  }
}
