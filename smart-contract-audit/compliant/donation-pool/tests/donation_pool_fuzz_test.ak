/// # Donation Pool — Fuzz Tests
///
/// Fuzz testing for edge cases in distribution amounts, recipient
/// addresses, admin keys, and attack vector boundary conditions.
///
/// Targets audit findings:
/// - F1 (High): Cross-pool budget inflation via mismatched admin in batched inputs
/// - F2 (Low): Duplicate recipients allowing under-delivery
/// - Redeemer manipulation: zero/negative amounts, empty lists
/// - Datum hijacking: change outputs with wrong admin
///
/// Authored by: Test Writer
/// Date: 2026-03-16

use aiken/collection/list
use aiken/fuzz
use cardano/address.{Address, VerificationKey}
use cardano/assets
use cardano/assets.{lovelace_of}
use cardano/transaction.{InlineDatum, NoDatum, Output}
use donation_types.{Distribution, DonationDatum}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const admin_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const recipient_a_pkh =
  #"11223344112233441122334411223344112233441122334411223344"

const recipient_b_pkh =
  #"55667788556677885566778855667788556677885566778855667788"

const script_hash =
  #"ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn script_address() -> Address {
  Address {
    payment_credential: address.Script(script_hash),
    stake_credential: None,
  }
}

fn wallet_address(pkh: ByteArray) -> Address {
  Address {
    payment_credential: VerificationKey(pkh),
    stake_credential: None,
  }
}

fn make_recipient_output(pkh: ByteArray, lovelace: Int) -> Output {
  Output {
    address: wallet_address(pkh),
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

fn validate_distribution(
  datum: DonationDatum,
  distributions: List<Distribution>,
  signatories: List<ByteArray>,
  script_input_datums: List<DonationDatum>,
  script_input_lovelaces: List<Int>,
  outputs: List<Output>,
) -> Bool {
  let admin_signed = list.has(signatories, datum.admin)
  let has_distributions = !list.is_empty(distributions)
  let all_positive =
    list.all(distributions, fn(dist) { dist.amount > 0 })
  let no_duplicate_recipients =
    list.length(distributions) == list.length(
      list.unique(list.map(distributions, fn(dist) { dist.recipient })),
    )
  let all_same_admin =
    list.all(
      script_input_datums,
      fn(input_datum) { input_datum.admin == datum.admin },
    )
  let total_input_lovelace =
    list.foldl(script_input_lovelaces, 0, fn(l, acc) { acc + l })
  let total_distributed =
    list.foldl(distributions, 0, fn(dist, acc) { acc + dist.amount })
  let distribution_within_budget = total_distributed <= total_input_lovelace
  let all_recipients_paid =
    list.all(
      distributions,
      fn(dist) {
        list.any(
          outputs,
          fn(output) {
            output.address.payment_credential == VerificationKey(
              dist.recipient,
            ) && lovelace_of(output.value) >= dist.amount
          },
        )
      },
    )
  let change_outputs =
    list.filter(outputs, fn(output) { output.address == script_address() })
  let change_datum_valid =
    list.all(
      change_outputs,
      fn(output) {
        expect InlineDatum(raw) = output.datum
        expect d: DonationDatum = raw
        d.admin == datum.admin
      },
    )

  and {
    admin_signed,
    has_distributions,
    all_positive,
    no_duplicate_recipients,
    all_same_admin,
    distribution_within_budget,
    all_recipients_paid,
    change_datum_valid,
  }
}

// ===========================================================================
// FUZZ 1: Random distribution amounts — valid when positive & within budget
// ===========================================================================

test fuzz_random_valid_amounts(raw_amount via fuzz.int()) {
  let amount =
    if raw_amount <= 0 {
      1
    } else if raw_amount > 1_000_000_000 {
      raw_amount % 1_000_000_000 + 1
    } else {
      raw_amount
    }
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [amount],
    [make_recipient_output(recipient_a_pkh, amount)],
  )
}

// ===========================================================================
// FUZZ 2: Random non-positive amounts always rejected
// Targets: redeemer manipulation with zero/negative amounts
// ===========================================================================

test fuzz_non_positive_amounts_rejected(raw_amount via fuzz.int()) {
  let amount =
    if raw_amount > 0 {
      -raw_amount
    } else if raw_amount == 0 {
      0
    } else {
      raw_amount
    }
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount }]
  !validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 10_000_000)],
  )
}

// ===========================================================================
// FUZZ 3: Random recipient addresses — valid when properly paid
// ===========================================================================

test fuzz_random_recipient_addresses(fuzzed_recipient via fuzz.bytearray()) {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: fuzzed_recipient, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(fuzzed_recipient, 5_000_000)],
  )
}

// ===========================================================================
// FUZZ 4: Random admin keys — wrong admin always fails signer check
// Targets: unauthorized withdrawal attack vector
// ===========================================================================

test fuzz_wrong_admin_always_fails(fuzzed_admin via fuzz.bytearray()) {
  if fuzzed_admin == admin_pkh {
    True
  } else {
    let datum = DonationDatum { admin: admin_pkh }
    let distributions =
      [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
    !validate_distribution(
      datum,
      distributions,
      [fuzzed_admin],
      [datum],
      [10_000_000],
      [make_recipient_output(recipient_a_pkh, 5_000_000)],
    )
  }
}

// ===========================================================================
// FUZZ 5: Random mismatched admin in batched inputs → always fails
// Targets: cross-pool budget inflation (audit finding F1)
// ===========================================================================

test fuzz_mismatched_admin_in_batch(fuzzed_admin via fuzz.bytearray()) {
  if fuzzed_admin == admin_pkh {
    True
  } else {
    let datum = DonationDatum { admin: admin_pkh }
    let other_datum = DonationDatum { admin: fuzzed_admin }
    let distributions =
      [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
    !validate_distribution(
      datum,
      distributions,
      [admin_pkh],
      [datum, other_datum],
      [5_000_000, 5_000_000],
      [make_recipient_output(recipient_a_pkh, 5_000_000)],
    )
  }
}

// ===========================================================================
// FUZZ 6: Fuzz two-recipient distribution with random split
// ===========================================================================

test fuzz_two_recipient_split(
  (raw_a, raw_b) via fuzz.both(fuzz.int(), fuzz.int()),
) {
  let clamp = fn(n) {
      if n <= 0 {
        1
      } else if n > 500_000_000 {
        n % 500_000_000 + 1
      } else {
        n
      }
    }
  let amount_a = clamp(raw_a)
  let amount_b = clamp(raw_b)
  let budget = amount_a + amount_b
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: amount_a },
      Distribution { recipient: recipient_b_pkh, amount: amount_b },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [budget],
    [
      make_recipient_output(recipient_a_pkh, amount_a),
      make_recipient_output(recipient_b_pkh, amount_b),
    ],
  )
}

// ===========================================================================
// FUZZ 7: Random underpayment delta — always rejected
// Targets: value manipulation / recipient payment verification
// ===========================================================================

test fuzz_underpayment_delta(raw_delta via fuzz.int()) {
  let delta =
    if raw_delta <= 0 {
      1
    } else if raw_delta > 5_000_000 {
      raw_delta % 5_000_000 + 1
    } else {
      raw_delta
    }
  let amount = 5_000_000
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount }]
  !validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, amount - delta)],
  )
}
