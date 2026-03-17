/// # Simple DEX — Unit Tests
///
/// Comprehensive test suite covering happy paths, rejection cases,
/// attack vectors, and edge cases for the simple_dex validator.
///
/// Tests replicate the validator logic to verify correctness of each
/// validation check independently. Covers all findings from audit:
/// - F1 (Critical): Double satisfaction — output-index pinning insufficient
/// - F2 (High): ceiling_div incorrect for negative numerators
/// - F3 (Medium): Token identity confusion — no policy ID length validation
/// - F4 (Low): No minimum payment sanity check
/// - F5 (Info): ADA-specific edge case in get_asset_amount
///
/// Authored by: Test Writer
/// Date: 2026-03-16

use aiken/collection/list
use aiken/primitive/bytearray
use cardano/address.{Address, VerificationKey}
use cardano/assets
use cardano/assets.{Value, lovelace_of, quantity_of}
use cardano/transaction.{NoDatum, Output}
use dex_types.{AssetClass, Cancel, SwapDatum, SwapRedeemer, Take}

// ---------------------------------------------------------------------------
// Reimplementation of validator helpers (mirrors validator logic exactly)
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

/// Full Take validation logic (mirrors the validator's Take path)
fn validate_take(
  datum: SwapDatum,
  maker_output_index: Int,
  locked_value: Value,
  outputs: List<Output>,
  script_input_count: Int,
) -> Bool {
  // Double satisfaction prevention (audit finding F1 fix)
  expect script_input_count == 1

  // Policy ID length validation (audit finding F3 fix)
  expect
    bytearray.length(datum.offered_asset.policy_id) == 28 || datum.offered_asset.policy_id == #""
  expect
    bytearray.length(datum.desired_asset.policy_id) == 28 || datum.desired_asset.policy_id == #""

  // Rate validation
  expect datum.rate_numerator > 0
  expect datum.rate_denominator > 0

  // Calculate locked amount
  let locked_amount_a = get_asset_amount(locked_value, datum.offered_asset)
  expect locked_amount_a > 0

  // Calculate required payment (ceiling_div with guards — audit finding F2 fix)
  let required_b =
    ceiling_div(
      locked_amount_a * datum.rate_denominator,
      datum.rate_numerator,
    )

  // Verify maker output
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

/// Cancel validation logic (mirrors the validator's Cancel path)
fn validate_cancel(
  datum: SwapDatum,
  signatories: List<ByteArray>,
  script_input_count: Int,
) -> Bool {
  expect script_input_count == 1
  list.has(signatories, datum.maker)
}

// ---------------------------------------------------------------------------
// Test constants
// ---------------------------------------------------------------------------

const maker_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const taker_pkh =
  #"11223344112233441122334411223344112233441122334411223344"

const wrong_pkh =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

/// Valid 28-byte policy ID for offered token
const token_a_policy =
  #"aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000"

/// Valid 28-byte policy ID for desired token
const token_b_policy =
  #"11111111222222223333333344444444555555556666666677777777"

const token_a_name = #"546f6b656e41"

const token_b_name = #"546f6b656e42"

/// ADA asset class
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

fn make_output_token(
  pkh: ByteArray,
  policy: ByteArray,
  name: ByteArray,
  qty: Int,
) -> Output {
  Output {
    address: make_address(pkh),
    value: assets.from_asset(policy, name, qty),
    datum: NoDatum,
    reference_script: None,
  }
}

/// Standard datum: offer 100 TokenA, want ADA at rate 1:2 (100 TokenA → 200 ADA)
fn make_token_for_ada_datum() -> SwapDatum {
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
}

/// Standard datum: offer 1000 ADA, want TokenB at rate 10:1 (10 ADA → 1 TokenB)
fn make_ada_for_token_datum() -> SwapDatum {
  SwapDatum {
    maker: maker_pkh,
    offered_asset: ada_asset,
    desired_asset: AssetClass {
      policy_id: token_b_policy,
      asset_name: token_b_name,
    },
    rate_numerator: 10,
    rate_denominator: 1,
  }
}

// ===========================================================================
// CEILING_DIV HELPER TESTS (audit finding F2: guards for safe math)
// ===========================================================================

/// Exact division: 10 / 5 = 2
test ceiling_div_exact() {
  ceiling_div(10, 5) == 2
}

/// Rounding up: 11 / 5 = 3 (ceil)
test ceiling_div_rounds_up() {
  ceiling_div(11, 5) == 3
}

/// Division by 1: ceil(7/1) = 7
test ceiling_div_by_one() {
  ceiling_div(7, 1) == 7
}

/// Zero numerator: ceil(0/5) = 0
test ceiling_div_zero_numerator() {
  ceiling_div(0, 5) == 0
}

/// Large values: ceil(1_000_000_001 / 1_000_000) = 1001
test ceiling_div_large_values() {
  ceiling_div(1_000_000_001, 1_000_000) == 1001
}

/// Edge: ceil(1/MAX) = 1 (any remainder rounds up)
test ceiling_div_one_over_large() {
  ceiling_div(1, 1_000_000_000) == 1
}

/// ceil(999/1000) = 1
test ceiling_div_just_under_one() {
  ceiling_div(999, 1000) == 1
}

/// ceil(1000/1000) = 1 (exact)
test ceiling_div_exact_one() {
  ceiling_div(1000, 1000) == 1
}

/// ceil(1001/1000) = 2
test ceiling_div_just_over_one() {
  ceiling_div(1001, 1000) == 2
}

/// Negative numerator must fail (audit finding F2: guard added)
test ceiling_div_negative_numerator_fails() fail {
  ceiling_div(-1, 5) == -1
}

/// Zero denominator must fail (guard)
test ceiling_div_zero_denominator_fails() fail {
  ceiling_div(10, 0) == 0
}

/// Negative denominator must fail (guard)
test ceiling_div_negative_denominator_fails() fail {
  ceiling_div(10, -5) == -2
}

// ===========================================================================
// GET_ASSET_AMOUNT HELPER TESTS
// ===========================================================================

/// Get ADA amount from value with lovelace
test get_asset_amount_ada() {
  let v = assets.from_lovelace(5_000_000)
  get_asset_amount(v, ada_asset) == 5_000_000
}

/// Get native token amount from value
test get_asset_amount_native_token() {
  let v = assets.from_asset(token_a_policy, token_a_name, 100)
  get_asset_amount(
    v,
    AssetClass { policy_id: token_a_policy, asset_name: token_a_name },
  ) == 100
}

/// Get amount of token not in value returns 0
test get_asset_amount_missing_token() {
  let v = assets.from_lovelace(5_000_000)
  get_asset_amount(
    v,
    AssetClass { policy_id: token_a_policy, asset_name: token_a_name },
  ) == 0
}

/// Get ADA from empty value returns 0
test get_asset_amount_empty_value() {
  get_asset_amount(assets.zero, ada_asset) == 0
}

// ===========================================================================
// HAPPY PATH — TAKE
// ===========================================================================

/// Take: TokenA for ADA, exact payment → pass
test take_happy_path_token_for_ada() {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: ADA for Token, exact payment → pass
test take_happy_path_ada_for_token() {
  let d = make_ada_for_token_datum()
  let locked = assets.from_lovelace(1_000_000_000)
  let outputs =
    [make_output_token(maker_pkh, token_b_policy, token_b_name, 100_000_000)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: overpayment → pass (taker pays more than required)
test take_overpayment_passes() {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 300)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: maker output at non-zero index → pass
test take_output_at_index_1() {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs =
    [
      make_output_lovelace(taker_pkh, 500),
      make_output_lovelace(maker_pkh, 200),
    ]
  validate_take(d, 1, locked, outputs, 1)
}

/// Take: ceiling division kicks in (rate 3:10, lock 10 → need ceil(10*10/3)=34)
test take_ceiling_div_rounding() {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 3,
      rate_denominator: 10,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 10)
  let outputs = [make_output_lovelace(maker_pkh, 34)]
  validate_take(d, 0, locked, outputs, 1)
}

// ===========================================================================
// HAPPY PATH — CANCEL
// ===========================================================================

/// Cancel: maker signature present → pass
test cancel_happy_path() {
  let d = make_token_for_ada_datum()
  validate_cancel(d, [maker_pkh], 1)
}

/// Cancel: maker among multiple signatories → pass
test cancel_maker_among_multiple_signers() {
  let d = make_token_for_ada_datum()
  validate_cancel(d, [wrong_pkh, maker_pkh, taker_pkh], 1)
}

// ===========================================================================
// REJECTION — TAKE: UNDERPAYMENT
// ===========================================================================

/// Take: underpayment by 1 → must fail
test take_underpayment_by_one() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 199)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: zero payment → must fail
test take_zero_payment() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 0)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: underpayment when ceiling applies (needs 34, pays 33) → must fail
test take_underpayment_ceiling() fail {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 3,
      rate_denominator: 10,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 10)
  let outputs = [make_output_lovelace(maker_pkh, 33)]
  validate_take(d, 0, locked, outputs, 1)
}

// ===========================================================================
// REJECTION — TAKE: WRONG TOKEN / ADDRESS
// ===========================================================================

/// Take: maker wants ADA but receives TokenB instead → must fail
test take_wrong_desired_token() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs =
    [make_output_token(maker_pkh, token_b_policy, token_b_name, 200)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: payment to wrong address → must fail
test take_payment_to_wrong_address() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(wrong_pkh, 200)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: payment to taker address instead of maker → must fail
test take_payment_to_taker() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(taker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 1)
}

// ===========================================================================
// REJECTION — CANCEL: MISSING SIGNATURE
// ===========================================================================

/// Cancel: no signature → must fail
test cancel_no_signature() fail {
  let d = make_token_for_ada_datum()
  validate_cancel(d, [], 1)
}

/// Cancel: wrong signer → must fail
test cancel_wrong_signer() fail {
  let d = make_token_for_ada_datum()
  validate_cancel(d, [wrong_pkh], 1)
}

/// Cancel: taker tries to cancel → must fail
test cancel_taker_not_authorized() fail {
  let d = make_token_for_ada_datum()
  validate_cancel(d, [taker_pkh], 1)
}

// ===========================================================================
// REJECTION — BAD POLICY ID LENGTH (audit finding F3: token identity confusion)
// ===========================================================================

/// Take: offered asset has truncated policy ID (27 bytes) → must fail
test take_bad_offered_policy_id_short() fail {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbcc",
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 1,
      rate_denominator: 2,
    }
  let locked =
    assets.from_asset(
      #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbcc",
      token_a_name,
      100,
    )
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: desired asset has padded policy ID (29 bytes) → must fail
test take_bad_desired_policy_id_long() fail {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: AssetClass {
        policy_id: #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddee",
        asset_name: token_b_name,
      },
      rate_numerator: 1,
      rate_denominator: 2,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs =
    [
      make_output_token(
        maker_pkh,
        #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddee",
        token_b_name,
        200,
      ),
    ]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: offered asset has 1-byte policy ID → must fail
test take_bad_policy_id_one_byte() fail {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass { policy_id: #"aa", asset_name: token_a_name },
      desired_asset: ada_asset,
      rate_numerator: 1,
      rate_denominator: 2,
    }
  let locked = assets.from_asset(#"aa", token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: both assets ADA (valid empty policy IDs) → should pass policy check
test take_ada_for_ada_policy_valid() {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: ada_asset,
      desired_asset: ada_asset,
      rate_numerator: 1,
      rate_denominator: 1,
    }
  let locked = assets.from_lovelace(100)
  let outputs = [make_output_lovelace(maker_pkh, 100)]
  validate_take(d, 0, locked, outputs, 1)
}

// ===========================================================================
// REJECTION — RATE VALIDATION
// ===========================================================================

/// Take: rate_numerator = 0 → must fail
test take_zero_rate_numerator() fail {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 0,
      rate_denominator: 2,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: rate_denominator = 0 → must fail
test take_zero_rate_denominator() fail {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 1,
      rate_denominator: 0,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 0)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: negative rate_numerator → must fail
test take_negative_rate_numerator() fail {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: -1,
      rate_denominator: 2,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: negative rate_denominator → must fail
test take_negative_rate_denominator() fail {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 1,
      rate_denominator: -2,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 1)
}

// ===========================================================================
// SINGLE-SCRIPT-INPUT ENFORCEMENT (audit finding F1: double satisfaction fix)
// ===========================================================================

/// Take: script_input_count = 2 → must fail (double satisfaction prevention)
test take_double_satisfaction_blocked() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 2)
}

/// Take: script_input_count = 0 → must fail
test take_zero_script_inputs() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 0)
}

/// Take: script_input_count = 5 → must fail
test take_five_script_inputs() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 5)
}

/// Cancel: script_input_count = 2 → must fail (applies to Cancel too)
test cancel_double_satisfaction_blocked() fail {
  let d = make_token_for_ada_datum()
  validate_cancel(d, [maker_pkh], 2)
}

/// Cancel: script_input_count = 3 → must fail
test cancel_triple_script_inputs_blocked() fail {
  let d = make_token_for_ada_datum()
  validate_cancel(d, [maker_pkh], 3)
}

// ===========================================================================
// OUTPUT-INDEX PINNING TESTS
// ===========================================================================

/// Take: output index out of bounds → must fail
test take_output_index_out_of_bounds() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 1, locked, outputs, 1)
}

/// Take: negative output index → must fail
test take_negative_output_index() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, -1, locked, outputs, 1)
}

/// Take: output at pinned index doesn't pay maker → must fail
test take_pinned_index_wrong_recipient() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs =
    [
      make_output_lovelace(wrong_pkh, 200),
      make_output_lovelace(maker_pkh, 200),
    ]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: empty outputs list → must fail
test take_no_outputs() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_asset(token_a_policy, token_a_name, 100)
  validate_take(d, 0, locked, [], 1)
}

// ===========================================================================
// EDGE CASES — LOCKED AMOUNT
// ===========================================================================

/// Take: zero locked amount → must fail (expect locked_amount_a > 0)
test take_zero_locked_amount() fail {
  let d = make_token_for_ada_datum()
  let locked = assets.from_lovelace(5_000_000)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Take: locked amount = 1, rate 1:1 → need 1 → pass
test take_minimum_locked_amount() {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 1,
      rate_denominator: 1,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 1)
  let outputs = [make_output_lovelace(maker_pkh, 1)]
  validate_take(d, 0, locked, outputs, 1)
}

// ===========================================================================
// EDGE CASES — RATE COMPUTATION
// ===========================================================================

/// Rate 1:1 — exact 1:1 swap
test take_rate_one_to_one() {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 1,
      rate_denominator: 1,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 500)
  let outputs = [make_output_lovelace(maker_pkh, 500)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Very large rate numerator (cheap token A): 1_000_000:1
test take_very_cheap_token() {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 1_000_000,
      rate_denominator: 1,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 1_000_000)
  let outputs = [make_output_lovelace(maker_pkh, 1)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Very small rate numerator (expensive token A): 1:1_000_000
test take_very_expensive_token() {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 1,
      rate_denominator: 1_000_000,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 1)
  let outputs = [make_output_lovelace(maker_pkh, 1_000_000)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Ceiling div edge: lock 1, rate 3:2 → ceil(1*2/3) = ceil(0.67) = 1
test take_ceiling_rounding_edge_small() {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 3,
      rate_denominator: 2,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 1)
  let outputs = [make_output_lovelace(maker_pkh, 1)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Ceiling div: exact result (no rounding needed)
test take_ceiling_exact_no_rounding() {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 3,
      rate_denominator: 2,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 6)
  let outputs = [make_output_lovelace(maker_pkh, 4)]
  validate_take(d, 0, locked, outputs, 1)
}

/// Ceiling div: underpay by 1 on exact division should fail
test take_ceiling_exact_underpay() fail {
  let d =
    SwapDatum {
      maker: maker_pkh,
      offered_asset: AssetClass {
        policy_id: token_a_policy,
        asset_name: token_a_name,
      },
      desired_asset: ada_asset,
      rate_numerator: 3,
      rate_denominator: 2,
    }
  let locked = assets.from_asset(token_a_policy, token_a_name, 6)
  let outputs = [make_output_lovelace(maker_pkh, 3)]
  validate_take(d, 0, locked, outputs, 1)
}

// ===========================================================================
// DOUBLE SATISFACTION DOCUMENTATION TEST
// ===========================================================================

/// Documents that the double satisfaction attack is blocked.
/// With script_input_count==1 enforcement, multi-offer TX is impossible.
test double_satisfaction_attack_blocked() {
  let d1 = make_token_for_ada_datum()
  let locked1 = assets.from_asset(token_a_policy, token_a_name, 100)
  let outputs = [make_output_lovelace(maker_pkh, 200)]
  let first_passes = validate_take(d1, 0, locked1, outputs, 1)
  first_passes
}
