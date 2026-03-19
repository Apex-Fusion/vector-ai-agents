# WS4: Agent Infrastructure — Test Index

**Last updated:** Day 4 (March 19, 2026)
**Total tests:** 141 (30 Aiken + 96 offline Python + 15 integration Python) — ALL PASSING ✅

---

## How to Run

### Aiken (on-chain validator tests)
```bash
cd agent-infrastructure/contracts/agent-registry
aiken check
```

### Python (off-chain SDK tests — all offline tests)
```bash
cd agent-infrastructure/python
python -m pytest tests/ -v -m "not integration"
```

### Python (integration tests — requires funded testnet wallet)
```bash
cd agent-infrastructure/python
VECTOR_SKEY_PATH=/path/to/payment.skey python -m pytest tests/test_integration.py -v -m integration
```

---

## Aiken Tests — 30 tests

**File:** `contracts/agent-registry/lib/agent_registry/validation_tests.ak`

These test the core validation logic extracted into `lib/agent_registry/validation.ak`. Each test constructs a mock `Transaction` using Aiken's `transaction.placeholder` and overrides only the relevant fields.

### Helper Function Tests (8 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `test_derive_asset_name_deterministic` | Same seed UTxO always produces the same NFT asset name |
| 2 | `test_derive_asset_name_unique` | Different seed UTxOs (different output_index) produce different names |
| 3 | `test_script_address_uses_script_credential` | `script_address_from_policy` creates an address with Script credential and no staking |
| 4 | `test_has_inline_datum_true` | Correctly detects `InlineDatum` on an output |
| 5 | `test_has_inline_datum_false` | Correctly rejects `NoDatum` on an output |
| 6 | `test_has_credential_signed_true` | Owner's VKH present in `extra_signatories` → returns True |
| 7 | `test_has_credential_signed_false_no_sig` | Empty `extra_signatories` → returns False |
| 8 | `test_has_credential_signed_false_for_script` | Script credential (not key-based) → always returns False |

### Mint: Register Tests (9 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 9 | `test_register_success` | Happy path: seed consumed, 1 NFT minted, output at script address with datum + NFT + ≥10 AP3X |
| 10 | `test_register_fails_seed_not_consumed` | Rejects if the seed UTxO is not in tx.inputs |
| 11 | `test_register_fails_wrong_mint_quantity` | Rejects if mint quantity is 2 instead of 1 |
| 12 | `test_register_fails_low_deposit` | Rejects if output has only 5 AP3X (below 10 AP3X minimum) |
| 13 | `test_register_fails_no_inline_datum` | Rejects if the script output has NoDatum instead of InlineDatum |
| 14 | `test_register_fails_wrong_address` | Rejects if the output goes to a key address instead of the script address |
| 15 | `test_register_fails_nft_missing_from_output` | Rejects if the output has lovelace but no NFT token |
| 16 | `test_register_exact_minimum_deposit` | Accepts exactly 10 AP3X (boundary: 10_000_000 DFM) |
| 17 | `test_register_fails_one_dfm_below_minimum` | Rejects 9_999_999 DFM (one smallest unit below the 10 AP3X minimum) |

### Mint: Burn Tests (3 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 18 | `test_burn_success` | Happy path: exactly one NFT burned (quantity = -1) |
| 19 | `test_burn_fails_positive_quantity` | Rejects minting (quantity = +1) when Burn redeemer is used |
| 20 | `test_burn_fails_no_tokens` | Rejects if no tokens at all under this policy in mint field |

### Spend: Update Tests (6 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 21 | `test_update_success` | Happy path: owner signed, continuing output with same NFT + datum + deposit |
| 22 | `test_update_fails_no_signature` | Rejects if owner VKH is not in `extra_signatories` |
| 23 | `test_update_fails_wrong_signer` | Rejects if a different VKH signed (not the datum's owner) |
| 24 | `test_update_fails_nft_missing_from_output` | Rejects if the continuing output lacks the identity NFT |
| 25 | `test_update_fails_low_deposit` | Rejects if continuing output has less than 10 AP3X |
| 26 | `test_update_allows_ownership_transfer` | Confirms ownership transfer works — original owner signs, but datum.owner can change (design decision D7) |

### Spend: Deregister Tests (3 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 27 | `test_deregister_success` | Happy path: owner signed, NFT burned (quantity = -1 in mint field) |
| 28 | `test_deregister_fails_no_signature` | Rejects if owner didn't sign |
| 29 | `test_deregister_fails_no_burn` | Rejects if mint field is empty (NFT not burned) |
| 30 | `test_deregister_fails_mint_instead_of_burn` | Rejects if NFT is minted (+1) instead of burned (-1) |

**Total: 30 tests, 30 passed** (confirmed via `aiken check`).

---

## Python Tests — 96 offline + 15 integration

### test_did.py — 7 tests

**File:** `python/tests/test_did.py`

Tests for the DID utility functions in `python/vector_agent/did.py`.

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `test_make_did` | Constructs `did:vector:agent:{policy_id}:{nft_name}` correctly |
| 2 | `test_parse_did` | Parses a DID string back into (policy_id, nft_asset_name) tuple |
| 3 | `test_roundtrip` | make_did → parse_did roundtrip produces original inputs |
| 4 | `test_is_valid_did` | Validates correct DID format returns True, garbage returns False |
| 5 | `test_make_did_rejects_bad_policy_id` | Raises ValueError if policy_id is not 56 hex chars |
| 6 | `test_make_did_rejects_bad_nft_name` | Raises ValueError if nft_asset_name is not 64 hex chars |
| 7 | `test_parse_did_rejects_bad_format` | Raises ValueError for malformed DID strings |

### test_models.py — 7 tests

**File:** `python/tests/test_models.py`

Tests for the off-chain data models in `python/vector_agent/models.py`.

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `test_agent_profile_defaults` | Default values: registered_at > 0, utxo_ref/nft/policy_id are None |
| 2 | `test_agent_profile_with_nft` | agent_id property returns correct DID when policy_id + nft_asset_name set |
| 3 | `test_agent_id_requires_both_fields` | agent_id returns None if nft_asset_name is missing |
| 4 | `test_mint_action_values` | MintAction.REGISTER=0, MintAction.BURN=1 |
| 5 | `test_spend_action_values` | SpendAction.UPDATE=0, SpendAction.DEREGISTER=1 |
| 6 | `test_spend_policy_defaults` | SpendPolicy defaults: 100 ADA per-tx, 500 ADA daily, empty lists |
| 7 | `test_ap3x_config` | MIN_AP3X_DEPOSIT_DFM=10_000_000, AP3X_DECIMALS=6, 10 * 10^6 = 10M |

### test_plutus_data.py — 19 tests

**File:** `python/tests/test_plutus_data.py`

Tests for PyCardano PlutusData CBOR serialization in `python/vector_agent/plutus_data.py`.

#### TestCredentials (4 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `test_vkey_credential_constr_id` | VerificationKeyCredential.CONSTR_ID == 0 |
| 2 | `test_script_credential_constr_id` | ScriptCredential.CONSTR_ID == 1 |
| 3 | `test_vkey_credential_cbor_roundtrip` | Serialize → deserialize preserves vkey_hash bytes |
| 4 | `test_script_credential_cbor_roundtrip` | Serialize → deserialize preserves script_hash bytes |

#### TestOutputReference (2 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 5 | `test_constr_id` | OutputReference.CONSTR_ID == 0 |
| 6 | `test_cbor_roundtrip` | Serialize → deserialize preserves tx_id and output_index |

#### TestAgentDatum (5 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 7 | `test_constr_id` | AgentDatum.CONSTR_ID == 0 |
| 8 | `test_cbor_roundtrip` | All 7 fields survive CBOR serialize → deserialize |
| 9 | `test_datum_owner_is_vkey_credential` | Owner field is correctly typed as VerificationKeyCredential |
| 10 | `test_capabilities_is_list` | Capabilities deserializes back to list of byte strings |
| 11 | `test_cbor_is_deterministic` | Two identical datums produce identical CBOR bytes |

#### TestMintRedeemers (4 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 12 | `test_register_constr_id` | RegisterRedeemer.CONSTR_ID == 0 |
| 13 | `test_register_cbor_roundtrip` | Seed OutputReference survives roundtrip inside RegisterRedeemer |
| 14 | `test_burn_constr_id` | BurnRedeemer.CONSTR_ID == 1 |
| 15 | `test_burn_cbor_roundtrip` | Empty BurnRedeemer survives roundtrip |

#### TestSpendRedeemers (4 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 16 | `test_update_constr_id` | UpdateRedeemer.CONSTR_ID == 0 |
| 17 | `test_deregister_constr_id` | DeregisterRedeemer.CONSTR_ID == 1 |
| 18 | `test_update_cbor_roundtrip` | Empty UpdateRedeemer survives roundtrip |
| 19 | `test_deregister_cbor_roundtrip` | Empty DeregisterRedeemer survives roundtrip |

### test_registry.py — 11 tests

**File:** `python/tests/test_registry.py`

Tests for the AgentRegistry client in `python/vector_agent/registry.py`. All tests are offline (no chain connection required).

#### TestFromBlueprint (5 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `test_loads_without_error` | AgentRegistry.from_blueprint() succeeds with real plutus.json |
| 2 | `test_policy_id_is_56_hex_chars` | Script hash is 28 bytes (56 hex chars) |
| 3 | `test_policy_id_matches_blueprint` | Computed script hash matches the hash in plutus.json |
| 4 | `test_script_address_is_testnet` | Testnet address starts with "addr_test1" |
| 5 | `test_mainnet_address` | Mainnet address starts with "addr1" |

#### TestDeriveNftName (4 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 6 | `test_deterministic` | Same seed → same NFT name |
| 7 | `test_is_32_bytes` | Output is exactly 32 bytes (blake2b-256 digest) |
| 8 | `test_different_seeds_different_names` | Different output_index → different names |
| 9 | `test_uses_blake2b_256` | Result matches manual blake2b(cbor(seed)) computation |

#### TestNotConnected (2 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 10 | `test_query_raises_without_connection` | query_agents() raises RuntimeError before connect_ogmios() |
| 11 | `test_context_raises_without_connection` | Accessing .context raises RuntimeError before connect_ogmios() |

### test_wallet_manager.py — 30 tests

**File:** `python/tests/test_wallet_manager.py`

Tests for the `AgentWalletManager` class in `python/vector_agent/wallet_manager.py`. All tests use mocked chain backends (no real connection required).

#### TestConstruction (5 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `test_creates_from_signing_key` | `from_signing_key()` factory creates a valid WalletManager |
| 2 | `test_owner_vkh_is_hex` | Owner VKH is 56 hex chars (28 bytes) |
| 3 | `test_default_spend_policy` | Defaults: 100 AP3X per-tx, 500 AP3X daily, empty allow/blocklists |
| 4 | `test_audit_log_starts_empty` | Audit log is empty on construction |
| 5 | `test_daily_spent_starts_zero` | Daily spent total is 0 on construction |

#### TestSpendPolicy (13 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 6 | `test_per_tx_limit_allows_below` | Amount below per-tx limit passes |
| 7 | `test_per_tx_limit_blocks_above` | Amount above per-tx limit raises SpendPolicyViolation |
| 8 | `test_per_tx_limit_allows_exact` | Amount exactly at per-tx limit passes (boundary) |
| 9 | `test_daily_limit_accumulates` | Multiple spends under daily limit all pass |
| 10 | `test_daily_limit_blocks_when_exceeded` | Cumulative daily spend exceeding limit raises SpendPolicyViolation |
| 11 | `test_blocklist_rejects` | Blocklisted destination raises SpendPolicyViolation |
| 12 | `test_allowlist_rejects_unlisted` | Non-allowlisted destination raises SpendPolicyViolation |
| 13 | `test_allowlist_permits_listed` | Allowlisted destination passes |
| 14 | `test_empty_allowlist_permits_all` | Empty allowlist = no restriction (all destinations permitted) |
| 15 | `test_blocklist_checked_before_allowlist` | Address on both lists → blocklist wins |
| 16 | `test_set_spend_policy_updates` | `set_spend_policy()` replaces the active policy |
| 17 | `test_check_send_validates` | `check_send()` passes for valid amount + destination |
| 18 | `test_check_send_raises_on_violation` | `check_send()` raises SpendPolicyViolation for invalid send |

#### TestAuditLog (5 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 19 | `test_blocked_action_logged` | Blocked spend creates audit entry with action="blocked" and violation details |
| 20 | `test_successful_spend_not_logged_by_enforce` | `_enforce_spend_policy` doesn't log successful checks (callers log) |
| 21 | `test_record_audit_appends` | `_record_audit()` appends entries with correct fields |
| 22 | `test_export_audit_log` | `export_audit_log()` writes valid JSON with all entries |
| 23 | `test_audit_log_is_readonly_copy` | `audit_log` property returns a copy (mutations don't affect original) |

#### TestDailyWindow (3 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 24 | `test_daily_spent_tracks` | `daily_spent_total()` sums recent spend entries |
| 25 | `test_old_entries_expire` | Entries older than 24 hours are excluded from daily total |
| 26 | `test_recent_entries_count` | Entries within the 24-hour window are included |

#### TestRegisterFlow (2 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 27 | `test_register_calls_registry` | `register_agent()` calls `registry.register()` and logs audit entry |
| 28 | `test_register_blocked_by_policy` | Registration blocked if 10 AP3X deposit exceeds per-tx limit; registry NOT called |

#### TestUpdateFlow (1 test)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 29 | `test_update_calls_registry` | `update_agent()` calls `registry.update()` and logs audit entry |

#### TestDeregisterFlow (1 test)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 30 | `test_deregister_calls_registry` | `deregister_agent()` calls `registry.deregister()` and logs audit entry |

### test_e2e_scenario.py — 5 tests

**File:** `python/tests/test_e2e_scenario.py`

End-to-end scenario tests exercising the full agent lifecycle through WalletManager → Registry with mocked chain backend.

#### TestFullLifecycle (2 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `test_register_update_deregister` | Full lifecycle: register → update → deregister; audit trail has 3 entries with correct actions and tx hashes |
| 2 | `test_daily_limit_blocks_after_multiple_registers` | 5 registrations (50 AP3X) succeed, 6th blocked by 50 AP3X daily limit; audit has 5 success + 1 blocked |

#### TestDIDConsistency (2 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 3 | `test_did_from_profile` | AgentProfile.agent_id matches `make_did()` and passes `is_valid_did()` |
| 4 | `test_did_survives_update` | DID is identical across profile versions when NFT asset name is unchanged |

#### TestAuditExport (1 test)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 5 | `test_export_lifecycle_audit` | Full lifecycle audit exported to JSON, reloaded, and verified: 3 entries with correct actions and tx hashes |

### test_cbor_parity.py — 17 tests

**File:** `python/tests/test_cbor_parity.py`

CBOR encoding parity tests verifying PyCardano PlutusData serialization matches the Plutus CBOR specification (as used by Aiken's `cbor.serialise()`). Critical for NFT name derivation correctness.

#### TestOutputReferenceCBOR (5 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `test_constr_tag_is_121` | Constructor 0 maps to CBOR tag 121 |
| 2 | `test_simple_output_reference_encoding` | OutputReference CBOR byte-exact match with Plutus spec (indef arrays) |
| 3 | `test_nonzero_output_index_encoding` | OutputReference with output_index=42 encodes correctly |
| 4 | `test_large_output_index` | OutputReference with output_index=256 (multi-byte CBOR int) |
| 5 | `test_all_zeros_tx_hash` | OutputReference with all-zero tx hash encodes correctly |

#### TestNftNameDerivation (4 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 6 | `test_nft_name_from_known_cbor` | blake2b_256(CBOR) matches _derive_nft_name() for known input |
| 7 | `test_nft_name_matches_manual_plutus_cbor` | Manual Plutus CBOR and PyCardano CBOR produce identical NFT names |
| 8 | `test_different_indices_different_names` | 10 different indices → 10 different NFT names (collision resistance) |
| 9 | `test_different_tx_hashes_different_names` | 10 different tx hashes → 10 different NFT names |

#### TestCredentialCBOR (2 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 10 | `test_vkey_credential_encoding` | VerificationKeyCredential (constr 0) byte-exact match |
| 11 | `test_script_credential_encoding` | ScriptCredential (constr 1) byte-exact match |

#### TestRedeemerCBOR (4 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 12 | `test_register_redeemer_encoding` | RegisterRedeemer with nested OutputReference encodes correctly |
| 13 | `test_burn_redeemer_encoding` | BurnRedeemer (empty constr 1) uses definite-length empty array |
| 14 | `test_update_redeemer_encoding` | UpdateRedeemer (empty constr 0) uses definite-length empty array |
| 15 | `test_deregister_redeemer_encoding` | DeregisterRedeemer (empty constr 1) uses definite-length empty array |

#### TestAgentDatumCBOR (2 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 16 | `test_datum_cbor_structure` | AgentDatum CBOR decodes to tag 121 with 7 fields in correct types |
| 17 | `test_datum_cbor_field_order_matches_aiken` | Field order matches Aiken declaration order (owner, name, description, capabilities, framework, endpoint, registered_at) |

### test_integration.py — 15 tests (requires testnet)

**File:** `python/tests/test_integration.py`

Integration tests against the live Vector testnet. Require `VECTOR_SKEY_PATH` environment variable pointing to a funded payment signing key. Run with `-m integration`.

#### TestConnection (4 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 1 | `test_ogmios_connected` | Ogmios context is available after connect |
| 2 | `test_can_query_protocol_params` | Protocol parameters retrieved from chain |
| 3 | `test_script_address_valid` | Script address is a valid testnet address |
| 4 | `test_policy_id_is_valid` | Policy ID is 28-byte hex hash |

#### TestQuery (2 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 5 | `test_query_agents_returns_list` | query_agents() returns a list (may be empty) |
| 6 | `test_query_agents_have_valid_datums` | Returned agents have parseable AgentDatum |

#### TestWallet (2 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 7 | `test_wallet_has_utxos` | Test wallet has at least one UTxO |
| 8 | `test_wallet_has_sufficient_balance` | Wallet has ≥12 AP3X (10 deposit + 2 fees) |

#### TestNftParity (1 test)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 9 | `test_derive_from_real_utxo` | NFT name derived from real UTxO is deterministic and 32 bytes |

#### TestLifecycle (6 tests)

| # | Test Name | What It Verifies |
|---|-----------|-----------------|
| 10 | `test_01_register` | Register a new agent on testnet (proves CBOR parity on-chain) |
| 11 | `test_02_find_registered_agent` | Registered agent is visible on-chain with correct datum |
| 12 | `test_03_update` | Update the agent's profile on-chain |
| 13 | `test_04_verify_update` | Updated datum fields are correct on-chain |
| 14 | `test_05_deregister` | Deregister agent (burn NFT, return deposit) |
| 15 | `test_06_verify_deregistration` | Agent no longer on-chain after deregistration |

---

## Integration Test Results (Day 4)

**Date:** March 19, 2026
**Duration:** 90.97s (includes 3 × 30s confirmation waits)
**Result:** 15/15 passed ✅

All lifecycle operations confirmed on Vector testnet:
- **Register** → `abc87540...` (mint budget: 96,809 mem / 35,887,948 cpu)
- **Update** → `3661cb29...` (spend budget: 123,813 mem / 41,794,630 cpu)
- **Deregister** → `42996d11...` (spend: 60,893 mem / 20,633,933 cpu + mint: 30,094 mem / 8,832,642 cpu)

**Key validations:**
- CBOR parity proven on-chain (register TX accepted = NFT name matches)
- RawCBOR inline datum parsing works correctly
- Wallet UTxO selection for fee coverage works after `add_input_address` fix

---

## Test Coverage Gaps (Known)

| Gap | Why | When to Address |
|-----|-----|-----------------|
| ~~CBOR parity~~ | ~~Offline tests confirm byte-exact match with Plutus spec.~~ **Proven on-chain** via successful register TX | ✅ Resolved Day 4 |
| ~~Integration test execution~~ | ~~Test module written but requires funded testnet wallet.~~ **All 15 tests passing** | ✅ Resolved Day 4 |
| Error paths in tx building | Edge cases like insufficient funds, wrong collateral, etc. | Future iteration |
