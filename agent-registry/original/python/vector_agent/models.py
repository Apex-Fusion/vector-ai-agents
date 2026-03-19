"""
Off-chain data models for the Vector Agent Registry.

These models mirror the on-chain Aiken types defined in:
  contracts/agent-registry/lib/agent_registry/types.ak

The Plutus blueprint (plutus.json) is the source of truth for serialization.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from enum import Enum
from typing import List, Optional


# ──────────────────────────────────────────────────────────────────────
# AP3X deposit configuration
# AP3X is the native coin on Vector (like ADA on Cardano), 6 decimal places.
# Smallest unit: DFM (like lovelace on Cardano). 1 AP3X = 1_000_000 DFM.
# No policy ID needed — it's the native coin in the UTxO value.
# ──────────────────────────────────────────────────────────────────────

MIN_AP3X_DEPOSIT_DFM = 10_000_000  # 10 AP3X = 10 * 1_000_000 DFM
AP3X_DECIMALS = 6


@dataclass
class AgentProfile:
    """
    Off-chain representation of an agent's registry entry.

    Maps 1:1 to the on-chain AgentDatum. The `owner` field is the hex-encoded
    payment credential (verification key hash) of the agent owner.

    On-chain, this is stored as an inline datum on a UTxO at the registry
    validator address, alongside an identity NFT and ≥10 AP3X native deposit.
    """

    owner: str
    """Hex-encoded verification key hash of the agent owner."""

    name: str
    """Human-readable agent name (e.g. 'EnviroBot')."""

    description: str
    """Short description of what this agent does."""

    capabilities: List[str]
    """List of capability tags (e.g. ['investing', 'research'])."""

    framework: str
    """Framework identifier (e.g. 'OpenClaw', 'LangChain', 'CrewAI', 'AutoGen', 'ElizaOS')."""

    endpoint: str
    """Off-chain endpoint URL for A2A communication."""

    registered_at: int = field(default_factory=lambda: int(time.time() * 1000))
    """POSIX timestamp in milliseconds of registration."""

    # --- Off-chain only fields (not stored on-chain) ---

    utxo_ref: Optional[str] = None
    """UTxO reference (tx_hash#index) where this agent's datum lives on-chain.
    Populated when reading from chain."""

    nft_asset_name: Optional[str] = None
    """Hex-encoded NFT asset name (blake2b_256 of seed UTxO ref).
    Stable across updates — only set once at registration."""

    policy_id: Optional[str] = None
    """Hex-encoded policy ID of the registry multi-validator.
    Same as the script hash. Populated when reading from chain."""

    @property
    def agent_id(self) -> Optional[str]:
        """
        Derive the agent's DID from its identity NFT.

        Format: did:vector:agent:{policy_id}:{nft_asset_name}

        This DID is stable across profile updates because the NFT
        asset name doesn't change — only the UTxO reference does.

        Returns None if policy_id or nft_asset_name is not set.
        """
        if self.policy_id is None or self.nft_asset_name is None:
            return None
        return f"did:vector:agent:{self.policy_id}:{self.nft_asset_name}"


class MintAction(Enum):
    """
    Redeemer for the mint handler (NFT lifecycle).
    Maps to on-chain MintAction type.

    - REGISTER (constructor index 0): mint NFT, requires seed UTxO reference
    - BURN (constructor index 1): burn NFT during deregistration
    """

    REGISTER = 0
    BURN = 1


class SpendAction(Enum):
    """
    Redeemer for the spend handler (UTxO lifecycle).
    Maps to on-chain SpendAction type.

    - UPDATE (constructor index 0): modify agent profile, NFT continues
    - DEREGISTER (constructor index 1): remove agent, NFT must be burned
    """

    UPDATE = 0
    DEREGISTER = 1


@dataclass
class SpendPolicy:
    """
    Spend limits enforced off-chain by the AgentWalletManager.

    These are NOT enforced on-chain — they are local safety guardrails
    that the SDK enforces before building transactions.
    """

    per_tx_lovelace: int = 100_000_000
    """Maximum lovelace per single transaction (default: 100 ADA)."""

    daily_lovelace: int = 500_000_000
    """Maximum lovelace per 24h rolling window (default: 500 ADA)."""

    allowlist: List[str] = field(default_factory=list)
    """If non-empty, only these addresses can receive funds."""

    blocklist: List[str] = field(default_factory=list)
    """These addresses are always blocked from receiving funds."""


@dataclass
class AuditEntry:
    """A single entry in the wallet manager's audit log."""

    timestamp: int
    """POSIX timestamp in milliseconds."""

    action: str
    """Action type: 'send', 'register', 'update', 'deregister', 'blocked'."""

    tx_hash: Optional[str]
    """Transaction hash if submitted, None if blocked."""

    lovelace: int
    """Amount of lovelace involved."""

    destination: Optional[str]
    """Destination address, if applicable."""

    details: str = ""
    """Human-readable description of what happened."""
