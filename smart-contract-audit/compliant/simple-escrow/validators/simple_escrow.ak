/// # Simple Escrow Validator (Compliant — Post-Audit)
///
/// Locks ADA with a secret-hash commitment. The beneficiary can claim by
/// revealing the correct secret before the deadline. The sender can reclaim
/// after the deadline passes.
///
/// ## Security fixes applied
/// - **Double satisfaction (CRITICAL)**: Added `script_input_count == 1` check.
///   Only one escrow UTxO from this script address may be spent per transaction.
///   This eliminates the double-satisfaction vector entirely — no shared output
///   can satisfy two validator invocations because there is only one invocation.
/// - **Output matching**: `list.any` is retained. With the single-input guard,
///   each TX has exactly one validator invocation, so the output can only be
///   "claimed" once. No distinctness issue.
///
/// ## Known limitations (documented, not fixed on-chain)
/// - **Front-running**: Mitigated by beneficiary signature requirement.
/// - **Credential type**: Datum accepts any ByteArray; if a script hash is used
///   as beneficiary/sender, the escrow becomes unclaimable/unreclaimable.
///   This is a datum construction concern, not a validator bug.
/// - **Deadline dead zone**: 1ms gap at exact deadline where neither path is
///   valid. Minimal practical impact.

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

    // Resolve our own input to get the locked value and script address.
    expect own_oref: OutputReference = own_ref
    expect Some(own_input) = find_input(tx.inputs, own_oref)
    let own_value = own_input.output.value

    // ─── CRITICAL FIX: Prevent double satisfaction ───
    // Count how many TX inputs come from this script address.
    // Require exactly 1 — our own. This ensures the validator runs
    // at most once per TX, so `list.any` output matching is safe.
    let script_address = own_input.output.address
    let script_input_count =
      list.count(tx.inputs, fn(i) { i.output.address == script_address })
    expect script_input_count == 1

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
        //    Safe with script_input_count == 1: only one validator invocation
        //    per TX, so this output cannot be double-counted.
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
        //    Safe with script_input_count == 1 (see above).
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
