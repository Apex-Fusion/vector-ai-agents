# Agent Registry — Contract Function Description

## Purpose

The Vector Agent Registry is an on-chain identity system for AI agents on the Vector/Cardano chain. It allows agents to register with a soulbound NFT identity, maintain an updateable profile, and cleanly deregister when no longer active. The system provides decentralized, tamper-evident agent identity via the `did:vector:agent:{policyId}:{assetName}` DID format.

## Architecture

A single Aiken **multi-validator** serves two roles from one script hash:

| Role | Script Purpose | Redeemers |
|------|---------------|-----------|
| **Minting policy** | Controls NFT lifecycle | `Register { seed }`, `Burn` |
| **Spend validator** | Controls UTxO lifecycle | `Update`, `Deregister` |

Because both handlers share the same script hash: `policy_id == script_hash == payment_credential of the registry address`. This allows the spend validator to verify NFT presence by checking tokens under its own policy ID.

## On-Chain State

Each registered agent is a single UTxO at the script address containing:

- **Identity NFT** — unique, non-fungible token (1 per agent) under the registry policy
- **Inline AgentDatum** — the agent's profile:
  - `owner: Credential` — payment credential authorized to manage this agent
  - `name: ByteArray` — human-readable agent name
  - `description: ByteArray` — what the agent does
  - `capabilities: List<ByteArray>` — capability tags
  - `framework: ByteArray` — framework identifier (e.g., "OpenClaw")
  - `endpoint: ByteArray` — off-chain A2A communication URL
  - `registered_at: Int` — POSIX timestamp of initial registration
- **Deposit** — minimum 10 AP3X (10,000,000 DFM) locked with the UTxO

## Operations

### Register (Mint: `Register { seed }`)

Creates a new agent identity.

1. Consumes a seed UTxO from the registrant's wallet (provides uniqueness entropy)
2. Derives NFT asset name: `blake2b_256(cbor.serialise(seed_output_reference))`
3. Mints exactly 1 NFT under the registry policy
4. Creates output at the script address with: inline AgentDatum, the NFT, ≥10 AP3X

**Invariants enforced:**
- Seed UTxO must appear in transaction inputs
- Exactly one token minted (quantity = 1) with the derived asset name
- Output must be at the script address (NFT is soulbound from birth)
- Output must have inline datum
- Output must carry ≥10 AP3X deposit

### Update (Spend: `Update`)

Modifies an agent's profile while preserving identity.

1. Spends the agent's current UTxO at the script address
2. Creates a new UTxO at the same script address with updated datum

**Invariants enforced:**
- Owner (from current datum) must sign the transaction
- Continuing output at script address must contain the same NFT
- Continuing output must have inline datum
- Continuing output must carry ≥10 AP3X deposit

**Not enforced:** Datum contents are not validated — any inline datum is accepted. This permits ownership transfer (changing the `owner` field) but also allows arbitrary datum mutation.

### Deregister (Spend: `Deregister` + Mint: `Burn`)

Removes an agent and destroys its identity.

1. Spends the agent's UTxO at the script address (Deregister redeemer)
2. Burns the identity NFT (Burn mint redeemer, quantity = -1)
3. Deposit is returned (implicitly, via transaction outputs)

**Invariants enforced:**
- Owner (from current datum) must sign the transaction
- Exactly one token burned (quantity = -1) under the registry policy

### Burn (Mint: `Burn`)

Standalone burn handler for the minting policy.

**Invariants enforced:**
- Exactly one token with quantity -1 under the policy

**Not enforced:** No authorization check — relies on the spend validator (Deregister path) to gate access to the NFT.

## Soulbound Property

The identity NFT **never** enters a user's personal wallet:
- **Register:** minted directly to the script address
- **Update:** moves from old script UTxO to new script UTxO
- **Deregister:** burned from the script address

The validator physically controls the NFT. The owner interacts with it only through the validator's authorized operations.

## DID Format

Each agent has a stable decentralized identifier:
```
did:vector:agent:{policy_id}:{nft_asset_name}
```

The DID survives profile updates because the NFT asset name (derived at registration from the seed UTxO) never changes. Only deregistration (burning the NFT) invalidates the DID.

## Constants

| Name | Value | Meaning |
|------|-------|---------|
| `min_deposit_lovelace` | `10_000_000` | Minimum 10 AP3X deposit in DFM (smallest unit) |

## Key Helpers

| Function | Purpose |
|----------|---------|
| `derive_asset_name(seed)` | `blake2b_256(cbor.serialise(seed))` → unique 32-byte NFT name |
| `script_address_from_policy(pid)` | Constructs `Address { Script(pid), None }` |
| `has_credential_signed(tx, cred)` | Checks `extra_signatories` for key-based credentials only |
| `find_nft_name(value, pid)` | Extracts the single NFT name under a policy from a Value |
| `has_inline_datum(output)` | Returns true if output datum is `InlineDatum(_)` |
