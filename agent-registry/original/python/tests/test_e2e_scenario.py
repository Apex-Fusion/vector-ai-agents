"""
End-to-end scenario test: Register → Update → Deregister.

This test exercises the full agent lifecycle through the WalletManager
with a mocked chain backend. It verifies:
  - The correct sequence of registry calls
  - Spend policy is enforced at each step
  - Audit log captures the complete lifecycle
  - DID derivation is consistent

No real chain connection required — uses mocks for chain interaction.
"""

from unittest.mock import MagicMock, patch, PropertyMock
from pathlib import Path

import pytest
from pycardano import Network, PaymentSigningKey, PaymentVerificationKey

from vector_agent.did import make_did, is_valid_did
from vector_agent.models import AgentProfile, SpendPolicy, MIN_AP3X_DEPOSIT_DFM
from vector_agent.wallet_manager import AgentWalletManager, SpendPolicyViolation


BLUEPRINT_PATH = (
    Path(__file__).parent.parent.parent
    / "contracts"
    / "agent-registry"
    / "plutus.json"
)


@pytest.fixture
def skey():
    return PaymentSigningKey.generate()


@pytest.fixture
def mock_registry():
    """Mock registry that simulates the full lifecycle."""
    reg = MagicMock()
    reg._config = MagicMock()
    reg._config.network = Network.TESTNET
    reg.script_address = MagicMock()
    reg.script_address.encode.return_value = "addr_test1_registry"
    reg.policy_id_hex = "ab" * 28

    # Simulate register returns a tx hash
    reg.register.return_value = "register_tx_aaa111"

    # Simulate update returns a tx hash
    reg.update.return_value = "update_tx_bbb222"

    # Simulate deregister returns a tx hash
    reg.deregister.return_value = "deregister_tx_ccc333"

    # Simulate query_agents returns our agent
    reg.query_agents.return_value = []

    return reg


class TestFullLifecycle:
    """
    Scenario: An agent registers, updates its profile, then deregisters.
    Verifies the complete flow through WalletManager → Registry → audit.
    """

    def test_register_update_deregister(self, skey, mock_registry):
        # ── Setup ──
        wm = AgentWalletManager.from_signing_key(
            skey,
            mock_registry,
            SpendPolicy(
                per_tx_lovelace=100_000_000,
                daily_lovelace=500_000_000,
            ),
        )

        # ── Step 1: Register ──
        tx1 = wm.register_agent(
            name="EnviroBot",
            description="Monitors environmental data on-chain",
            capabilities=["monitoring", "reporting"],
            framework="OpenClaw",
            endpoint="https://envirobot.example.com/a2a",
        )

        assert tx1 == "register_tx_aaa111"
        mock_registry.register.assert_called_once()

        # Verify the register call args
        call_kwargs = mock_registry.register.call_args.kwargs
        assert call_kwargs["name"] == "EnviroBot"
        assert call_kwargs["framework"] == "OpenClaw"
        assert call_kwargs["capabilities"] == ["monitoring", "reporting"]

        # Audit: 1 entry
        assert len(wm.audit_log) == 1
        assert wm.audit_log[0].action == "register"
        assert wm.audit_log[0].lovelace == MIN_AP3X_DEPOSIT_DFM

        # ── Step 2: Update ──
        mock_utxo = MagicMock()
        tx2 = wm.update_agent(
            agent_utxo=mock_utxo,
            name="EnviroBot v2",
            capabilities=["monitoring", "reporting", "alerting"],
        )

        assert tx2 == "update_tx_bbb222"
        mock_registry.update.assert_called_once()

        update_kwargs = mock_registry.update.call_args.kwargs
        assert update_kwargs["name"] == "EnviroBot v2"
        assert update_kwargs["capabilities"] == ["monitoring", "reporting", "alerting"]
        # Fields not passed should be None (registry preserves existing)
        assert update_kwargs["description"] is None
        assert update_kwargs["framework"] is None

        # Audit: 2 entries
        assert len(wm.audit_log) == 2
        assert wm.audit_log[1].action == "update"

        # ── Step 3: Deregister ──
        tx3 = wm.deregister_agent(agent_utxo=mock_utxo)

        assert tx3 == "deregister_tx_ccc333"
        mock_registry.deregister.assert_called_once()

        # Audit: 3 entries — complete lifecycle
        assert len(wm.audit_log) == 3
        assert wm.audit_log[2].action == "deregister"

        # ── Verify audit trail ──
        actions = [e.action for e in wm.audit_log]
        assert actions == ["register", "update", "deregister"]

        tx_hashes = [e.tx_hash for e in wm.audit_log]
        assert tx_hashes == [
            "register_tx_aaa111",
            "update_tx_bbb222",
            "deregister_tx_ccc333",
        ]

    def test_daily_limit_blocks_after_multiple_registers(self, skey, mock_registry):
        """
        Scenario: An owner tries to register 6 agents at 10 AP3X each.
        With a 50 AP3X daily limit, the 6th should be blocked.
        """
        wm = AgentWalletManager.from_signing_key(
            skey,
            mock_registry,
            SpendPolicy(
                per_tx_lovelace=100_000_000,  # 100 AP3X per tx — fine
                daily_lovelace=50_000_000,     # 50 AP3X per day
            ),
        )

        # Register 5 agents successfully (5 × 10M = 50M)
        for i in range(5):
            mock_registry.register.return_value = f"tx_{i}"
            wm.register_agent(
                name=f"Bot{i}",
                description="test",
                capabilities=[],
                framework="test",
                endpoint="https://test.com",
            )

        assert wm.daily_spent_total() == 50_000_000

        # 6th registration should be blocked
        with pytest.raises(SpendPolicyViolation, match="Daily limit"):
            wm.register_agent(
                name="Bot5",
                description="one too many",
                capabilities=[],
                framework="test",
                endpoint="https://test.com",
            )

        # Audit: 5 successful + 1 blocked = 6 entries
        assert len(wm.audit_log) == 6
        assert wm.audit_log[5].action == "blocked"


class TestDIDConsistency:
    """Verify DID format works end-to-end with the models."""

    def test_did_from_profile(self):
        policy_id = "ab" * 28
        nft_name = "cd" * 32

        profile = AgentProfile(
            owner="11" * 28,
            name="TestBot",
            description="desc",
            capabilities=["test"],
            framework="fw",
            endpoint="https://test.com",
            policy_id=policy_id,
            nft_asset_name=nft_name,
        )

        # DID from profile matches manual construction
        assert profile.agent_id == make_did(policy_id, nft_name)
        assert is_valid_did(profile.agent_id)

    def test_did_survives_update(self):
        """DID doesn't change when profile fields change (same NFT)."""
        policy_id = "ab" * 28
        nft_name = "cd" * 32

        profile_v1 = AgentProfile(
            owner="11" * 28,
            name="BotV1",
            description="version 1",
            capabilities=["v1"],
            framework="fw",
            endpoint="https://v1.test.com",
            policy_id=policy_id,
            nft_asset_name=nft_name,
        )

        profile_v2 = AgentProfile(
            owner="11" * 28,
            name="BotV2",
            description="version 2",
            capabilities=["v1", "v2"],
            framework="fw",
            endpoint="https://v2.test.com",
            policy_id=policy_id,
            nft_asset_name=nft_name,
        )

        assert profile_v1.agent_id == profile_v2.agent_id


class TestAuditExport:
    """Verify the full lifecycle audit can be exported and reloaded."""

    def test_export_lifecycle_audit(self, skey, mock_registry, tmp_path):
        wm = AgentWalletManager.from_signing_key(skey, mock_registry)

        # Run through lifecycle
        mock_registry.register.return_value = "tx_r"
        wm.register_agent(
            name="Bot", description="d", capabilities=[], framework="f", endpoint="e"
        )

        mock_registry.update.return_value = "tx_u"
        wm.update_agent(agent_utxo=MagicMock(), name="Bot2")

        mock_registry.deregister.return_value = "tx_d"
        wm.deregister_agent(agent_utxo=MagicMock())

        # Export
        export_path = str(tmp_path / "lifecycle_audit.json")
        wm.export_audit_log(export_path)

        # Reload and verify
        import json
        with open(export_path) as f:
            data = json.load(f)

        assert len(data) == 3
        assert [e["action"] for e in data] == ["register", "update", "deregister"]
        assert all(e["timestamp"] > 0 for e in data)
        assert data[0]["tx_hash"] == "tx_r"
        assert data[1]["tx_hash"] == "tx_u"
        assert data[2]["tx_hash"] == "tx_d"
