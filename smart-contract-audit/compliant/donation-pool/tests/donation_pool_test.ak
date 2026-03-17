/// # Donation Pool — Unit Tests
///
/// Comprehensive test suite covering happy paths, rejection cases,
/// and attack vector scenarios for the donation_pool validator.
///
/// Tests replicate the validator logic to verify correctness of each
/// validation check independently. Attack vectors mapped from audit findings:
/// - Finding 1 (High): Missing same-admin enforcement — cross-pool budget inflation
/// - Finding 2 (Low): Duplicate recipients allow single output to satisfy multiple entries
/// - Finding 3 (Info): Native token extraction not validated
///
/// Authored by: Test Writer
/// Date: 2026-03-16

use aiken/collection/list
use cardano/address.{Address, VerificationKey}
use cardano/assets
use cardano/assets.{lovelace_of}
use cardano/transaction.{InlineDatum, NoDatum, Output}
use donation_types.{Distribution, DonationDatum}

// ---------------------------------------------------------------------------
// Test constants
// ---------------------------------------------------------------------------

const admin_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const recipient_a_pkh =
  #"11223344112233441122334411223344112233441122334411223344"

const recipient_b_pkh =
  #"55667788556677885566778855667788556677885566778855667788"

const recipient_c_pkh =
  #"99aabbcc99aabbcc99aabbcc99aabbcc99aabbcc99aabbcc99aabbcc"

const wrong_admin_pkh =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

const attacker_pkh =
  #"cafebabecafebabecafebabecafebabecafebabecafebabecafebabe"

const script_hash =
  #"ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00"

// ---------------------------------------------------------------------------
// Helpers: Addresses
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

// ---------------------------------------------------------------------------
// Helpers: Outputs
// ---------------------------------------------------------------------------

fn make_recipient_output(pkh: ByteArray, lovelace: Int) -> Output {
  Output {
    address: wallet_address(pkh),
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

fn make_script_output(admin: ByteArray, lovelace: Int) -> Output {
  Output {
    address: script_address(),
    value: assets.from_lovelace(lovelace),
    datum: InlineDatum(DonationDatum { admin }),
    reference_script: None,
  }
}

fn make_script_output_wrong_datum(lovelace: Int) -> Output {
  Output {
    address: script_address(),
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

// ---------------------------------------------------------------------------
// Re-implementation of validator logic (mirrors donation_pool.ak exactly)
// ---------------------------------------------------------------------------

fn validate_distribution(
  datum: DonationDatum,
  distributions: List<Distribution>,
  signatories: List<ByteArray>,
  script_input_datums: List<DonationDatum>,
  script_input_lovelaces: List<Int>,
  outputs: List<Output>,
) -> Bool {
  // 1. Admin must have signed
  let admin_signed = list.has(signatories, datum.admin)

  // 2. Distribution list must not be empty
  let has_distributions = !list.is_empty(distributions)

  // 3. Every distribution amount must be positive
  let all_positive =
    list.all(distributions, fn(dist) { dist.amount > 0 })

  // 3b. No duplicate recipients (audit finding F2 fix)
  let no_duplicate_recipients =
    list.length(distributions) == list.length(
      list.unique(list.map(distributions, fn(dist) { dist.recipient })),
    )

  // 4. All script inputs must share the same admin (audit finding F1 fix)
  let all_same_admin =
    list.all(
      script_input_datums,
      fn(input_datum) { input_datum.admin == datum.admin },
    )

  // Total input lovelace
  let total_input_lovelace =
    list.foldl(script_input_lovelaces, 0, fn(l, acc) { acc + l })

  // 5. Sum of distribution amounts must not exceed total input
  let total_distributed =
    list.foldl(distributions, 0, fn(dist, acc) { acc + dist.amount })
  let distribution_within_budget = total_distributed <= total_input_lovelace

  // 6. Each recipient must receive at least their stated amount
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

  // 7. Change outputs at script address must preserve admin datum
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
// HAPPY PATH TESTS
// ===========================================================================

/// Admin distributes to a single recipient — basic happy path
test distribute_single_recipient_happy_path() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 5_000_000)],
  )
}

/// Admin distributes to multiple recipients
test distribute_multiple_recipients() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 3_000_000 },
      Distribution { recipient: recipient_b_pkh, amount: 4_000_000 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 3_000_000),
      make_recipient_output(recipient_b_pkh, 4_000_000),
    ],
  )
}

/// Admin distributes to three recipients
test distribute_three_recipients() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 2_000_000 },
      Distribution { recipient: recipient_b_pkh, amount: 3_000_000 },
      Distribution { recipient: recipient_c_pkh, amount: 4_000_000 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 2_000_000),
      make_recipient_output(recipient_b_pkh, 3_000_000),
      make_recipient_output(recipient_c_pkh, 4_000_000),
    ],
  )
}

/// Partial distribution with change going back to script
test distribute_with_change() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 3_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 3_000_000),
      make_script_output(admin_pkh, 7_000_000),
    ],
  )
}

/// Distribute exact full amount (no change)
test distribute_exact_budget() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 5_000_000 },
      Distribution { recipient: recipient_b_pkh, amount: 5_000_000 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 5_000_000),
      make_recipient_output(recipient_b_pkh, 5_000_000),
    ],
  )
}

/// Overpayment to recipient is allowed
test distribute_overpayment_allowed() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 3_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 8_000_000)],
  )
}

/// Batching multiple UTxOs from the same admin
test distribute_batched_inputs_same_admin() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 8_000_000 },
      Distribution { recipient: recipient_b_pkh, amount: 7_000_000 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum, datum, datum],
    [5_000_000, 5_000_000, 5_000_000],
    [
      make_recipient_output(recipient_a_pkh, 8_000_000),
      make_recipient_output(recipient_b_pkh, 7_000_000),
    ],
  )
}

// ===========================================================================
// REJECTION TESTS — UNAUTHORIZED (missing signer checks)
// ===========================================================================

/// Distribution without admin signature → must fail
test distribute_no_admin_signature() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 5_000_000)],
  )
}

/// Distribution signed by wrong party → must fail
test distribute_wrong_signer() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [wrong_admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 5_000_000)],
  )
}

/// Distribution signed by attacker → must fail
test distribute_attacker_signer() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: attacker_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [attacker_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(attacker_pkh, 5_000_000)],
  )
}

/// Distribution signed by recipient (not admin) → must fail
test distribute_recipient_signs() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [recipient_a_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 5_000_000)],
  )
}

// ===========================================================================
// REJECTION TESTS — EMPTY DISTRIBUTIONS (redeemer manipulation)
// ===========================================================================

/// Empty distribution list → must fail
test distribute_empty_list() fail {
  let datum = DonationDatum { admin: admin_pkh }
  validate_distribution(
    datum,
    [],
    [admin_pkh],
    [datum],
    [10_000_000],
    [],
  )
}

// ===========================================================================
// REJECTION TESTS — ZERO/NEGATIVE AMOUNTS (redeemer manipulation)
// ===========================================================================

/// Distribution with zero amount → must fail
test distribute_zero_amount() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 0 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 0)],
  )
}

/// Distribution with negative amount → must fail
test distribute_negative_amount() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: -1_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 10_000_000)],
  )
}

/// Mix of valid and zero amounts → must fail
test distribute_mixed_zero_amounts() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 5_000_000 },
      Distribution { recipient: recipient_b_pkh, amount: 0 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 5_000_000),
      make_recipient_output(recipient_b_pkh, 0),
    ],
  )
}

/// Mix of valid and negative amounts → must fail
test distribute_mixed_negative_amounts() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 5_000_000 },
      Distribution { recipient: recipient_b_pkh, amount: -1 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 5_000_000),
      make_recipient_output(recipient_b_pkh, 10_000_000),
    ],
  )
}

// ===========================================================================
// REJECTION TESTS — INCORRECT RECIPIENT PAYMENTS
// ===========================================================================

/// Recipient receives less than stated amount → must fail
test distribute_underpayment() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 4_999_999)],
  )
}

/// Payment goes to wrong recipient → must fail
test distribute_wrong_recipient_paid() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_b_pkh, 5_000_000)],
  )
}

/// No outputs at all → must fail
test distribute_no_outputs() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [],
  )
}

/// One recipient paid, another not → must fail
test distribute_partial_payment() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 3_000_000 },
      Distribution { recipient: recipient_b_pkh, amount: 4_000_000 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 3_000_000)],
  )
}

// ===========================================================================
// REJECTION TESTS — OVER-DISTRIBUTION (budget exceeded)
// ===========================================================================

/// Total distributed exceeds total input → must fail
test distribute_over_budget() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 15_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 15_000_000)],
  )
}

/// Multiple distributions exceed total input → must fail
test distribute_multi_over_budget() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 6_000_000 },
      Distribution { recipient: recipient_b_pkh, amount: 6_000_000 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 6_000_000),
      make_recipient_output(recipient_b_pkh, 6_000_000),
    ],
  )
}

// ===========================================================================
// REJECTION TESTS — SAME-ADMIN CHECK (audit finding F1: cross-pool
// budget inflation — HIGH severity, now fixed)
// ===========================================================================

/// Cross-pool attack: batched inputs with different admins → must fail
test distribute_different_admin_batched() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let other_datum = DonationDatum { admin: wrong_admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 15_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum, other_datum],
    [10_000_000, 10_000_000],
    [make_recipient_output(recipient_a_pkh, 15_000_000)],
  )
}

/// Cross-pool budget inflation: Admin A exploits Admin B's funds → must fail
/// This is the specific attack scenario from audit finding F1.
test cross_pool_budget_inflation_attack() fail {
  let admin_a_datum = DonationDatum { admin: admin_pkh }
  let admin_b_datum = DonationDatum { admin: wrong_admin_pkh }
  let distributions =
    [Distribution { recipient: attacker_pkh, amount: 18_000_000 }]
  validate_distribution(
    admin_a_datum,
    distributions,
    [admin_pkh],
    [admin_a_datum, admin_b_datum],
    [10_000_000, 10_000_000],
    [make_recipient_output(attacker_pkh, 18_000_000)],
  )
}

/// Three inputs, one from different admin → must fail
test distribute_three_inputs_one_different_admin() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let other = DonationDatum { admin: attacker_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 20_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum, datum, other],
    [10_000_000, 10_000_000, 10_000_000],
    [make_recipient_output(recipient_a_pkh, 20_000_000)],
  )
}

// ===========================================================================
// REJECTION TESTS — DUPLICATE RECIPIENTS (audit finding F2: single output
// satisfying multiple entries — LOW severity, now fixed)
// ===========================================================================

/// Duplicate recipient in distribution list → must fail
test distribute_duplicate_recipient() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 3_000_000 },
      Distribution { recipient: recipient_a_pkh, amount: 3_000_000 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 6_000_000)],
  )
}

/// Duplicate recipient under-delivery attack: single output satisfying both → must fail
/// This was the specific attack vector from audit finding F2.
test duplicate_recipient_under_delivery_attack() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 50_000_000 },
      Distribution { recipient: recipient_a_pkh, amount: 50_000_000 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [100_000_000],
    [make_recipient_output(recipient_a_pkh, 50_000_000)],
  )
}

/// Triple duplicate recipient → must fail
test distribute_triple_duplicate() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 2_000_000 },
      Distribution { recipient: recipient_a_pkh, amount: 2_000_000 },
      Distribution { recipient: recipient_a_pkh, amount: 2_000_000 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 6_000_000)],
  )
}

// ===========================================================================
// REJECTION TESTS — DATUM HIJACKING ON CHANGE (datum hijacking attack vector)
// ===========================================================================

/// Change output at script address with different admin → must fail
test change_output_wrong_admin() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 3_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 3_000_000),
      make_script_output(attacker_pkh, 7_000_000),
    ],
  )
}

/// Change output with attacker admin → datum hijacking attack
test datum_hijacking_on_change() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 1_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 1_000_000),
      make_script_output(wrong_admin_pkh, 9_000_000),
    ],
  )
}

/// Multiple change outputs — one valid, one hijacked → must fail
test change_output_mixed_valid_and_hijacked() fail {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 2_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [20_000_000],
    [
      make_recipient_output(recipient_a_pkh, 2_000_000),
      make_script_output(admin_pkh, 9_000_000),
      make_script_output(attacker_pkh, 9_000_000),
    ],
  )
}

// ===========================================================================
// DOUBLE SATISFACTION TESTS
// ===========================================================================

/// Document that same-admin batching shares output checking
/// (acceptable per trust model — admin is authorized spender)
test double_satisfaction_same_admin_acceptable() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum, datum],
    [5_000_000, 5_000_000],
    [make_recipient_output(recipient_a_pkh, 5_000_000)],
  )
}

// ===========================================================================
// VALUE PRESERVATION TESTS
// ===========================================================================

/// Distribution exactly equals total input — no change needed
test value_preservation_exact() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [
      Distribution { recipient: recipient_a_pkh, amount: 6_000_000 },
      Distribution { recipient: recipient_b_pkh, amount: 4_000_000 },
    ]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 6_000_000),
      make_recipient_output(recipient_b_pkh, 4_000_000),
    ],
  )
}

/// Distribution less than total — change must go back to script with valid datum
test value_preservation_with_valid_change() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 2_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 2_000_000),
      make_script_output(admin_pkh, 8_000_000),
    ],
  )
}

/// Minimum distribution amount (1 lovelace — positive check boundary)
test distribute_minimum_amount() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 1 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 1)],
  )
}

// ===========================================================================
// EDGE CASES
// ===========================================================================

/// Admin is also a recipient — allowed (no restriction in contract)
test admin_is_recipient() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: admin_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(admin_pkh, 5_000_000)],
  )
}

/// Extra signatories beyond admin — doesn't affect validity
test extra_signatories_allowed() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 5_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh, recipient_a_pkh, wrong_admin_pkh],
    [datum],
    [10_000_000],
    [make_recipient_output(recipient_a_pkh, 5_000_000)],
  )
}

/// Multiple valid change outputs (splitting change)
test multiple_valid_change_outputs() {
  let datum = DonationDatum { admin: admin_pkh }
  let distributions =
    [Distribution { recipient: recipient_a_pkh, amount: 2_000_000 }]
  validate_distribution(
    datum,
    distributions,
    [admin_pkh],
    [datum],
    [10_000_000],
    [
      make_recipient_output(recipient_a_pkh, 2_000_000),
      make_script_output(admin_pkh, 4_000_000),
      make_script_output(admin_pkh, 4_000_000),
    ],
  )
}
