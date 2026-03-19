"""Tests for data models."""

from vector_agent.models import (
    AgentProfile,
    MintAction,
    SpendAction,
    SpendPolicy,
    MIN_AP3X_DEPOSIT_DFM,
    AP3X_DECIMALS,
)

SAMPLE_POLICY_ID = "ab" * 28
SAMPLE_NFT_NAME = "cd" * 32


def test_agent_profile_defaults():
    profile = AgentProfile(
        owner="ab" * 14,
        name="TestBot",
        description="A test agent",
        capabilities=["testing"],
        framework="pytest",
        endpoint="https://example.com/agent",
    )
    assert profile.name == "TestBot"
    assert profile.registered_at > 0
    assert profile.utxo_ref is None
    assert profile.nft_asset_name is None
    assert profile.policy_id is None
    assert profile.agent_id is None


def test_agent_profile_with_nft():
    profile = AgentProfile(
        owner="ab" * 14,
        name="TestBot",
        description="A test agent",
        capabilities=["testing"],
        framework="pytest",
        endpoint="https://example.com/agent",
        policy_id=SAMPLE_POLICY_ID,
        nft_asset_name=SAMPLE_NFT_NAME,
    )
    assert profile.agent_id == f"did:vector:agent:{SAMPLE_POLICY_ID}:{SAMPLE_NFT_NAME}"


def test_agent_id_requires_both_fields():
    """agent_id returns None if either policy_id or nft_asset_name is missing."""
    profile = AgentProfile(
        owner="ab" * 14,
        name="TestBot",
        description="A test agent",
        capabilities=["testing"],
        framework="pytest",
        endpoint="https://example.com/agent",
        policy_id=SAMPLE_POLICY_ID,
        # nft_asset_name intentionally omitted
    )
    assert profile.agent_id is None


def test_mint_action_values():
    assert MintAction.REGISTER.value == 0
    assert MintAction.BURN.value == 1


def test_spend_action_values():
    assert SpendAction.UPDATE.value == 0
    assert SpendAction.DEREGISTER.value == 1


def test_spend_policy_defaults():
    policy = SpendPolicy()
    assert policy.per_tx_lovelace == 100_000_000
    assert policy.daily_lovelace == 500_000_000
    assert policy.allowlist == []
    assert policy.blocklist == []


def test_ap3x_config():
    assert AP3X_DECIMALS == 6
    assert MIN_AP3X_DEPOSIT_DFM == 10_000_000  # 10 AP3X
    assert MIN_AP3X_DEPOSIT_DFM == 10 * (10 ** AP3X_DECIMALS)
