"""Tests for AgentWalletManager — spend policy enforcement and audit logging."""

import time
from unittest.mock import MagicMock, patch

import pytest
from pycardano import Address, Network, PaymentSigningKey, PaymentVerificationKey

from vector_agent.models import AuditEntry, SpendPolicy, MIN_AP3X_DEPOSIT_DFM
from vector_agent.wallet_manager import AgentWalletManager, SpendPolicyViolation


# ──────────────────────────────────────────────────────────────────────
# Fixtures
# ──────────────────────────────────────────────────────────────────────


@pytest.fixture
def skey():
    """Generate a fresh signing key for tests."""
    return PaymentSigningKey.generate()


@pytest.fixture
def mock_registry():
    """A mock AgentRegistry with no real chain connection."""
    reg = MagicMock()
    reg._config = MagicMock()
    reg._config.network = Network.TESTNET
    reg.script_address = MagicMock()
    reg.script_address.encode.return_value = "addr_test1_script_address"
    return reg


@pytest.fixture
def wallet(skey, mock_registry):
    """A wallet manager with default spend policy."""
    return AgentWalletManager.from_signing_key(skey, mock_registry)


@pytest.fixture
def strict_wallet(skey, mock_registry):
    """A wallet manager with a strict spend policy."""
    policy = SpendPolicy(
        per_tx_lovelace=20_000_000,  # 20 AP3X max per tx
        daily_lovelace=50_000_000,   # 50 AP3X max per day
        allowlist=["addr_test1_allowed"],
        blocklist=["addr_test1_blocked"],
    )
    return AgentWalletManager.from_signing_key(skey, mock_registry, policy)


# ──────────────────────────────────────────────────────────────────────
# Construction and properties
# ──────────────────────────────────────────────────────────────────────


class TestConstruction:
    def test_creates_from_signing_key(self, skey, mock_registry):
        wm = AgentWalletManager.from_signing_key(skey, mock_registry)
        assert wm is not None

    def test_owner_vkh_is_hex(self, wallet):
        vkh = wallet.owner_vkh_hex
        assert len(vkh) == 56  # 28 bytes hex
        bytes.fromhex(vkh)  # must be valid hex

    def test_default_spend_policy(self, wallet):
        p = wallet.spend_policy
        assert p.per_tx_lovelace == 100_000_000
        assert p.daily_lovelace == 500_000_000
        assert p.allowlist == []
        assert p.blocklist == []

    def test_audit_log_starts_empty(self, wallet):
        assert wallet.audit_log == []

    def test_daily_spent_starts_zero(self, wallet):
        assert wallet.daily_spent_total() == 0


# ──────────────────────────────────────────────────────────────────────
# Spend policy enforcement
# ──────────────────────────────────────────────────────────────────────


class TestSpendPolicy:
    def test_per_tx_limit_allows_below(self, strict_wallet):
        # 15M < 20M limit → should pass
        strict_wallet._enforce_spend_policy(
            15_000_000, "addr_test1_allowed", "send"
        )

    def test_per_tx_limit_blocks_above(self, strict_wallet):
        with pytest.raises(SpendPolicyViolation, match="Per-tx limit"):
            strict_wallet._enforce_spend_policy(
                25_000_000, "addr_test1_allowed", "send"
            )

    def test_per_tx_limit_allows_exact(self, strict_wallet):
        strict_wallet._enforce_spend_policy(
            20_000_000, "addr_test1_allowed", "send"
        )

    def test_daily_limit_accumulates(self, strict_wallet):
        # 3 x 15M = 45M, under 50M daily limit → all pass
        strict_wallet._enforce_spend_policy(
            15_000_000, "addr_test1_allowed", "send"
        )
        strict_wallet._enforce_spend_policy(
            15_000_000, "addr_test1_allowed", "send"
        )
        strict_wallet._enforce_spend_policy(
            15_000_000, "addr_test1_allowed", "send"
        )

    def test_daily_limit_blocks_when_exceeded(self, strict_wallet):
        # 15M + 15M + 15M = 45M ok, then 10M = 55M > 50M → blocked
        strict_wallet._enforce_spend_policy(
            15_000_000, "addr_test1_allowed", "send"
        )
        strict_wallet._enforce_spend_policy(
            15_000_000, "addr_test1_allowed", "send"
        )
        strict_wallet._enforce_spend_policy(
            15_000_000, "addr_test1_allowed", "send"
        )
        with pytest.raises(SpendPolicyViolation, match="Daily limit"):
            strict_wallet._enforce_spend_policy(
                10_000_000, "addr_test1_allowed", "send"
            )

    def test_blocklist_rejects(self, strict_wallet):
        with pytest.raises(SpendPolicyViolation, match="blocklisted"):
            strict_wallet._enforce_spend_policy(
                1_000_000, "addr_test1_blocked", "send"
            )

    def test_allowlist_rejects_unlisted(self, strict_wallet):
        with pytest.raises(SpendPolicyViolation, match="not in allowlist"):
            strict_wallet._enforce_spend_policy(
                1_000_000, "addr_test1_unknown", "send"
            )

    def test_allowlist_permits_listed(self, strict_wallet):
        strict_wallet._enforce_spend_policy(
            1_000_000, "addr_test1_allowed", "send"
        )

    def test_empty_allowlist_permits_all(self, wallet):
        # Default policy has empty allowlist → no restriction
        wallet._enforce_spend_policy(
            1_000_000, "addr_test1_anything", "send"
        )

    def test_blocklist_checked_before_allowlist(self, strict_wallet):
        """If an address is on both lists, blocklist wins."""
        # Add blocked address to allowlist too
        strict_wallet._policy.allowlist.append("addr_test1_blocked")
        with pytest.raises(SpendPolicyViolation, match="blocklisted"):
            strict_wallet._enforce_spend_policy(
                1_000_000, "addr_test1_blocked", "send"
            )

    def test_set_spend_policy_updates(self, wallet):
        new_policy = SpendPolicy(per_tx_lovelace=5_000_000)
        wallet.set_spend_policy(new_policy)
        assert wallet.spend_policy.per_tx_lovelace == 5_000_000

    def test_check_send_validates(self, strict_wallet):
        # Should not raise
        strict_wallet.check_send(1_000_000, "addr_test1_allowed")

    def test_check_send_raises_on_violation(self, strict_wallet):
        with pytest.raises(SpendPolicyViolation):
            strict_wallet.check_send(100_000_000, "addr_test1_allowed")


# ──────────────────────────────────────────────────────────────────────
# Audit logging
# ──────────────────────────────────────────────────────────────────────


class TestAuditLog:
    def test_blocked_action_logged(self, strict_wallet):
        with pytest.raises(SpendPolicyViolation):
            strict_wallet._enforce_spend_policy(
                100_000_000, "addr_test1_allowed", "send"
            )
        assert len(strict_wallet.audit_log) == 1
        entry = strict_wallet.audit_log[0]
        assert entry.action == "blocked"
        assert entry.tx_hash is None
        assert entry.lovelace == 100_000_000
        assert "Per-tx limit" in entry.details

    def test_successful_spend_not_logged_by_enforce(self, wallet):
        # _enforce_spend_policy doesn't log success — only callers do
        wallet._enforce_spend_policy(1_000_000, "somewhere", "send")
        assert len(wallet.audit_log) == 0

    def test_record_audit_appends(self, wallet):
        wallet._record_audit("test_action", "abc123", 5_000_000, "dest", "test")
        assert len(wallet.audit_log) == 1
        entry = wallet.audit_log[0]
        assert entry.action == "test_action"
        assert entry.tx_hash == "abc123"
        assert entry.lovelace == 5_000_000

    def test_export_audit_log(self, wallet, tmp_path):
        wallet._record_audit("register", "hash1", 10_000_000, "dest1", "test1")
        wallet._record_audit("update", "hash2", 0, "dest2", "test2")

        export_path = str(tmp_path / "audit.json")
        wallet.export_audit_log(export_path)

        import json
        with open(export_path) as f:
            data = json.load(f)
        assert len(data) == 2
        assert data[0]["action"] == "register"
        assert data[1]["action"] == "update"

    def test_audit_log_is_readonly_copy(self, wallet):
        wallet._record_audit("test", "h", 0, "d", "details")
        log = wallet.audit_log
        log.clear()  # Mutating the copy
        assert len(wallet.audit_log) == 1  # Original unchanged


# ──────────────────────────────────────────────────────────────────────
# Daily window
# ──────────────────────────────────────────────────────────────────────


class TestDailyWindow:
    def test_daily_spent_tracks(self, wallet):
        wallet._enforce_spend_policy(5_000_000, "dest", "send")
        wallet._enforce_spend_policy(3_000_000, "dest", "send")
        assert wallet.daily_spent_total() == 8_000_000

    def test_old_entries_expire(self, wallet):
        # Inject an old entry (25 hours ago)
        old_ts = int(time.time() * 1000) - 25 * 60 * 60 * 1000
        wallet._daily_spent.append((old_ts, 999_000_000))
        # Should not count toward daily total
        assert wallet.daily_spent_total() == 0

    def test_recent_entries_count(self, wallet):
        # Inject a 1-hour-old entry
        recent_ts = int(time.time() * 1000) - 1 * 60 * 60 * 1000
        wallet._daily_spent.append((recent_ts, 50_000_000))
        assert wallet.daily_spent_total() == 50_000_000


# ──────────────────────────────────────────────────────────────────────
# Register flow (with mocked registry)
# ──────────────────────────────────────────────────────────────────────


class TestRegisterFlow:
    def test_register_calls_registry(self, wallet, mock_registry):
        mock_registry.register.return_value = "tx_hash_123"

        tx = wallet.register_agent(
            name="TestBot",
            description="A test agent",
            capabilities=["testing"],
            framework="pytest",
            endpoint="https://example.com",
        )

        assert tx == "tx_hash_123"
        mock_registry.register.assert_called_once()
        # Check audit log
        assert len(wallet.audit_log) == 1
        assert wallet.audit_log[0].action == "register"
        assert wallet.audit_log[0].tx_hash == "tx_hash_123"

    def test_register_blocked_by_policy(self, skey, mock_registry):
        # Policy: max 5M per tx, but deposit is 10M
        tight_policy = SpendPolicy(per_tx_lovelace=5_000_000)
        wm = AgentWalletManager.from_signing_key(skey, mock_registry, tight_policy)

        with pytest.raises(SpendPolicyViolation, match="Per-tx limit"):
            wm.register_agent(
                name="Bot",
                description="desc",
                capabilities=[],
                framework="f",
                endpoint="e",
            )

        # Registry should NOT have been called
        mock_registry.register.assert_not_called()
        # But the block should be logged
        assert len(wm.audit_log) == 1
        assert wm.audit_log[0].action == "blocked"


class TestUpdateFlow:
    def test_update_calls_registry(self, wallet, mock_registry):
        mock_registry.update.return_value = "tx_hash_456"
        mock_utxo = MagicMock()

        tx = wallet.update_agent(agent_utxo=mock_utxo, name="UpdatedBot")

        assert tx == "tx_hash_456"
        mock_registry.update.assert_called_once()
        assert len(wallet.audit_log) == 1
        assert wallet.audit_log[0].action == "update"


class TestDeregisterFlow:
    def test_deregister_calls_registry(self, wallet, mock_registry):
        mock_registry.deregister.return_value = "tx_hash_789"
        mock_utxo = MagicMock()

        tx = wallet.deregister_agent(agent_utxo=mock_utxo)

        assert tx == "tx_hash_789"
        mock_registry.deregister.assert_called_once()
        assert len(wallet.audit_log) == 1
        assert wallet.audit_log[0].action == "deregister"
