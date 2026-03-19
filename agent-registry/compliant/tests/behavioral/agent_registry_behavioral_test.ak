/// Behavioral test suite for the Vector Agent Registry.
///
/// These tests document what the contract IS DESIGNED to do.
/// All tests PASS on the original contract.
/// All tests should ALSO PASS on the compliant version (security fixes
/// must not break intended functionality).
///
/// Run with: aiken check

use cardano/address.{Address, Script, VerificationKey}
use cardano/assets
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
  placeholder,
}
use agent_registry/types.{AgentDatum}
use agent_registry/validation.{
  derive_asset_name, has_credential_signed,
  min_deposit_lovelace, script_address_from_policy, validate_burn,
  validate_deregister, validate_register, validate_update,
}

// ──────────────────────────────────────────────────────────────────────
// Shared fixtures (mirrors validation_tests.ak pattern)
// ──────────────────────────────────────────────────────────────────────

const test_policy_id: ByteArray =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const test_owner_vkh: ByteArray =
  #"1122334455667788112233445566778811223344556677881122334455667788"

const test_seed_tx_hash: ByteArray =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

fn test_seed() -> OutputReference {
  OutputReference { transaction_id: test_seed_tx_hash, output_index: 0 }
}

fn test_nft_name() -> ByteArray {
  derive_asset_name(test_seed())
}

fn test_script_address() -> Address {
  script_address_from_policy(test_policy_id)
}

fn make_value_with_nft(
  lovelace: Int,
  policy: ByteArray,
  name: ByteArray,
  qty: Int,
) -> assets.Value {
  assets.from_lovelace(lovelace)
    |> assets.add(policy, name, qty)
}

fn seed_input() -> Input {
  Input {
    output_reference: test_seed(),
    output: Output {
      address: Address {
        payment_credential: VerificationKey(test_owner_vkh),
        stake_credential: None,
      },
      value: assets.from_lovelace(20_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn valid_registry_output() -> Output {
  Output {
    address: test_script_address(),
    value: make_value_with_nft(min_deposit_lovelace, test_policy_id, test_nft_name(), 1),
    datum: InlineDatum(base_agent_datum()),
    reference_script: None,
  }
}

fn base_agent_datum() -> AgentDatum {
  AgentDatum {
    owner: VerificationKey(test_owner_vkh),
    name: "TestBot",
    description: "A test agent",
    capabilities: ["testing"],
    framework: "Aiken",
    endpoint: "https://example.com",
    registered_at: 1710000000,
  }
}

const registry_tx_hash: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

fn registry_utxo_ref() -> OutputReference {
  OutputReference { transaction_id: registry_tx_hash, output_index: 0 }
}

fn registry_input() -> Input {
  Input {
    output_reference: registry_utxo_ref(),
    output: valid_registry_output(),
  }
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Datum field validation (contract accepts any values)
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: The contract does not enforce non-empty agent name.
/// An empty name bytearray is accepted on-chain.
/// Design note: datum content validation is intentionally off-chain (D6/D7).
test behavior_register_with_empty_name() {
  let datum =
    AgentDatum { ..base_agent_datum(), name: "" }
  let output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(min_deposit_lovelace, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(datum),
      reference_script: None,
    }
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [output],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_register(test_seed(), test_policy_id, tx)
}

/// BEHAVIOR: The contract does not enforce non-empty endpoint URL.
/// An empty endpoint bytearray is accepted on-chain.
test behavior_register_with_empty_endpoint() {
  let datum =
    AgentDatum { ..base_agent_datum(), endpoint: "" }
  let output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(min_deposit_lovelace, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(datum),
      reference_script: None,
    }
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [output],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_register(test_seed(), test_policy_id, tx)
}

/// BEHAVIOR: The contract does not enforce non-empty capabilities list.
/// An empty capabilities list is accepted on-chain.
test behavior_register_with_empty_capabilities() {
  let datum =
    AgentDatum { ..base_agent_datum(), capabilities: [] }
  let output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(min_deposit_lovelace, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(datum),
      reference_script: None,
    }
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [output],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_register(test_seed(), test_policy_id, tx)
}

/// BEHAVIOR: The contract does not validate registered_at as a real timestamp.
/// A value of 0 is accepted on-chain.
test behavior_register_with_zero_registered_at() {
  let datum =
    AgentDatum { ..base_agent_datum(), registered_at: 0 }
  let output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(min_deposit_lovelace, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(datum),
      reference_script: None,
    }
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [output],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_register(test_seed(), test_policy_id, tx)
}

/// BEHAVIOR: The contract does not validate registered_at as a positive value.
/// A negative timestamp is accepted on-chain.
test behavior_register_with_negative_registered_at() {
  let datum =
    AgentDatum { ..base_agent_datum(), registered_at: -1 }
  let output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(min_deposit_lovelace, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(datum),
      reference_script: None,
    }
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [output],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_register(test_seed(), test_policy_id, tx)
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Deposit amounts
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Deposits above the minimum are accepted.
/// The contract enforces a floor, not a ceiling.
test behavior_register_accepts_large_deposit() {
  let large_deposit = min_deposit_lovelace * 10
  let output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(large_deposit, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(base_agent_datum()),
      reference_script: None,
    }
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [output],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_register(test_seed(), test_policy_id, tx)
}

/// BEHAVIOR: Update accepts a larger deposit than the original.
/// Owners may top up their deposit voluntarily.
test behavior_update_accepts_increased_deposit() {
  let larger_output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(min_deposit_lovelace * 2, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(base_agent_datum()),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      outputs: [larger_output],
      extra_signatories: [test_owner_vkh],
    }
  validate_update(base_agent_datum(), registry_utxo_ref(), tx)
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Ownership transfer (Design Decision D7)
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Update allows transferring ownership to a different key credential.
/// The current owner signs, and the datum.owner field can be changed (D7).
/// This is an intentional design decision, not a vulnerability.
test behavior_update_allows_key_to_key_ownership_transfer() {
  let new_owner_vkh =
    #"9999999999999999999999999999999999999999999999999999999999999999"
  let new_datum =
    AgentDatum { ..base_agent_datum(), owner: VerificationKey(new_owner_vkh) }
  let continuing_output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(min_deposit_lovelace, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(new_datum),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      outputs: [continuing_output],
      extra_signatories: [test_owner_vkh],
    }
  // Original owner signs; new owner is a different key credential
  validate_update(base_agent_datum(), registry_utxo_ref(), tx)
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Burn behavior
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: validate_burn requires a script input (agent UTxO being spent).
/// The compliant burn couples NFT destruction to the spend validator,
/// preventing orphan burns where the NFT is destroyed but the UTxO remains locked.
test behavior_burn_requires_script_input() {
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), -1)
  let script_input =
    Input {
      output_reference: registry_utxo_ref(),
      output: Output {
        address: test_script_address(),
        value: make_value_with_nft(min_deposit_lovelace, test_policy_id, test_nft_name(), 1),
        datum: InlineDatum(base_agent_datum()),
        reference_script: None,
      },
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [script_input],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_burn(test_policy_id, tx)
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Deregister — deposit destination not enforced
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Deregister does not enforce where the deposit lovelace is sent.
/// The validator only checks owner signature and NFT burn.
/// The deposit can go to any address — including an attacker's.
/// Note: This is only possible if the owner signs (so it's authorized), but
/// a malicious SDK or confused user could construct such a transaction.
test behavior_deregister_deposit_destination_not_enforced() {
  let attacker_vkh =
    #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  let attacker_address =
    Address {
      payment_credential: VerificationKey(attacker_vkh),
      stake_credential: None,
    }
  // Deposit goes to attacker, not owner
  let attacker_output =
    Output {
      address: attacker_address,
      value: assets.from_lovelace(min_deposit_lovelace),
      datum: NoDatum,
      reference_script: None,
    }
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), -1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      outputs: [attacker_output],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_deregister(base_agent_datum(), registry_utxo_ref(), tx)
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Multiple capabilities tags
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: The contract accepts any number of capability tags.
test behavior_register_with_many_capabilities() {
  let datum =
    AgentDatum {
      ..base_agent_datum(),
      capabilities: ["research", "trading", "vision", "text", "code", "audio"],
    }
  let output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(min_deposit_lovelace, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(datum),
      reference_script: None,
    }
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [output],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_register(test_seed(), test_policy_id, tx)
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: NFT asset name properties
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Different seed tx hashes produce different NFT names.
test behavior_different_tx_hashes_produce_different_nft_names() {
  let seed_a =
    OutputReference {
      transaction_id: #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      output_index: 0,
    }
  let seed_b =
    OutputReference {
      transaction_id: #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      output_index: 0,
    }
  derive_asset_name(seed_a) != derive_asset_name(seed_b)
}

/// BEHAVIOR: Different output indices produce different NFT names.
test behavior_different_output_indices_produce_different_nft_names() {
  let seed_0 =
    OutputReference { transaction_id: test_seed_tx_hash, output_index: 0 }
  let seed_1 =
    OutputReference { transaction_id: test_seed_tx_hash, output_index: 1 }
  let seed_2 =
    OutputReference { transaction_id: test_seed_tx_hash, output_index: 2 }
  and {
    derive_asset_name(seed_0) != derive_asset_name(seed_1),
    derive_asset_name(seed_1) != derive_asset_name(seed_2),
    derive_asset_name(seed_0) != derive_asset_name(seed_2),
  }
}

/// BEHAVIOR: has_credential_signed always returns False for script credentials.
/// This is by design (D4) — script-based ownership is not supported.
test behavior_script_credential_never_signs() {
  let script_cred = Script(test_policy_id)
  let tx_with_any_signatories =
    Transaction {
      ..placeholder,
      extra_signatories: [
        test_owner_vkh,
        #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      ],
    }
  // Even with signatories present, script credential always returns False
  !has_credential_signed(tx_with_any_signatories, script_cred)
}
