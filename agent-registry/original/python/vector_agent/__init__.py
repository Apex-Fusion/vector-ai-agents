"""
Vector Agent Infrastructure — Python SDK for the Vector Agent Registry.

Register, update, and manage AI agents on the Vector blockchain.

Public API:
    - AgentRegistry          — chain client (register/update/deregister/query)
    - AgentWalletManager     — audited wallet wrapper with spend policy
    - AgentProfile           — off-chain agent profile model
    - SpendPolicy            — off-chain spend limits configuration
    - SpendPolicyViolation   — exception for policy violations
    - make_did / parse_did   — DID utilities (did:vector:agent:{policy}:{nft})

Quick start:
    from vector_agent import AgentRegistry, AgentWalletManager

    registry = AgentRegistry.from_blueprint("path/to/plutus.json")
    registry.connect_ogmios("ogmios.vector.testnet.apexfusion.org", port=443, secure=True)

    wm = AgentWalletManager.from_keys("payment.skey", registry)
    tx = wm.register_agent(name="MyBot", description="...", ...)
"""

__version__ = "0.1.0"

from vector_agent.registry import AgentRegistry
from vector_agent.wallet_manager import AgentWalletManager, SpendPolicyViolation
from vector_agent.models import AgentProfile, SpendPolicy, AuditEntry, MIN_AP3X_DEPOSIT_DFM
from vector_agent.did import make_did, parse_did, is_valid_did
from vector_agent.plutus_data import (
    AgentDatum,
    OutputReference,
    VerificationKeyCredential,
    ScriptCredential,
    RegisterRedeemer,
    BurnRedeemer,
    UpdateRedeemer,
    DeregisterRedeemer,
)

__all__ = [
    # Core client
    "AgentRegistry",
    "AgentWalletManager",
    "SpendPolicyViolation",
    # Models
    "AgentProfile",
    "SpendPolicy",
    "AuditEntry",
    "MIN_AP3X_DEPOSIT_DFM",
    # DID utilities
    "make_did",
    "parse_did",
    "is_valid_did",
    # PlutusData types
    "AgentDatum",
    "OutputReference",
    "VerificationKeyCredential",
    "ScriptCredential",
    "RegisterRedeemer",
    "BurnRedeemer",
    "UpdateRedeemer",
    "DeregisterRedeemer",
]
