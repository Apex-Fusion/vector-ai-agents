# Smart Contract Testing on Vector

A developer guide for testing Aiken smart contracts on the Vector chain — ApexFusion's Cardano-compatible eUTXO sidechain. This document covers Vector-specific considerations, Aiken testing patterns, test organization strategies, and integration testing workflows.

---

## Introduction

Vector is the eUTXO-based chain in ApexFusion's multi-chain architecture. It runs a Cardano-compatible ledger, which means:

- Smart contracts are written in **Aiken** and compile to **Plutus V3** UPLC
- Transaction validation follows the **extended UTxO** model
- The native coin is **AP3X** (not ADA), but the ledger mechanics are identical
- Standard Cardano tooling (Aiken, PyCardano, Ogmios) works with Vector — but with important configuration differences

If you've written Aiken contracts for Cardano, you already know 90% of what you need. This guide covers the other 10% — the Vector-specific gotchas that will cost you hours if you don't know about them upfront.

---

## Vector-Specific Considerations

### AP3X Native Coin

Vector's native coin is **AP3X**. It occupies the same role as ADA on Cardano — it's the native asset used for transaction fees, deposits, and the base unit in the UTxO value map.

**Key facts:**

| Property | Value |
|----------|-------|
| Native coin name | AP3X |
| Smallest unit | DFM (like lovelace on Cardano) |
| Decimal places | 6 |
| Conversion | 1 AP3X = 1,000,000 DFM |
| Example | 10 AP3X = 10,000,000 DFM |

**In Aiken**, you use `assets.lovelace_of(value)` to read the native coin amount — the function name is `lovelace_of` regardless of the chain's coin branding:

```aiken
use cardano/assets

// Check that an output has at least 10 AP3X (10,000,000 DFM)
let native_coin = assets.lovelace_of(output.value)
expect native_coin >= 10_000_000
```

**In Python (PyCardano)**, the native coin appears as `lovelace` in the UTxO value. No policy ID — it's the same slot as ADA on Cardano:

```python
# Building a value with 10 AP3X
from pycardano import Value
value = Value(coin=10_000_000)  # 10 AP3X in DFM
```

> **Common mistake:** Don't look for AP3X as a native token with a policy ID. It's the **native coin** — accessed via `lovelace_of` in Aiken and `coin` in PyCardano.

---

### Network ID: Mainnet on Testnet

This is the single most surprising Vector-specific detail:

> **Vector testnet uses the mainnet network ID.**

| Parameter | Value |
|-----------|-------|
| `networkMagic` | `764824073` |
| Network ID in addresses | Mainnet (`0b0001`) |
| Address prefix | `addr1` (NOT `addr_test1`) |

This means when configuring PyCardano or any Cardano library:

```python
from pycardano import Network

# CORRECT for Vector testnet
network = Network.MAINNET  # produces addr1... addresses

# WRONG — will produce addr_test1... and transactions will fail
# network = Network.TESTNET
```

**Why this matters:** The network tag is encoded into the first byte of every Shelley address. If you use `Network.TESTNET`, your addresses will start with `addr_test1` and every transaction submission will be rejected — the chain expects `addr1` addresses.

---

### Ogmios Configuration

Vector provides Ogmios endpoints for chain interaction. You'll need Ogmios for querying UTxOs, submitting transactions, and fetching protocol parameters.

**Local Ogmios (Docker):**

```bash
# Default local endpoint
OGMIOS_HOST=localhost
OGMIOS_PORT=1732
OGMIOS_SECURE=false
```

**Remote Ogmios (ApexFusion hosted):**

```bash
OGMIOS_HOST=ogmios.vector.testnet.apexfusion.org
OGMIOS_PORT=443
OGMIOS_SECURE=true
```

**RawCBOR Datum Parsing:**

Ogmios returns inline datums as `RawCBOR` objects, not as parsed `PlutusData`. Your code must handle this:

```python
from pycardano import RawPlutusData

def parse_datum(raw_datum):
    """Handle both RawCBOR and parsed PlutusData from Ogmios."""
    if isinstance(raw_datum, RawPlutusData):
        # Ogmios returns RawCBOR — decode manually
        return AgentDatum.from_cbor(raw_datum.cbor)
    else:
        # Already parsed PlutusData
        return AgentDatum.from_primitive(raw_datum)
```

This is a gotcha that only surfaces during integration testing — unit tests with mocked backends won't hit it.

---

### CBOR Parity

If your contract derives values from CBOR-serialized data (e.g., hashing a UTxO reference to produce an NFT asset name), you **must** ensure byte-exact CBOR parity between your off-chain code and the on-chain Aiken `cbor.serialise()`.

**The critical detail:** PyCardano uses **indefinite-length arrays** (`0x9F...0xFF`) for non-empty constructors and **definite-length empty arrays** (`0x80`) for empty constructors. This matches the Plutus CBOR convention used by Aiken.

```
# Non-empty constructor (e.g., Register { seed }):
# Tag 121 (constructor 0) + indefinite array 0x9F + fields + 0xFF break
d8 79 9f [field bytes...] ff

# Empty constructor (e.g., Burn {}):
# Tag 122 (constructor 1) + definite empty array 0x80
d8 7a 80
```

**Why this matters in practice:** If you derive an NFT asset name as `blake2b_256(cbor.serialise(output_reference))`, even a single byte difference in the CBOR encoding between Python and Aiken will produce a completely different hash. Your registration transaction will fail on-chain because the validator computes a different expected NFT name.

**Recommendation:** Write explicit CBOR parity tests (see [Test Organization Strategy](#test-organization-strategy) below). Don't assume your off-chain library matches — verify it.

---

## Testing Framework: Aiken Check

### Project Structure

A standard Aiken project for Vector follows this layout:

```
my-contract/
├── aiken.toml                  # Project config (Aiken version, Plutus V3, stdlib)
├── aiken.lock                  # Dependency lock file
├── lib/
│   └── my_contract/
│       ├── types.ak            # On-chain types (datums, redeemers)
│       ├── validation.ak       # Core validation logic (testable functions)
│       └── validation_tests.ak # Unit tests for validation logic
├── validators/
│   └── contract.ak             # Validator entry point (thin wrapper)
└── plutus.json                 # Generated blueprint (after aiken build)
```

**Key architectural pattern:** Extract your validation logic into `lib/` as regular `pub fn` functions. Aiken's `validator` blocks compile to UPLC and **cannot be called directly from `test` blocks**. By keeping logic in library functions, you can test every validation path independently.

```toml
# aiken.toml
name = "vector/my-contract"
version = "0.0.0"
compiler = "v1.1.21"
plutus = "v3"

[dependencies]
aiken-lang/stdlib = "v3.0.0"
```

### Writing Tests

Aiken tests live in `.ak` files inside `lib/` (not `validators/`). Each test is a `test` block that returns a `Bool`:

```aiken
test my_test_name() {
  // Arrange: build test data
  let result = my_validation_function(args)
  // Assert: check the result
  result == True
}
```

**The placeholder + spread pattern** is the standard way to construct test transactions. Start from `transaction.placeholder` (an empty transaction with all fields set to defaults) and override only what your test needs:

```aiken
use cardano/transaction.{Transaction, placeholder}

test my_validation_test() {
  let tx = Transaction {
    ..placeholder,
    inputs: [my_test_input],
    outputs: [my_test_output],
    mint: my_test_mint_value,
    extra_signatories: [owner_vkh],
  }
  validate_something(tx)
}
```

This keeps tests focused — you only specify the fields relevant to the validation path being tested.

### Running Tests

```bash
# Run all tests
aiken check

# Expected output
# Compiling vector/my-contract 0.0.0
# Compiling aiken-lang/stdlib v3.0.0
# Collecting all test scenarios across all modules
# Testing ...
# Summary: 30 checks, 0 errors
```

> **Note:** The `aiken` binary may not be on `$PATH` by default. Common location: `~/.aiken/bin/aiken`. Add it to your PATH or reference it directly in CI.

---

## Test Organization Strategy

A comprehensive test suite for a Vector smart contract should include five categories:

### Behavioral Tests (What SHOULD Work)

Behavioral tests document the contract's intended functionality. Every legitimate use case gets a test. These tests must pass on **both** the original and any security-hardened version — they're your regression safety net.

```aiken
/// BEHAVIOR: The contract accepts deposits above the minimum.
/// The contract enforces a floor, not a ceiling.
test behavior_register_accepts_large_deposit() {
  let large_deposit = min_deposit_lovelace * 10
  let output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(large_deposit, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(base_agent_datum()),
      reference_script: None,
    }
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [output],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  validate_register(test_seed(), test_policy_id, tx)
}
```

**Naming convention:** Prefix with `behavior_` for clarity.

**What to cover:**
- Happy path for every validator action (register, update, deregister)
- Boundary values (exact minimum deposit, empty fields)
- Design decisions that might look like bugs (e.g., ownership transfer, unrestricted datum content)

### Exploit Tests (What Should NOT Work)

Exploit tests prove that a vulnerability is **real and exploitable**. They pass on the vulnerable version and **fail** on the fixed version. This inverted logic is deliberate — a failing exploit test means the security fix is working.

```aiken
/// EXPLOIT: Burn succeeds without spending the agent UTxO.
/// Finding: AR-ORPHAN-BURN (Critical)
///
/// COMPLIANT VERSION: This test should FAIL — burn must be coupled
/// to a valid deregister spend action.
test exploit_orphan_burn_no_spend() {
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), -1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [],       // No agent UTxO spent — deposit permanently locked
      outputs: [],
      mint: mint_value,
    }
  validate_burn(test_policy_id, tx)
}
```

**Naming convention:** Prefix with `exploit_` and reference the finding ID.

**Key principle:** Each exploit test should clearly document:
1. The attack scenario
2. The root cause
3. What the expected behavior is after the fix

### Property-Based Tests

Test invariants that must hold across all operations:

```aiken
/// Different seed UTxOs always produce different NFT names.
test behavior_different_tx_hashes_produce_different_nft_names() {
  let seed_a =
    OutputReference {
      transaction_id: #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      output_index: 0,
    }
  let seed_b =
    OutputReference {
      transaction_id: #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      output_index: 0,
    }
  derive_asset_name(seed_a) != derive_asset_name(seed_b)
}
```

### Fuzz Tests

Aiken supports property-based fuzzing with the `via` keyword. Use it to test validation boundaries with random inputs:

```aiken
test register_always_fails_below_minimum(deposit_dfm via fuzzer.int_between(0, 9_999_999)) {
  let output =
    Output {
      address: test_script_address(),
      value: make_value_with_nft(deposit_dfm, test_policy_id, test_nft_name(), 1),
      datum: InlineDatum(base_agent_datum()),
      reference_script: None,
    }
  let mint_value = assets.zero |> assets.add(test_policy_id, test_nft_name(), 1)
  let tx =
    Transaction {
      ..placeholder,
      inputs: [seed_input()],
      outputs: [output],
      mint: mint_value,
      extra_signatories: [test_owner_vkh],
    }
  !validate_register(test_seed(), test_policy_id, tx)
}
```

### Integration Tests (Testnet)

Integration tests run against the live Vector testnet. They require a funded wallet and Ogmios access. These are typically written in Python (or your off-chain language) and marked separately so they don't run in CI by default:

```python
@pytest.mark.integration
def test_register_on_testnet(registry, wallet):
    """Register an agent on Vector testnet — proves CBOR parity on-chain."""
    profile = AgentProfile(name="TestBot", ...)
    tx_hash = registry.register(profile, wallet)
    assert tx_hash is not None
    # Wait for confirmation
    time.sleep(30)
    agents = registry.query_agents()
    assert any(a.name == "TestBot" for a in agents)
```

---

## Testing Patterns in Aiken

### Transaction Construction (Placeholder + Spread)

The `transaction.placeholder` provides an empty transaction. Use the spread operator (`..placeholder`) to override specific fields:

```aiken
use cardano/transaction.{Transaction, placeholder}

let tx = Transaction {
  ..placeholder,
  inputs: [seed_input()],
  outputs: [registry_output()],
  mint: mint_value,
  extra_signatories: [test_owner_vkh],
}
```

Fields you'll commonly override:
- `inputs` — UTxOs being consumed
- `outputs` — UTxOs being created
- `mint` — tokens being minted or burned
- `extra_signatories` — public key hashes that signed the transaction

### Mock Inputs and Outputs

Build `Input` values by combining an `OutputReference` with an `Output`:

```aiken
use cardano/transaction.{Input, Output, OutputReference}

fn seed_input() -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
      output_index: 0,
    },
    output: Output {
      address: Address {
        payment_credential: VerificationKey(test_owner_vkh),
        stake_credential: None,
      },
      value: assets.from_lovelace(20_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}
```

### Value Construction (Lovelace + Native Tokens)

Build values with both the native coin and custom tokens:

```aiken
use cardano/assets

// Native coin only (10 AP3X)
let value_lovelace = assets.from_lovelace(10_000_000)

// Native coin + NFT
fn make_value_with_nft(
  lovelace: Int,
  policy: ByteArray,
  name: ByteArray,
  qty: Int,
) -> assets.Value {
  assets.from_lovelace(lovelace)
    |> assets.add(policy, name, qty)
}

// Usage: 10 AP3X + 1 identity NFT
let value = make_value_with_nft(10_000_000, policy_id, nft_name, 1)
```

### Datum Handling (InlineDatum, NoDatum)

Vector contracts typically use inline datums (Plutus V3). In tests, you'll construct outputs with either:

```aiken
use cardano/transaction.{InlineDatum, NoDatum}

// Output with an inline datum (typical for registry UTxOs)
let registry_output = Output {
  address: script_address,
  value: value_with_nft,
  datum: InlineDatum(agent_datum),     // Datum visible on-chain
  reference_script: None,
}

// Output without a datum (typical for wallet UTxOs)
let wallet_output = Output {
  address: wallet_address,
  value: assets.from_lovelace(5_000_000),
  datum: NoDatum,
  reference_script: None,
}
```

**Testing datum presence:**

```aiken
// Verify a validator rejects outputs without inline datums
test register_fails_no_inline_datum() {
  let output = Output {
    ..valid_registry_output(),
    datum: NoDatum,  // Missing datum
  }
  // ... build tx ...
  !validate_register(seed, policy_id, tx)  // Should fail
}
```

### Signature Testing (extra_signatories)

Test authorization by controlling the `extra_signatories` field:

```aiken
// Test: correct signer → should pass
test update_success() {
  let tx = Transaction {
    ..placeholder,
    inputs: [registry_input()],
    outputs: [updated_output()],
    extra_signatories: [test_owner_vkh],  // Owner signed
  }
  validate_update(datum, utxo_ref, tx)
}

// Test: wrong signer → should fail
test update_fails_wrong_signer() {
  let wrong_vkh = #"9999999999999999999999999999999999999999999999999999999999999999"
  let tx = Transaction {
    ..placeholder,
    inputs: [registry_input()],
    outputs: [updated_output()],
    extra_signatories: [wrong_vkh],  // Wrong person signed
  }
  !validate_update(datum, utxo_ref, tx)
}

// Test: no signer → should fail
test update_fails_no_signature() {
  let tx = Transaction {
    ..placeholder,
    inputs: [registry_input()],
    outputs: [updated_output()],
    extra_signatories: [],  // Nobody signed
  }
  !validate_update(datum, utxo_ref, tx)
}
```

### Mint Field Construction

The `mint` field in a transaction represents tokens being created or destroyed:

```aiken
use cardano/assets

// Minting 1 NFT (registration)
let mint_value = assets.zero
  |> assets.add(test_policy_id, test_nft_name(), 1)

// Burning 1 NFT (deregistration)
let burn_value = assets.zero
  |> assets.add(test_policy_id, test_nft_name(), -1)
```

**Testing mint validation:**

```aiken
// Wrong quantity (mint 2 instead of 1)
test register_fails_wrong_mint_quantity() {
  let bad_mint = assets.zero |> assets.add(policy_id, nft_name, 2)
  let tx = Transaction { ..placeholder, mint: bad_mint, ... }
  !validate_register(seed, policy_id, tx)
}

// Positive quantity on a burn redeemer
test burn_fails_positive_quantity() {
  let bad_mint = assets.zero |> assets.add(policy_id, nft_name, 1)
  let tx = Transaction { ..placeholder, mint: bad_mint, ... }
  !validate_burn(policy_id, tx)
}
```

---

## Integration Testing on Vector Testnet

### Prerequisites

Before running integration tests, you need:

1. **A funded wallet** — at least 12 AP3X (10 for the minimum deposit + ~2 for fees)
2. **A payment signing key** — `payment.skey` file
3. **Ogmios access** — local Docker container or the remote ApexFusion endpoint
4. **The compiled contract** — `plutus.json` generated by `aiken build`

```bash
# Set environment variables
export VECTOR_SKEY_PATH=/path/to/payment.skey

# For local Ogmios (default)
export VECTOR_OGMIOS_HOST=localhost
export VECTOR_OGMIOS_PORT=1732

# For remote Ogmios
export VECTOR_OGMIOS_HOST=ogmios.vector.testnet.apexfusion.org
export VECTOR_OGMIOS_PORT=443
export VECTOR_OGMIOS_SECURE=true
```

### Transaction Lifecycle

A full integration test exercises the complete lifecycle:

```
Register → (wait) → Query → Update → (wait) → Query → Deregister → (wait) → Verify gone
```

Each step submits a transaction to the Vector testnet and waits for confirmation.

**Register:**
```
1. Choose a seed UTxO from the wallet
2. Derive NFT asset name = blake2b_256(cbor(seed_utxo_ref))
3. Build TX: consume seed, mint 1 NFT, create registry output with datum + NFT + ≥10 AP3X
4. Submit and wait for confirmation
```

**Update:**
```
1. Find the agent's registry UTxO on-chain
2. Build TX: spend registry UTxO (Update redeemer), create new output with updated datum
3. Owner must sign
4. Submit and wait for confirmation
```

**Deregister:**
```
1. Find the agent's registry UTxO on-chain
2. Build TX: spend registry UTxO (Deregister redeemer), burn the NFT (Burn mint redeemer)
3. Owner must sign
4. Submit and wait for confirmation
5. AP3X deposit is returned to the owner
```

### Confirmation Timing

Vector testnet block times are similar to Cardano. Expect **~30 seconds** for transaction confirmation. Integration tests typically include explicit waits:

```python
# After submitting a transaction
time.sleep(30)  # Wait for next block
```

For a full register → update → deregister lifecycle, budget **~90 seconds** of wait time.

### Error Handling

**UTxOSelectionException:**

The most common integration test failure. PyCardano's `TransactionBuilder` needs access to wallet UTxOs to cover transaction fees (~0.25 AP3X). If you only add the script UTxO as an input, coin selection will fail:

```python
# WRONG — builder only knows about the script UTxO
builder = TransactionBuilder(context)
builder.add_script_input(script_utxo, redeemer=redeemer)
# Fails: UTxOSelectionException — can't cover fees

# CORRECT — also add the wallet's address for fee coverage
builder = TransactionBuilder(context)
builder.add_script_input(script_utxo, redeemer=redeemer)
builder.add_input_address(wallet_address)  # Allows coin selection from wallet UTxOs
```

**RawCBOR Datum Parsing:**

When querying on-chain UTxOs, Ogmios may return datums as `RawCBOR`. Always handle both formats (see [Ogmios Configuration](#ogmios-configuration) above).

---

## Common Pitfalls

### Wrong Network ID (addr_test1 vs addr1)

**Symptom:** Transaction submission fails with an address mismatch error.

**Cause:** Using `Network.TESTNET` instead of `Network.MAINNET` for Vector.

**Fix:** Always use `Network.MAINNET` when targeting Vector testnet:

```python
from pycardano import Network, Address

# Vector testnet address
address = Address(payment_part=vkh, network=Network.MAINNET)
assert str(address).startswith("addr1")  # NOT addr_test1
```

### CBOR Encoding Mismatch

**Symptom:** On-chain transactions fail because derived values (e.g., NFT asset names) don't match between off-chain and on-chain computation.

**Cause:** Your off-chain CBOR serialization doesn't match Aiken's `cbor.serialise()`.

**Fix:** Write explicit CBOR parity tests that compare byte-exact output:

```python
def test_output_reference_cbor_matches_plutus_spec():
    """Verify PyCardano CBOR matches Aiken's cbor.serialise() for OutputReference."""
    ref = OutputReference(
        transaction_id=TransactionId(bytes.fromhex("deadbeef" * 8)),
        output_index=0,
    )
    cbor_bytes = ref.to_cbor()
    # Verify tag 121 (constructor 0) + indefinite array
    assert cbor_bytes[0:2] == bytes([0xd8, 0x79])  # Tag 121
    assert cbor_bytes[2] == 0x9f  # Indefinite array start
    assert cbor_bytes[-1] == 0xff  # Break byte
```

### Missing UTxO for Fee Coverage

**Symptom:** `UTxOSelectionException` during transaction building.

**Cause:** The `TransactionBuilder` only knows about script UTxOs (pre-selected inputs) but needs wallet UTxOs to pay fees.

**Fix:** Always call `builder.add_input_address(change_address)` so PyCardano can select additional UTxOs for fees:

```python
builder = TransactionBuilder(context)
builder.add_script_input(script_utxo, script=script, redeemer=redeemer)
builder.add_input_address(change_address)  # Critical for fee coverage
```

### Hex Literal Length (Even Bytes Only)

**Symptom:** Aiken compilation fails with a parse error on a hex literal.

**Cause:** Hex byte arrays in Aiken must have an **even number** of hex characters (each byte is 2 hex chars). An odd-length literal like `#"aabbccdde"` (9 chars = 4.5 bytes) is invalid.

**Fix:** Always double-check hex literal lengths:

```aiken
// WRONG — 9 hex chars (odd)
const bad_hash: ByteArray = #"aabbccdde"

// CORRECT — 10 hex chars (5 bytes)
const good_hash: ByteArray = #"aabbccddee"

// For 28-byte hashes (policy IDs, key hashes): 56 hex chars
// For 32-byte hashes (tx hashes, blake2b-256 digests): 64 hex chars
```

---

## Quick Start Template

Here's a minimal Aiken test file to get you started on Vector:

```aiken
/// My contract tests for Vector
/// Run with: aiken check

use cardano/address.{Address, VerificationKey}
use cardano/assets
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
  placeholder,
}
use my_contract/types.{MyDatum}
use my_contract/validation.{validate_action, min_deposit_lovelace}

// ──────────────────────────────────────────────────────────────────────
// Fixtures — reusable test data
// ──────────────────────────────────────────────────────────────────────

const test_policy_id: ByteArray =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const test_owner_vkh: ByteArray =
  #"1122334455667788112233445566778811223344556677881122334455667788"

const test_tx_hash: ByteArray =
  #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

fn test_seed() -> OutputReference {
  OutputReference { transaction_id: test_tx_hash, output_index: 0 }
}

fn test_script_address() -> Address {
  Address {
    payment_credential: address.Script(test_policy_id),
    stake_credential: None,
  }
}

fn make_value_with_nft(
  lovelace: Int,
  policy: ByteArray,
  name: ByteArray,
  qty: Int,
) -> assets.Value {
  assets.from_lovelace(lovelace)
    |> assets.add(policy, name, qty)
}

fn wallet_input() -> Input {
  Input {
    output_reference: test_seed(),
    output: Output {
      address: Address {
        payment_credential: VerificationKey(test_owner_vkh),
        stake_credential: None,
      },
      value: assets.from_lovelace(20_000_000),  // 20 AP3X
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn base_datum() -> MyDatum {
  MyDatum {
    owner: VerificationKey(test_owner_vkh),
    // ... your datum fields
  }
}

// ──────────────────────────────────────────────────────────────────────
// Behavioral Tests — what SHOULD work
// ──────────────────────────────────────────────────────────────────────

test behavior_happy_path() {
  let output = Output {
    address: test_script_address(),
    value: assets.from_lovelace(min_deposit_lovelace),
    datum: InlineDatum(base_datum()),
    reference_script: None,
  }
  let tx = Transaction {
    ..placeholder,
    inputs: [wallet_input()],
    outputs: [output],
    extra_signatories: [test_owner_vkh],
  }
  validate_action(tx)
}

// ──────────────────────────────────────────────────────────────────────
// Exploit Tests — what should NOT work
// ──────────────────────────────────────────────────────────────────────

test exploit_no_signature_should_fail() {
  let output = Output {
    address: test_script_address(),
    value: assets.from_lovelace(min_deposit_lovelace),
    datum: InlineDatum(base_datum()),
    reference_script: None,
  }
  let tx = Transaction {
    ..placeholder,
    inputs: [wallet_input()],
    outputs: [output],
    extra_signatories: [],  // No signature
  }
  !validate_action(tx)  // Should fail — negated assertion
}

test exploit_below_minimum_deposit() {
  let output = Output {
    address: test_script_address(),
    value: assets.from_lovelace(min_deposit_lovelace - 1),  // One DFM below
    datum: InlineDatum(base_datum()),
    reference_script: None,
  }
  let tx = Transaction {
    ..placeholder,
    inputs: [wallet_input()],
    outputs: [output],
    extra_signatories: [test_owner_vkh],
  }
  !validate_action(tx)  // Should fail
}
```

**To run:**

```bash
cd my-contract/
aiken check
# Expected: all checks pass
```

**Next steps after this template:**
1. Replace `MyDatum` and `validate_action` with your actual types and validators
2. Add tests for every validation path (success + failure)
3. Add boundary tests (exact minimums, empty fields)
4. Write exploit tests for any security-sensitive logic
5. Add integration tests (Python/PyCardano) for testnet verification
6. Verify CBOR parity if you derive on-chain values from serialized data

---

*This guide is based on real-world experience building and auditing smart contracts on the Vector testnet, including a full agent registry contract with 30 Aiken unit tests and 15 integration tests achieving complete lifecycle verification.*
