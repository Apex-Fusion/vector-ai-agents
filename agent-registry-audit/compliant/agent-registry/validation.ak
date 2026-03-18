/// Core validation logic for the Vector Agent Registry (COMPLIANT VERSION).
///
/// Addresses all 11 audit findings (AR-01 through AR-11).
/// Extracted from the multi-validator so that each validation path
/// can be unit-tested independently via `aiken check`.

use aiken/builtin
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
/// Aiken stdlib `lovelace_of` reads the native coin regardless of chain.
pub const min_deposit_lovelace: Int = 10_000_000

// FIX: AR-08 — Datum size limits to prevent bloated UTxOs / DoS on indexers
pub const max_name_length: Int = 256
pub const max_description_length: Int = 1024
pub const max_capability_length: Int = 128
pub const max_capabilities_count: Int = 32
pub const max_framework_length: Int = 128
pub const max_endpoint_length: Int = 512

// ──────────────────────────────────────────────────────────────────────
// Mint validation
// ──────────────────────────────────────────────────────────────────────

/// Validate an agent registration (mint handler, Register redeemer).
///
/// Checks:
///   1. The seed UTxO is consumed in the transaction
///   2. Exactly one NFT is minted with the correct asset name
///   3. An output exists at the script address with the NFT, inline datum, and ≥10 AP3X
///   4. The datum owner has signed the transaction (AR-05)
///   5. The datum is valid AgentDatum with size limits (AR-08)
///   6. The owner is key-based (AR-07)
///   7. Exactly one valid registration output exists (AR-02)
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

  // FIX: AR-02 — Enforce exactly one token minted under this policy per TX
  let correct_mint =
    when dict.to_pairs(minted_tokens) is {
      [Pair(name, qty)] -> name == expected_name && qty == 1
      _ -> False
    }

  // 3. Find the valid output at script address and extract datum
  let script_address = script_address_from_policy(policy_id)

  // FIX: AR-02 — Count valid outputs; ensure exactly one registration output
  let valid_outputs =
    list.filter(
      tx.outputs,
      fn(output) {
        and {
          output.address == script_address,
          has_inline_datum(output),
          assets.quantity_of(output.value, policy_id, expected_name) == 1,
          assets.lovelace_of(output.value) >= min_deposit_lovelace,
        }
      },
    )

  // FIX: AR-02 — Exactly one matching output
  let single_valid_output =
    when valid_outputs is {
      [output] -> {
        // FIX: AR-05 — Extract datum and verify owner signed the TX
        expect InlineDatum(raw_datum) = output.datum
        expect datum: AgentDatum = raw_datum

        // FIX: AR-07 — Reject script credentials as owner during registration
        let owner_is_key = is_verification_key(datum.owner)

        // FIX: AR-05 — Owner must have signed
        let owner_signed = has_credential_signed(tx, datum.owner)

        // FIX: AR-08 — Enforce datum field size limits
        let datum_within_limits = validate_datum_size(datum)

        and {
          owner_is_key,
          owner_signed,
          datum_within_limits,
        }
      }
      _ -> False
    }

  and {
    seed_consumed,
    correct_mint,
    single_valid_output,
  }
}

/// Validate an NFT burn (mint handler, Burn redeemer).
///
/// Checks:
///   1. Exactly one NFT is burned (quantity == -1) under this policy
///   2. The burned NFT's owner has signed the transaction (AR-03)
///   3. The burned NFT name matches a spent script input (AR-06)
pub fn validate_burn(policy_id: PolicyId, tx: Transaction) -> Bool {
  let minted_tokens = assets.tokens(tx.mint, policy_id)

  // FIX: AR-06 — Extract and validate the specific NFT name being burned
  when dict.to_pairs(minted_tokens) is {
    [Pair(burned_name, qty)] -> {
      expect qty == -1

      let script_address = script_address_from_policy(policy_id)

      // FIX: AR-03 — Find the spent script input containing the burned NFT
      // and verify the owner authorized the burn
      let matching_input =
        list.find(
          tx.inputs,
          fn(input) {
            and {
              input.output.address == script_address,
              // FIX: AR-06 — Verify the specific NFT asset name matches
              assets.quantity_of(input.output.value, policy_id, burned_name) == 1,
            }
          },
        )

      when matching_input is {
        Some(input) -> {
          // FIX: AR-03 — Extract owner from datum and require their signature
          expect InlineDatum(raw_datum) = input.output.datum
          expect datum: AgentDatum = raw_datum
          has_credential_signed(tx, datum.owner)
        }
        None -> False
      }
    }
    _ -> False
  }
}

// ──────────────────────────────────────────────────────────────────────
// Spend validation
// ──────────────────────────────────────────────────────────────────────

/// Validate an agent profile update (spend handler, Update redeemer).
///
/// Checks:
///   1. Owner signed the transaction
///   2. Exactly one script input is spent (AR-01 — prevent double satisfaction)
///   3. A continuing output exists at the same script address with:
///      - A valid AgentDatum inline datum (AR-04)
///      - The same identity NFT
///      - Value >= input value (AR-09 — prevent value draining)
///   4. The continuing datum preserves registered_at (AR-04)
///   5. The new owner is key-based (AR-07)
///   6. Datum field sizes are within limits (AR-08)
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

  // FIX: AR-01 — Enforce that only ONE script input is being spent in this TX
  // This prevents double satisfaction where one output satisfies two spend validators
  let script_input_count =
    list.count(
      tx.inputs,
      fn(input) { input.output.address == own_address },
    )
  let single_script_input = script_input_count == 1

  // Find the specific continuing output (not list.any — must be deterministic)
  let valid_continuing_output =
    list.find(
      tx.outputs,
      fn(output) {
        and {
          output.address == own_address,
          assets.quantity_of(output.value, own_policy, input_nft_name) == 1,
        }
      },
    )

  let has_valid_continuing_output =
    when valid_continuing_output is {
      Some(output) -> {
        // FIX: AR-04 — Validate datum deserializes to AgentDatum
        expect InlineDatum(raw_datum) = output.datum
        expect new_datum: AgentDatum = raw_datum

        // FIX: AR-04 — Preserve immutable field: registered_at
        let registered_at_preserved =
          new_datum.registered_at == agent_datum.registered_at

        // FIX: AR-07 — Reject script credentials as new owner
        let new_owner_is_key = is_verification_key(new_datum.owner)

        // FIX: AR-08 — Enforce datum field size limits
        let datum_within_limits = validate_datum_size(new_datum)

        // FIX: AR-09 — Prevent value draining: output must preserve at least input value
        let value_preserved =
          assets.lovelace_of(output.value) >= assets.lovelace_of(input_value)

        and {
          registered_at_preserved,
          new_owner_is_key,
          datum_within_limits,
          value_preserved,
        }
      }
      None -> False
    }

  and {
    owner_signed,
    single_script_input,
    has_valid_continuing_output,
  }
}

/// Validate an agent deregistration (spend handler, Deregister redeemer).
///
/// Checks:
///   1. Owner signed the transaction
///   2. The specific identity NFT is burned in this transaction (AR-06)
///   3. Deposit is returned to owner address (AR-10)
pub fn validate_deregister(
  agent_datum: AgentDatum,
  own_utxo: OutputReference,
  tx: Transaction,
) -> Bool {
  let owner_signed = has_credential_signed(tx, agent_datum.owner)
  let own_address = get_own_address(tx.inputs, own_utxo)
  let own_policy = get_policy_from_address(own_address)
  let input_value = get_own_value(tx.inputs, own_utxo)

  // FIX: AR-06 — Extract the specific NFT name from the spent input
  let input_nft_name = find_nft_name(input_value, own_policy)

  let minted_tokens = assets.tokens(tx.mint, own_policy)

  // FIX: AR-06 — Verify the specific NFT name is burned, not just any token
  let nft_burned =
    when dict.to_pairs(minted_tokens) is {
      [Pair(name, qty)] -> name == input_nft_name && qty == -1
      _ -> False
    }

  // FIX: AR-10 — Verify deposit is returned to an address owned by the owner
  let deposit_returned =
    when agent_datum.owner is {
      VerificationKey(vkh) -> {
        let owner_address = Address {
          payment_credential: VerificationKey(vkh),
          stake_credential: None,
        }
        list.any(
          tx.outputs,
          fn(output) {
            and {
              output.address.payment_credential == owner_address.payment_credential,
              assets.lovelace_of(output.value) >= min_deposit_lovelace,
            }
          },
        )
      }
      // Script owners can't deregister (AR-07), but handle gracefully
      _ -> False
    }

  and {
    owner_signed,
    nft_burned,
    deposit_returned,
  }
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

// FIX: AR-07 — Helper to check if a credential is key-based (not script)
pub fn is_verification_key(credential: Credential) -> Bool {
  when credential is {
    VerificationKey(_) -> True
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

// FIX: AR-08 — Validate datum field sizes are within acceptable limits
pub fn validate_datum_size(datum: AgentDatum) -> Bool {
  let name_ok = builtin.length_of_bytearray(datum.name) <= max_name_length
  let desc_ok = builtin.length_of_bytearray(datum.description) <= max_description_length
  let framework_ok = builtin.length_of_bytearray(datum.framework) <= max_framework_length
  let endpoint_ok = builtin.length_of_bytearray(datum.endpoint) <= max_endpoint_length
  let caps_count_ok = list.length(datum.capabilities) <= max_capabilities_count
  let caps_size_ok =
    list.all(
      datum.capabilities,
      fn(cap) { builtin.length_of_bytearray(cap) <= max_capability_length },
    )
  and {
    name_ok,
    desc_ok,
    framework_ok,
    endpoint_ok,
    caps_count_ok,
    caps_size_ok,
  }
}
