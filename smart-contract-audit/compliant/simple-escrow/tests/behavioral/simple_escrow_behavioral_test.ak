/// Simple Escrow — Behavioral Test Suite
///
/// These tests document what the contract IS DESIGNED to do.
/// All tests PASS on the original contract.
/// All tests should ALSO PASS on the compliant version.
///
/// Since the validator logic is inside a `validator` block and cannot
/// be called directly from tests, we reimplement the validation logic
/// to test it independently. This mirrors the validator exactly.

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/interval
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{Value, flatten, quantity_of}
use cardano/assets
use cardano/transaction.{NoDatum, Output}
use escrow_types.{EscrowDatum}

// ──────────────────────────────────────────────────────────────────────
// Mirror of validator logic (exact reimplementation for testing)
// ──────────────────────────────────────────────────────────────────────

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

fn validate_claim(
  d: EscrowDatum,
  secret: ByteArray,
  signatories: List<ByteArray>,
  validity_upper: Int,
  deadline: Int,
  outputs: List<Output>,
  own_value: Value,
) -> Bool {
  let secret_valid = blake2b_256(secret) == d.secret_hash
  let before_deadline = validity_upper < deadline
  let beneficiary_signed = list.has(signatories, d.beneficiary)
  let paid_to_beneficiary =
    list.any(
      outputs,
      fn(output) {
        output.address.payment_credential == VerificationKey(d.beneficiary) && assets_gte(
          output.value,
          own_value,
        )
      },
    )
  and {
    secret_valid,
    before_deadline,
    beneficiary_signed,
    paid_to_beneficiary,
  }
}

fn validate_reclaim(
  d: EscrowDatum,
  signatories: List<ByteArray>,
  validity_lower: Int,
  deadline: Int,
  outputs: List<Output>,
  own_value: Value,
) -> Bool {
  let after_deadline = validity_lower > deadline
  let sender_signed = list.has(signatories, d.sender)
  let paid_to_sender =
    list.any(
      outputs,
      fn(output) {
        output.address.payment_credential == VerificationKey(d.sender) && assets_gte(
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

// ──────────────────────────────────────────────────────────────────────
// Test constants
// ──────────────────────────────────────────────────────────────────────

const beneficiary_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const sender_pkh =
  #"1122334411223344112233441122334411223344112233441122334411223344"

const wrong_pkh =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

const secret_preimage = "super_secret_preimage"

const deadline = 1_700_000_000_000

const locked_lovelace = 10_000_000

fn make_datum() -> EscrowDatum {
  EscrowDatum {
    beneficiary: beneficiary_pkh,
    sender: sender_pkh,
    deadline,
    secret_hash: blake2b_256(secret_preimage),
  }
}

fn make_address(pkh: ByteArray) -> Address {
  Address {
    payment_credential: VerificationKey(pkh),
    stake_credential: None,
  }
}

fn beneficiary_output(lovelace: Int) -> Output {
  Output {
    address: make_address(beneficiary_pkh),
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

fn sender_output(lovelace: Int) -> Output {
  Output {
    address: make_address(sender_pkh),
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Claim happy path
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Claim succeeds with correct secret, before deadline,
/// beneficiary signed, and output pays at least locked value.
test behavior_claim_success() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret_preimage,
    [beneficiary_pkh],
    deadline - 1000,
    deadline,
    [beneficiary_output(locked_lovelace)],
    own_value,
  )
}

/// BEHAVIOR: Claim succeeds with output paying MORE than locked value.
test behavior_claim_overpay_succeeds() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    secret_preimage,
    [beneficiary_pkh],
    deadline - 1000,
    deadline,
    [beneficiary_output(locked_lovelace * 2)],
    own_value,
  )
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Claim rejection cases
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Claim fails with wrong secret.
test behavior_claim_wrong_secret_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_claim(
    d,
    "wrong_secret",
    [beneficiary_pkh],
    deadline - 1000,
    deadline,
    [beneficiary_output(locked_lovelace)],
    own_value,
  )
}

/// BEHAVIOR: Claim fails after deadline.
test behavior_claim_after_deadline_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_claim(
    d,
    secret_preimage,
    [beneficiary_pkh],
    deadline + 1000,
    deadline,
    [beneficiary_output(locked_lovelace)],
    own_value,
  )
}

/// BEHAVIOR: Claim fails without beneficiary signature.
test behavior_claim_no_signature_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_claim(
    d,
    secret_preimage,
    [],
    deadline - 1000,
    deadline,
    [beneficiary_output(locked_lovelace)],
    own_value,
  )
}

/// BEHAVIOR: Claim fails with wrong signer.
test behavior_claim_wrong_signer_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_claim(
    d,
    secret_preimage,
    [wrong_pkh],
    deadline - 1000,
    deadline,
    [beneficiary_output(locked_lovelace)],
    own_value,
  )
}

/// BEHAVIOR: Claim fails when output pays less than locked.
test behavior_claim_underpay_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_claim(
    d,
    secret_preimage,
    [beneficiary_pkh],
    deadline - 1000,
    deadline,
    [beneficiary_output(locked_lovelace - 1)],
    own_value,
  )
}

/// BEHAVIOR: Claim fails when output goes to wrong address.
test behavior_claim_wrong_recipient_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_claim(
    d,
    secret_preimage,
    [beneficiary_pkh],
    deadline - 1000,
    deadline,
    [sender_output(locked_lovelace)],
    own_value,
  )
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Reclaim happy path
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Reclaim succeeds after deadline, sender signed, output pays.
test behavior_reclaim_success() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_reclaim(
    d,
    [sender_pkh],
    deadline + 1000,
    deadline,
    [sender_output(locked_lovelace)],
    own_value,
  )
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Reclaim rejection cases
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Reclaim fails before deadline.
test behavior_reclaim_before_deadline_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_reclaim(
    d,
    [sender_pkh],
    deadline - 1000,
    deadline,
    [sender_output(locked_lovelace)],
    own_value,
  )
}

/// BEHAVIOR: Reclaim fails without sender signature.
test behavior_reclaim_no_signature_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_reclaim(
    d,
    [],
    deadline + 1000,
    deadline,
    [sender_output(locked_lovelace)],
    own_value,
  )
}

/// BEHAVIOR: Reclaim fails when output pays less than locked.
test behavior_reclaim_underpay_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_reclaim(
    d,
    [sender_pkh],
    deadline + 1000,
    deadline,
    [sender_output(locked_lovelace - 1)],
    own_value,
  )
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Deadline edge cases
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Claim fails at exact deadline (upper bound == deadline).
/// This is the "dead zone" documented in README.
test behavior_claim_at_exact_deadline_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_claim(
    d,
    secret_preimage,
    [beneficiary_pkh],
    deadline,
    deadline,
    [beneficiary_output(locked_lovelace)],
    own_value,
  )
}

/// BEHAVIOR: Reclaim fails at exact deadline (lower bound == deadline).
test behavior_reclaim_at_exact_deadline_fails() {
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_reclaim(
    d,
    [sender_pkh],
    deadline,
    deadline,
    [sender_output(locked_lovelace)],
    own_value,
  )
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: assets_gte correctness
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: assets_gte returns True when values are equal.
test behavior_assets_gte_equal() {
  let v = assets.from_lovelace(10_000_000)
  assets_gte(v, v)
}

/// BEHAVIOR: assets_gte returns True when a > b.
test behavior_assets_gte_greater() {
  let a = assets.from_lovelace(20_000_000)
  let b = assets.from_lovelace(10_000_000)
  assets_gte(a, b)
}

/// BEHAVIOR: assets_gte returns False when a < b.
test behavior_assets_gte_less() {
  let a = assets.from_lovelace(5_000_000)
  let b = assets.from_lovelace(10_000_000)
  !assets_gte(a, b)
}
