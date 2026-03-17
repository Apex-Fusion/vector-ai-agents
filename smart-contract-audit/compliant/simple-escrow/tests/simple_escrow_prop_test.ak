/// # Simple Escrow — Property-Based Tests
///
/// Property tests using Aiken's fuzz framework to verify
/// invariants hold across random inputs.
///
/// Authored by: Test Writer
/// Date: 2026-03-16

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/fuzz
use aiken/interval
use cardano/address.{Address, VerificationKey}
use cardano/assets.{Value, flatten, quantity_of}
use cardano/transaction.{NoDatum, Output}
use escrow_types.{EscrowDatum}

// ---------------------------------------------------------------------------
// Reimplementation of assets_gte
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
// Constants
// ---------------------------------------------------------------------------

const beneficiary_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const sender_pkh =
  #"11223344112233441122334411223344112233441122334411223344"

const deadline = 1_700_000_000_000

const locked_lovelace = 2_000_000

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_address(pkh: ByteArray) -> Address {
  Address {
    payment_credential: VerificationKey(pkh),
    stake_credential: None,
  }
}

fn make_output(pkh: ByteArray, lovelace: Int) -> Output {
  Output {
    address: make_address(pkh),
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

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

// ===========================================================================
// PROPERTY 1: Random valid secrets always pass Claim
// ===========================================================================

test prop_any_secret_claim_works(random_secret via fuzz.bytearray()) {
  let secret_hash = blake2b_256(random_secret)
  let d =
    EscrowDatum {
      beneficiary: beneficiary_pkh,
      sender: sender_pkh,
      deadline,
      secret_hash,
    }
  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    random_secret,
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, locked_lovelace)],
    interval.entirely_before(deadline),
  )
}

// ===========================================================================
// PROPERTY 2: Random wrong secrets always fail hash check
// ===========================================================================

test prop_wrong_secret_hash_fails(
  (correct, wrong) via fuzz.both(fuzz.bytearray(), fuzz.bytearray()),
) {
  if correct == wrong {
    // Skip — same value, trivially passes
    True
  } else {
    // Different bytearrays should produce different hashes (no collision)
    blake2b_256(wrong) != blake2b_256(correct)
  }
}

// ===========================================================================
// PROPERTY 3: assets_gte is reflexive
// ===========================================================================

test prop_assets_gte_reflexive(amount via fuzz.int()) {
  let clamped =
    if amount < 0 {
      0
    } else if amount > 1_000_000_000_000 {
      1_000_000_000_000
    } else {
      amount
    }
  let v = assets.from_lovelace(clamped)
  assets_gte(v, v)
}

// ===========================================================================
// PROPERTY 4: assets_gte — larger always >= smaller
// ===========================================================================

test prop_assets_gte_monotonic(
  (a, b) via fuzz.both(fuzz.int(), fuzz.int()),
) {
  let clamp = fn(n) {
      if n < 0 {
        -n % 1_000_000_000
      } else {
        n % 1_000_000_000
      }
    }
  let x = clamp(a)
  let y = clamp(b)
  let big =
    if x >= y {
      x
    } else {
      y
    }
  let small =
    if x >= y {
      y
    } else {
      x
    }
  assets_gte(assets.from_lovelace(big), assets.from_lovelace(small))
}
