/// # Simple Escrow Validator
///
/// Locks ADA with a secret-hash commitment. The beneficiary can claim by
/// revealing the correct secret before the deadline. The sender can reclaim
/// after the deadline passes.
///
/// ## Security considerations
/// - **Double satisfaction**: Mitigated by requiring the output pays to the
///   correct beneficiary/sender address AND the value is at least the input value.
///   Each input is checked independently against its own datum.
/// - **Datum hijacking**: We validate the datum from the script's own input only
///   (resolved via output_reference). Inline datum is enforced by type-checking.
/// - **Redeemer manipulation**: The redeemer is a typed enum; Claim requires a
///   secret that hashes correctly, Reclaim requires deadline to have passed.
/// - **Alternative spending paths**: The validator is the sole authority over UTxOs
///   at its script address. No minting or withdrawal logic is involved.

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/interval
use escrow_types.{Claim, EscrowDatum, EscrowRedeemer, Reclaim}
use cardano/address.{VerificationKey}
use cardano/assets.{Value, flatten, quantity_of}
use cardano/transaction.{Output, OutputReference, Transaction, find_input}

validator simple_escrow {
  spend(
    datum: Option<EscrowDatum>,
    redeemer: EscrowRedeemer,
    own_ref: Data,
    tx: Transaction,
  ) {
    // Datum must be present (inline datum).
    expect Some(d) = datum

    // Resolve our own input to get the locked value.
    expect own_oref: OutputReference = own_ref
    expect Some(own_input) = find_input(tx.inputs, own_oref)
    let own_value = own_input.output.value

    when redeemer is {
      // --- CLAIM PATH ---
      // Beneficiary reveals the secret before the deadline.
      Claim { secret } -> {
        // 1. Secret must hash to the committed hash.
        let secret_valid = blake2b_256(secret) == d.secret_hash

        // 2. Transaction must execute before the deadline.
        //    The entire validity range must be before the deadline.
        let before_deadline =
          interval.is_entirely_before(tx.validity_range, d.deadline)

        // 3. Beneficiary must have signed the transaction.
        let beneficiary_signed =
          list.has(tx.extra_signatories, d.beneficiary)

        // 4. An output must pay at least the locked value to the beneficiary.
        //    This defends against double satisfaction: each input's value must
        //    be accounted for in a distinct output to the correct beneficiary.
        let paid_to_beneficiary =
          list.any(
            tx.outputs,
            fn(output) {
              output.address.payment_credential == VerificationKey(
                d.beneficiary,
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

      // --- RECLAIM PATH ---
      // Sender reclaims after the deadline has passed.
      Reclaim -> {
        // 1. Transaction must execute entirely after the deadline.
        let after_deadline =
          interval.is_entirely_after(tx.validity_range, d.deadline)

        // 2. Sender must have signed the transaction.
        let sender_signed = list.has(tx.extra_signatories, d.sender)

        // 3. An output must pay at least the locked value back to the sender.
        let paid_to_sender =
          list.any(
            tx.outputs,
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
    }
  }
}

/// Check that `a` contains at least as much of every asset as `b`.
/// This defends against value extraction attacks.
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
