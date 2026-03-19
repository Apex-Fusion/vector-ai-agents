"""Shared fixtures for the Vector Agent test suite."""

from pathlib import Path
from unittest.mock import MagicMock

import pytest
from pycardano import Network, PaymentSigningKey

from vector_agent.models import SpendPolicy
from vector_agent.registry import AgentRegistry


# ──────────────────────────────────────────────────────────────────────
# Paths
# ──────────────────────────────────────────────────────────────────────

BLUEPRINT_PATH = (
    Path(__file__).parent.parent.parent
    / "contracts"
    / "agent-registry"
    / "plutus.json"
)


# ──────────────────────────────────────────────────────────────────────
# Keys
# ──────────────────────────────────────────────────────────────────────


@pytest.fixture
def skey():
    """Generate a fresh payment signing key for tests."""
    return PaymentSigningKey.generate()


# ──────────────────────────────────────────────────────────────────────
# Registry (offline)
# ──────────────────────────────────────────────────────────────────────


@pytest.fixture
def blueprint_path():
    """Path to the compiled Plutus blueprint."""
    return str(BLUEPRINT_PATH)


@pytest.fixture
def registry():
    """An offline AgentRegistry loaded from the Plutus blueprint."""
    return AgentRegistry.from_blueprint(str(BLUEPRINT_PATH), network="testnet")


# ──────────────────────────────────────────────────────────────────────
# Mock registry (no chain)
# ──────────────────────────────────────────────────────────────────────


@pytest.fixture
def mock_registry():
    """A mock AgentRegistry with no real chain connection."""
    reg = MagicMock()
    reg._config = MagicMock()
    reg._config.network = Network.TESTNET
    reg.script_address = MagicMock()
    reg.script_address.encode.return_value = "addr_test1_script_address"
    reg.policy_id_hex = "ab" * 28
    reg.register.return_value = "tx_hash_mock"
    reg.update.return_value = "tx_hash_mock"
    reg.deregister.return_value = "tx_hash_mock"
    reg.query_agents.return_value = []
    return reg
