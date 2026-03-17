# WS4: Agent Infrastructure — Design Document

**Owner:** Filip
**Sprint:** March 16–20, 2026
**Status:** Day 5 complete — 30 Aiken + 96 Python offline + 15 integration tests passing, full lifecycle verified on Vector testnet, demo script ready

---

## Project Structure

```
agent-infrastructure/
├── contracts/
│   └── agent-registry/            # Aiken smart contract (multi-validator)
│       ├── aiken.toml              # Aiken v1.1.21, Plutus V3, stdlib v3.0.0
│       ├── lib/agent_registry/
│       │   ├── types.ak            # On-chain types: AgentDatum, MintAction, SpendAction
│       │   ├── validation.ak       # Core validation logic (testable functions)
│       │   └── validation_tests.ak # 30 unit tests for all validator paths
│       ├── validators/
│       │   └── registry.ak         # Multi-validator: thin wrapper over validation.ak
│       └── plutus.json             # Generated Plutus blueprint
├── python/
│   ├── pyproject.toml              # Package config, dependencies, pytest markers
│   ├── demo.py                     # Interactive demo: register → query → update → deregister
│   └── vector_agent/
│       ├── __init__.py             # Public API exports + version
│       ├── models.py               # Off-chain Python models (mirrors on-chain types)
│       ├── did.py                  # DID utilities (did:vector:agent:{policyId}:{assetName})
│       ├── plutus_data.py          # PyCardano PlutusData classes (CBOR serialization)
│       ├── registry.py             # AgentRegistry client (tx building via PyCardano/Ogmios)
│       └── wallet_manager.py       # AgentWalletManager (keys, spend policy, audit)
│   └── tests/
│       ├── conftest.py             # Shared fixtures (keys, registry, mock_registry)
│       ├── test_models.py          # Model unit tests (7 passing)
│       ├── test_did.py             # DID utility tests (7 passing)
│       ├── test_plutus_data.py     # PlutusData CBOR roundtrip tests (19 passing)
│       ├── test_registry.py        # Registry client tests (11 passing)
│       ├── test_wallet_manager.py  # WalletManager + spend policy tests (30 passing)
│       ├── test_e2e_scenario.py    # Full lifecycle scenario tests (5 passing)
│       ├── test_cbor_parity.py     # CBOR encoding parity tests (17 passing)
│       └── test_integration.py     # Vector testnet integration tests (15, requires funded wallet)
└── docs/
    ├── DESIGN.md                   # This file
    └── TESTS.md                    # Complete test index
```

---

## Architecture: Multi-Validator Design

The registry uses a **single Aiken multi-validator** that serves as both:

1. **Minting policy** — controls identity NFT creation (Register) and destruction (Burn)
2. **Spend validator** — controls agent UTxO updates (Update) and deregistration (Deregister)

Because both handlers compile to the same script hash:
```
policy_id == script_hash == payment_credential of the registry address
```

This means the spend validator can verify NFT presence by checking tokens under its own policy ID — no cross-script references needed.

### Flows

**Registration:**
```
1. Choose a seed UTxO from the owner's wallet
2. Derive NFT asset name = blake2b_256(cbor.serialise(seed_utxo_ref))
3. Build TX that:
   - Consumes the seed UTxO
   - Mints 1 NFT (redeemer: Register { seed })
   - Creates output at registry script address with:
     * Inline AgentDatum
     * The minted identity NFT
     * ≥ 10 AP3X (native coin, 10_000_000 DFM)
```

**Update:**
```
1. Spend the agent's registry UTxO (redeemer: Update, owner must sign)
2. Create new output at the same script address with:
   * Updated inline AgentDatum
   * The same identity NFT (must be present)
   * ≥ 10 AP3X (native coin, 10_000_000 DFM)
```

**Deregister:**
```
1. Spend the agent's registry UTxO (redeemer: Deregister, owner must sign)
2. Burn the identity NFT (mint redeemer: Burn, quantity: -1)
3. AP3X deposit returned to owner
```

---

## "Soulbound" NFTs in eUTXO

**True soulbound behavior works _better_ in eUTXO than in account-model chains.**

The identity NFT lives inside the registry UTxO at the **script address**, never in the user's personal wallet. The user can only interact with it through the validator's rules:

- **Register**: NFT is minted directly into the script address
- **Update**: NFT moves from old UTxO to new UTxO (both at script address)
- **Deregister**: NFT is burned — it never leaves the script

This is stronger than Ethereum's ERC-5192 "soulbound" standard, where the token technically sits in the user's account and relies on transfer hooks to prevent movement. In eUTXO, the validator **physically controls** the NFT.

---

## Design Decisions & Presumptions

### D1: Multi-validator with minting policy (NFT identity)

**Decision:** The registry is a multi-validator with both mint and spend handlers. Each agent gets a unique identity NFT minted at registration.

**Why:** The NFT provides:
- **Spam protection** — registration requires going through the minting policy
- **Stable identity** — DID format `did:vector:agent:{policyId}:{assetName}` survives profile updates
- **Soulbound guarantee** — NFT lives at script address, not user wallet
- **Clean deregistration** — burn the NFT to retire the identity

**Asset name derivation:** `blake2b_256(cbor.serialise(seed_utxo_ref))` — uses a consumed UTxO as entropy source, guaranteeing uniqueness (no two transactions can consume the same UTxO).

### D2: Stable DID via NFT (survives updates)

**Decision:** Agent DIDs follow the format `did:vector:agent:{policy_id}:{nft_asset_name}`. The DID is stable because the NFT asset name is derived once at registration and doesn't change on updates.

**Why:** The previous UTxO-based DID (`did:vector:agent:{tx_hash}:{index}`) changed on every update. The NFT-based DID is permanent for the lifetime of the agent registration.

### D3: Minimum 10 AP3X deposit enforced on-chain

**Decision:** The minting policy (on Register) and the spend validator (on Update) both check that the registry output contains `≥ 10 AP3X` in lovelace (10,000,000 lovelace). The deposit is returned to the owner on Deregister.

**Why:** On-chain enforcement prevents bypassing the minimum via direct chain interaction (not just SDK). The AP3X deposit also creates economic skin-in-the-game for registered agents.

**AP3X is the native coin** on Vector (like ADA on Cardano), with 6 decimal places. No policy ID needed — it's represented as DFM (smallest unit, like lovelace on Cardano) in the UTxO value. The validator checks `assets.lovelace_of(output.value) >= 10_000_000`. Note: Aiken stdlib uses `lovelace_of` as the function name for the native coin regardless of chain naming.

### D4: Owner identified by payment credential (key-based only)

**Decision:** The `owner` field in AgentDatum is a `Credential` type. The validator only authorizes key-based credentials (checks `extra_signatories`). Script-based ownership is not supported.

**Why:** Key-based ownership covers 95%+ of use cases. Multi-sig or script-based ownership can be added later by extending the `has_credential_signed` function.

### D5: Spend limits enforced off-chain only

**Decision:** The `SpendPolicy` (per-tx and daily limits, allow/blocklist) is enforced in the Python SDK's `AgentWalletManager`, NOT on-chain.

**Why:** On-chain spend limits would require time-based state tracking (slot windows, rolling sums). Off-chain enforcement in the SDK is sufficient because the SDK controls the signing keys and is the only path to building transactions. Audit logging provides accountability.

### D6: Inline datums, Plutus V3

**Decision:** All agent profiles use inline datums. The contract targets Plutus V3.

**Why:** Inline datums allow off-chain tools to read agent profiles directly from UTxOs without resolving datum hashes. Plutus V3 is the latest version supported by the Vector testnet.

### D7: Update checks NFT continuity but not datum shape

**Decision:** On Update, the validator verifies:
- Owner signed the TX
- A continuing output exists at the same script address
- The continuing output has an inline datum
- The continuing output contains the same identity NFT
- The continuing output has ≥ 10 AP3X (≥ 10_000_000 DFM)

It does NOT verify the datum structure or that the `owner` field is preserved.

**Why:** This allows ownership transfer (by changing the `owner` field in the datum during an update). The current owner must sign, making this an intentional action. Restricting datum fields would add on-chain cost for little benefit.

### D8: Validation logic extracted to library (Day 2 refactor)

**Decision:** Core validation logic was moved from `validators/registry.ak` into `lib/agent_registry/validation.ak`. The validator file is now a thin wrapper that delegates to `validation.validate_register()`, `validate_burn()`, `validate_update()`, and `validate_deregister()`.

**Why:** Aiken's `validator` block compiles to UPLC and its handlers cannot be called directly from `test` blocks. By extracting the logic into regular `pub fn` functions in a library module, all validation paths can be unit-tested independently using `aiken check`. The compiled output is identical — the UPLC inlines the library functions.

**Impact:** The contract hash changed from `c8d23d01...` to `5dd51189...` due to this refactor. The on-chain behavior is unchanged. The `min_deposit_lovelace` constant now lives in `validation.ak` (was in `registry.ak`).

### D9: CBOR parity verified offline (Day 4)

**Decision:** Added 17 CBOR parity tests that verify PyCardano's PlutusData serialization matches the Plutus CBOR specification (constructor tags + indefinite-length arrays). This provides high confidence that off-chain NFT name derivation will match on-chain.

**Key finding:** PyCardano uses **indefinite-length arrays** (`0x9F...0xFF`) for non-empty constructors and **definite-length empty arrays** (`0x80`) for empty constructors. This matches the Plutus CBOR convention used by Aiken's `cbor.serialise()`.

**Why this is critical:** The NFT asset name is `blake2b_256(CBOR(OutputReference))`. Even a single byte difference in CBOR encoding between Python and Aiken would produce a completely different hash, causing every registration to fail on-chain. The parity tests confirm byte-exact equality for OutputReference, Credential, all redeemers, and AgentDatum.

**Resolved:** The final proof came from a successful `register` transaction on testnet — the on-chain validator accepted the NFT name, confirming byte-exact CBOR parity between PyCardano and Aiken.

### D10: Vector testnet uses mainnet network ID (Day 4)


**Decision:** The Vector testnet uses `networkId: Mainnet` with `networkMagic: 764824073`. Addresses start with `addr1` (not `addr_test1`). The SDK uses `Network.MAINNET` when targeting Vector testnet.

**Why this matters:** PyCardano's `Address` encodes the network tag into the first byte of the address. Using `Network.TESTNET` would produce `addr_test1` addresses that don't match the chain's expected format, causing transaction failures.

**Local Ogmios:** The development environment runs a local Ogmios on `localhost:1732` (Docker container `vector-public-testnet-tools-10_1_4-ogmios-1`). The integration test defaults to this local endpoint. For the remote endpoint, set `VECTOR_OGMIOS_HOST=ogmios.vector.testnet.apexfusion.org` and `VECTOR_OGMIOS_PORT=443` with `VECTOR_OGMIOS_SECURE=true`.

### D11: Full lifecycle verified on Vector testnet (Day 4)

**Decision:** All three on-chain operations (register, update, deregister) were successfully executed and verified on the Vector testnet. This is the definitive proof that the off-chain SDK correctly interacts with the on-chain validator.

**Test transactions:**
- **Register:** `abc87540413a4a46b9dbb76b5d6b45f04dc95f24d133f3a93ea1c4de5d12acc0` — minted NFT `ed58770a...`, proved CBOR parity
- **Update:** `3661cb29b38480331346793a62a93b363155db531b293f6159c0fd9ac3aa225c` — changed name to "IntegrationTestBot v2"
- **Deregister:** `42996d11e8bb610b202447a4d55b6b5b28a5561e4d40005d3b052d2cb5cfeb2f` — burned NFT, returned deposit

**Bug fixed during testing:** `update()` and `deregister()` failed with `UTxOSelectionException` because the `TransactionBuilder` only knew about the script UTxO (pre-selected input) but needed wallet UTxOs to cover transaction fees (~0.25 AP3X). Fixed by adding `builder.add_input_address(change_address)` to both methods, allowing PyCardano's coin selection to draw from the wallet's UTxO pool.

**Bug fixed during testing:** Ogmios returns inline datums as `RawCBOR` objects, not parsed PlutusData. Added `_parse_datum()` helper that handles both `RawCBOR` (via `AgentDatum.from_cbor(raw_datum.cbor)`) and standard PlutusData objects.

---

## On-Chain Schema (Aiken)

### AgentDatum (inline datum on registry UTxOs)
| Field | Type | Description |
|-------|------|-------------|
| owner | Credential | Payment credential (VerificationKey hash) |
| name | ByteArray | Agent name (UTF-8 encoded) |
| description | ByteArray | Short description |
| capabilities | List\<ByteArray\> | Capability tags |
| framework | ByteArray | Framework identifier |
| endpoint | ByteArray | A2A endpoint URL |
| registered_at | Int | POSIX timestamp (milliseconds) |

### MintAction (redeemer for mint handler)
| Constructor | Index | Fields | Description |
|------------|-------|--------|-------------|
| Register | 0 | seed: OutputReference | Mint identity NFT |
| Burn | 1 | — | Burn identity NFT |

### SpendAction (redeemer for spend handler)
| Constructor | Index | Description |
|------------|-------|-------------|
| Update | 0 | Modify profile; NFT + ≥10 AP3X must continue |
| Deregister | 1 | Remove agent; NFT must be burned |

### Contract Hash
`5dd5118943d5aa7329696181252a6565a27dbf2c6de92b02a6aae361`

> **Note:** Hash changes on every recompilation when source changes. Always re-read from `plutus.json` at runtime — the `AgentRegistry.from_blueprint()` client does this automatically and verifies the hash.

### Configurable Constants (in validation.ak)
| Constant | Value | Description |
|----------|-------|-------------|
| min_deposit_lovelace | `10_000_000` | Minimum 10 AP3X (= 10M DFM). Uses Aiken's `lovelace_of` for native coin |

---

## Off-Chain Schema (Python)

The Python `AgentProfile` dataclass mirrors `AgentDatum` 1:1, with additional off-chain fields:
- `utxo_ref` — current UTxO reference (changes on update)
- `nft_asset_name` — identity NFT asset name (stable, set at registration)
- `policy_id` — registry script hash / policy ID
- `agent_id` — derived property: `did:vector:agent:{policy_id}:{nft_asset_name}`

Additional models:
- `MintAction` — enum for mint redeemer (Register=0, Burn=1)
- `SpendAction` — enum for spend redeemer (Update=0, Deregister=1)
- `SpendPolicy` — per-tx/daily limits, allow/blocklist (off-chain)
- `AuditEntry` — audit log entries for the wallet manager

---

## What's NOT included (and why)

| Feature | Status | Reason |
|---------|--------|--------|
| On-chain messaging (label 674) | Out of scope | Nice-to-have per sprint plan |
| Reputation score | Out of scope | Nice-to-have; depends on external system |
| Script-based ownership | Not yet | Can be added by extending validator |
| On-chain spend limits | Not yet | Off-chain enforcement is sufficient for MVP |
| Datum structure validation | By design | On-chain: too expensive; off-chain indexer handles |

---

## Day 2–5 Plan

| Day | Deliverable | Status |
|-----|-------------|--------|
| Day 2 (Tue) | Aiken unit tests (30 passing), `AgentRegistry` Python client, PlutusData CBOR types | ✅ Done |
| Day 3 (Wed) | `AgentWalletManager` + spend policy + audit log + e2e scenario test (79 Python tests) | ✅ Done |
| Day 4 (Thu) | CBOR parity tests (17), integration test module (15), pyproject.toml packaging, `__init__.py` public API | ✅ Done |
| Day 5 (Fri) | Demo script, final testing, handoff to David | ✅ Done |
