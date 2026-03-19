#!/usr/bin/env python3
"""
Vector Agent Registry — Demo Script

Demonstrates the full agent lifecycle on the Vector testnet:
  1. Connect to chain via local Ogmios
  2. Register a new agent (mint NFT, lock deposit)
  3. Query the agent on-chain
  4. Update the agent's profile
  5. Deregister (burn NFT, return deposit)
  6. Export the audit log

Prerequisites:
  - Local Ogmios running on localhost:1732 (Docker)
  - Funded payment signing key at ./test_payment.skey
  - At least 15 AP3X in the wallet

Usage:
    cd agent-infrastructure/python
    python demo.py                          # full lifecycle (register → update → deregister)
    python demo.py --register-only          # register only (leave agent on-chain)
    python demo.py --query-only             # just query existing agents

Environment:
    VECTOR_SKEY_PATH    — path to .skey (default: ./test_payment.skey)
    VECTOR_OGMIOS_HOST  — Ogmios host (default: localhost)
    VECTOR_OGMIOS_PORT  — Ogmios port (default: 1732)
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from pathlib import Path

from pycardano import PaymentVerificationKey

from vector_agent import (
    AgentRegistry,
    AgentWalletManager,
    SpendPolicy,
    make_did,
)

# ──────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────

BLUEPRINT_PATH = (
    Path(__file__).parent.parent
    / "contracts"
    / "agent-registry"
    / "plutus.json"
)

SKEY_PATH = os.environ.get("VECTOR_SKEY_PATH", "./test_payment.skey")
OGMIOS_HOST = os.environ.get("VECTOR_OGMIOS_HOST", "localhost")
OGMIOS_PORT = int(os.environ.get("VECTOR_OGMIOS_PORT", "1732"))
OGMIOS_SECURE = os.environ.get("VECTOR_OGMIOS_SECURE", "false").lower() == "true"

AUDIT_LOG_PATH = "demo_audit.json"


def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )
    # Quiet noisy libraries
    logging.getLogger("ogmios").setLevel(logging.WARNING)
    logging.getLogger("pycardano").setLevel(logging.WARNING)


def wait_for_confirmation(seconds: int = 30):
    """Wait for transaction confirmation with a progress indicator."""
    print(f"  ... Waiting {seconds}s for confirmation", end="", flush=True)
    for i in range(seconds):
        time.sleep(1)
        if (i + 1) % 5 == 0:
            print(".", end="", flush=True)
    print(" done")


# ──────────────────────────────────────────────────────────────────────
# Demo steps
# ──────────────────────────────────────────────────────────────────────


def connect(registry: AgentRegistry) -> None:
    """Step 0: Connect to the Vector testnet."""
    print("\n--- Step 0: Connect to Vector testnet ---")
    registry.connect_ogmios(host=OGMIOS_HOST, port=OGMIOS_PORT, secure=OGMIOS_SECURE)
    print(f"  Connected to Ogmios at {OGMIOS_HOST}:{OGMIOS_PORT}")
    print(f"  Script address: {registry.script_address.encode()}")
    print(f"  Policy ID: {registry.policy_id_hex}")


def query_agents(registry: AgentRegistry) -> None:
    """Query and display all registered agents."""
    print("\n--- Query registered agents ---")
    agents = registry.query_agents()
    if not agents:
        print("  No agents registered on-chain.")
        return

    for utxo, datum in agents:
        profile = registry.to_agent_profile(utxo, datum)
        print(f"\n  Agent: {profile.name}")
        print(f"    DID:          {profile.agent_id}")
        print(f"    Owner:        {profile.owner[:16]}...")
        print(f"    Description:  {profile.description}")
        print(f"    Capabilities: {profile.capabilities}")
        print(f"    Framework:    {profile.framework}")
        print(f"    Endpoint:     {profile.endpoint}")
        print(f"    UTxO:         {profile.utxo_ref}")


def demo_register(wm: AgentWalletManager) -> str:
    """Step 1: Register a new agent."""
    print("\n--- Step 1: Register agent ---")
    tx_hash = wm.register_agent(
        name="DemoBot",
        description="Demonstration agent created by the Vector SDK demo script",
        capabilities=["demo", "testing", "a2a"],
        framework="vector-sdk",
        endpoint="https://demo.vector.example.com/a2a",
    )
    print(f"  TX submitted: {tx_hash}")
    wait_for_confirmation()
    return tx_hash


def demo_find_agent(wm: AgentWalletManager) -> None:
    """Step 2: Find the registered agent on-chain."""
    print("\n--- Step 2: Find agent on-chain ---")
    agents = wm.find_my_agents()
    if not agents:
        print("  ERROR: Agent not found on-chain!")
        return

    for profile in agents:
        print(f"  Found: {profile.name}")
        print(f"    DID: {profile.agent_id}")
        print(f"    Registered at: {profile.registered_at}")


def demo_update(wm: AgentWalletManager, registry: AgentRegistry) -> str:
    """Step 3: Update the agent's profile."""
    print("\n--- Step 3: Update agent profile ---")

    agents = wm.find_my_agents()
    if not agents:
        print("  ERROR: No agent found to update!")
        return ""

    # Find the agent's UTxO
    profile = agents[0]
    nft_name_bytes = bytes.fromhex(profile.nft_asset_name)
    result = registry.find_agent_utxo(nft_name_bytes)
    if result is None:
        print("  ERROR: Could not find agent UTxO!")
        return ""

    agent_utxo, _ = result

    tx_hash = wm.update_agent(
        agent_utxo=agent_utxo,
        name="DemoBot v2",
        capabilities=["demo", "testing", "a2a", "updated"],
        endpoint="https://demo-v2.vector.example.com/a2a",
    )
    print(f"  TX submitted: {tx_hash}")
    wait_for_confirmation()
    return tx_hash


def demo_deregister(wm: AgentWalletManager, registry: AgentRegistry) -> str:
    """Step 4: Deregister the agent (burn NFT, return deposit)."""
    print("\n--- Step 4: Deregister agent ---")

    agents = wm.find_my_agents()
    if not agents:
        print("  ERROR: No agent found to deregister!")
        return ""

    profile = agents[0]
    nft_name_bytes = bytes.fromhex(profile.nft_asset_name)
    result = registry.find_agent_utxo(nft_name_bytes)
    if result is None:
        print("  ERROR: Could not find agent UTxO!")
        return ""

    agent_utxo, _ = result

    tx_hash = wm.deregister_agent(agent_utxo=agent_utxo)
    print(f"  TX submitted: {tx_hash}")
    print(f"  10 AP3X deposit returned to {wm.change_address.encode()}")
    wait_for_confirmation()
    return tx_hash


def demo_audit_log(wm: AgentWalletManager) -> None:
    """Step 5: Export and display audit log."""
    print("\n--- Step 5: Audit log ---")
    wm.export_audit_log(AUDIT_LOG_PATH)
    print(f"  Exported to {AUDIT_LOG_PATH}")

    for entry in wm.audit_log:
        tx_short = entry.tx_hash[:12] + "..." if entry.tx_hash else "N/A"
        print(f"  [{entry.action:>12}] tx={tx_short}  lovelace={entry.lovelace:>12}  {entry.details}")


# ──────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Vector Agent Registry Demo")
    parser.add_argument(
        "--register-only",
        action="store_true",
        help="Only register an agent (don't update or deregister)",
    )
    parser.add_argument(
        "--query-only",
        action="store_true",
        help="Only query existing agents on-chain",
    )
    args = parser.parse_args()

    setup_logging()

    print("=" * 60)
    print("  Vector Agent Registry — Demo")
    print("=" * 60)

    # Load registry from blueprint
    if not BLUEPRINT_PATH.exists():
        print(f"ERROR: Blueprint not found at {BLUEPRINT_PATH}")
        print("  Run 'aiken build' in contracts/agent-registry/ first.")
        sys.exit(1)

    registry = AgentRegistry.from_blueprint(str(BLUEPRINT_PATH), network="mainnet")
    connect(registry)

    # Query-only mode
    if args.query_only:
        query_agents(registry)
        print("\nDone.")
        return

    # Check for signing key
    if not Path(SKEY_PATH).exists():
        print(f"\nERROR: Signing key not found at {SKEY_PATH}")
        print("  Set VECTOR_SKEY_PATH or place test_payment.skey in python/")
        sys.exit(1)

    # Create wallet manager with spend policy
    wm = AgentWalletManager.from_keys(
        skey_path=SKEY_PATH,
        registry=registry,
        spend_policy=SpendPolicy(
            per_tx_lovelace=50_000_000,   # 50 AP3X max per tx
            daily_lovelace=200_000_000,   # 200 AP3X daily limit
        ),
    )
    print(f"\n  Wallet: {wm.change_address.encode()}")
    print(f"  Owner VKH: {wm.owner_vkh_hex}")

    # Run lifecycle
    demo_register(wm)
    query_agents(registry)

    if not args.register_only:
        demo_update(wm, registry)
        query_agents(registry)
        demo_deregister(wm, registry)

        # Verify deregistration
        print("\n--- Verify deregistration ---")
        remaining = wm.find_my_agents()
        if not remaining:
            print("  Confirmed: agent is no longer on-chain.")
        else:
            print(f"  WARNING: {len(remaining)} agent(s) still on-chain!")

    demo_audit_log(wm)

    print("\n" + "=" * 60)
    print("  Demo complete!")
    print("=" * 60)


if __name__ == "__main__":
    main()
