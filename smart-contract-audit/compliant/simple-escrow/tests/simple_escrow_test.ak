/// # Simple Escrow — Unit Tests
///
/// Comprehensive test suite covering happy paths, rejection cases,
/// and edge cases for the simple_escrow validator.
///
/// Tests replicate the validator logic to verify correctness of each
/// validation check independently.
///
/// Authored by: Test Writer
/// Date: 2026-03-16

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/interval
use cardano/address.{Address, VerificationKey}
use cardano/assets.{Value, flatten, quantity_of}
use cardano/transaction.{NoDatum, Output}
use escrow_types.{EscrowDatum}

// ---------------------------------------------------------------------------
// Reimplementation of assets_gte (mirrors validator logic exactly)
// ---------------------------------------------------------------------------

fn assets_gte(a: Value, b: Value) -> Bool {
  let flat_b = flatten(b)
  list.all(
    flat_b,
    fn(entry) {
      let (policy, name, qty) = entry
      quantity_of(a, policy, name) >= qty
    },
  )
}

// ---------------------------------------------------------------------------
// Test constants
// ---------------------------------------------------------------------------

const beneficiary_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const sender_pkh =
  #"11223344112233441122334411223344112233441122334411223344"

const wrong_pkh =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

const secret = "super_secret_preimage"

const deadline = 1_700_000_000_000

// 2 ADA in lovelace
const locked_lovelace = 2_000_000

// ---------------------------------------------------------------------------
// Helper: build a standard EscrowDatum
// ---------------------------------------------------------------------------

fn make_datum() -> EscrowDatum {
  EscrowDatum {
    beneficiary: beneficiary_pkh,
    sender: sender_pkh,
    deadline,
    secret_hash: blake2b_256(secret),
  }
}

// ---------------------------------------------------------------------------
// Helper: build an Address from a pkh
// ---------------------------------------------------------------------------

fn make_address(pkh: ByteArray) -> Address {
  Address {
    payment_credential: VerificationKey(pkh),
    stake_credential: None,
  }
}

// ---------------------------------------------------------------------------
// Claim validation logic (mirrors the validator's Claim path exactly)
// ---------------------------------------------------------------------------

fn validate_claim(
  datum: EscrowDatum,
  secret_bytes: ByteArray,
  own_value: Value,
  signatories: List<ByteArray>,
  outputs: List<Output>,
  validity_range: interval.Interval,
) -> Bool {
  let secret_valid = blake2b_256(secret_bytes) == datum.secret_hash

  let before_deadline =
    interval.is_entirely_before(validity_range, datum.deadline)

  let beneficiary_signed = list.has(signatories, datum.beneficiary)

  let paid_to_beneficiary =
    list.any(
      outputs,
      fn(output) {
        output.address.payment_credential == VerificationKey(
          datum.beneficiary,
        ) && assets_gte(output.value, own_value)
      },
    )

  and {
    secret_valid,
    before_deadline,
    beneficiary_signed,
    paid_to_beneficiary,
  }
}

// ---------------------------------------------------------------------------
// Reclaim validation logic (mirrors the validator's Reclaim path exactly)
// ---------------------------------------------------------------------------

fn validate_reclaim(
  datum: EscrowDatum,
  own_value: Value,
  signatories: List<ByteArray>,
  outputs: List<Output>,
  validity_range: interval.Interval,
) -> Bool {
  let after_deadline =
    interval.is_entirely_after(validity_range, datum.deadline)

  let sender_signed = list.has(signatories, datum.sender)

  let paid_to_sender =
    list.any(
      outputs,
      fn(output) {
        output.address.payment_credential == VerificationKey(datum.sender) && assets_gte(
          output.value,
          own_value,
        )
      },
    )

  and {
    after_deadline,
    sender_signed,
    paid_to_sender,
  }
}

// ---------------------------------------------------------------------------
// Helper: make an output paying lovelace to a pkh
// ---------------------------------------------------------------------------

fn make_output(pkh: ByteArray, lovelace: Int) -> Output {
  Output {
    address: make_address(pkh),
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

// ===========================================================================
// HAPPY PATH TESTS
// ===========================================================================

/// Claim: correct secret + beneficiary signature + before deadline → pass
test claim_happy_path() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, locked_lovelace)],
    interval.before(deadline - 1_000),
  )
}

/// Claim with overpayment → pass (beneficiary gets more than locked)
test claim_overpayment() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, locked_lovelace + 1_000_000)],
    interval.before(deadline - 1_000),
  )
}

/// Reclaim: sender signature + after deadline → pass
test reclaim_happy_path() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_reclaim(
    d,
    own_value,
    [sender_pkh],
    [make_output(sender_pkh, locked_lovelace)],
    interval.after(deadline + 1_000),
  )
}

// ===========================================================================
// REJECTION TESTS — SECRET
// ===========================================================================

/// Claim with WRONG secret → must fail
test claim_wrong_secret() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    "wrong_secret",
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, locked_lovelace)],
    interval.before(deadline - 1_000),
  )
}

/// Claim with empty secret → must fail
test claim_empty_secret() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    "",
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, locked_lovelace)],
    interval.before(deadline - 1_000),
  )
}

// ===========================================================================
// REJECTION TESTS — WRONG SIGNER
// ===========================================================================

/// Claim signed by wrong party (not beneficiary) → must fail
test claim_wrong_signer() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [wrong_pkh],
    [make_output(beneficiary_pkh, locked_lovelace)],
    interval.before(deadline - 1_000),
  )
}

/// Claim signed by sender (not beneficiary) → must fail
test claim_sender_signs_instead() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [sender_pkh],
    [make_output(beneficiary_pkh, locked_lovelace)],
    interval.before(deadline - 1_000),
  )
}

/// Claim with no signatories → must fail
test claim_no_signatories() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [],
    [make_output(beneficiary_pkh, locked_lovelace)],
    interval.before(deadline - 1_000),
  )
}

/// Reclaim signed by wrong party (not sender) → must fail
test reclaim_wrong_signer() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_reclaim(
    d,
    own_value,
    [wrong_pkh],
    [make_output(sender_pkh, locked_lovelace)],
    interval.after(deadline + 1_000),
  )
}

/// Reclaim signed by beneficiary (not sender) → must fail
test reclaim_beneficiary_signs_instead() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_reclaim(
    d,
    own_value,
    [beneficiary_pkh],
    [make_output(sender_pkh, locked_lovelace)],
    interval.after(deadline + 1_000),
  )
}

// ===========================================================================
// REJECTION TESTS — DEADLINE / TIMING
// ===========================================================================

/// Claim AFTER deadline → must fail
test claim_after_deadline() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, locked_lovelace)],
    interval.after(deadline + 1_000),
  )
}

/// Reclaim BEFORE deadline → must fail
test reclaim_before_deadline() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_reclaim(
    d,
    own_value,
    [sender_pkh],
    [make_output(sender_pkh, locked_lovelace)],
    interval.before(deadline - 1_000),
  )
}

/// Claim at exact deadline boundary (dead zone — Reviewer Finding 3)
test claim_at_exact_deadline() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, locked_lovelace)],
    interval.before(deadline),
  )
}

/// Reclaim at exact deadline (dead zone — Reviewer Finding 3)
test reclaim_at_exact_deadline() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_reclaim(
    d,
    own_value,
    [sender_pkh],
    [make_output(sender_pkh, locked_lovelace)],
    interval.after(deadline),
  )
}

// ===========================================================================
// REJECTION TESTS — VALUE NOT SENT TO CORRECT ADDRESS
// ===========================================================================

/// Claim: value sent to wrong address → must fail
test claim_paid_to_wrong_address() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [beneficiary_pkh],
    [make_output(wrong_pkh, locked_lovelace)],
    interval.before(deadline - 1_000),
  )
}

/// Reclaim: value sent to wrong address → must fail
test reclaim_paid_to_wrong_address() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_reclaim(
    d,
    own_value,
    [sender_pkh],
    [make_output(wrong_pkh, locked_lovelace)],
    interval.after(deadline + 1_000),
  )
}

/// Claim: insufficient value → must fail
test claim_insufficient_value() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, locked_lovelace / 2)],
    interval.before(deadline - 1_000),
  )
}

/// Reclaim: insufficient value → must fail
test reclaim_insufficient_value() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_reclaim(
    d,
    own_value,
    [sender_pkh],
    [make_output(sender_pkh, locked_lovelace / 2)],
    interval.after(deadline + 1_000),
  )
}

/// Claim: zero value output → must fail
test claim_zero_value() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, 0)],
    interval.before(deadline - 1_000),
  )
}

/// Claim: no outputs at all → must fail
test claim_no_outputs() fail {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret,
    own_value,
    [beneficiary_pkh],
    [],
    interval.before(deadline - 1_000),
  )
}

// ===========================================================================
// ASSETS_GTE HELPER TESTS
// ===========================================================================

/// Zero >= Zero → true
test assets_gte_zero_zero() {
  assets_gte(assets.zero, assets.zero)
}

/// Positive >= Zero → true
test assets_gte_positive_zero() {
  assets_gte(assets.from_lovelace(1_000_000), assets.zero)
}

/// Zero >= Positive → false
test assets_gte_zero_positive() fail {
  assets_gte(assets.zero, assets.from_lovelace(1_000_000))
}

/// Equal values → true
test assets_gte_equal() {
  assets_gte(
    assets.from_lovelace(2_000_000),
    assets.from_lovelace(2_000_000),
  )
}

/// Greater >= lesser → true
test assets_gte_greater() {
  assets_gte(
    assets.from_lovelace(3_000_000),
    assets.from_lovelace(2_000_000),
  )
}

/// Lesser >= greater → false
test assets_gte_lesser() fail {
  assets_gte(
    assets.from_lovelace(1_000_000),
    assets.from_lovelace(2_000_000),
  )
}

// ===========================================================================
// DOUBLE SATISFACTION (Reviewer Finding 1)
// ===========================================================================

/// Documents the known double satisfaction vulnerability:
/// Two escrow UTxOs same beneficiary — single output satisfies both.
test double_satisfaction_vulnerability_documented() {
  let d = make_datum()
  let own_value_a = assets.from_lovelace(2_000_000)
  let own_value_b = assets.from_lovelace(1_000_000)

  let outputs = [make_output(beneficiary_pkh, 2_000_000)]
  let signatories = [beneficiary_pkh]
  let vrange = interval.before(deadline - 1_000)

  // Both validations pass against the SAME outputs
  let check_a =
    validate_claim(d, secret, own_value_a, signatories, outputs, vrange)
  let check_b =
    validate_claim(d, secret, own_value_b, signatories, outputs, vrange)

  // Vulnerability: both pass despite only 2 ADA output (should need 3 ADA total)
  and {
    check_a,
    check_b,
  }
}
