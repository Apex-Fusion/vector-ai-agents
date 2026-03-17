/// # Vesting — Unit Tests
///
/// Comprehensive test suite covering happy paths, rejection cases,
/// security invariants, and edge cases for the vesting validator.
///
/// Tests replicate the validator logic to verify correctness of each
/// validation check independently. Attack vector tests cover double
/// satisfaction, datum hijacking, output-index pinning, and single-
/// script-input enforcement — all flagged in audit reviews.
///
/// Authored by: Test Writer
/// Date: 2026-03-16

use aiken/collection/list
use aiken/interval.{Finite, Interval, IntervalBound}
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets
use cardano/assets.{lovelace_of}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, OutputReference}
use vesting_types.{Claim, VestingDatum}

// ---------------------------------------------------------------------------
// Test constants
// ---------------------------------------------------------------------------

const beneficiary_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const wrong_pkh =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

const script_hash =
  #"ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00"

const cliff_time = 1_000_000_000_000

const vesting_end_time = 2_000_000_000_000

const total_vesting_amount = 100_000_000

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_datum() -> VestingDatum {
  VestingDatum {
    beneficiary: beneficiary_pkh,
    total_vesting_amount,
    cliff_time,
    vesting_end_time,
  }
}

fn make_beneficiary_address() -> Address {
  Address {
    payment_credential: VerificationKey(beneficiary_pkh),
    stake_credential: None,
  }
}

fn make_script_address() -> Address {
  Address {
    payment_credential: Script(script_hash),
    stake_credential: None,
  }
}

fn make_wrong_address() -> Address {
  Address {
    payment_credential: VerificationKey(wrong_pkh),
    stake_credential: None,
  }
}

fn make_output(addr: Address, lovelace: Int) -> Output {
  Output {
    address: addr,
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

fn make_continuation_output(addr: Address, lovelace: Int, d: VestingDatum) -> Output {
  Output {
    address: addr,
    value: assets.from_lovelace(lovelace),
    datum: InlineDatum(d),
    reference_script: None,
  }
}

fn make_script_input(lovelace: Int) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00",
      output_index: 0,
    },
    output: Output {
      address: make_script_address(),
      value: assets.from_lovelace(lovelace),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn min_int(a: Int, b: Int) -> Int {
  if a <= b {
    a
  } else {
    b
  }
}

// ---------------------------------------------------------------------------
// Core validation logic (mirrors validator exactly)
// ---------------------------------------------------------------------------

/// Compute vested amount given current time and datum parameters.
fn compute_vested(d: VestingDatum, current_time: Int) -> Int {
  if current_time >= d.vesting_end_time {
    d.total_vesting_amount
  } else {
    let elapsed = current_time - d.cliff_time
    let duration = d.vesting_end_time - d.cliff_time
    d.total_vesting_amount * elapsed / duration
  }
}

/// Full validator logic replicated for unit testing.
/// Accepts explicit parameters that would come from a Transaction context.
fn validate_vesting(
  d: VestingDatum,
  beneficiary_index: Int,
  continuation_index: Int,
  locked_lovelace: Int,
  script_input_count: Int,
  extra_signatories: List<ByteArray>,
  current_time: Int,
  outputs: List<Output>,
  script_address: Address,
) -> Bool {
  // 0. Single script input (prevents double satisfaction — audit finding F1/F2)
  expect script_input_count == 1

  // 1. Beneficiary must sign
  let beneficiary_signed =
    list.has(extra_signatories, d.beneficiary)

  // 2. Past cliff
  let past_cliff = current_time >= d.cliff_time

  // 3. Vested amount
  let vested_amount = compute_vested(d, current_time)
  let claimable = min_int(vested_amount, locked_lovelace)

  // 4. Must remain
  let must_remain = locked_lovelace - claimable

  // 5. Beneficiary paid at pinned index
  let beneficiary_paid =
    if claimable <= 0 {
      False
    } else {
      expect Some(beneficiary_output) = list.at(outputs, beneficiary_index)
      let pays_beneficiary =
        beneficiary_output.address.payment_credential == VerificationKey(d.beneficiary)
      let enough_value = lovelace_of(beneficiary_output.value) >= claimable
      pays_beneficiary && enough_value
    }

  // 6. Continuation valid at pinned index (datum hijacking prevention)
  let continuation_valid =
    if must_remain <= 0 {
      True
    } else {
      expect Some(cont_output) = list.at(outputs, continuation_index)
      let indices_differ = beneficiary_index != continuation_index
      let address_ok = cont_output.address == script_address
      let value_ok = lovelace_of(cont_output.value) >= must_remain
      let datum_ok =
        when cont_output.datum is {
          InlineDatum(raw) -> {
            expect cont_datum: VestingDatum = raw
            cont_datum.beneficiary == d.beneficiary && cont_datum.total_vesting_amount == d.total_vesting_amount && cont_datum.cliff_time == d.cliff_time && cont_datum.vesting_end_time == d.vesting_end_time
          }
          _ -> False
        }
      and {
        indices_differ,
        address_ok,
        value_ok,
        datum_ok,
      }
    }

  and {
    beneficiary_signed,
    past_cliff,
    beneficiary_paid,
    continuation_valid,
  }
}

// ===========================================================================
// HAPPY PATH TESTS
// ===========================================================================

/// Full vesting claim: after vesting_end_time, claim everything, no continuation needed.
test claim_full_vesting() {
  let d = make_datum()
  let time = vesting_end_time + 1_000
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: time,
    outputs: [make_output(make_beneficiary_address(), total_vesting_amount)],
    script_address: make_script_address(),
  )
}

/// Partial claim at midpoint: 50% vested, claim 50%, remainder to continuation.
test claim_partial_midpoint() {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  let remainder = total_vesting_amount - vested
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
      make_continuation_output(make_script_address(), remainder, d),
    ],
    script_address: make_script_address(),
  )
}

/// Partial claim at 25%: cliff + 25% of duration.
test claim_partial_quarter() {
  let d = make_datum()
  let duration = vesting_end_time - cliff_time
  let quarter_time = cliff_time + duration / 4
  let vested = total_vesting_amount * ( duration / 4 ) / duration
  let remainder = total_vesting_amount - vested
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: quarter_time,
    outputs: [
      make_output(make_beneficiary_address(), vested),
      make_continuation_output(make_script_address(), remainder, d),
    ],
    script_address: make_script_address(),
  )
}

/// Claim exactly at cliff_time: 0% vested but past_cliff is True.
/// claimable = 0, so beneficiary_paid = False → reject.
test claim_at_exact_cliff() fail {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: cliff_time,
    outputs: [
      make_output(make_beneficiary_address(), 0),
      make_continuation_output(make_script_address(), total_vesting_amount, d),
    ],
    script_address: make_script_address(),
  )
}

/// Claim at exactly vesting_end_time: 100% vested, full claim.
test claim_at_exact_end() {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [make_output(make_beneficiary_address(), total_vesting_amount)],
    script_address: make_script_address(),
  )
}

/// Claim with overpayment to beneficiary → pass (extra lovelace is OK).
test claim_with_overpayment() {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [
      make_output(make_beneficiary_address(), total_vesting_amount + 5_000_000),
    ],
    script_address: make_script_address(),
  )
}

/// Continuation with more lovelace than must_remain → pass (extra is OK).
test continuation_overfunded() {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
      make_continuation_output(make_script_address(), total_vesting_amount, d),
    ],
    script_address: make_script_address(),
  )
}

// ===========================================================================
// REJECTION TESTS — BEFORE CLIFF
// ===========================================================================

/// Reject claim before cliff time.
test reject_before_cliff() fail {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: cliff_time - 1,
    outputs: [
      make_output(make_beneficiary_address(), total_vesting_amount),
    ],
    script_address: make_script_address(),
  )
}

/// Reject claim well before cliff.
test reject_well_before_cliff() fail {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: 0,
    outputs: [
      make_output(make_beneficiary_address(), total_vesting_amount),
    ],
    script_address: make_script_address(),
  )
}

// ===========================================================================
// REJECTION TESTS — SIGNATURE
// ===========================================================================

/// Reject without beneficiary signature.
test reject_no_signature() fail {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [],
    current_time: vesting_end_time,
    outputs: [make_output(make_beneficiary_address(), total_vesting_amount)],
    script_address: make_script_address(),
  )
}

/// Reject with wrong signer.
test reject_wrong_signer() fail {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [wrong_pkh],
    current_time: vesting_end_time,
    outputs: [make_output(make_beneficiary_address(), total_vesting_amount)],
    script_address: make_script_address(),
  )
}

// ===========================================================================
// REJECTION TESTS — BENEFICIARY PAYMENT
// ===========================================================================

/// Reject: payment to wrong address at pinned index.
test reject_payment_to_wrong_address() fail {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [make_output(make_wrong_address(), total_vesting_amount)],
    script_address: make_script_address(),
  )
}

/// Reject: insufficient payment at pinned index.
test reject_insufficient_payment() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  let remainder = total_vesting_amount - vested
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested - 1),
      make_continuation_output(make_script_address(), remainder + 1, d),
    ],
    script_address: make_script_address(),
  )
}

/// Reject: beneficiary index out of bounds.
test reject_beneficiary_index_out_of_bounds() fail {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 5,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [make_output(make_beneficiary_address(), total_vesting_amount)],
    script_address: make_script_address(),
  )
}

// ===========================================================================
// CONTINUATION UTxO ENFORCEMENT (datum hijacking prevention)
// ===========================================================================

/// Reject: partial claim with no continuation output.
test reject_partial_no_continuation() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
    ],
    script_address: make_script_address(),
  )
}

/// Reject: continuation at wrong address.
test reject_continuation_wrong_address() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  let remainder = total_vesting_amount - vested
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
      make_continuation_output(make_wrong_address(), remainder, d),
    ],
    script_address: make_script_address(),
  )
}

/// Reject: continuation with insufficient value.
test reject_continuation_insufficient_value() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  let remainder = total_vesting_amount - vested
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
      make_continuation_output(make_script_address(), remainder - 1, d),
    ],
    script_address: make_script_address(),
  )
}

/// Reject: continuation with NoDatum (datum hijacking — audit finding: continuation
/// UTxO check was global in v1, fixed in v3).
test reject_continuation_no_datum() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  let remainder = total_vesting_amount - vested
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
      make_output(make_script_address(), remainder),
    ],
    script_address: make_script_address(),
  )
}

/// Reject: continuation with altered datum (different beneficiary — datum hijacking).
test reject_continuation_altered_beneficiary() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  let remainder = total_vesting_amount - vested
  let altered_datum =
    VestingDatum { ..d, beneficiary: wrong_pkh }
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
      make_continuation_output(make_script_address(), remainder, altered_datum),
    ],
    script_address: make_script_address(),
  )
}

/// Reject: continuation with altered datum (different cliff_time).
test reject_continuation_altered_cliff() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  let remainder = total_vesting_amount - vested
  let altered_datum =
    VestingDatum { ..d, cliff_time: cliff_time - 100_000 }
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
      make_continuation_output(make_script_address(), remainder, altered_datum),
    ],
    script_address: make_script_address(),
  )
}

/// Reject: continuation with altered datum (different vesting_end_time).
test reject_continuation_altered_end() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  let remainder = total_vesting_amount - vested
  let altered_datum =
    VestingDatum { ..d, vesting_end_time: vesting_end_time + 500_000 }
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
      make_continuation_output(make_script_address(), remainder, altered_datum),
    ],
    script_address: make_script_address(),
  )
}

/// Reject: continuation with altered datum (different total_vesting_amount).
test reject_continuation_altered_total() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  let remainder = total_vesting_amount - vested
  let altered_datum =
    VestingDatum { ..d, total_vesting_amount: total_vesting_amount * 2 }
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
      make_continuation_output(make_script_address(), remainder, altered_datum),
    ],
    script_address: make_script_address(),
  )
}

// ===========================================================================
// OUTPUT-INDEX PINNING (audit findings: double satisfaction prevention)
// ===========================================================================

/// Reject: beneficiary_index == continuation_index (self-satisfaction).
test reject_same_indices() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  let remainder = total_vesting_amount - vested
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 0,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_continuation_output(make_script_address(), total_vesting_amount, d),
    ],
    script_address: make_script_address(),
  )
}

/// Reject: continuation_index out of bounds.
test reject_continuation_index_out_of_bounds() fail {
  let d = make_datum()
  let midpoint = cliff_time + ( vesting_end_time - cliff_time ) / 2
  let vested = total_vesting_amount / 2
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 99,
    locked_lovelace: total_vesting_amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: midpoint,
    outputs: [
      make_output(make_beneficiary_address(), vested),
    ],
    script_address: make_script_address(),
  )
}

// ===========================================================================
// SINGLE SCRIPT INPUT ENFORCEMENT (critical fix for double satisfaction)
// ===========================================================================

/// Reject: two script inputs (double satisfaction attempt).
/// Audit finding: global output scanning in v1 enabled double satisfaction;
/// fixed in v3 via single-script-input constraint.
test reject_double_satisfaction_two_inputs() fail {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 2,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [make_output(make_beneficiary_address(), total_vesting_amount)],
    script_address: make_script_address(),
  )
}

/// Reject: three script inputs.
test reject_triple_script_inputs() fail {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 3,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [make_output(make_beneficiary_address(), total_vesting_amount)],
    script_address: make_script_address(),
  )
}

/// Reject: zero script inputs (impossible in practice, but defensive).
test reject_zero_script_inputs() fail {
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: 0,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [make_output(make_beneficiary_address(), total_vesting_amount)],
    script_address: make_script_address(),
  )
}

// ===========================================================================
// EDGE CASES — VESTING COMPUTATION
// ===========================================================================

/// Vested amount is conservative: integer truncation favors contract.
/// Audit finding: integer division truncation is conservative (intended).
test vesting_truncation_conservative() {
  let d = make_datum()
  let duration = vesting_end_time - cliff_time
  let one_third_time = cliff_time + duration / 3
  let vested = compute_vested(d, one_third_time)
  vested == 33_333_333
}

/// After vesting_end_time: full amount regardless of how far past.
test vesting_full_after_end() {
  let d = make_datum()
  compute_vested(d, vesting_end_time + 999_999_999_999) == total_vesting_amount
}

/// At cliff: vested = 0 (elapsed = 0).
test vesting_zero_at_cliff() {
  let d = make_datum()
  compute_vested(d, cliff_time) == 0
}

/// Just after cliff: vested is tiny but positive (1ms past cliff).
test vesting_tiny_after_cliff() {
  let d = make_datum()
  let vested = compute_vested(d, cliff_time + 1)
  // 100_000_000 * 1 / 1_000_000_000_000 = 0 (truncated)
  vested == 0
}

/// Degenerate: vesting_end_time == cliff_time → full vesting at cliff (time-lock).
/// Audit finding: degenerate datum parameters not validated on-chain.
test degenerate_end_equals_cliff() {
  let d =
    VestingDatum {
      beneficiary: beneficiary_pkh,
      total_vesting_amount,
      cliff_time,
      vesting_end_time: cliff_time,
    }
  compute_vested(d, cliff_time) == total_vesting_amount
}

/// Degenerate: vesting_end_time < cliff_time → full vesting once past cliff.
test degenerate_end_before_cliff() {
  let d =
    VestingDatum {
      beneficiary: beneficiary_pkh,
      total_vesting_amount,
      cliff_time,
      vesting_end_time: cliff_time - 1_000,
    }
  compute_vested(d, cliff_time) == total_vesting_amount
}

// ===========================================================================
// EDGE CASES — LOCKED > TOTAL (audit finding: total_vesting_amount vs
// actual locked value mismatch requiring 2-TX withdrawal)
// ===========================================================================

/// When locked > total_vesting_amount, claimable is capped at total after full vesting.
/// Must_remain > 0, so continuation is needed (2-TX withdrawal).
test excess_lovelace_requires_continuation() {
  let d = make_datum()
  let locked = total_vesting_amount + 50_000_000
  let vested = compute_vested(d, vesting_end_time)
  let claimable = min_int(vested, locked)
  let must_remain = locked - claimable
  and {
    claimable == total_vesting_amount,
    must_remain == 50_000_000,
  }
}

/// Full claim with excess: beneficiary gets total, continuation gets remainder.
test claim_with_excess_lovelace() {
  let d = make_datum()
  let locked = total_vesting_amount + 50_000_000
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: locked,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [
      make_output(make_beneficiary_address(), total_vesting_amount),
      make_continuation_output(make_script_address(), 50_000_000, d),
    ],
    script_address: make_script_address(),
  )
}

// ===========================================================================
// EDGE CASE — DEGENERATE DATUMS
// ===========================================================================

/// Zero total_vesting_amount → claimable = 0, beneficiary_paid = False → reject.
/// Audit finding: degenerate datums create permanently unspendable UTxOs.
test reject_zero_total_vesting_amount() fail {
  let d =
    VestingDatum {
      beneficiary: beneficiary_pkh,
      total_vesting_amount: 0,
      cliff_time,
      vesting_end_time,
    }
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: 2_000_000,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [make_output(make_beneficiary_address(), 2_000_000)],
    script_address: make_script_address(),
  )
}

/// Negative total_vesting_amount → same as zero, always rejects.
test reject_negative_total_vesting_amount() fail {
  let d =
    VestingDatum {
      beneficiary: beneficiary_pkh,
      total_vesting_amount: -100,
      cliff_time,
      vesting_end_time,
    }
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: 2_000_000,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [make_output(make_beneficiary_address(), 2_000_000)],
    script_address: make_script_address(),
  )
}
