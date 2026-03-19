"""
PyCardano PlutusData definitions matching the on-chain Aiken types.

These classes are derived from the Plutus blueprint (plutus.json) and must
stay in sync with `contracts/agent-registry/lib/agent_registry/types.ak`.

CONSTR_ID values match the constructor index in the blueprint.
Field order matches the on-chain CBOR serialization order.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Union

from pycardano import PlutusData
from pycardano.serialization import IndefiniteList


# ──────────────────────────────────────────────────────────────────────
# Credential types (cardano/address/Credential)
# ──────────────────────────────────────────────────────────────────────


@dataclass
class VerificationKeyCredential(PlutusData):
    """Constructor 0: VerificationKey(VerificationKeyHash)"""
    CONSTR_ID = 0
    vkey_hash: bytes


@dataclass
class ScriptCredential(PlutusData):
    """Constructor 1: Script(ScriptHash)"""
    CONSTR_ID = 1
    script_hash: bytes


Credential = Union[VerificationKeyCredential, ScriptCredential]


# ──────────────────────────────────────────────────────────────────────
# OutputReference (cardano/transaction/OutputReference)
# ──────────────────────────────────────────────────────────────────────


@dataclass
class OutputReference(PlutusData):
    """Constructor 0: OutputReference { transaction_id, output_index }"""
    CONSTR_ID = 0
    transaction_id: bytes  # 32-byte tx hash
    output_index: int


# ──────────────────────────────────────────────────────────────────────
# AgentDatum (agent_registry/types/AgentDatum)
# ──────────────────────────────────────────────────────────────────────


@dataclass
class AgentDatum(PlutusData):
    """
    The inline datum stored on each agent's registry UTxO.

    Constructor index 0 — matches Aiken's AgentDatum type.
    Fields are in the same order as the on-chain type.
    """
    CONSTR_ID = 0
    owner: Credential                    # VerificationKeyCredential or ScriptCredential
    name: bytes                          # UTF-8 encoded agent name
    description: bytes                   # UTF-8 encoded description
    capabilities: IndefiniteList          # List<ByteArray> — list of UTF-8 capability tags
    framework: bytes                     # UTF-8 encoded framework identifier
    endpoint: bytes                      # UTF-8 encoded A2A endpoint URL
    registered_at: int                   # POSIX timestamp in milliseconds


# ──────────────────────────────────────────────────────────────────────
# MintAction redeemers (agent_registry/types/MintAction)
# ──────────────────────────────────────────────────────────────────────


@dataclass
class RegisterRedeemer(PlutusData):
    """Constructor 0: Register { seed: OutputReference }"""
    CONSTR_ID = 0
    seed: OutputReference


@dataclass
class BurnRedeemer(PlutusData):
    """Constructor 1: Burn (no fields)"""
    CONSTR_ID = 1


# ──────────────────────────────────────────────────────────────────────
# SpendAction redeemers (agent_registry/types/SpendAction)
# ──────────────────────────────────────────────────────────────────────


@dataclass
class UpdateRedeemer(PlutusData):
    """Constructor 0: Update (no fields)"""
    CONSTR_ID = 0


@dataclass
class DeregisterRedeemer(PlutusData):
    """Constructor 1: Deregister (no fields)"""
    CONSTR_ID = 1
