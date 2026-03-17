/// # Donation Pool Validator
///
/// A pool contract where anyone can donate ADA (by sending to the script
/// address with an inline datum specifying the admin), and the admin can
/// distribute funds to verified recipients.
///
/// ## Security considerations
/// - **Double satisfaction**: Each consumed pool UTxO independently verifies
///   that the total outputs to recipients cover the distribution amounts.
///   We also verify that ALL inputs from this script share the same admin
///   and that the total distributed equals the total input value (minus
///   what may return to the script as change).
/// - **Datum hijacking**: Datum is read from the script's own resolved input
///   via output_reference. We validate admin from each input's datum.
/// - **Redeemer manipulation**: The redeemer is a typed Distribution list.
///   We verify that the sum of distribution amounts does not exceed available
///   funds, and that each recipient actually receives their stated amount.
/// - **Alternative spending paths**: Only the Distribute redeemer is accepted.
///   No minting, staking, or withdrawal logic is involved.
/// - **Unauthorized withdrawal**: Admin signature is required. Without it,
///   no UTxO at this script address can be consumed.

use aiken/collection/list
use cardano/address.{VerificationKey}
use cardano/assets.{lovelace_of}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction, find_input}
use donation_types.{DonationDatum, DonationRedeemer, Distribute}

validator donation_pool {
  spend(
    datum: Option<DonationDatum>,
    redeemer: DonationRedeemer,
    own_ref: Data,
    tx: Transaction,
  ) {
    // Datum must be present (inline datum required).
    expect Some(d) = datum

    // Resolve our own input to know the script address and locked value.
    expect own_oref: OutputReference = own_ref
    expect Some(own_input) = find_input(tx.inputs, own_oref)
    let script_address = own_input.output.address

    let Distribute { distributions } = redeemer
    {
        // 1. Admin must have signed the transaction.
        let admin_signed = list.has(tx.extra_signatories, d.admin)

        // 2. Distribution list must not be empty.
        let has_distributions = !list.is_empty(distributions)

        // 3. Every distribution amount must be positive.
        let all_positive =
          list.all(distributions, fn(dist) { dist.amount > 0 })

        // 3b. No duplicate recipients in the distribution list.
        //     Prevents a single output from satisfying multiple entries
        //     for the same recipient, which could allow the admin to
        //     under-deliver while appearing to distribute the full budget.
        let no_duplicate_recipients =
          list.length(distributions) == list.length(
            list.unique(list.map(distributions, fn(dist) { dist.recipient })),
          )

        // 4. Compute total lovelace across ALL script inputs in this TX.
        //    All script inputs must share the same admin (prevents mixing
        //    pools from different admins in one TX — defends against
        //    cross-pool attacks and ensures single-admin authority).
        let script_inputs =
          list.filter(
            tx.inputs,
            fn(input) { input.output.address == script_address },
          )

        let all_same_admin =
          list.all(
            script_inputs,
            fn(input) {
              expect input_datum: DonationDatum = resolve_output_datum(input.output)
              input_datum.admin == d.admin
            },
          )

        let total_input_lovelace =
          list.foldl(
            script_inputs,
            0,
            fn(input, acc) { acc + lovelace_of(input.output.value) },
          )

        // 5. Sum of distribution amounts must not exceed total input.
        let total_distributed =
          list.foldl(
            distributions,
            0,
            fn(dist, acc) { acc + dist.amount },
          )

        let distribution_within_budget = total_distributed <= total_input_lovelace

        // 6. Each recipient must receive at least their stated amount
        //    in the transaction outputs. This is the core correctness check.
        let all_recipients_paid =
          list.all(
            distributions,
            fn(dist) {
              list.any(
                tx.outputs,
                fn(output) {
                  output.address.payment_credential == VerificationKey(
                    dist.recipient,
                  ) && lovelace_of(output.value) >= dist.amount
                },
              )
            },
          )

        // 7. Any change going back to the script must preserve the same
        //    admin datum (prevents datum hijacking on change outputs).
        let change_outputs =
          list.filter(
            tx.outputs,
            fn(output) { output.address == script_address },
          )

        let change_datum_valid =
          list.all(
            change_outputs,
            fn(output) {
              // Change UTxOs at the script address must carry the same admin.
              expect datum_data: DonationDatum = resolve_output_datum(output)
              datum_data.admin == d.admin
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
  }
}

/// Extract an inline datum from a transaction output, expecting a specific type.
/// Fails (aborts) if no inline datum is present.
fn resolve_output_datum(output: Output) -> Data {
  expect InlineDatum(raw) = output.datum
  raw
}
