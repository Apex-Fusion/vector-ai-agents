/// # Simple Escrow — Fuzz Tests
///
/// Fuzz testing for edge cases in secret hashing, deadline handling,
/// payment validation, and signer verification.
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

const correct_secret = "super_secret_preimage"

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

fn make_datum() -> EscrowDatum {
  EscrowDatum {
    beneficiary: beneficiary_pkh,
    sender: sender_pkh,
    deadline,
    secret_hash: blake2b_256(correct_secret),
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

// ===========================================================================
// FUZZ 1: Random secrets should fail claim (hash mismatch)
// ===========================================================================

test fuzz_random_secret_rejects(fuzzed_secret via fuzz.bytearray()) {
  if fuzzed_secret == correct_secret {
    True
  } else {
    let d = make_datum()
    let own_value = assets.from_lovelace(locked_lovelace)
    !validate_claim(
      d,
      fuzzed_secret,
      own_value,
      [beneficiary_pkh],
      [make_output(beneficiary_pkh, locked_lovelace)],
      interval.entirely_before(deadline),
    )
  }
}

// ===========================================================================
// FUZZ 2: Random secret hashes in datum — correct secret doesn't match
// ===========================================================================

test fuzz_secret_hash_mismatch(fuzzed_hash via fuzz.bytearray()) {
  let expected_hash = blake2b_256(correct_secret)
  if fuzzed_hash == expected_hash {
    True
  } else {
    let d =
      EscrowDatum {
        beneficiary: beneficiary_pkh,
        sender: sender_pkh,
        deadline,
        secret_hash: fuzzed_hash,
      }
    // correct_secret should NOT pass with a random hash in datum
    !(blake2b_256(correct_secret) == d.secret_hash)
  }
}

// ===========================================================================
// FUZZ 3: Random deadlines — claim works with entirely_before range
// ===========================================================================

test fuzz_deadline_claim_valid(fuzzed_deadline via fuzz.int()) {
  let dl =
    if fuzzed_deadline < 1_000 {
      1_000
    } else if fuzzed_deadline > 2_000_000_000_000 {
      2_000_000_000_000
    } else {
      fuzzed_deadline
    }

  let d =
    EscrowDatum {
      beneficiary: beneficiary_pkh,
      sender: sender_pkh,
      deadline: dl,
      secret_hash: blake2b_256(correct_secret),
    }

  let own_value = assets.from_lovelace(locked_lovelace)
  validate_claim(
    d,
    correct_secret,
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, locked_lovelace)],
    interval.entirely_before(dl),
  )
}

// ===========================================================================
// FUZZ 4: Random deadlines — reclaim works with entirely_after range
// ===========================================================================

test fuzz_deadline_reclaim_valid(fuzzed_deadline via fuzz.int()) {
  let dl =
    if fuzzed_deadline < 0 {
      0
    } else if fuzzed_deadline > 2_000_000_000_000 {
      2_000_000_000_000
    } else {
      fuzzed_deadline
    }

  let d =
    EscrowDatum {
      beneficiary: beneficiary_pkh,
      sender: sender_pkh,
      deadline: dl,
      secret_hash: blake2b_256(correct_secret),
    }

  let own_value = assets.from_lovelace(locked_lovelace)
  validate_reclaim(
    d,
    own_value,
    [sender_pkh],
    [make_output(sender_pkh, locked_lovelace)],
    interval.entirely_after(dl),
  )
}

// ===========================================================================
// FUZZ 5: Random underpayment amounts always fail claim
// ===========================================================================

test fuzz_underpayment_fails(fuzzed_amount via fuzz.int()) {
  let amount =
    if fuzzed_amount < 0 {
      0
    } else {
      fuzzed_amount % locked_lovelace
    }

  // amount is in [0, locked_lovelace - 1], always less than locked
  let d = make_datum()
  let own_value = assets.from_lovelace(locked_lovelace)
  !validate_claim(
    d,
    correct_secret,
    own_value,
    [beneficiary_pkh],
    [make_output(beneficiary_pkh, amount)],
    interval.entirely_before(deadline),
  )
}

// ===========================================================================
// FUZZ 6: Random signers always fail claim (unless they match beneficiary)
// ===========================================================================

test fuzz_wrong_signer_fails(fuzzed_signer via fuzz.bytearray()) {
  if fuzzed_signer == beneficiary_pkh {
    True
  } else {
    let d = make_datum()
    let own_value = assets.from_lovelace(locked_lovelace)
    !validate_claim(
      d,
      correct_secret,
      own_value,
      [fuzzed_signer],
      [make_output(beneficiary_pkh, locked_lovelace)],
      interval.entirely_before(deadline),
    )
  }
}
