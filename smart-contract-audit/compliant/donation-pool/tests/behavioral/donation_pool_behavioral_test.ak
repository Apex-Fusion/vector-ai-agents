/// Donation Pool — Behavioral Test Suite
///
/// Documents what the contract IS DESIGNED to do.
/// All pass on original, should also pass on compliant.

use aiken/collection/list
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets
use cardano/assets.{lovelace_of}
use cardano/transaction.{InlineDatum, NoDatum, Output}
use donation_types.{DonationDatum, Distribution}

// ──────────────────────────────────────────────────────────────────────
// Reimplemented validation logic (mirrors contract exactly)
// ──────────────────────────────────────────────────────────────────────

fn validate_distribute(
  d: DonationDatum,
  distributions: List<Distribution>,
  signatories: List<ByteArray>,
  script_inputs_lovelace: List<Int>,
  script_inputs_admins: List<ByteArray>,
  outputs: List<Output>,
  change_admins: List<ByteArray>,
) -> Bool {
  let admin_signed = list.has(signatories, d.admin)
  let has_distributions = !list.is_empty(distributions)
  let all_positive = list.all(distributions, fn(dist) { dist.amount > 0 })
  let no_dup =
    list.length(distributions) == list.length(
      list.unique(list.map(distributions, fn(dist) { dist.recipient })),
    )
  let all_same_admin = list.all(script_inputs_admins, fn(a) { a == d.admin })
  let total_input = list.foldl(script_inputs_lovelace, 0, fn(v, acc) { acc + v })
  let total_dist = list.foldl(distributions, 0, fn(dist, acc) { acc + dist.amount })
  let within_budget = total_dist <= total_input
  let all_paid =
    list.all(
      distributions,
      fn(dist) {
        list.any(
          outputs,
          fn(output) {
            output.address.payment_credential == VerificationKey(dist.recipient) && lovelace_of(
              output.value,
            ) >= dist.amount
          },
        )
      },
    )
  let change_valid = list.all(change_admins, fn(a) { a == d.admin })

  and {
    admin_signed,
    has_distributions,
    all_positive,
    no_dup,
    all_same_admin,
    within_budget,
    all_paid,
    change_valid,
  }
}

// ──────────────────────────────────────────────────────────────────────
// Constants
// ──────────────────────────────────────────────────────────────────────

const admin_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const alice_pkh =
  #"1122334411223344112233441122334411223344112233441122334411223344"

const bob_pkh =
  #"5566778855667788556677885566778855667788556677885566778855667788"

fn make_output(pkh: ByteArray, lovelace: Int) -> Output {
  Output {
    address: Address {
      payment_credential: VerificationKey(pkh),
      stake_credential: None,
    },
    value: assets.from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

fn make_datum() -> DonationDatum {
  DonationDatum { admin: admin_pkh }
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Happy path
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Single distribution to one recipient succeeds.
test behavior_single_distribution_success() {
  validate_distribute(
    make_datum(),
    [Distribution { recipient: alice_pkh, amount: 5_000_000 }],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [make_output(alice_pkh, 5_000_000)],
    [],
  )
}

/// BEHAVIOR: Multiple distributions succeed.
test behavior_multi_distribution_success() {
  validate_distribute(
    make_datum(),
    [
      Distribution { recipient: alice_pkh, amount: 3_000_000 },
      Distribution { recipient: bob_pkh, amount: 5_000_000 },
    ],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [make_output(alice_pkh, 3_000_000), make_output(bob_pkh, 5_000_000)],
    [],
  )
}

/// BEHAVIOR: Distribution with change back to script succeeds.
test behavior_distribution_with_change() {
  validate_distribute(
    make_datum(),
    [Distribution { recipient: alice_pkh, amount: 3_000_000 }],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [make_output(alice_pkh, 3_000_000)],
    [admin_pkh],
  )
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral: Rejection cases
// ──────────────────────────────────────────────────────────────────────

/// BEHAVIOR: Fails without admin signature.
test behavior_no_admin_signature_fails() {
  !validate_distribute(
    make_datum(),
    [Distribution { recipient: alice_pkh, amount: 5_000_000 }],
    [],
    [10_000_000],
    [admin_pkh],
    [make_output(alice_pkh, 5_000_000)],
    [],
  )
}

/// BEHAVIOR: Fails with empty distribution list.
test behavior_empty_distributions_fails() {
  !validate_distribute(
    make_datum(),
    [],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [],
    [],
  )
}

/// BEHAVIOR: Fails with negative amount.
test behavior_negative_amount_fails() {
  !validate_distribute(
    make_datum(),
    [Distribution { recipient: alice_pkh, amount: -1 }],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [make_output(alice_pkh, 10_000_000)],
    [],
  )
}

/// BEHAVIOR: Fails with zero amount.
test behavior_zero_amount_fails() {
  !validate_distribute(
    make_datum(),
    [Distribution { recipient: alice_pkh, amount: 0 }],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [make_output(alice_pkh, 10_000_000)],
    [],
  )
}

/// BEHAVIOR: Fails with duplicate recipients.
test behavior_duplicate_recipients_fails() {
  !validate_distribute(
    make_datum(),
    [
      Distribution { recipient: alice_pkh, amount: 3_000_000 },
      Distribution { recipient: alice_pkh, amount: 2_000_000 },
    ],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [make_output(alice_pkh, 5_000_000)],
    [],
  )
}

/// BEHAVIOR: Fails when distribution exceeds budget.
test behavior_over_budget_fails() {
  !validate_distribute(
    make_datum(),
    [Distribution { recipient: alice_pkh, amount: 15_000_000 }],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [make_output(alice_pkh, 15_000_000)],
    [],
  )
}

/// BEHAVIOR: Fails when recipient underpaid.
test behavior_underpaid_recipient_fails() {
  !validate_distribute(
    make_datum(),
    [Distribution { recipient: alice_pkh, amount: 5_000_000 }],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [make_output(alice_pkh, 4_999_999)],
    [],
  )
}

/// BEHAVIOR: Fails with different admin on cross-pool input.
test behavior_cross_admin_fails() {
  let other_admin =
    #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  !validate_distribute(
    make_datum(),
    [Distribution { recipient: alice_pkh, amount: 5_000_000 }],
    [admin_pkh],
    [10_000_000, 10_000_000],
    [admin_pkh, other_admin],
    [make_output(alice_pkh, 5_000_000)],
    [],
  )
}

/// BEHAVIOR: Fails when change output has wrong admin.
test behavior_wrong_change_admin_fails() {
  let other_admin =
    #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  !validate_distribute(
    make_datum(),
    [Distribution { recipient: alice_pkh, amount: 3_000_000 }],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [make_output(alice_pkh, 3_000_000)],
    [other_admin],
  )
}

/// BEHAVIOR: Admin can distribute to themselves (by design).
test behavior_admin_distributes_to_self() {
  validate_distribute(
    make_datum(),
    [Distribution { recipient: admin_pkh, amount: 10_000_000 }],
    [admin_pkh],
    [10_000_000],
    [admin_pkh],
    [make_output(admin_pkh, 10_000_000)],
    [],
  )
}
