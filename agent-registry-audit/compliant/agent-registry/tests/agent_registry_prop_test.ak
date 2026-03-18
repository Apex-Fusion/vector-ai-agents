/// # Agent Registry — Property-Based Tests
///
/// Property tests verifying invariants that must hold for ALL inputs:
///   - Valid registrations always succeed
///   - Unauthorized operations always fail
///   - NFT counts are always correct
///   - Value is always preserved (or not — documenting AR-09)
///
/// These tests use parameterized helpers to sweep across different
/// configurations and verify properties hold universally.
///
/// Authored by: the test writer (Vector Security Audit Team)
/// Date: 2026-03-18

use cardano/address.{Address, Script, VerificationKey}
use cardano/assets
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
  placeholder,
}
use agent_registry/types.{AgentDatum}
use agent_registry/validation.{
  derive_asset_name, has_credential_signed, min_deposit_lovelace,
  script_address_from_policy, validate_burn, validate_deregister,
  validate_register, validate_update,
}

// ──────────────────────────────────────────────────────────────────────
// Constants
// ──────────────────────────────────────────────────────────────────────

const policy_id: ByteArray =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const owner_vkh: ByteArray =
  #"1122334455667788112233445566778811223344556677881122334455667788"

const other_vkh: ByteArray =
  #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

const attacker_vkh: ByteArray =
  #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

const third_vkh: ByteArray =
  #"abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"

const seed_hash_1: ByteArray =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

const seed_hash_2: ByteArray =
  #"cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe"

const seed_hash_3: ByteArray =
  #"0123456701234567012345670123456701234567012345670123456701234567"

const reg_tx_hash: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

// ──────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────

fn script_addr() -> Address {
  script_address_from_policy(policy_id)
}

fn make_datum(vkh: ByteArray) -> AgentDatum {
  AgentDatum {
    owner: VerificationKey(vkh),
    name: "Agent",
    description: "Test",
    capabilities: [],
    framework: "Aiken",
    endpoint: "https://test.com",
    registered_at: 1710000000,
  }
}

fn make_seed(hash: ByteArray, idx: Int) -> OutputReference {
  OutputReference { transaction_id: hash, output_index: idx }
}

fn make_seed_input(hash: ByteArray, idx: Int) -> Input {
  Input {
    output_reference: make_seed(hash, idx),
    output: Output {
      address: Address {
        payment_credential: VerificationKey(owner_vkh),
        stake_credential: None,
      },
      value: assets.from_lovelace(20_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn make_reg_ref(idx: Int) -> OutputReference {
  OutputReference { transaction_id: reg_tx_hash, output_index: idx }
}

fn make_registry_input(
  idx: Int,
  vkh: ByteArray,
  nft_name: ByteArray,
  lovelace: Int,
) -> Input {
  Input {
    output_reference: make_reg_ref(idx),
    output: Output {
      address: script_addr(),
      value: assets.from_lovelace(lovelace)
        |> assets.add(policy_id, nft_name, 1),
      datum: InlineDatum(make_datum(vkh)),
      reference_script: None,
    },
  }
}

fn make_nft_value(
  lovelace: Int,
  nft_name: ByteArray,
) -> assets.Value {
  assets.from_lovelace(lovelace)
    |> assets.add(policy_id, nft_name, 1)
}

// ══════════════════════════════════════════════════════════════════════
// PROPERTY 1: Valid registrations always succeed
//
// For ANY valid seed, if all conditions are met (seed consumed,
// correct mint, valid output), registration must pass.
// Covers: AR-02 (incidental safety), AR-05 (no signer check)
// ══════════════════════════════════════════════════════════════════════

/// Property: registration succeeds for different seed indices
test prop_register_any_seed_index_0() {
  let seed = make_seed(seed_hash_1, 0)
  let name = derive_asset_name(seed)
  let mint = assets.zero |> assets.add(policy_id, name, 1)
  let output =
    Output {
      address: script_addr(),
      value: make_nft_value(min_deposit_lovelace, name),
      datum: InlineDatum(make_datum(owner_vkh)),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [make_seed_input(seed_hash_1, 0)],
      outputs: [output],
      mint: mint,
    }
  validate_register(seed, policy_id, tx)
}

test prop_register_any_seed_index_1() {
  let seed = make_seed(seed_hash_1, 1)
  let name = derive_asset_name(seed)
  let mint = assets.zero |> assets.add(policy_id, name, 1)
  let output =
    Output {
      address: script_addr(),
      value: make_nft_value(min_deposit_lovelace, name),
      datum: InlineDatum(make_datum(owner_vkh)),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [
        Input {
          output_reference: seed,
          output: Output {
            address: Address {
              payment_credential: VerificationKey(owner_vkh),
              stake_credential: None,
            },
            value: assets.from_lovelace(20_000_000),
            datum: NoDatum,
            reference_script: None,
          },
        },
      ],
      outputs: [output],
      mint: mint,
    }
  validate_register(seed, policy_id, tx)
}

test prop_register_any_seed_index_42() {
  let seed = make_seed(seed_hash_2, 42)
  let name = derive_asset_name(seed)
  let mint = assets.zero |> assets.add(policy_id, name, 1)
  let output =
    Output {
      address: script_addr(),
      value: make_nft_value(min_deposit_lovelace, name),
      datum: InlineDatum(make_datum(owner_vkh)),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [
        Input {
          output_reference: seed,
          output: Output {
            address: Address {
              payment_credential: VerificationKey(owner_vkh),
              stake_credential: None,
            },
            value: assets.from_lovelace(20_000_000),
            datum: NoDatum,
            reference_script: None,
          },
        },
      ],
      outputs: [output],
      mint: mint,
    }
  validate_register(seed, policy_id, tx)
}

/// Property: different seeds produce different NFT names (collision resistance)
test prop_different_seeds_different_names() {
  let s1 = make_seed(seed_hash_1, 0)
  let s2 = make_seed(seed_hash_1, 1)
  let s3 = make_seed(seed_hash_2, 0)
  let s4 = make_seed(seed_hash_3, 0)
  let n1 = derive_asset_name(s1)
  let n2 = derive_asset_name(s2)
  let n3 = derive_asset_name(s3)
  let n4 = derive_asset_name(s4)
  and {
    n1 != n2,
    n1 != n3,
    n1 != n4,
    n2 != n3,
    n2 != n4,
    n3 != n4,
  }
}

/// Property: registration succeeds for any deposit ≥ minimum
/// AR-08: no upper bound on deposit
test prop_register_any_deposit_above_min() {
  let seed = make_seed(seed_hash_1, 0)
  let name = derive_asset_name(seed)
  let mint = assets.zero |> assets.add(policy_id, name, 1)

  // Test with exactly min, 2x min, and 100x min
  let deposits = [min_deposit_lovelace, 20_000_000, 1_000_000_000]

  let check = fn(lovelace) {
    let output =
      Output {
        address: script_addr(),
        value: make_nft_value(lovelace, name),
        datum: InlineDatum(make_datum(owner_vkh)),
        reference_script: None,
      }
    let tx =
      Transaction {
        ..placeholder,
        inputs: [make_seed_input(seed_hash_1, 0)],
        outputs: [output],
        mint: mint,
      }
    validate_register(seed, policy_id, tx)
  }

  and {
    check(min_deposit_lovelace),
    check(20_000_000),
    check(1_000_000_000),
  }
}

// ══════════════════════════════════════════════════════════════════════
// PROPERTY 2: Unauthorized operations always fail
//
// For ANY credential that is NOT the owner, Update and Deregister
// must ALWAYS fail. Covers: AR-03, AR-07
// ══════════════════════════════════════════════════════════════════════

/// Property: update fails for any non-owner signer
/// Tests multiple wrong signers — none should pass
test prop_update_unauthorized_always_fails() {
  let wrong_signers = [other_vkh, attacker_vkh, third_vkh]

  let check_fails = fn(signer) {
    let tx =
      Transaction {
        ..placeholder,
        inputs: [
          make_registry_input(0, owner_vkh, derive_asset_name(make_seed(seed_hash_1, 0)), min_deposit_lovelace),
        ],
        outputs: [
          Output {
            address: script_addr(),
            value: make_nft_value(min_deposit_lovelace, derive_asset_name(make_seed(seed_hash_1, 0))),
            datum: InlineDatum(make_datum(owner_vkh)),
            reference_script: None,
          },
        ],
        extra_signatories: [signer],
      }
    !validate_update(make_datum(owner_vkh), make_reg_ref(0), tx)
  }

  and {
    check_fails(other_vkh),
    check_fails(attacker_vkh),
    check_fails(third_vkh),
  }
}

/// Property: deregister fails for any non-owner signer
test prop_deregister_unauthorized_always_fails() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let burn = assets.zero |> assets.add(policy_id, nft_name, -1)

  let check_fails = fn(signer) {
    let tx =
      Transaction {
        ..placeholder,
        inputs: [make_registry_input(0, owner_vkh, nft_name, min_deposit_lovelace)],
        mint: burn,
        extra_signatories: [signer],
      }
    !validate_deregister(make_datum(owner_vkh), make_reg_ref(0), tx)
  }

  and {
    check_fails(other_vkh),
    check_fails(attacker_vkh),
    check_fails(third_vkh),
  }
}

/// Property: update with empty signatories always fails
/// AR-03: this covers the case where no authorization at all is provided
test prop_update_no_signatories_always_fails() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let tx =
    Transaction {
      ..placeholder,
      inputs: [make_registry_input(0, owner_vkh, nft_name, min_deposit_lovelace)],
      outputs: [
        Output {
          address: script_addr(),
          value: make_nft_value(min_deposit_lovelace, nft_name),
          datum: InlineDatum(make_datum(owner_vkh)),
          reference_script: None,
        },
      ],
      extra_signatories: [],
    }
  !validate_update(make_datum(owner_vkh), make_reg_ref(0), tx)
}

/// AR-07: Property: Script credentials always fail authorization
test prop_script_credential_always_fails_auth() {
  let script_cred = Script(policy_id)
  let tx1 = Transaction { ..placeholder, extra_signatories: [] }
  let tx2 = Transaction { ..placeholder, extra_signatories: [owner_vkh] }
  let tx3 =
    Transaction {
      ..placeholder,
      extra_signatories: [owner_vkh, other_vkh, attacker_vkh],
    }
  and {
    !has_credential_signed(tx1, script_cred),
    !has_credential_signed(tx2, script_cred),
    !has_credential_signed(tx3, script_cred),
  }
}

// ══════════════════════════════════════════════════════════════════════
// PROPERTY 3: NFT counts are always correct
//
// Register must mint exactly 1. Burn must burn exactly 1.
// Any other quantity must be rejected.
// Covers: AR-02, AR-06
// ══════════════════════════════════════════════════════════════════════

/// Property: only qty==1 passes register mint check
test prop_register_only_qty_1_passes() {
  let seed = make_seed(seed_hash_1, 0)
  let name = derive_asset_name(seed)

  let check_qty = fn(qty) {
    let mint = assets.zero |> assets.add(policy_id, name, qty)
    let output =
      Output {
        address: script_addr(),
        value: make_nft_value(min_deposit_lovelace, name),
        datum: InlineDatum(make_datum(owner_vkh)),
        reference_script: None,
      }
    let tx =
      Transaction {
        ..placeholder,
        inputs: [make_seed_input(seed_hash_1, 0)],
        outputs: [output],
        mint: mint,
      }
    validate_register(seed, policy_id, tx)
  }

  and {
    check_qty(1),
    !check_qty(2),
    !check_qty(5),
    !check_qty(-1),
  }
}

/// Property: only qty==-1 passes burn check
test prop_burn_only_negative_1_passes() {
  let name = derive_asset_name(make_seed(seed_hash_1, 0))

  let check_qty = fn(qty) {
    let mint = assets.zero |> assets.add(policy_id, name, qty)
    let tx = Transaction { ..placeholder, mint: mint }
    validate_burn(policy_id, tx)
  }

  and {
    check_qty(-1),
    !check_qty(1),
    !check_qty(-2),
    !check_qty(0),
  }
}

/// AR-02: Property: multiple tokens under same policy fail both register and burn
test prop_multiple_tokens_fail_single_pair_match() {
  let name_a = derive_asset_name(make_seed(seed_hash_1, 0))
  let name_b = derive_asset_name(make_seed(seed_hash_2, 0))

  // Two mints
  let two_mints =
    assets.zero
      |> assets.add(policy_id, name_a, 1)
      |> assets.add(policy_id, name_b, 1)

  // One mint + one burn
  let mint_and_burn =
    assets.zero
      |> assets.add(policy_id, name_a, 1)
      |> assets.add(policy_id, name_b, -1)

  let tx_two = Transaction { ..placeholder, mint: two_mints }
  let tx_mixed = Transaction { ..placeholder, mint: mint_and_burn }

  // All fail [Pair(name, qty)] pattern match
  and {
    !validate_burn(policy_id, tx_two),
    !validate_burn(policy_id, tx_mixed),
  }
}

// ══════════════════════════════════════════════════════════════════════
// PROPERTY 4: Value preservation (or lack thereof — AR-09)
//
// Currently, update only requires ≥ min_deposit.
// This property documents that excess value is NOT preserved.
// ══════════════════════════════════════════════════════════════════════

/// AR-09: Property: update allows ANY amount ≥ min_deposit regardless
/// of input value. Value is NOT preserved.
test prop_update_value_not_preserved() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))

  // Input has 100 AP3X
  let rich_input =
    make_registry_input(0, owner_vkh, nft_name, 100_000_000)

  // Output has only minimum — 90 AP3X drained
  let min_output =
    Output {
      address: script_addr(),
      value: make_nft_value(min_deposit_lovelace, nft_name),
      datum: InlineDatum(make_datum(owner_vkh)),
      reference_script: None,
    }

  let tx =
    Transaction {
      ..placeholder,
      inputs: [rich_input],
      outputs: [min_output],
      extra_signatories: [owner_vkh],
    }

  // VULNERABILITY: 90 AP3X can be drained — AR-09
  validate_update(make_datum(owner_vkh), make_reg_ref(0), tx)
}

/// Property: update below minimum deposit ALWAYS fails regardless
/// of input value
test prop_update_below_min_always_fails() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))

  let check_below = fn(input_lovelace) {
    let input =
      make_registry_input(0, owner_vkh, nft_name, input_lovelace)
    let below_output =
      Output {
        address: script_addr(),
        value: assets.from_lovelace(min_deposit_lovelace - 1)
          |> assets.add(policy_id, nft_name, 1),
        datum: InlineDatum(make_datum(owner_vkh)),
        reference_script: None,
      }
    let tx =
      Transaction {
        ..placeholder,
        inputs: [input],
        outputs: [below_output],
        extra_signatories: [owner_vkh],
      }
    !validate_update(make_datum(owner_vkh), make_reg_ref(0), tx)
  }

  // Fails regardless of how much was in the input
  and {
    check_below(min_deposit_lovelace),
    check_below(50_000_000),
    check_below(1_000_000_000),
  }
}
