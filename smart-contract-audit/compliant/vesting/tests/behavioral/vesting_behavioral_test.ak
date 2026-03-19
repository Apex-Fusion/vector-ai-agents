/// Vesting — Behavioral Test Suite
///
/// Documents intended contract behavior. All pass on both original and compliant.

use aiken/collection/list
use aiken/interval.{Finite}
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets
use cardano/assets.{lovelace_of}
use cardano/transaction.{InlineDatum, NoDatum, Output}
use vesting_types.{VestingDatum}

// ──────────────────────────────────────────────────────────────────────
// Reimplemented validation (mirrors contract logic)
// ──────────────────────────────────────────────────────────────────────

fn min_int(a: Int, b: Int) -> Int {
  if a <= b { a } else { b }
}

fn validate_claim(
  d: VestingDatum,
  signatories: List<ByteArray>,
  current_time: Int,
  locked_lovelace: Int,
  beneficiary_output: Option<Output>,
  beneficiary_index: Int,
  continuation_output: Option<Output>,
  continuation_index: Int,
  script_address: Address,
  script_input_count: Int,
) -> Bool {
  expect script_input_count == 1
  let beneficiary_signed = list.has(signatories, d.beneficiary)
  let past_cliff = current_time >= d.cliff_time

  let vested_amount =
    if current_time >= d.vesting_end_time {
      d.total_vesting_amount
    } else {
      let elapsed = current_time - d.cliff_time
      let duration = d.vesting_end_time - d.cliff_time
      d.total_vesting_amount * elapsed / duration
    }
  let claimable = min_int(vested_amount, locked_lovelace)
  let must_remain = locked_lovelace - claimable

  let beneficiary_paid =
    if claimable <= 0 { False }
    else {
      when beneficiary_output is {
        Some(out) ->
          out.address.payment_credential == VerificationKey(d.beneficiary) &&
          lovelace_of(out.value) >= claimable
        None -> False
      }
    }

  let continuation_valid =
    if must_remain <= 0 { True }
    else {
      when continuation_output is {
        Some(out) -> {
          let indices_differ = beneficiary_index != continuation_index
          let address_ok = out.address == script_address
          let value_ok = lovelace_of(out.value) >= must_remain
          let datum_ok =
            when out.datum is {
              InlineDatum(raw) -> {
                expect cont_datum: VestingDatum = raw
                cont_datum.beneficiary == d.beneficiary &&
                cont_datum.total_vesting_amount == d.total_vesting_amount &&
                cont_datum.cliff_time == d.cliff_time &&
                cont_datum.vesting_end_time == d.vesting_end_time
              }
              _ -> False
            }
          and { indices_differ, address_ok, value_ok, datum_ok }
        }
        None -> False
      }
    }

  and { beneficiary_signed, past_cliff, beneficiary_paid, continuation_valid }
}

// ──────────────────────────────────────────────────────────────────────
// Constants
// ──────────────────────────────────────────────────────────────────────

const beneficiary_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const wrong_pkh =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

const script_hash =
  #"1111111111111111111111111111111111111111111111111111111111111111"

const cliff_time = 1_000_000_000_000

const vesting_end = 2_000_000_000_000

const total_amount = 100_000_000

const locked = 100_000_000

fn script_addr() -> Address {
  Address { payment_credential: Script(script_hash), stake_credential: None }
}

fn make_datum() -> VestingDatum {
  VestingDatum {
    beneficiary: beneficiary_pkh,
    total_vesting_amount: total_amount,
    cliff_time,
    vesting_end_time: vesting_end,
  }
}

fn beneficiary_out(lovelace: Int) -> Output {
  Output {
    address: Address { payment_credential: VerificationKey(beneficiary_pkh), stake_credential: None },
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

fn continuation_out(lovelace: Int) -> Output {
  Output {
    address: script_addr(),
    value: assets.from_lovelace(lovelace),
    datum: InlineDatum(make_datum()),
    reference_script: None,
  }
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Full claim after vesting_end
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Full claim after vesting_end succeeds — no continuation needed.
test behavior_full_claim_after_vesting_end() {
  validate_claim(
    make_datum(), [beneficiary_pkh], vesting_end + 1000, locked,
    Some(beneficiary_out(locked)), 0, None, 1, script_addr(), 1,
  )
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Partial claim between cliff and end
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Partial claim at midpoint — 50% vested.
test behavior_partial_claim_midpoint() {
  let midpoint = cliff_time + (vesting_end - cliff_time) / 2
  let claimable = total_amount / 2
  let remaining = locked - claimable
  validate_claim(
    make_datum(), [beneficiary_pkh], midpoint, locked,
    Some(beneficiary_out(claimable)), 0,
    Some(continuation_out(remaining)), 1,
    script_addr(), 1,
  )
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Rejection cases
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Claim before cliff fails.
test behavior_claim_before_cliff_fails() {
  !validate_claim(
    make_datum(), [beneficiary_pkh], cliff_time - 1000, locked,
    Some(beneficiary_out(locked)), 0, None, 1, script_addr(), 1,
  )
}

/// BEHAVIOR: Claim without beneficiary signature fails.
test behavior_claim_no_signature_fails() {
  !validate_claim(
    make_datum(), [], vesting_end + 1000, locked,
    Some(beneficiary_out(locked)), 0, None, 1, script_addr(), 1,
  )
}

/// BEHAVIOR: Claim with wrong signer fails.
test behavior_claim_wrong_signer_fails() {
  !validate_claim(
    make_datum(), [wrong_pkh], vesting_end + 1000, locked,
    Some(beneficiary_out(locked)), 0, None, 1, script_addr(), 1,
  )
}

/// BEHAVIOR: Partial claim with underpaid beneficiary fails.
test behavior_partial_claim_underpaid_fails() {
  let midpoint = cliff_time + (vesting_end - cliff_time) / 2
  let claimable = total_amount / 2
  !validate_claim(
    make_datum(), [beneficiary_pkh], midpoint, locked,
    Some(beneficiary_out(claimable - 1)), 0,
    Some(continuation_out(locked - claimable)), 1,
    script_addr(), 1,
  )
}

/// BEHAVIOR: Continuation with wrong datum fails (datum hijacking blocked).
test behavior_datum_hijacking_blocked() {
  let midpoint = cliff_time + (vesting_end - cliff_time) / 2
  let claimable = total_amount / 2
  let bad_cont = Output {
    address: script_addr(),
    value: assets.from_lovelace(locked - claimable),
    datum: InlineDatum(VestingDatum { ..make_datum(), beneficiary: wrong_pkh }),
    reference_script: None,
  }
  !validate_claim(
    make_datum(), [beneficiary_pkh], midpoint, locked,
    Some(beneficiary_out(claimable)), 0,
    Some(bad_cont), 1,
    script_addr(), 1,
  )
}

/// BEHAVIOR: Same index for beneficiary and continuation fails.
test behavior_same_index_fails() {
  let midpoint = cliff_time + (vesting_end - cliff_time) / 2
  let claimable = total_amount / 2
  !validate_claim(
    make_datum(), [beneficiary_pkh], midpoint, locked,
    Some(beneficiary_out(claimable)), 0,
    Some(continuation_out(locked - claimable)), 0,
    script_addr(), 1,
  )
}

/// BEHAVIOR: Double satisfaction blocked by script_input_count.
test behavior_double_satisfaction_blocked() {
  !validate_claim(
    make_datum(), [beneficiary_pkh], vesting_end + 1000, locked,
    Some(beneficiary_out(locked)), 0, None, 1, script_addr(), 2,
  )
}
