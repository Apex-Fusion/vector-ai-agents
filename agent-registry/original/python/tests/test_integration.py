"""
Integration tests against the Vector testnet.

These tests require:
  1. A live Vector testnet Ogmios endpoint
  2. A funded testnet wallet (payment.skey with AP3X balance)

Run with:
    python -m pytest tests/test_integration.py -v -m integration

Skip with:
    python -m pytest tests/ -v -m "not integration"

Environment variables:
    VECTOR_SKEY_PATH      — Path to payment signing key file (.skey)
    VECTOR_OGMIOS_HOST    — Ogmios hostname (default: ogmios.vector.testnet.apexfusion.org)
    VECTOR_OGMIOS_PORT    — Ogmios port (default: 443)
    VECTOR_NETWORK        — "testnet" or "mainnet" (default: mainnet)
                            Note: Vector testnet uses mainnet network ID (addr1 addresses)
"""

from __future__ import annotations

import hashlib
import logging
import os
import time
from pathlib import Path
from typing import Optional

import pytest
from pycardano import (
    Address,
    Network,
    PaymentSigningKey,
    PaymentVerificationKey,
    UTxO,
)

from vector_agent.models import MIN_AP3X_DEPOSIT_DFM, AgentProfile
from vector_agent.registry import AgentRegistry, _derive_nft_name
from vector_agent.wallet_manager import AgentWalletManager
from vector_agent.plutus_data import OutputReference

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────────────────────────────
# Configuration from environment
# ──────────────────────────────────────────────────────────────────────

BLUEPRINT_PATH = (
    Path(__file__).parent.parent.parent
    / "contracts"
    / "agent-registry"
    / "plutus.json"
)

SKEY_PATH = os.environ.get("VECTOR_SKEY_PATH")
OGMIOS_HOST = os.environ.get("VECTOR_OGMIOS_HOST", "localhost")
OGMIOS_PORT = int(os.environ.get("VECTOR_OGMIOS_PORT", "1732"))
NETWORK = os.environ.get("VECTOR_NETWORK", "mainnet")


def _has_testnet_config() -> bool:
    """Check if testnet configuration is available."""
    return SKEY_PATH is not None and Path(SKEY_PATH).exists()


# Skip all tests in this module if no testnet config
pytestmark = pytest.mark.integration


# ──────────────────────────────────────────────────────────────────────
# Fixtures
# ──────────────────────────────────────────────────────────────────────


@pytest.fixture(scope="module")
def skey():
    """Load the payment signing key from file."""
    if not _has_testnet_config():
        pytest.skip("VECTOR_SKEY_PATH not set or file not found")
    return PaymentSigningKey.load(SKEY_PATH)


@pytest.fixture(scope="module")
def registry():
    """Create and connect an AgentRegistry to the testnet."""
    if not _has_testnet_config():
        pytest.skip("VECTOR_SKEY_PATH not set or file not found")

    reg = AgentRegistry.from_blueprint(str(BLUEPRINT_PATH), network=NETWORK)
    secure = os.environ.get("VECTOR_OGMIOS_SECURE", "false").lower() == "true"
    reg.connect_ogmios(host=OGMIOS_HOST, port=OGMIOS_PORT, secure=secure)
    return reg


@pytest.fixture(scope="module")
def owner_vkh(skey):
    """Derive the owner VKH from the signing key."""
    vk = PaymentVerificationKey.from_signing_key(skey)
    return bytes(vk.hash())


@pytest.fixture(scope="module")
def change_address(skey):
    """Derive the change address from the signing key."""
    vk = PaymentVerificationKey.from_signing_key(skey)
    net = Network.TESTNET if NETWORK == "testnet" else Network.MAINNET
    return Address(payment_part=vk.hash(), network=net)


@pytest.fixture(scope="module")
def wallet_utxos(registry, change_address):
    """Fetch available UTxOs at the owner's address."""
    utxos = registry.context.utxos(change_address)
    if not utxos:
        pytest.skip("No UTxOs available at change address — wallet not funded")
    return utxos


# ──────────────────────────────────────────────────────────────────────
# Connection tests
# ──────────────────────────────────────────────────────────────────────


class TestConnection:
    """Verify basic connectivity to the Vector testnet."""

    def test_ogmios_connected(self, registry):
        """Ogmios context is available after connect."""
        assert registry.context is not None

    def test_can_query_protocol_params(self, registry):
        """Can fetch protocol parameters from the chain."""
        params = registry.context.protocol_param
        assert params is not None
        # Verify we got real protocol params
        assert hasattr(params, "min_fee_coefficient")

    def test_script_address_valid(self, registry):
        """Script address is a valid Vector testnet address (mainnet network ID)."""
        addr_str = registry.script_address.encode()
        assert addr_str.startswith("addr1")

    def test_policy_id_is_valid(self, registry):
        """Policy ID is a valid 28-byte hex hash."""
        pid = registry.policy_id_hex
        assert len(pid) == 56
        bytes.fromhex(pid)


# ──────────────────────────────────────────────────────────────────────
# Query tests
# ──────────────────────────────────────────────────────────────────────


class TestQuery:
    """Test querying the on-chain registry state."""

    def test_query_agents_returns_list(self, registry):
        """query_agents() returns a list (may be empty on fresh testnet)."""
        agents = registry.query_agents()
        assert isinstance(agents, list)
        logger.info("Found %d registered agents on-chain", len(agents))

    def test_query_agents_have_valid_datums(self, registry):
        """Any returned agents have parseable AgentDatum."""
        agents = registry.query_agents()
        for utxo, datum in agents:
            assert datum.name is not None
            assert datum.endpoint is not None
            assert datum.registered_at > 0


# ──────────────────────────────────────────────────────────────────────
# Wallet tests
# ──────────────────────────────────────────────────────────────────────


class TestWallet:
    """Test wallet balance and UTxO availability."""

    def test_wallet_has_utxos(self, wallet_utxos):
        """The test wallet has at least one UTxO."""
        assert len(wallet_utxos) > 0

    def test_wallet_has_sufficient_balance(self, wallet_utxos):
        """
        The test wallet has enough AP3X for at least one registration.
        Need: 10 AP3X deposit + tx fees (~2 AP3X) = ~12 AP3X minimum.
        """
        total_lovelace = 0
        for utxo in wallet_utxos:
            if isinstance(utxo.output.amount, int):
                total_lovelace += utxo.output.amount
            else:
                total_lovelace += utxo.output.amount.coin

        min_required = MIN_AP3X_DEPOSIT_DFM + 2_000_000  # 12 AP3X
        logger.info(
            "Wallet balance: %d DFM (%.2f AP3X), minimum required: %d DFM",
            total_lovelace,
            total_lovelace / 1_000_000,
            min_required,
        )
        assert total_lovelace >= min_required, (
            f"Insufficient balance: {total_lovelace} DFM < {min_required} DFM. "
            f"Fund the test wallet with at least 15 AP3X."
        )


# ──────────────────────────────────────────────────────────────────────
# NFT name parity test (on-chain vs off-chain)
# ──────────────────────────────────────────────────────────────────────


class TestNftParity:
    """
    Verify NFT name derivation matches between off-chain (Python) and
    what the on-chain validator expects.

    This uses a real UTxO reference from the wallet to derive the name
    and checks the bytes are consistent. The definitive proof comes from
    a successful register transaction (which requires the on-chain
    validator to accept the same name).
    """

    def test_derive_from_real_utxo(self, wallet_utxos, registry):
        """
        Use a real wallet UTxO to derive the NFT name off-chain.
        Verify the output is deterministic and 32 bytes.
        """
        utxo = wallet_utxos[0]
        seed_ref = OutputReference(
            transaction_id=bytes(utxo.input.transaction_id),
            output_index=utxo.input.index,
        )

        name1 = _derive_nft_name(seed_ref)
        name2 = _derive_nft_name(seed_ref)

        assert name1 == name2, "NFT name derivation is not deterministic"
        assert len(name1) == 32, f"NFT name should be 32 bytes, got {len(name1)}"


# ──────────────────────────────────────────────────────────────────────
# Full lifecycle test
# ──────────────────────────────────────────────────────────────────────


class TestLifecycle:
    """
    Full register → update → deregister lifecycle on testnet.

    This is the definitive integration test. If register succeeds,
    it proves CBOR parity between Python and Aiken.

    WARNING: This test spends real testnet AP3X and may take 30-60 seconds
    for transaction confirmations.
    """

    # We track state across methods with module-scoped variables
    _nft_asset_name: Optional[bytes] = None
    _register_tx: Optional[str] = None

    def test_01_register(
        self, skey, registry, owner_vkh, change_address, wallet_utxos
    ):
        """Step 1: Register a new agent on testnet."""
        collateral = wallet_utxos[-1]  # Use last UTxO as collateral
        seed = wallet_utxos[0]  # Use first UTxO as seed

        tx_hash = registry.register(
            payment_skey=skey,
            owner_vkh=owner_vkh,
            name="IntegrationTestBot",
            description="Created by Day 4 integration test",
            capabilities=["testing", "integration"],
            framework="pytest",
            endpoint="https://test.vector.example.com/a2a",
            change_address=change_address,
            collateral_utxo=collateral,
            seed_utxo=seed,
        )

        assert tx_hash is not None
        assert len(tx_hash) == 64  # 32-byte hex
        TestLifecycle._register_tx = tx_hash
        logger.info("Register TX submitted: %s", tx_hash)

        # Derive the NFT name for later lookups
        seed_ref = OutputReference(
            transaction_id=bytes(seed.input.transaction_id),
            output_index=seed.input.index,
        )
        TestLifecycle._nft_asset_name = _derive_nft_name(seed_ref)

        # Wait for confirmation
        logger.info("Waiting for register TX to confirm...")
        time.sleep(30)

    def test_02_find_registered_agent(self, registry):
        """Step 2: Verify the registered agent is visible on-chain."""
        if TestLifecycle._nft_asset_name is None:
            pytest.skip("Register step did not complete")

        result = registry.find_agent_utxo(TestLifecycle._nft_asset_name)
        assert result is not None, "Agent not found on-chain after registration"

        utxo, datum = result
        assert datum.name == b"IntegrationTestBot"
        assert datum.framework == b"pytest"
        logger.info("Agent found on-chain: %s", datum.name)

    def test_03_update(self, skey, registry, change_address):
        """Step 3: Update the agent's profile."""
        if TestLifecycle._nft_asset_name is None:
            pytest.skip("Register step did not complete")

        result = registry.find_agent_utxo(TestLifecycle._nft_asset_name)
        if result is None:
            pytest.skip("Agent not found on-chain")

        agent_utxo, _ = result

        wallet_utxos = registry.context.utxos(change_address)
        collateral = wallet_utxos[-1] if wallet_utxos else None

        tx_hash = registry.update(
            payment_skey=skey,
            agent_utxo=agent_utxo,
            name="IntegrationTestBot v2",
            capabilities=["testing", "integration", "updated"],
            change_address=change_address,
            collateral_utxo=collateral,
        )

        assert tx_hash is not None
        logger.info("Update TX submitted: %s", tx_hash)

        time.sleep(30)

    def test_04_verify_update(self, registry):
        """Step 4: Verify the update was applied."""
        if TestLifecycle._nft_asset_name is None:
            pytest.skip("Register step did not complete")

        result = registry.find_agent_utxo(TestLifecycle._nft_asset_name)
        assert result is not None

        _, datum = result
        assert datum.name == b"IntegrationTestBot v2"
        logger.info("Updated agent verified: %s", datum.name)

    def test_05_deregister(self, skey, registry, change_address):
        """Step 5: Deregister the agent (burn NFT, return deposit)."""
        if TestLifecycle._nft_asset_name is None:
            pytest.skip("Register step did not complete")

        result = registry.find_agent_utxo(TestLifecycle._nft_asset_name)
        if result is None:
            pytest.skip("Agent not found on-chain")

        agent_utxo, _ = result

        wallet_utxos = registry.context.utxos(change_address)
        collateral = wallet_utxos[-1] if wallet_utxos else None

        tx_hash = registry.deregister(
            payment_skey=skey,
            agent_utxo=agent_utxo,
            change_address=change_address,
            collateral_utxo=collateral,
        )

        assert tx_hash is not None
        logger.info("Deregister TX submitted: %s", tx_hash)

        time.sleep(30)

    def test_06_verify_deregistration(self, registry):
        """Step 6: Verify the agent is no longer on-chain."""
        if TestLifecycle._nft_asset_name is None:
            pytest.skip("Register step did not complete")

        result = registry.find_agent_utxo(TestLifecycle._nft_asset_name)
        assert result is None, "Agent should be gone after deregistration"
        logger.info("Deregistration confirmed — agent no longer on-chain")
