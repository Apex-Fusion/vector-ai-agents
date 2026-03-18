"""
DID (Decentralized Identifier) utilities for Vector agents.

DID format: did:vector:agent:{policy_id}:{nft_asset_name}

The agent's DID is derived from its identity NFT (policy ID + asset name).
Since the NFT asset name is derived from the seed UTxO at registration time
and never changes (it moves with the agent across updates), the DID is
**stable across profile updates**.

On deregister the NFT is burned, retiring the DID.
"""

from __future__ import annotations

DID_PREFIX = "did:vector:agent"


def make_did(policy_id: str, nft_asset_name: str) -> str:
    """
    Construct a Vector agent DID from its identity NFT.

    Args:
        policy_id: Registry script hash / NFT policy ID (hex, 56 chars).
        nft_asset_name: NFT asset name (hex, 64 chars — blake2b_256 hash).

    Returns:
        DID string in format did:vector:agent:{policy_id}:{nft_asset_name}
    """
    if len(policy_id) != 56:
        raise ValueError(f"policy_id must be 56 hex chars, got {len(policy_id)}")
    if len(nft_asset_name) != 64:
        raise ValueError(f"nft_asset_name must be 64 hex chars, got {len(nft_asset_name)}")
    return f"{DID_PREFIX}:{policy_id}:{nft_asset_name}"


def parse_did(did: str) -> tuple[str, str]:
    """
    Parse a Vector agent DID into its components.

    Args:
        did: DID string in format did:vector:agent:{policy_id}:{nft_asset_name}

    Returns:
        Tuple of (policy_id, nft_asset_name).

    Raises:
        ValueError: If the DID format is invalid.
    """
    parts = did.split(":")
    if len(parts) != 5 or parts[:3] != ["did", "vector", "agent"]:
        raise ValueError(f"Invalid Vector agent DID: {did}")
    policy_id = parts[3]
    if len(policy_id) != 56:
        raise ValueError(f"Invalid policy_id in DID: expected 56 hex chars, got {len(policy_id)}")
    nft_asset_name = parts[4]
    if len(nft_asset_name) != 64:
        raise ValueError(
            f"Invalid nft_asset_name in DID: expected 64 hex chars, got {len(nft_asset_name)}"
        )
    return policy_id, nft_asset_name


def is_valid_did(did: str) -> bool:
    """Check if a string is a valid Vector agent DID."""
    try:
        parse_did(did)
        return True
    except ValueError:
        return False
