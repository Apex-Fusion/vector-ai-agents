/// # Vesting Validator
///
/// Time-locked linear vesting of ADA. Funds are locked with a schedule
/// defined by (beneficiary, total_vesting_amount, cliff_time, vesting_end_time).
///
/// - **Before cliff_time**: nothing can be withdrawn.
/// - **Between cliff_time and vesting_end_time**: proportional (linear) amount
///   can be claimed. The vested fraction = (current_time - cliff_time) /
///   (vesting_end_time - cliff_time).
/// - **After vesting_end_time**: full amount is claimable.
///
/// ## Timing Model
/// On Cardano/Vector, validators cannot read the current wall-clock time.
/// Instead they see `tx.validity_range` — the slot window the transaction
/// is valid within. We use the **lower bound** of the validity range as
/// "earliest possible execution time" for computing vested amounts. This is
/// conservative: the beneficiary can never claim more than what's vested at
/// the start of the validity window. The tighter the validity range, the more
/// precise the claim.
///
/// **Limitation:** Slot-to-POSIX conversion depends on chain parameters.
/// If slot length changes, vesting schedules created before the change may
/// drift. This is a known, documented limitation.
///
/// ## Lower-Bound Assumption
/// The `get_lower_bound` function extracts the `Finite` bound value and
/// assumes it is **inclusive** (i.e., the validity range starts at exactly
/// that time). In Cardano, lower bounds are always inclusive in practice.
/// If an exclusive lower bound were ever produced, our time would be off by
/// 1 ms (conservative direction: we would under-estimate vested amount).
///
/// ## Security Considerations
/// - **Double satisfaction**: Fixed via single-script-input constraint plus
///   output-index pinning. The validator enforces that exactly one input from
///   the script address exists in the transaction, preventing any cross-input
///   sharing of outputs. The `Claim` redeemer carries `beneficiary_index` and
///   `continuation_index` which pin the single vesting input to specific
///   outputs. This means batching multiple vesting claims in one TX is not
///   supported — each claim requires its own transaction.
/// - **Datum hijacking**: Change outputs to the script address must carry
///   an identical datum (same beneficiary, same schedule). Prevents an
///   attacker from swapping the datum on the continuation UTxO.
/// - **Redeemer manipulation**: Only one redeemer variant (Claim). The
///   vested amount is computed from chain state, not from the redeemer.
///   The index fields only select *which* output to check — they cannot
///   inflate the claimable amount.
/// - **Alternative spending paths**: No minting, staking, or withdrawal
///   logic. The validator is the sole authority.
/// - **Timing attacks**: We use the lower bound (conservative) of the
///   validity range. An attacker cannot inflate the vested amount by
///   widening the upper bound.
/// - **Value extraction**: We verify the total of (beneficiary payout +
///   script continuation) equals at least the input value, preventing
///   value leaks.
/// - **Signature requirement**: Beneficiary must sign every claim TX.
/// - **Degenerate datums**: See vesting_types.ak for off-chain warnings
///   about zero/negative total_vesting_amount and end <= cliff edge cases.

use aiken/collection/list
use aiken/interval.{Finite}
use cardano/address.{VerificationKey}
use cardano/assets.{lovelace_of}
use cardano/transaction.{InlineDatum, OutputReference, Transaction, find_input}
use vesting_types.{Claim, VestingDatum, VestingRedeemer}

validator vesting {
  spend(
    datum: Option<VestingDatum>,
    redeemer: VestingRedeemer,
    own_ref: Data,
    tx: Transaction,
  ) {
    // Datum must be present (inline datum).
    expect Some(d) = datum

    // Destructure redeemer to get pinned output indices.
    let Claim { beneficiary_index, continuation_index } = redeemer

    // Resolve own input.
    expect own_oref: OutputReference = own_ref
    expect Some(own_input) = find_input(tx.inputs, own_oref)
    let script_address = own_input.output.address
    let locked_lovelace = lovelace_of(own_input.output.value)

    // --- 0. Ensure exactly one script input (prevents double satisfaction) ---
    let script_input_count =
      list.count(tx.inputs, fn(i) { i.output.address == script_address })
    expect script_input_count == 1

    // --- 1. Beneficiary must sign ---
    let beneficiary_signed =
      list.has(tx.extra_signatories, d.beneficiary)

    // --- 2. Determine "current time" from validity range lower bound ---
    // We require a finite lower bound. Without it, we cannot compute
    // vested amount (the TX would be valid from the dawn of time).
    let current_time = get_lower_bound(tx)

    // --- 3. Cliff check: reject if before cliff ---
    let past_cliff = current_time >= d.cliff_time

    // --- 4. Compute vested amount ---
    let vested_amount =
      if current_time >= d.vesting_end_time {
        d.total_vesting_amount
      } else {
        // Linear interpolation.
        // vested = total * (current_time - cliff_time) / (vesting_end_time - cliff_time)
        let elapsed = current_time - d.cliff_time
        let duration = d.vesting_end_time - d.cliff_time
        d.total_vesting_amount * elapsed / duration
      }

    // Clamp: cannot claim more than what's actually locked.
    let claimable = min_int(vested_amount, locked_lovelace)

    // --- 5. Compute what must remain at the script ---
    let must_remain = locked_lovelace - claimable

    // --- 6. Verify beneficiary receives at least `claimable` lovelace ---
    //        Check ONLY the output at the pinned `beneficiary_index`.
    let beneficiary_paid =
      if claimable <= 0 {
        // Nothing to claim (shouldn't happen past cliff with valid datum, but safe).
        False
      } else {
        // Index must be in bounds and output must pay the beneficiary.
        expect Some(beneficiary_output) =
          list.at(tx.outputs, beneficiary_index)
        let pays_beneficiary =
          beneficiary_output.address.payment_credential == VerificationKey(
            d.beneficiary,
          )
        let enough_value = lovelace_of(beneficiary_output.value) >= claimable
        pays_beneficiary && enough_value
      }

    // --- 7. Verify continuation UTxO at script address (if funds remain) ---
    //        Check ONLY the output at the pinned `continuation_index`.
    let continuation_valid =
      if must_remain <= 0 {
        // Fully vested & claimed: no continuation needed.
        True
      } else {
        // The pinned continuation output must:
        //   a) be at the same script address
        //   b) hold at least `must_remain` lovelace
        //   c) carry an identical datum (prevents datum hijacking)
        //   d) be a different output than the beneficiary payment
        expect Some(cont_output) =
          list.at(tx.outputs, continuation_index)

        // Indices must differ — cannot use one output for both roles.
        let indices_differ = beneficiary_index != continuation_index

        let address_ok = cont_output.address == script_address
        let value_ok = lovelace_of(cont_output.value) >= must_remain
        let datum_ok =
          when cont_output.datum is {
            InlineDatum(raw) -> {
              expect cont_datum: VestingDatum = raw
              cont_datum.beneficiary == d.beneficiary && cont_datum.total_vesting_amount == d.total_vesting_amount && cont_datum.cliff_time == d.cliff_time && cont_datum.vesting_end_time == d.vesting_end_time
            }
            _ -> False
          }

        and {
          indices_differ,
          address_ok,
          value_ok,
          datum_ok,
        }
      }

    and {
      beneficiary_signed,
      past_cliff,
      beneficiary_paid,
      continuation_valid,
    }
  }
}

/// Extract the finite lower bound from the transaction validity range.
/// Fails (aborts) if no finite lower bound is set.
///
/// Note: assumes the lower bound is inclusive, which is standard for
/// Cardano transactions. If exclusive, time is off by 1ms (conservative).
fn get_lower_bound(tx: Transaction) -> Int {
  expect Finite(t) = tx.validity_range.lower_bound.bound_type
  t
}

/// Return the smaller of two integers.
fn min_int(a: Int, b: Int) -> Int {
  if a <= b {
    a
  } else {
    b
  }
}
