"""
AgentWalletManager — manages an agent's signing keys, enforces off-chain
spend policies, and provides an audited interface to the AgentRegistry.

This is the primary entry point for agent operations. It wraps the
AgentRegistry client with:
  - Key management (loading/generating signing keys)
  - Spend policy enforcement (per-tx, daily limits, allow/blocklist)
  - Audit logging (every action recorded with timestamp + tx hash)
  - Convenience methods (register_agent, update_agent, deregister_agent, send)

Usage:
    from vector_agent.wallet_manager import AgentWalletManager

    wm = AgentWalletManager.from_keys(skey_path="payment.skey", registry=registry)
    wm.set_spend_policy(SpendPolicy(per_tx_lovelace=50_000_000))
    tx_hash = wm.register_agent(name="MyBot", ...)
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import List, Optional, Tuple

from pycardano import (
    Address,
    Network,
    PaymentSigningKey,
    PaymentVerificationKey,
    UTxO,
    Value,
)

from vector_agent.models import (
    MIN_AP3X_DEPOSIT_DFM,
    AgentProfile,
    AuditEntry,
    SpendPolicy,
)
from vector_agent.registry import AgentRegistry

logger = logging.getLogger(__name__)


class SpendPolicyViolation(Exception):
    """Raised when a transaction would violate the spend policy."""
    pass


class AgentWalletManager:
    """
    Audited wallet manager for a single agent owner.

    Wraps an AgentRegistry with key management, spend policy enforcement,
    and an append-only audit log.
    """

    def __init__(
        self,
        payment_skey: PaymentSigningKey,
        registry: AgentRegistry,
        spend_policy: Optional[SpendPolicy] = None,
    ):
        self._skey = payment_skey
        self._vkey = PaymentVerificationKey.from_signing_key(payment_skey)
        self._registry = registry
        self._policy = spend_policy or SpendPolicy()
        self._audit_log: List[AuditEntry] = []
        self._daily_spent: List[Tuple[int, int]] = []  # [(timestamp_ms, lovelace)]

        # Derived
        self._owner_vkh: bytes = bytes(self._vkey.hash())
        self._change_address: Optional[Address] = None

    # ──────────────────────────────────────────────────────────────────
    # Factory methods
    # ──────────────────────────────────────────────────────────────────

    @classmethod
    def from_keys(
        cls,
        skey_path: str,
        registry: AgentRegistry,
        spend_policy: Optional[SpendPolicy] = None,
    ) -> "AgentWalletManager":
        """
        Create a wallet manager from a signing key file.

        Args:
            skey_path: Path to a Cardano payment signing key file (.skey).
            registry: Connected AgentRegistry instance.
            spend_policy: Optional spend limits (defaults to SpendPolicy defaults).
        """
        skey = PaymentSigningKey.load(skey_path)
        return cls(skey, registry, spend_policy)

    @classmethod
    def from_signing_key(
        cls,
        payment_skey: PaymentSigningKey,
        registry: AgentRegistry,
        spend_policy: Optional[SpendPolicy] = None,
    ) -> "AgentWalletManager":
        """Create a wallet manager from an in-memory signing key."""
        return cls(payment_skey, registry, spend_policy)

    # ──────────────────────────────────────────────────────────────────
    # Configuration
    # ──────────────────────────────────────────────────────────────────

    def set_spend_policy(self, policy: SpendPolicy) -> None:
        """Update the spend policy. Takes effect on the next transaction."""
        self._policy = policy
        logger.info(
            "Spend policy updated: per_tx=%d, daily=%d, allowlist=%d, blocklist=%d",
            policy.per_tx_lovelace,
            policy.daily_lovelace,
            len(policy.allowlist),
            len(policy.blocklist),
        )

    def set_change_address(self, address: Address) -> None:
        """Set the change/return address. If not set, derived from signing key."""
        self._change_address = address

    @property
    def change_address(self) -> Address:
        """Get the change address (derived from VK if not explicitly set)."""
        if self._change_address is not None:
            return self._change_address
        return Address(
            payment_part=self._vkey.hash(),
            network=self._registry._config.network,
        )

    @property
    def owner_vkh_hex(self) -> str:
        """Hex-encoded verification key hash of the owner."""
        return self._owner_vkh.hex()

    @property
    def spend_policy(self) -> SpendPolicy:
        """Current spend policy."""
        return self._policy

    @property
    def audit_log(self) -> List[AuditEntry]:
        """Read-only access to the audit log."""
        return list(self._audit_log)

    # ──────────────────────────────────────────────────────────────────
    # Agent lifecycle operations
    # ──────────────────────────────────────────────────────────────────

    def register_agent(
        self,
        name: str,
        description: str,
        capabilities: List[str],
        framework: str,
        endpoint: str,
        collateral_utxo: Optional[UTxO] = None,
        seed_utxo: Optional[UTxO] = None,
    ) -> str:
        """
        Register a new agent on-chain.

        Enforces spend policy on the deposit amount, then delegates to
        AgentRegistry.register().

        Returns:
            Transaction hash (hex string).
        """
        # Enforce policy on the deposit
        self._enforce_spend_policy(
            lovelace=MIN_AP3X_DEPOSIT_DFM,
            destination=str(self._registry.script_address.encode()),
            action="register",
        )

        tx_hash = self._registry.register(
            payment_skey=self._skey,
            owner_vkh=self._owner_vkh,
            name=name,
            description=description,
            capabilities=capabilities,
            framework=framework,
            endpoint=endpoint,
            change_address=self.change_address,
            collateral_utxo=collateral_utxo,
            seed_utxo=seed_utxo,
        )

        self._record_audit(
            action="register",
            tx_hash=tx_hash,
            lovelace=MIN_AP3X_DEPOSIT_DFM,
            destination=str(self._registry.script_address.encode()),
            details=f"Registered agent '{name}'",
        )
        return tx_hash

    def update_agent(
        self,
        agent_utxo: UTxO,
        name: Optional[str] = None,
        description: Optional[str] = None,
        capabilities: Optional[List[str]] = None,
        framework: Optional[str] = None,
        endpoint: Optional[str] = None,
        collateral_utxo: Optional[UTxO] = None,
    ) -> str:
        """
        Update an existing agent's profile.

        No deposit change — the same UTxO value continues.

        Returns:
            Transaction hash (hex string).
        """
        # Update doesn't move funds (continuing output), so no spend policy check
        # on the deposit. Only the tx fee is "spent".
        tx_hash = self._registry.update(
            payment_skey=self._skey,
            agent_utxo=agent_utxo,
            name=name,
            description=description,
            capabilities=capabilities,
            framework=framework,
            endpoint=endpoint,
            change_address=self.change_address,
            collateral_utxo=collateral_utxo,
        )

        self._record_audit(
            action="update",
            tx_hash=tx_hash,
            lovelace=0,
            destination=str(self._registry.script_address.encode()),
            details=f"Updated agent profile",
        )
        return tx_hash

    def deregister_agent(
        self,
        agent_utxo: UTxO,
        collateral_utxo: Optional[UTxO] = None,
    ) -> str:
        """
        Deregister an agent — burns NFT, returns deposit.

        Returns:
            Transaction hash (hex string).
        """
        tx_hash = self._registry.deregister(
            payment_skey=self._skey,
            agent_utxo=agent_utxo,
            change_address=self.change_address,
            collateral_utxo=collateral_utxo,
        )

        self._record_audit(
            action="deregister",
            tx_hash=tx_hash,
            lovelace=0,
            destination=_encode_address(self.change_address),
            details="Deregistered agent, deposit returned",
        )
        return tx_hash

    # ──────────────────────────────────────────────────────────────────
    # Generic send (for non-registry transactions)
    # ──────────────────────────────────────────────────────────────────

    def check_send(self, lovelace: int, destination: str) -> None:
        """
        Check if a send would be allowed by the spend policy.

        Raises SpendPolicyViolation if the send would be blocked.
        Does NOT actually send — use this for dry-run checks.
        """
        self._enforce_spend_policy(lovelace, destination, action="send")

    # ──────────────────────────────────────────────────────────────────
    # Query convenience
    # ──────────────────────────────────────────────────────────────────

    def find_my_agents(self) -> List[AgentProfile]:
        """
        Find all agents registered under this wallet's owner VKH.

        Returns:
            List of AgentProfile for agents owned by this key.
        """
        all_agents = self._registry.query_agents()
        my_agents = []
        for utxo, datum in all_agents:
            profile = self._registry.to_agent_profile(utxo, datum)
            if profile.owner == self.owner_vkh_hex:
                my_agents.append(profile)
        return my_agents

    # ──────────────────────────────────────────────────────────────────
    # Spend policy enforcement
    # ──────────────────────────────────────────────────────────────────

    def _enforce_spend_policy(
        self,
        lovelace: int,
        destination: str,
        action: str,
    ) -> None:
        """
        Check a proposed transaction against the spend policy.

        Raises SpendPolicyViolation if the transaction would violate policy.
        """
        policy = self._policy

        # 1. Per-transaction limit
        if lovelace > policy.per_tx_lovelace:
            msg = (
                f"Per-tx limit exceeded: {lovelace} > {policy.per_tx_lovelace} "
                f"(action={action}, dest={destination})"
            )
            self._record_audit(
                action="blocked",
                tx_hash=None,
                lovelace=lovelace,
                destination=destination,
                details=msg,
            )
            raise SpendPolicyViolation(msg)

        # 2. Daily rolling window limit
        now_ms = int(time.time() * 1000)
        window_ms = 24 * 60 * 60 * 1000  # 24 hours
        cutoff = now_ms - window_ms

        # Prune old entries
        self._daily_spent = [
            (ts, amt) for ts, amt in self._daily_spent if ts > cutoff
        ]

        daily_total = sum(amt for _, amt in self._daily_spent)
        if daily_total + lovelace > policy.daily_lovelace:
            msg = (
                f"Daily limit exceeded: {daily_total} + {lovelace} > "
                f"{policy.daily_lovelace} (action={action})"
            )
            self._record_audit(
                action="blocked",
                tx_hash=None,
                lovelace=lovelace,
                destination=destination,
                details=msg,
            )
            raise SpendPolicyViolation(msg)

        # 3. Blocklist
        if destination in policy.blocklist:
            msg = f"Destination is blocklisted: {destination} (action={action})"
            self._record_audit(
                action="blocked",
                tx_hash=None,
                lovelace=lovelace,
                destination=destination,
                details=msg,
            )
            raise SpendPolicyViolation(msg)

        # 4. Allowlist (if non-empty, only listed destinations allowed)
        if policy.allowlist and destination not in policy.allowlist:
            msg = (
                f"Destination not in allowlist: {destination} "
                f"(action={action}, allowed={policy.allowlist})"
            )
            self._record_audit(
                action="blocked",
                tx_hash=None,
                lovelace=lovelace,
                destination=destination,
                details=msg,
            )
            raise SpendPolicyViolation(msg)

        # Track spending for daily window
        self._daily_spent.append((now_ms, lovelace))

    # ──────────────────────────────────────────────────────────────────
    # Audit logging
    # ──────────────────────────────────────────────────────────────────

    def _record_audit(
        self,
        action: str,
        tx_hash: Optional[str],
        lovelace: int,
        destination: Optional[str],
        details: str,
    ) -> None:
        """Append an entry to the audit log."""
        entry = AuditEntry(
            timestamp=int(time.time() * 1000),
            action=action,
            tx_hash=tx_hash,
            lovelace=lovelace,
            destination=destination,
            details=details,
        )
        self._audit_log.append(entry)
        logger.info("AUDIT: %s — %s (tx=%s)", action, details, tx_hash)

    def export_audit_log(self, path: str) -> None:
        """Export the audit log to a JSON file."""
        entries = [
            {
                "timestamp": e.timestamp,
                "action": e.action,
                "tx_hash": e.tx_hash,
                "lovelace": e.lovelace,
                "destination": e.destination,
                "details": e.details,
            }
            for e in self._audit_log
        ]
        with open(path, "w") as f:
            json.dump(entries, f, indent=2)
        logger.info("Exported %d audit entries to %s", len(entries), path)

    def daily_spent_total(self) -> int:
        """Total lovelace spent in the current 24h rolling window."""
        now_ms = int(time.time() * 1000)
        cutoff = now_ms - 24 * 60 * 60 * 1000
        return sum(amt for ts, amt in self._daily_spent if ts > cutoff)


def _encode_address(addr: Address) -> str:
    """Safely encode an address to string (handles test mocks)."""
    try:
        return addr.encode()
    except Exception:
        return str(addr)
