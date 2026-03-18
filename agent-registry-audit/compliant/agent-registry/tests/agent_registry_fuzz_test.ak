/// # Agent Registry — Fuzz Tests
///
/// Fuzz-style tests exercising the validator with varied random-like
/// inputs: different signers, datum fields, token quantities, and
/// input counts. Since Aiken doesn't have a native fuzzer, we
/// simulate fuzzing by sweeping over diverse adversarial values.
///
/// Covers: AR-01 through AR-09 with adversarial input combinations.
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
  derive_asset_name, min_deposit_lovelace, script_address_from_policy,
  validate_burn, validate_deregister, validate_register, validate_update,
}

// ──────────────────────────────────────────────────────────────────────
// Constants — diverse key material
// ──────────────────────────────────────────────────────────────────────

const policy_id: ByteArray =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const owner_vkh: ByteArray =
  #"1122334455667788112233445566778811223344556677881122334455667788"

// "Random" signers
const signer_a: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const signer_b: ByteArray =
  #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const signer_c: ByteArray =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
const signer_d: ByteArray =
  #"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
const signer_e: ByteArray =
  #"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

const seed_hash_1: ByteArray =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
const seed_hash_2: ByteArray =
  #"cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe"
const seed_hash_3: ByteArray =
  #"0123456701234567012345670123456701234567012345670123456701234567"
const seed_hash_4: ByteArray =
  #"fedcba98fedcba98fedcba98fedcba98fedcba98fedcba98fedcba98fedcba98"

const reg_tx: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

// ──────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────

fn addr() -> Address {
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

fn reg_ref(idx: Int) -> OutputReference {
  OutputReference { transaction_id: reg_tx, output_index: idx }
}

fn make_reg_input(
  idx: Int,
  vkh: ByteArray,
  nft_name: ByteArray,
  lovelace: Int,
) -> Input {
  Input {
    output_reference: reg_ref(idx),
    output: Output {
      address: addr(),
      value: assets.from_lovelace(lovelace)
        |> assets.add(policy_id, nft_name, 1),
      datum: InlineDatum(make_datum(vkh)),
      reference_script: None,
    },
  }
}

// ══════════════════════════════════════════════════════════════════════
// FUZZ: Random Signers (AR-03, AR-05, AR-07)
//
// Sweep through multiple random signers — none should authorize
// operations on an agent they don't own.
// ══════════════════════════════════════════════════════════════════════

/// Fuzz random signers against update — all must fail (AR-03, AR-05)
test fuzz_random_signers_update_all_fail() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let input = make_reg_input(0, owner_vkh, nft_name, min_deposit_lovelace)
  let output =
    Output {
      address: addr(),
      value: assets.from_lovelace(min_deposit_lovelace)
        |> assets.add(policy_id, nft_name, 1),
      datum: InlineDatum(make_datum(owner_vkh)),
      reference_script: None,
    }

  let check = fn(signer) {
    let tx =
      Transaction {
        ..placeholder,
        inputs: [input],
        outputs: [output],
        extra_signatories: [signer],
      }
    !validate_update(make_datum(owner_vkh), reg_ref(0), tx)
  }

  and {
    check(signer_a),
    check(signer_b),
    check(signer_c),
    check(signer_d),
    check(signer_e),
  }
}

/// Fuzz random signers against deregister — all must fail
test fuzz_random_signers_deregister_all_fail() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let input = make_reg_input(0, owner_vkh, nft_name, min_deposit_lovelace)
  let burn = assets.zero |> assets.add(policy_id, nft_name, -1)

  let check = fn(signer) {
    let tx =
      Transaction {
        ..placeholder,
        inputs: [input],
        mint: burn,
        extra_signatories: [signer],
      }
    !validate_deregister(make_datum(owner_vkh), reg_ref(0), tx)
  }

  and {
    check(signer_a),
    check(signer_b),
    check(signer_c),
    check(signer_d),
    check(signer_e),
  }
}

/// Fuzz: multiple random signers at once — still fail without owner
test fuzz_multiple_signers_no_owner_update_fails() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let input = make_reg_input(0, owner_vkh, nft_name, min_deposit_lovelace)
  let output =
    Output {
      address: addr(),
      value: assets.from_lovelace(min_deposit_lovelace)
        |> assets.add(policy_id, nft_name, 1),
      datum: InlineDatum(make_datum(owner_vkh)),
      reference_script: None,
    }
  let tx =
    Transaction {
      ..placeholder,
      inputs: [input],
      outputs: [output],
      extra_signatories: [signer_a, signer_b, signer_c, signer_d, signer_e],
    }
  !validate_update(make_datum(owner_vkh), reg_ref(0), tx)
}

// ══════════════════════════════════════════════════════════════════════
// FUZZ: Random Datum Fields (AR-04, AR-08)
//
// Sweep through various datum shapes — the validator accepts all
// of them (documenting AR-04 and AR-08 vulnerabilities).
// ══════════════════════════════════════════════════════════════════════

/// Fuzz: update with various datum mutations — all pass (AR-04)
test fuzz_datum_mutations_all_accepted() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let input = make_reg_input(0, owner_vkh, nft_name, min_deposit_lovelace)

  let check = fn(new_datum) {
    let output =
      Output {
        address: addr(),
        value: assets.from_lovelace(min_deposit_lovelace)
          |> assets.add(policy_id, nft_name, 1),
        datum: InlineDatum(new_datum),
        reference_script: None,
      }
    let tx =
      Transaction {
        ..placeholder,
        inputs: [input],
        outputs: [output],
        extra_signatories: [owner_vkh],
      }
    validate_update(make_datum(owner_vkh), reg_ref(0), tx)
  }

  // All these mutations are accepted — AR-04
  and {
    // Changed owner
    check(
      AgentDatum {
        ..make_datum(owner_vkh),
        owner: VerificationKey(signer_a),
      },
    ),
    // Changed name
    check(AgentDatum { ..make_datum(owner_vkh), name: "HIJACKED" }),
    // Empty everything
    check(
      AgentDatum {
        owner: VerificationKey(owner_vkh),
        name: "",
        description: "",
        capabilities: [],
        framework: "",
        endpoint: "",
        registered_at: 0,
      },
    ),
    // Ridiculous registered_at
    check(
      AgentDatum { ..make_datum(owner_vkh), registered_at: -999999999 },
    ),
    // Many capabilities
    check(
      AgentDatum {
        ..make_datum(owner_vkh),
        capabilities: [
          "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
        ],
      },
    ),
  }
}

/// Fuzz: update with non-AgentDatum inline data — passes (AR-04)
test fuzz_non_datum_types_accepted() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let input = make_reg_input(0, owner_vkh, nft_name, min_deposit_lovelace)

  let check = fn(garbage) {
    let output =
      Output {
        address: addr(),
        value: assets.from_lovelace(min_deposit_lovelace)
          |> assets.add(policy_id, nft_name, 1),
        datum: InlineDatum(garbage),
        reference_script: None,
      }
    let tx =
      Transaction {
        ..placeholder,
        inputs: [input],
        outputs: [output],
        extra_signatories: [owner_vkh],
      }
    validate_update(make_datum(owner_vkh), reg_ref(0), tx)
  }

  // AR-04: any InlineDatum passes — no type check
  and {
    check(42),
    check("just a string"),
    check([1, 2, 3]),
    check(True),
  }
}

// ══════════════════════════════════════════════════════════════════════
// FUZZ: Random Token Quantities (AR-02, AR-06)
//
// Sweep through various mint/burn quantities — verify only the
// expected ones pass.
// ══════════════════════════════════════════════════════════════════════

/// Fuzz: register with various mint quantities
test fuzz_register_mint_quantities() {
  let seed = make_seed(seed_hash_1, 0)
  let name = derive_asset_name(seed)

  let check = fn(qty) {
    let mint = assets.zero |> assets.add(policy_id, name, qty)
    let output =
      Output {
        address: addr(),
        value: assets.from_lovelace(min_deposit_lovelace)
          |> assets.add(policy_id, name, 1),
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

  and {
    check(1),
    !check(2),
    !check(3),
    !check(10),
    !check(100),
    !check(-1),
    !check(-100),
  }
}

/// Fuzz: burn with various quantities
test fuzz_burn_quantities() {
  let name = derive_asset_name(make_seed(seed_hash_1, 0))

  let check = fn(qty) {
    let mint = assets.zero |> assets.add(policy_id, name, qty)
    let tx = Transaction { ..placeholder, mint: mint }
    validate_burn(policy_id, tx)
  }

  and {
    check(-1),
    !check(1),
    !check(-2),
    !check(-10),
    !check(2),
    !check(100),
  }
}

/// Fuzz: deregister with various burn quantities
test fuzz_deregister_burn_quantities() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let input = make_reg_input(0, owner_vkh, nft_name, min_deposit_lovelace)

  let check = fn(qty) {
    let mint = assets.zero |> assets.add(policy_id, nft_name, qty)
    let tx =
      Transaction {
        ..placeholder,
        inputs: [input],
        mint: mint,
        extra_signatories: [owner_vkh],
      }
    validate_deregister(make_datum(owner_vkh), reg_ref(0), tx)
  }

  and {
    check(-1),
    !check(1),
    !check(-2),
    !check(0),
    !check(100),
  }
}

// ══════════════════════════════════════════════════════════════════════
// FUZZ: Random Input Counts (AR-01)
//
// Test with varying numbers of script inputs to probe
// double satisfaction vulnerabilities.
// ══════════════════════════════════════════════════════════════════════

/// AR-01: Fuzz multiple script inputs — single output satisfies all
test fuzz_multiple_inputs_single_output_double_satisfaction() {
  let name_0 = derive_asset_name(make_seed(seed_hash_1, 0))
  let name_1 = derive_asset_name(make_seed(seed_hash_2, 0))
  let name_2 = derive_asset_name(make_seed(seed_hash_3, 0))

  let input_0 = make_reg_input(0, owner_vkh, name_0, min_deposit_lovelace)
  let input_1 = make_reg_input(1, owner_vkh, name_1, 50_000_000)
  let input_2 = make_reg_input(2, owner_vkh, name_2, 100_000_000)

  // Single output with all three NFTs — minimum deposit
  let combined_output =
    Output {
      address: addr(),
      value: assets.from_lovelace(min_deposit_lovelace)
        |> assets.add(policy_id, name_0, 1)
        |> assets.add(policy_id, name_1, 1)
        |> assets.add(policy_id, name_2, 1),
      datum: InlineDatum(make_datum(owner_vkh)),
      reference_script: None,
    }

  let tx =
    Transaction {
      ..placeholder,
      inputs: [input_0, input_1, input_2],
      outputs: [combined_output],
      extra_signatories: [owner_vkh],
    }

  // VULNERABILITY: all three pass with one output — AR-01
  let pass_0 = validate_update(make_datum(owner_vkh), reg_ref(0), tx)
  let pass_1 = validate_update(make_datum(owner_vkh), reg_ref(1), tx)
  let pass_2 = validate_update(make_datum(owner_vkh), reg_ref(2), tx)

  // All pass — 140 AP3X of deposits can be drained to just 10 AP3X
  and {
    pass_0,
    pass_1,
    pass_2,
  }
}

/// Fuzz: single input, multiple outputs — update still works
test fuzz_single_input_multiple_outputs() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let input = make_reg_input(0, owner_vkh, nft_name, min_deposit_lovelace)

  // Multiple outputs — one valid, others irrelevant
  let valid_output =
    Output {
      address: addr(),
      value: assets.from_lovelace(min_deposit_lovelace)
        |> assets.add(policy_id, nft_name, 1),
      datum: InlineDatum(make_datum(owner_vkh)),
      reference_script: None,
    }
  let extra_output_1 =
    Output {
      address: Address {
        payment_credential: VerificationKey(signer_a),
        stake_credential: None,
      },
      value: assets.from_lovelace(5_000_000),
      datum: NoDatum,
      reference_script: None,
    }
  let extra_output_2 =
    Output {
      address: Address {
        payment_credential: VerificationKey(signer_b),
        stake_credential: None,
      },
      value: assets.from_lovelace(3_000_000),
      datum: NoDatum,
      reference_script: None,
    }

  let tx =
    Transaction {
      ..placeholder,
      inputs: [input],
      outputs: [extra_output_1, valid_output, extra_output_2],
      extra_signatories: [owner_vkh],
    }

  validate_update(make_datum(owner_vkh), reg_ref(0), tx)
}

/// Fuzz: zero outputs — update must fail
test fuzz_zero_outputs_update_fails() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let input = make_reg_input(0, owner_vkh, nft_name, min_deposit_lovelace)

  let tx =
    Transaction {
      ..placeholder,
      inputs: [input],
      outputs: [],
      extra_signatories: [owner_vkh],
    }

  !validate_update(make_datum(owner_vkh), reg_ref(0), tx)
}

// ══════════════════════════════════════════════════════════════════════
// FUZZ: Deposit Amount Boundaries (AR-09)
//
// Sweep around the minimum deposit boundary.
// ══════════════════════════════════════════════════════════════════════

/// Fuzz deposit amounts around the boundary
test fuzz_deposit_boundaries_register() {
  let seed = make_seed(seed_hash_1, 0)
  let name = derive_asset_name(seed)

  let check = fn(lovelace) {
    let mint = assets.zero |> assets.add(policy_id, name, 1)
    let output =
      Output {
        address: addr(),
        value: assets.from_lovelace(lovelace)
          |> assets.add(policy_id, name, 1),
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
              value: assets.from_lovelace(200_000_000),
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

  and {
    // Below minimum — all fail
    !check(0),
    !check(1),
    !check(1_000_000),
    !check(9_999_999),
    // At minimum — pass
    check(10_000_000),
    // Above minimum — pass
    check(10_000_001),
    check(50_000_000),
    check(1_000_000_000),
  }
}

/// Fuzz deposit amounts around the boundary for update
test fuzz_deposit_boundaries_update() {
  let nft_name = derive_asset_name(make_seed(seed_hash_1, 0))
  let input = make_reg_input(0, owner_vkh, nft_name, 100_000_000)

  let check = fn(lovelace) {
    let output =
      Output {
        address: addr(),
        value: assets.from_lovelace(lovelace)
          |> assets.add(policy_id, nft_name, 1),
        datum: InlineDatum(make_datum(owner_vkh)),
        reference_script: None,
      }
    let tx =
      Transaction {
        ..placeholder,
        inputs: [input],
        outputs: [output],
        extra_signatories: [owner_vkh],
      }
    validate_update(make_datum(owner_vkh), reg_ref(0), tx)
  }

  and {
    !check(0),
    !check(9_999_999),
    check(10_000_000),
    check(10_000_001),
    // AR-09: draining from 100 AP3X to min is allowed
    check(min_deposit_lovelace),
  }
}

// ══════════════════════════════════════════════════════════════════════
// FUZZ: Mixed Operations (AR-02)
//
// Combining different redeemer operations in one TX.
// ══════════════════════════════════════════════════════════════════════

/// AR-02: Fuzz — register with wrong asset name in mint field
test fuzz_register_wrong_asset_names() {
  let seed = make_seed(seed_hash_1, 0)
  let correct_name = derive_asset_name(seed)
  let wrong_names =
    [
      #"0000000000000000000000000000000000000000000000000000000000000000",
      #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      #"deadbeef",
      #"",
    ]

  let check = fn(name) {
    let mint = assets.zero |> assets.add(policy_id, name, 1)
    let output =
      Output {
        address: addr(),
        value: assets.from_lovelace(min_deposit_lovelace)
          |> assets.add(policy_id, name, 1),
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

  // All wrong names must fail — the derive check prevents this
  and {
    !check(
      #"0000000000000000000000000000000000000000000000000000000000000000",
    ),
    !check(
      #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    ),
    !check(#"deadbeef"),
    !check(#""),
  }
}
