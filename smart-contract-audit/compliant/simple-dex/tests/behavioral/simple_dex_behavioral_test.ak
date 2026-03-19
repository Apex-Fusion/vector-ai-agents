/// Simple DEX — Behavioral Test Suite
///
/// Documents intended contract behavior.

use aiken/collection/list
use aiken/primitive/bytearray
use cardano/address.{Address, VerificationKey}
use cardano/assets
use cardano/assets.{lovelace_of, quantity_of}
use cardano/transaction.{NoDatum, Output}
use dex_types.{AssetClass, SwapDatum}

fn ceiling_div(a: Int, b: Int) -> Int {
  expect a >= 0
  expect b > 0
  let q = a / b
  if q * b == a { q } else { q + 1 }
}

fn get_asset_amount(value: assets.Value, asset: AssetClass) -> Int {
  if asset.policy_id == #"" && asset.asset_name == #"" {
    lovelace_of(value)
  } else {
    quantity_of(value, asset.policy_id, asset.asset_name)
  }
}

fn validate_take(
  d: SwapDatum,
  locked_value: assets.Value,
  maker_output: Output,
  script_input_count: Int,
) -> Bool {
  expect script_input_count == 1
  expect bytearray.length(d.offered_asset.policy_id) == 28 || d.offered_asset.policy_id == #""
  expect bytearray.length(d.desired_asset.policy_id) == 28 || d.desired_asset.policy_id == #""
  expect d.rate_numerator > 0
  expect d.rate_denominator > 0
  let locked_a = get_asset_amount(locked_value, d.offered_asset)
  expect locked_a > 0
  let required_b = ceiling_div(locked_a * d.rate_denominator, d.rate_numerator)
  let pays_maker = maker_output.address.payment_credential == VerificationKey(d.maker)
  let received = get_asset_amount(maker_output.value, d.desired_asset)
  let enough = received >= required_b
  pays_maker && enough
}

fn validate_cancel(d: SwapDatum, signatories: List<ByteArray>) -> Bool {
  list.has(signatories, d.maker)
}

const maker_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const wrong_pkh =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

const ada_asset = AssetClass { policy_id: #"", asset_name: #"" }

const token_policy =
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const token_asset = AssetClass { policy_id: token_policy, asset_name: #"544f4b454e" }

fn make_datum() -> SwapDatum {
  SwapDatum {
    maker: maker_pkh,
    offered_asset: ada_asset,
    desired_asset: token_asset,
    rate_numerator: 10,
    rate_denominator: 1,
  }
}

fn maker_out_with_tokens(token_qty: Int) -> Output {
  Output {
    address: Address { payment_credential: VerificationKey(maker_pkh), stake_credential: None },
    value: assets.from_lovelace(2_000_000) |> assets.add(token_policy, #"544f4b454e", token_qty),
    datum: NoDatum,
    reference_script: None,
  }
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Take happy path
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Take succeeds with correct payment (10 ADA offered, rate 10:1, need 1 token).
test behavior_take_success() {
  let locked = assets.from_lovelace(10_000_000)
  // required = ceil(10_000_000 * 1 / 10) = 1_000_000 tokens
  validate_take(make_datum(), locked, maker_out_with_tokens(1_000_000), 1)
}

/// BEHAVIOR: Take succeeds with overpayment.
test behavior_take_overpay_succeeds() {
  let locked = assets.from_lovelace(10_000_000)
  validate_take(make_datum(), locked, maker_out_with_tokens(2_000_000), 1)
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Take rejection cases
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Take fails with underpayment.
test behavior_take_underpay_fails() {
  let locked = assets.from_lovelace(10_000_000)
  !validate_take(make_datum(), locked, maker_out_with_tokens(999_999), 1)
}

/// BEHAVIOR: Take fails when output goes to wrong address.
test behavior_take_wrong_recipient_fails() {
  let locked = assets.from_lovelace(10_000_000)
  let wrong_out = Output {
    address: Address { payment_credential: VerificationKey(wrong_pkh), stake_credential: None },
    value: assets.from_lovelace(2_000_000) |> assets.add(token_policy, #"544f4b454e", 1_000_000),
    datum: NoDatum,
    reference_script: None,
  }
  !validate_take(make_datum(), locked, wrong_out, 1)
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Cancel
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Cancel succeeds with maker signature.
test behavior_cancel_success() {
  validate_cancel(make_datum(), [maker_pkh])
}

/// BEHAVIOR: Cancel fails without maker signature.
test behavior_cancel_no_signature_fails() {
  !validate_cancel(make_datum(), [])
}

/// BEHAVIOR: Cancel fails with wrong signer.
test behavior_cancel_wrong_signer_fails() {
  !validate_cancel(make_datum(), [wrong_pkh])
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Double satisfaction blocked
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Double satisfaction blocked by script_input_count.
test behavior_double_satisfaction_blocked() {
  let locked = assets.from_lovelace(10_000_000)
  !validate_take(make_datum(), locked, maker_out_with_tokens(1_000_000), 2)
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Ceiling division favors maker
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Ceiling division rounds up (maker gets at least the correct amount).
test behavior_ceiling_div_rounds_up() {
  // 7 / 3 = 2.333... → ceil = 3
  ceiling_div(7, 3) == 3
}

/// BEHAVIOR: Exact division stays exact.
test behavior_ceiling_div_exact() {
  ceiling_div(9, 3) == 3
}
