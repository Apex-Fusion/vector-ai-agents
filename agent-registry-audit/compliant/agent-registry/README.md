# Agent Registry — Compliant Contract Function Description

## Purpose

The Vector Agent Registry is an on-chain identity system for AI agents on the Vector/Cardano chain. It allows agents to register with a soulbound NFT identity, maintain an updateable profile, and cleanly deregister when no longer active. The system provides decentralized, tamper-evident agent identity via the `did:vector:agent:{policyId}:{assetName}` DID format.

This is the **compliant version** addressing all 11 audit findings (AR-01 through AR-11).

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
  - `owner: Credential` — payment credential authorized to manage this agent (must be key-based)
  - `name: ByteArray` — human-readable agent name (≤256 bytes)
  - `description: ByteArray` — what the agent does (≤1024 bytes)
  - `capabilities: List<ByteArray>` — capability tags (≤32 items, each ≤128 bytes)
  - `framework: ByteArray` — framework identifier (≤128 bytes)
  - `endpoint: ByteArray` — off-chain A2A communication URL (≤512 bytes)
  - `registered_at: Int` — POSIX timestamp of initial registration (immutable after creation)
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
- Exactly one valid registration output at the script address (AR-02)
- Output must have inline datum deserializable to `AgentDatum`
- Datum owner must have signed the transaction (AR-05)
- Datum owner must be a key-based credential (AR-07)
- All datum fields within size limits (AR-08)
- Output must carry ≥10 AP3X deposit

### Update (Spend: `Update`)

Modifies an agent's profile while preserving identity.

1. Spends the agent's current UTxO at the script address
2. Creates a new UTxO at the same script address with updated datum

**Invariants enforced:**
- Owner (from current datum) must sign the transaction
- Only one script input may be spent per transaction (AR-01)
- Continuing output must contain a valid `AgentDatum` inline datum (AR-04)
- The `registered_at` field must be preserved (AR-04)
- New owner must be key-based (AR-07)
- All datum fields within size limits (AR-08)
- Continuing output value must be ≥ input value (AR-09)
- Continuing output must contain the same identity NFT

### Deregister (Spend: `Deregister` + Mint: `Burn`)

Removes an agent and destroys its identity.

1. Spends the agent's UTxO at the script address (Deregister redeemer)
2. Burns the identity NFT (Burn mint redeemer, quantity = -1)
3. Deposit is returned to the owner

**Invariants enforced:**
- Owner (from current datum) must sign the transaction
- The specific NFT from the spent input must be burned (AR-06)
- An output to the owner's payment credential with ≥ minimum deposit must exist (AR-10)

### Burn (Mint: `Burn`)

Burn handler for the minting policy with independent authorization.

**Invariants enforced:**
- Exactly one token burned (quantity = -1) under the policy
- A spent script input containing the burned NFT must exist (AR-06)
- The owner from the spent input's datum must have signed (AR-03)

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
| `max_name_length` | `256` | Maximum agent name bytes |
| `max_description_length` | `1024` | Maximum description bytes |
| `max_capability_length` | `128` | Maximum bytes per capability tag |
| `max_capabilities_count` | `32` | Maximum number of capability tags |
| `max_framework_length` | `128` | Maximum framework identifier bytes |
| `max_endpoint_length` | `512` | Maximum endpoint URL bytes |

## Key Helpers

| Function | Purpose |
|----------|---------|
| `derive_asset_name(seed)` | `blake2b_256(cbor.serialise(seed))` → unique 32-byte NFT name |
| `script_address_from_policy(pid)` | Constructs `Address { Script(pid), None }` |
| `has_credential_signed(tx, cred)` | Checks `extra_signatories` for key-based credentials only |
| `is_verification_key(credential)` | AR-07 — Check credential is key-based |
| `validate_datum_size(datum)` | AR-08 — Enforce all field length limits |
| `find_nft_name(value, pid)` | Extracts the single NFT name under a policy from a Value |
| `has_inline_datum(output)` | Returns true if output datum is `InlineDatum(_)` |

## Audit Findings Addressed

All 11 findings from the security audit are addressed in this version. See `reports/audit-report.md` for full details.
