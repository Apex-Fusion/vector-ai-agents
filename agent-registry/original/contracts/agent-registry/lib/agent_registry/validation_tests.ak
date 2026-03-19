/// Unit tests for the agent registry validation logic.
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
  derive_asset_name, has_credential_signed, has_inline_datum,
  min_deposit_lovelace, script_address_from_policy, validate_burn,
  validate_deregister, validate_register, validate_update,
}

// ──────────────────────────────────────────────────────────────────────
// Test fixtures
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

fn test_agent_datum() -> AgentDatum {
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

/// Build a Value with lovelace + one NFT.
fn make_value_with_nft(
  lovelace: Int,
  policy: ByteArray,
  name: ByteArray,
  qty: Int,
) -> assets.Value {
  assets.from_lovelace(lovelace)
    |> assets.add(policy, name, qty)
}

/// A seed UTxO input (consumed during registration).
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

/// A valid registry output with inline datum, NFT, and deposit.
fn valid_registry_output() -> Output {
  Output {
    address: test_script_address(),
    value: make_value_with_nft(
      min_deposit_lovelace,
      test_policy_id,
      test_nft_name(),
      1,
    ),
    datum: InlineDatum(test_agent_datum()),
    reference_script: None,
  }
}

const registry_tx_hash: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

fn registry_utxo_ref() -> OutputReference {
  OutputReference { transaction_id: registry_tx_hash, output_index: 0 }
}

/// A valid registry input (for spend tests).
fn registry_input() -> Input {
  Input {
    output_reference: registry_utxo_ref(),
    output: valid_registry_output(),
  }
}

// ──────────────────────────────────────────────────────────────────────
// Helper function tests
// ──────────────────────────────────────────────────────────────────────

test test_derive_asset_name_deterministic() {
  derive_asset_name(test_seed()) == derive_asset_name(test_seed())
}

test test_derive_asset_name_unique() {
  let seed2 =
    OutputReference { transaction_id: test_seed_tx_hash, output_index: 1 }
  derive_asset_name(test_seed()) != derive_asset_name(seed2)
}

test test_script_address_uses_script_credential() {
  let addr = script_address_from_policy(test_policy_id)
  addr.payment_credential == Script(test_policy_id) && addr.stake_credential == None
}

test test_has_inline_datum_true() {
  has_inline_datum(valid_registry_output())
}

test test_has_inline_datum_false() {
  let output =
    Output {
      address: test_script_address(),
      value: assets.from_lovelace(10_000_000),
      datum: NoDatum,
      reference_script: None,
    }
  !has_inline_datum(output)
}

test test_has_credential_signed_true() {
  let tx =
    Transaction { ..placeholder, extra_signatories: [test_owner_vkh] }
  has_credential_signed(tx, VerificationKey(test_owner_vkh))
}

test test_has_credential_signed_false_no_sig() {
  let tx = Transaction { ..placeholder, extra_signatories: [] }
  !has_credential_signed(tx, VerificationKey(test_owner_vkh))
}

test test_has_credential_signed_false_for_script() {
  let script_cred = Script(test_policy_id)
  let tx =
    Transaction { ..placeholder, extra_signatories: [test_owner_vkh] }
  !has_credential_signed(tx, script_cred)
}

// ──────────────────────────────────────────────────────────────────────
// Mint: Register tests
// ──────────────────────────────────────────────────────────────────────

test test_register_success() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [valid_registry_output()],
      mint: mint_value,
    }
  validate_register(test_seed(), test_policy_id, tx)
}

test test_register_fails_seed_not_consumed() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [],
      outputs: [valid_registry_output()],
      mint: mint_value,
    }
  !validate_register(test_seed(), test_policy_id, tx)
}

test test_register_fails_wrong_mint_quantity() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 2)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [valid_registry_output()],
      mint: mint_value,
    }
  !validate_register(test_seed(), test_policy_id, tx)
}

test test_register_fails_low_deposit() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 1)
  let low_deposit_output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(5_000_000, test_policy_id, nft_name, 1),
      datum: InlineDatum(test_agent_datum()),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [low_deposit_output],
      mint: mint_value,
    }
  !validate_register(test_seed(), test_policy_id, tx)
}

test test_register_fails_no_inline_datum() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 1)
  let no_datum_output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(
        min_deposit_lovelace,
        test_policy_id,
        nft_name,
        1,
      ),
      datum: NoDatum,
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [no_datum_output],
      mint: mint_value,
    }
  !validate_register(test_seed(), test_policy_id, tx)
}

test test_register_fails_wrong_address() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 1)
  let wrong_address_output =
    Output {
      address: Address {
        payment_credential: VerificationKey(test_owner_vkh),
        stake_credential: None,
      },
      value: make_value_with_nft(
        min_deposit_lovelace,
        test_policy_id,
        nft_name,
        1,
      ),
      datum: InlineDatum(test_agent_datum()),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [wrong_address_output],
      mint: mint_value,
    }
  !validate_register(test_seed(), test_policy_id, tx)
}

test test_register_fails_nft_missing_from_output() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 1)
  let no_nft_output =
    Output {
      address: test_script_address(),
      value: assets.from_lovelace(min_deposit_lovelace),
      datum: InlineDatum(test_agent_datum()),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [no_nft_output],
      mint: mint_value,
    }
  !validate_register(test_seed(), test_policy_id, tx)
}

test test_register_exact_minimum_deposit() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [valid_registry_output()],
      mint: mint_value,
    }
  validate_register(test_seed(), test_policy_id, tx)
}

test test_register_fails_one_dfm_below_minimum() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 1)
  let below_min_output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(
        min_deposit_lovelace - 1,
        test_policy_id,
        nft_name,
        1,
      ),
      datum: InlineDatum(test_agent_datum()),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [below_min_output],
      mint: mint_value,
    }
  !validate_register(test_seed(), test_policy_id, tx)
}

// ──────────────────────────────────────────────────────────────────────
// Mint: Burn tests
// ──────────────────────────────────────────────────────────────────────

test test_burn_success() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, -1)
  let tx = Transaction { ..placeholder, mint: mint_value }
  validate_burn(test_policy_id, tx)
}

test test_burn_fails_positive_quantity() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 1)
  let tx = Transaction { ..placeholder, mint: mint_value }
  !validate_burn(test_policy_id, tx)
}

test test_burn_fails_no_tokens() {
  let tx = Transaction { ..placeholder, mint: assets.zero }
  !validate_burn(test_policy_id, tx)
}

// ──────────────────────────────────────────────────────────────────────
// Spend: Update tests
// ──────────────────────────────────────────────────────────────────────

test test_update_success() {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      outputs: [valid_registry_output()],
      extra_signatories: [test_owner_vkh],
    }
  validate_update(test_agent_datum(), registry_utxo_ref(), tx)
}

test test_update_fails_no_signature() {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      outputs: [valid_registry_output()],
      extra_signatories: [],
    }
  !validate_update(test_agent_datum(), registry_utxo_ref(), tx)
}

test test_update_fails_wrong_signer() {
  let other_vkh =
    #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      outputs: [valid_registry_output()],
      extra_signatories: [other_vkh],
    }
  !validate_update(test_agent_datum(), registry_utxo_ref(), tx)
}

test test_update_fails_nft_missing_from_output() {
  let no_nft_output =
    Output {
      address: test_script_address(),
      value: assets.from_lovelace(min_deposit_lovelace),
      datum: InlineDatum(test_agent_datum()),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      outputs: [no_nft_output],
      extra_signatories: [test_owner_vkh],
    }
  !validate_update(test_agent_datum(), registry_utxo_ref(), tx)
}

test test_update_fails_low_deposit() {
  let nft_name = test_nft_name()
  let low_output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(5_000_000, test_policy_id, nft_name, 1),
      datum: InlineDatum(test_agent_datum()),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      outputs: [low_output],
      extra_signatories: [test_owner_vkh],
    }
  !validate_update(test_agent_datum(), registry_utxo_ref(), tx)
}

test test_update_allows_ownership_transfer() {
  let new_owner_vkh =
    #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  let transferred_datum =
    AgentDatum {
      ..test_agent_datum(),
      owner: VerificationKey(new_owner_vkh),
    }
  let continuing_output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(
        min_deposit_lovelace,
        test_policy_id,
        test_nft_name(),
        1,
      ),
      datum: InlineDatum(transferred_datum),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      outputs: [continuing_output],
      extra_signatories: [test_owner_vkh],
    }
  validate_update(test_agent_datum(), registry_utxo_ref(), tx)
}

// ──────────────────────────────────────────────────────────────────────
// Spend: Deregister tests
// ──────────────────────────────────────────────────────────────────────

test test_deregister_success() {
  let nft_name = test_nft_name()
  let burn_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, -1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      mint: burn_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_deregister(test_agent_datum(), registry_utxo_ref(), tx)
}

test test_deregister_fails_no_signature() {
  let nft_name = test_nft_name()
  let burn_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, -1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      mint: burn_value,
      extra_signatories: [],
    }
  !validate_deregister(test_agent_datum(), registry_utxo_ref(), tx)
}

test test_deregister_fails_no_burn() {
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      mint: assets.zero,
      extra_signatories: [test_owner_vkh],
    }
  !validate_deregister(test_agent_datum(), registry_utxo_ref(), tx)
}

test test_deregister_fails_mint_instead_of_burn() {
  let nft_name = test_nft_name()
  let mint_value =
    assets.zero
      |> assets.add(test_policy_id, nft_name, 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [registry_input()],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  !validate_deregister(test_agent_datum(), registry_utxo_ref(), tx)
}
