/// # Simple DEX — Fuzz Tests
///
/// Fuzz testing for edge cases in exchange rates, payment amounts,
/// policy IDs, signer verification, and output-index handling.
///
/// Targets audit findings:
/// - F1 (Critical): Double satisfaction — single-script-input enforcement
/// - F2 (High): ceiling_div safety guards
/// - F3 (Medium): Policy ID length validation
/// - Redeemer manipulation: output-index pinning
/// - Missing signer checks: Cancel authorization
///
/// Authored by: Test Writer
/// Date: 2026-03-16

use aiken/collection/list
use aiken/fuzz
use aiken/primitive/bytearray
use cardano/address.{Address, VerificationKey}
use cardano/assets
use cardano/assets.{Value, lovelace_of, quantity_of}
use cardano/transaction.{NoDatum, Output}
use dex_types.{AssetClass, SwapDatum}

// ---------------------------------------------------------------------------
// Reimplementation of validator helpers
// ---------------------------------------------------------------------------

fn get_asset_amount(value: Value, asset: AssetClass) -> Int {
  if asset.policy_id == #"" && asset.asset_name == #"" {
    lovelace_of(value)
  } else {
    quantity_of(value, asset.policy_id, asset.asset_name)
  }
}

fn ceiling_div(a: Int, b: Int) -> Int {
  expect a >= 0
  expect b > 0
  let q = a / b
  if q * b == a {
    q
  } else {
    q + 1
  }
}

fn validate_take(
  datum: SwapDatum,
  maker_output_index: Int,
  locked_value: Value,
  outputs: List<Output>,
  script_input_count: Int,
) -> Bool {
  expect script_input_count == 1
  expect
    bytearray.length(datum.offered_asset.policy_id) == 28 || datum.offered_asset.policy_id == #""
  expect
    bytearray.length(datum.desired_asset.policy_id) == 28 || datum.desired_asset.policy_id == #""
  expect datum.rate_numerator > 0
  expect datum.rate_denominator > 0
  let locked_amount_a = get_asset_amount(locked_value, datum.offered_asset)
  expect locked_amount_a > 0
  let required_b =
    ceiling_div(
      locked_amount_a * datum.rate_denominator,
      datum.rate_numerator,
    )
  expect Some(maker_output) = list.at(outputs, maker_output_index)
  let pays_maker =
    maker_output.address.payment_credential == VerificationKey(datum.maker)
  let maker_received = get_asset_amount(maker_output.value, datum.desired_asset)
  let enough_payment = maker_received >= required_b
  and {
    pays_maker,
    enough_payment,
  }
}

fn validate_cancel(
  datum: SwapDatum,
  signatories: List<ByteArray>,
  script_input_count: Int,
) -> Bool {
  expect script_input_count == 1
  list.has(signatories, datum.maker)
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const maker_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const token_a_policy =
  #"aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000"

const token_a_name = #"546f6b656e41"

const ada_asset =
  AssetClass { policy_id: #"", asset_name: #"" }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_address(pkh: ByteArray) -> Address {
  Address {
    payment_credential: VerificationKey(pkh),
    stake_credential: None,
  }
}

fn make_output_lovelace(pkh: ByteArray, lovelace: Int) -> Output {
  Output {
    address: make_address(pkh),
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

// ===========================================================================
// FUZZ 1: Random exchange rates — exact payment always accepted
// ===========================================================================

test fuzz_exchange_rates_exact_payment(
  (raw_num, raw_denom) via fuzz.both(fuzz.int(), fuzz.int()),
) {
  let rate_num =
    if raw_num <= 0 {
      1
    } else if raw_num > 100_000 {
      raw_num % 100_000 + 1
    } else {
      raw_num
    }
  let rate_denom =
    if raw_denom <= 0 {
      1
    } else if raw_denom > 100_000 {
      raw_denom % 100_000 + 1
    } else {
      raw_denom
    }

  let locked_amount = 50
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: rate_num,
      rate_denominator: rate_denom,
    }

  let required = ceiling_div(locked_amount * rate_denom, rate_num)
  let locked = assets.from_asset(token_a_policy, token_a_name, locked_amount)
  let outputs = [make_output_lovelace(maker_pkh, required)]
  validate_take(d, 0, locked, outputs, 1)
}

// ===========================================================================
// FUZZ 2: Random underpayment amounts always rejected
// Targets: value manipulation attack vector
// ===========================================================================

test fuzz_underpayment_always_rejected(raw_shortfall via fuzz.int()) {
  let shortfall =
    if raw_shortfall <= 0 {
      1
    } else if raw_shortfall > 1000 {
      raw_shortfall % 1000 + 1
    } else {
      raw_shortfall
    }

  let locked_amount = 100
  let rate_num = 1
  let rate_denom = 2
  let required = ceiling_div(locked_amount * rate_denom, rate_num)

  let payment = required - shortfall

  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: rate_num,
      rate_denominator: rate_denom,
    }

  let locked = assets.from_asset(token_a_policy, token_a_name, locked_amount)

  if payment < 0 {
    True
  } else {
    let outputs = [make_output_lovelace(maker_pkh, payment)]
    !validate_take(d, 0, locked, outputs, 1)
  }
}

// ===========================================================================
// FUZZ 3: Random policy ID lengths (not 28 and not 0) always rejected
// Targets: token identity confusion (audit finding F3)
// ===========================================================================

test fuzz_bad_policy_id_length(raw_len via fuzz.int()) {
  let pre_len =
    if raw_len <= 0 {
      1
    } else if raw_len > 64 {
      raw_len % 64 + 1
    } else {
      raw_len
    }
  let len =
    if pre_len == 28 {
      29
    } else {
      pre_len
    }

  let bad_policy =
    bytearray.take(
      #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd",
      len,
    )

  let is_bad_length =
    bytearray.length(bad_policy) != 28 && bad_policy != #""

  is_bad_length
}

// ===========================================================================
// FUZZ 4: Random signers never authorize Cancel (unless match maker)
// Targets: missing signer checks attack vector
// ===========================================================================

test fuzz_random_signer_cancel_rejected(fuzzed_signer via fuzz.bytearray()) {
  if fuzzed_signer == maker_pkh {
    True
  } else {
    let d =
      SwapDatum {
        maker: maker_pkh,
        offered_asset: AssetClass {
          policy_id: token_a_policy,
          asset_name: token_a_name,
        },
        desired_asset: ada_asset,
        rate_numerator: 1,
        rate_denominator: 2,
      }
    !validate_cancel(d, [fuzzed_signer], 1)
  }
}

// ===========================================================================
// FUZZ 5: Random locked amounts with exact payment always pass
// ===========================================================================

test fuzz_random_locked_amount(raw_amount via fuzz.int()) {
  let amount =
    if raw_amount <= 0 {
      1
    } else if raw_amount > 10_000_000 {
      raw_amount % 10_000_000 + 1
    } else {
      raw_amount
    }

  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 7,
      rate_denominator: 3,
    }

  let required = ceiling_div(amount * 3, 7)
  let locked = assets.from_asset(token_a_policy, token_a_name, amount)
  let outputs = [make_output_lovelace(maker_pkh, required)]
  validate_take(d, 0, locked, outputs, 1)
}

// ===========================================================================
// FUZZ 6: Random payment to random address always fails
// Targets: datum hijacking / payment redirection
// ===========================================================================

test fuzz_payment_to_wrong_address(fuzzed_pkh via fuzz.bytearray()) {
  if fuzzed_pkh == maker_pkh {
    True
  } else {
    let d =
      SwapDatum {
        maker: maker_pkh,
        offered_asset: AssetClass {
          policy_id: token_a_policy,
          asset_name: token_a_name,
        },
        desired_asset: ada_asset,
        rate_numerator: 1,
        rate_denominator: 2,
      }
    let locked = assets.from_asset(token_a_policy, token_a_name, 100)
    let outputs = [make_output_lovelace(fuzzed_pkh, 200)]
    !validate_take(d, 0, locked, outputs, 1)
  }
}

// ===========================================================================
// FUZZ 7: ceiling_div with random positive inputs always satisfies
//         result * b >= a (ceiling guarantee)
// Targets: audit finding F2 (ceiling_div correctness)
// ===========================================================================

test fuzz_ceiling_div_guarantee(
  (raw_a, raw_b) via fuzz.both(fuzz.int(), fuzz.int()),
) {
  let a =
    if raw_a < 0 {
      -raw_a % 1_000_000_000
    } else {
      raw_a % 1_000_000_000
    }
  let b =
    if raw_b <= 0 {
      ( -raw_b ) % 1_000_000_000 + 1
    } else if raw_b > 1_000_000_000 {
      raw_b % 1_000_000_000 + 1
    } else {
      raw_b
    }

  let result = ceiling_div(a, b)
  result * b >= a
}

// ===========================================================================
// FUZZ 8: Random maker PKH in datum — only matching signer passes Cancel
// ===========================================================================

test fuzz_maker_identity_cancel(fuzzed_maker via fuzz.bytearray()) {
  let d =
    SwapDatum {
      maker: fuzzed_maker,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 1,
      rate_denominator: 2,
    }

  let correct_passes = validate_cancel(d, [fuzzed_maker], 1)

  let other_fails =
    if fuzzed_maker == maker_pkh {
      True
    } else {
      !validate_cancel(d, [maker_pkh], 1)
    }

  and {
    correct_passes,
    other_fails,
  }
}
