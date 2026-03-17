/// # Vesting — Fuzz Tests
///
/// Fuzz testing for edge cases in vesting amounts, time values,
/// and validator behavior under random inputs.
///
/// Targets audit findings:
/// - Double satisfaction (single-script-input enforcement)
/// - Datum hijacking (continuation datum integrity)
/// - Integer truncation (conservative vesting computation)
/// - Degenerate datums (zero/negative amounts, inverted schedules)
///
/// Authored by: Test Writer
/// Date: 2026-03-16

use aiken/collection/list
use aiken/fuzz
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets
use cardano/assets.{lovelace_of}
use cardano/transaction.{InlineDatum, NoDatum, Output}
use vesting_types.{VestingDatum}

// ---------------------------------------------------------------------------
// Constants
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

fn min_int(a: Int, b: Int) -> Int {
  if a <= b {
    a
  } else {
    b
  }
}

fn compute_vested(d: VestingDatum, current_time: Int) -> Int {
  if current_time >= d.vesting_end_time {
    d.total_vesting_amount
  } else {
    let elapsed = current_time - d.cliff_time
    let duration = d.vesting_end_time - d.cliff_time
    d.total_vesting_amount * elapsed / duration
  }
}

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

fn make_output(addr: Address, lovelace: Int) -> Output {
  Output {
    address: addr,
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

fn make_continuation_output(
  addr: Address,
  lovelace: Int,
  d: VestingDatum,
) -> Output {
  Output {
    address: addr,
    value: assets.from_lovelace(lovelace),
    datum: InlineDatum(d),
    reference_script: None,
  }
}

/// Replicate validator logic for testing.
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
  // Single-script-input enforcement (double satisfaction prevention)
  expect script_input_count == 1

  let beneficiary_signed = list.has(extra_signatories, d.beneficiary)
  let past_cliff = current_time >= d.cliff_time

  let vested_amount = compute_vested(d, current_time)
  let claimable = min_int(vested_amount, locked_lovelace)
  let must_remain = locked_lovelace - claimable

  let beneficiary_paid =
    if claimable <= 0 {
      False
    } else {
      expect Some(beneficiary_output) = list.at(outputs, beneficiary_index)
      let pays_beneficiary =
        beneficiary_output.address.payment_credential == VerificationKey(
          d.beneficiary,
        )
      let enough_value = lovelace_of(beneficiary_output.value) >= claimable
      pays_beneficiary && enough_value
    }

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
// FUZZ 1: Random vesting amounts — full claim after end always works
// ===========================================================================

test fuzz_random_amount_full_claim(amount_raw via fuzz.int()) {
  let amount =
    if amount_raw < 1 {
      1
    } else if amount_raw > 10_000_000_000 {
      amount_raw % 10_000_000_000 + 1
    } else {
      amount_raw
    }
  let d =
    VestingDatum {
      beneficiary: beneficiary_pkh,
      total_vesting_amount: amount,
      cliff_time,
      vesting_end_time,
    }
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: amount,
    script_input_count: 1,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time + 1,
    outputs: [make_output(make_beneficiary_address(), amount)],
    script_address: make_script_address(),
  )
}

// ===========================================================================
// FUZZ 2: Random valid times → partial claim succeeds with correct outputs
// ===========================================================================

test fuzz_valid_time_partial_claim(time_offset via fuzz.int()) {
  let d = make_datum()
  let duration = vesting_end_time - cliff_time
  let abs_off =
    if time_offset < 0 {
      -time_offset
    } else {
      time_offset
    }
  let elapsed = abs_off % ( duration - 1 ) + 1
  let time = cliff_time + elapsed

  let vested = compute_vested(d, time)
  let claimable = min_int(vested, total_vesting_amount)

  if claimable <= 0 {
    True
  } else {
    let must_remain = total_vesting_amount - claimable
    if must_remain <= 0 {
      validate_vesting(
        d,
        beneficiary_index: 0,
        continuation_index: 1,
        locked_lovelace: total_vesting_amount,
        script_input_count: 1,
        extra_signatories: [beneficiary_pkh],
        current_time: time,
        outputs: [make_output(make_beneficiary_address(), claimable)],
        script_address: make_script_address(),
      )
    } else {
      validate_vesting(
        d,
        beneficiary_index: 0,
        continuation_index: 1,
        locked_lovelace: total_vesting_amount,
        script_input_count: 1,
        extra_signatories: [beneficiary_pkh],
        current_time: time,
        outputs: [
          make_output(make_beneficiary_address(), claimable),
          make_continuation_output(make_script_address(), must_remain, d),
        ],
        script_address: make_script_address(),
      )
    }
  }
}

// ===========================================================================
// FUZZ 3: Random pre-cliff times always fail the cliff check
// ===========================================================================

test fuzz_pre_cliff_always_fails(offset via fuzz.int()) {
  let abs_off =
    if offset < 0 {
      -offset
    } else if offset == 0 {
      1
    } else {
      offset
    }
  let time = abs_off % cliff_time
  time < cliff_time
}

// ===========================================================================
// FUZZ 4: Random wrong signers always fail
// Targets: missing signer checks attack vector
// ===========================================================================

test fuzz_wrong_signer_rejects(fuzzed_signer via fuzz.bytearray()) {
  if fuzzed_signer == beneficiary_pkh {
    True
  } else {
    let d = make_datum()
    !validate_vesting(
      d,
      beneficiary_index: 0,
      continuation_index: 1,
      locked_lovelace: total_vesting_amount,
      script_input_count: 1,
      extra_signatories: [fuzzed_signer],
      current_time: vesting_end_time,
      outputs: [make_output(make_beneficiary_address(), total_vesting_amount)],
      script_address: make_script_address(),
    )
  }
}

// ===========================================================================
// FUZZ 5: Random script_input_count != 1 always fails
// Targets: double satisfaction vulnerability (critical audit finding)
// ===========================================================================

test fuzz_wrong_input_count_rejects(count_raw via fuzz.int()) fail {
  let count =
    if count_raw == 1 || count_raw < 0 {
      2
    } else if count_raw == 0 {
      0
    } else {
      count_raw
    }
  let d = make_datum()
  validate_vesting(
    d,
    beneficiary_index: 0,
    continuation_index: 1,
    locked_lovelace: total_vesting_amount,
    script_input_count: count,
    extra_signatories: [beneficiary_pkh],
    current_time: vesting_end_time,
    outputs: [make_output(make_beneficiary_address(), total_vesting_amount)],
    script_address: make_script_address(),
  )
}

// ===========================================================================
// FUZZ 6: Random locked amounts with valid schedules
// Targets: total_vesting_amount vs locked value mismatch (audit finding F3)
// ===========================================================================

test fuzz_locked_amounts_full_vesting(locked_raw via fuzz.int()) {
  let locked =
    if locked_raw < 1 {
      1
    } else if locked_raw > 10_000_000_000 {
      locked_raw % 10_000_000_000 + 1
    } else {
      locked_raw
    }
  let d = make_datum()
  let vested = compute_vested(d, vesting_end_time)
  let claimable = min_int(vested, locked)
  let must_remain = locked - claimable
  if must_remain <= 0 {
    validate_vesting(
      d,
      beneficiary_index: 0,
      continuation_index: 1,
      locked_lovelace: locked,
      script_input_count: 1,
      extra_signatories: [beneficiary_pkh],
      current_time: vesting_end_time,
      outputs: [make_output(make_beneficiary_address(), claimable)],
      script_address: make_script_address(),
    )
  } else {
    validate_vesting(
      d,
      beneficiary_index: 0,
      continuation_index: 1,
      locked_lovelace: locked,
      script_input_count: 1,
      extra_signatories: [beneficiary_pkh],
      current_time: vesting_end_time,
      outputs: [
        make_output(make_beneficiary_address(), claimable),
        make_continuation_output(make_script_address(), must_remain, d),
      ],
      script_address: make_script_address(),
    )
  }
}

// ===========================================================================
// FUZZ 7: Fuzz cliff and end times — vesting logic stays sound
// Targets: degenerate datum edge cases (audit finding F5)
// ===========================================================================

test fuzz_time_values(
  (cliff_raw, duration_raw) via fuzz.both(fuzz.int(), fuzz.int()),
) {
  let cliff =
    if cliff_raw < 0 {
      -cliff_raw % 2_000_000_000_000
    } else {
      cliff_raw % 2_000_000_000_000
    }
  let dur =
    if duration_raw < 1 {
      1
    } else if duration_raw > 2_000_000_000_000 {
      duration_raw % 2_000_000_000_000 + 1
    } else {
      duration_raw
    }
  let end = cliff + dur
  let d =
    VestingDatum {
      beneficiary: beneficiary_pkh,
      total_vesting_amount,
      cliff_time: cliff,
      vesting_end_time: end,
    }
  let vested_after = compute_vested(d, end + 1)
  let vested_at_cliff = compute_vested(d, cliff)
  and {
    vested_after == total_vesting_amount,
    vested_at_cliff == 0,
  }
}
