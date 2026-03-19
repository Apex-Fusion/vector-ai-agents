/// Vector Agent Registry — Multi-Validator
///
/// A single script that serves as both:
///   - Minting policy: controls NFT lifecycle (Register / Burn)
///   - Spend validator: controls UTxO lifecycle (Update / Deregister)
///
/// Because both handlers share the same script hash:
///   policy_id == script_hash == payment_credential of the registry address
///
/// Core validation logic lives in `agent_registry/validation.ak`
/// so it can be unit-tested independently.
///
/// [SECURITY] No changes needed to the multi-validator wrapper.
/// All security fixes are in validation.ak.

use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use agent_registry/types.{
  AgentDatum,
  Burn, Deregister, MintAction, Register, SpendAction, Update,
}
use agent_registry/validation

validator registry {
  /// Minting policy: controls identity NFT creation and destruction.
  mint(redeemer: MintAction, policy_id: PolicyId, tx: Transaction) {
    when redeemer is {
      Register { seed } -> validation.validate_register(seed, policy_id, tx)
      Burn -> validation.validate_burn(policy_id, tx)
    }
  }

  /// Spend validator: controls agent UTxO updates and deregistration.
  spend(
    datum: Option<AgentDatum>,
    redeemer: SpendAction,
    own_utxo: OutputReference,
    tx: Transaction,
  ) {
    expect Some(agent_datum) = datum
    when redeemer is {
      Update -> validation.validate_update(agent_datum, own_utxo, tx)
      Deregister -> validation.validate_deregister(agent_datum, own_utxo, tx)
    }
  }

  else(_ctx) {
    fail @"Unsupported script purpose"
  }
}
