/// On-chain types for the Vector Agent Registry.
///
/// Each registered agent is stored as a UTxO at the registry validator address.
/// The UTxO contains an inline AgentDatum and an identity NFT minted by the
/// same multi-validator (policy ID == script hash).
///
/// The NFT lives at the script address (never in the user's wallet), making it
/// effectively soulbound. On deregister the NFT is burned.
///
/// [ISKRA] No type changes needed. All fixes are in validation logic.

use cardano/address.{Credential}
use cardano/transaction.{OutputReference}

/// The profile data stored on-chain for each registered agent.
pub type AgentDatum {
  /// Payment credential of the agent owner (who can update/deregister)
  owner: Credential,
  /// Human-readable agent name (e.g. "EnviroBot")
  name: ByteArray,
  /// Short description of what this agent does
  description: ByteArray,
  /// List of capability tags (e.g. ["investing", "research"])
  capabilities: List<ByteArray>,
  /// Framework identifier (e.g. "OpenClaw", "LangChain", "CrewAI")
  framework: ByteArray,
  /// Off-chain endpoint URL for A2A communication
  endpoint: ByteArray,
  /// POSIX timestamp of registration
  registered_at: Int,
}

/// Redeemer for the mint handler (NFT lifecycle).
pub type MintAction {
  /// Mint a new agent identity NFT during registration.
  /// The seed UTxO is consumed to derive a unique asset name.
  Register { seed: OutputReference }
  /// Burn an agent identity NFT during deregistration.
  Burn
}

/// Redeemer for the spend handler (UTxO lifecycle).
pub type SpendAction {
  /// Update agent profile — must produce continuing output with same NFT
  Update
  /// Remove agent from registry — NFT must be burned in same TX
  Deregister
}
