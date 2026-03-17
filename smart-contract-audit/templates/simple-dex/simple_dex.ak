/// # Simple DEX Validator
///
/// A basic peer-to-peer token swap contract. A maker creates a swap offer
/// by locking token A at the script address, specifying the desired token B
/// and an exchange rate. A taker can fulfill the offer by paying the maker
/// the correct amount of token B. The maker can cancel at any time.
///
/// ## Design
/// This is a **limit order** model: each swap offer is an independent UTxO.
/// No shared state, no batching, no liquidity pool. This avoids eUTxO
/// concurrency issues entirely — each offer can be taken independently.
///
/// ## Exchange Rate
/// The rate is expressed as a rational: for every `rate_numerator` units
/// of token A offered, the maker demands `rate_denominator` units of token B.
///
/// required_b = (amount_a * rate_denominator) / rate_numerator
///
/// We use integer division and demand the taker pays **at least** the
/// ceiling of this ratio (rounding in the maker's favor).
///
/// ## Security Considerations
/// - **Double satisfaction**: Fixed via single-script-input enforcement.
///   The validator counts inputs from its own script address and requires
///   exactly one. This prevents an attacker from spending multiple swap
///   UTxOs in the same transaction and satisfying them with a single output.
///   The `Take` redeemer also carries `maker_output_index` for output pinning.
/// - **Partial fill attacks**: Not applicable — each offer is all-or-nothing.
///   The taker must pay for the ENTIRE locked amount. No partial fills.
/// - **Price manipulation via redeemer**: The exchange rate is fixed in the
///   datum (set by the maker). The redeemer only carries the output index —
///   it cannot influence the price calculation.
/// - **Datum hijacking**: We verify the maker receives payment at their
///   PKH address, not at a script address with a manipulated datum.
/// - **Redeemer manipulation**: Typed redeemers prevent structural attacks.
///   The index is bounds-checked. Cancel requires maker signature.
/// - **Missing signer checks**: Cancel requires maker's signature.
///   Take does NOT require a signature (anyone can fill an open offer —
///   this is by design for a DEX).
/// - **Alternative spending paths**: No minting, staking, or withdrawal
///   handlers. The validator only has `spend`. Aiken's default fallback
///   rejects all other purposes.
/// - **Stake credential attacks**: Maker payment is checked against
///   VerificationKey credential, not a full address. This means staking
///   credential can vary — acceptable since maker just receives tokens.
/// - **Token dust / large datum DoS**: Datum is fixed-size (5 fields).
///   The locked value is whatever the maker deposits — token dust at the
///   script address doesn't affect other offers (each UTxO is independent).
/// - **eUTxO concurrency DoS**: Not an issue — each offer is a separate
///   UTxO. No shared global state to contend over.
/// - **Zero-rate protection**: Validator rejects rate_numerator <= 0 or
///   rate_denominator <= 0, preventing division by zero or nonsensical rates.

use aiken/collection/list
use aiken/primitive/bytearray
use cardano/address.{VerificationKey}
use cardano/assets.{Value, lovelace_of, quantity_of}
use cardano/transaction.{OutputReference, Transaction, find_input}
use dex_types.{AssetClass, Cancel, SwapDatum, SwapRedeemer, Take}

validator simple_dex {
  spend(
    datum: Option<SwapDatum>,
    redeemer: SwapRedeemer,
    own_ref: Data,
    tx: Transaction,
  ) {
    // Datum must be present (inline datum).
    expect Some(d) = datum

    // Resolve own input to know what's locked.
    expect own_oref: OutputReference = own_ref
    expect Some(own_input) = find_input(tx.inputs, own_oref)

    // --- Double satisfaction prevention ---
    // Ensure exactly one script input (prevents double satisfaction attack).
    let script_address = own_input.output.address
    let script_input_count =
      list.count(tx.inputs, fn(i) { i.output.address == script_address })
    expect script_input_count == 1

    when redeemer is {
      Take { maker_output_index } -> {
        // --- Policy ID length validation ---
        // Cardano policy IDs are exactly 28 bytes (Blake2b-224).
        // Empty (#"") is ADA. Reject anything else.
        expect
          bytearray.length(d.offered_asset.policy_id) == 28 || d.offered_asset.policy_id == #""
        expect
          bytearray.length(d.desired_asset.policy_id) == 28 || d.desired_asset.policy_id == #""

        // --- Rate validation ---
        // Reject nonsensical rates that would cause division by zero
        // or negative/zero required payments.
        expect d.rate_numerator > 0
        expect d.rate_denominator > 0

        // --- Calculate how much token A is locked ---
        let locked_amount_a =
          get_asset_amount(own_input.output.value, d.offered_asset)
        // Must have something to swap
        expect locked_amount_a > 0

        // --- Calculate required token B payment to maker ---
        // required_b = ceil(locked_a * rate_denominator / rate_numerator)
        // We round up (ceiling division) to favor the maker.
        let required_b =
          ceiling_div(
            locked_amount_a * d.rate_denominator,
            d.rate_numerator,
          )

        // --- Verify maker receives payment at pinned output ---
        expect Some(maker_output) = list.at(tx.outputs, maker_output_index)

        // Maker must receive at their PKH address
        let pays_maker =
          maker_output.address.payment_credential == VerificationKey(d.maker)

        // Maker must receive at least required_b of the desired token
        let maker_received =
          get_asset_amount(maker_output.value, d.desired_asset)
        let enough_payment = maker_received >= required_b

        and {
          pays_maker,
          enough_payment,
        }
      }

      Cancel -> {
        // Only the maker can cancel their own offer.
        list.has(tx.extra_signatories, d.maker)
      }
    }
  }
}

/// Get the amount of a specific asset from a Value.
/// Handles both ADA (lovelace) and native tokens.
fn get_asset_amount(value: Value, asset: AssetClass) -> Int {
  if asset.policy_id == #"" && asset.asset_name == #"" {
    lovelace_of(value)
  } else {
    quantity_of(value, asset.policy_id, asset.asset_name)
  }
}

/// Integer ceiling division: ceil(a / b).
/// Requires: a >= 0, b > 0. Fails explicitly otherwise.
fn ceiling_div(a: Int, b: Int) -> Int {
  expect a >= 0
  expect b > 0
  let q = a / b
  if q * b == a {
    q
  } else {
    q + 1
  }
}
