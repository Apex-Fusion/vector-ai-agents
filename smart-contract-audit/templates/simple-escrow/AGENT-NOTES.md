# Agent Notes — Simple Escrow

# Deployment Guide — Simple Escrow (Compliant)

## Prerequisites

- Aiken v1.1.21+ installed (`curl -sSfL https://install.aiken-lang.org | bash`)
- A Cardano/Vector node or API access (Ogmios, Blockfrost, etc.)
- Off-chain transaction builder (PyCardano, Lucid, cardano-cli)

## Build

```bash
cd your-project
aiken build
# Produces plutus.json with the compiled validator
```

## Deploy (Create an Escrow)

1. Extract the script address from `plutus.json`
2. Build a transaction that sends ADA to the script address with an inline `EscrowDatum`
3. The datum must contain: `beneficiary` PKH, `sender` PKH, `deadline` (POSIX ms), `secret_hash` (blake2b_256 of secret)

```python
import hashlib, os

# Generate secret
secret = os.urandom(32)
secret_hash = hashlib.blake2b(secret, digest_size=32).digest()

# Build datum
datum = {
    "constructor": 0,
    "fields": [
        {"bytes": beneficiary_pkh_hex},
        {"bytes": sender_pkh_hex},
        {"int": deadline_posix_ms},
        {"bytes": secret_hash.hex()}
    ]
}
```

## Claim Transaction

- Spend the script UTxO with `Claim { secret }` redeemer
- Set validity range upper bound < deadline
- Include beneficiary in `extra_signatories`
- Create output to beneficiary with ≥ locked value

## Reclaim Transaction

- Spend the script UTxO with `Reclaim` redeemer
- Set validity range lower bound > deadline
- Include sender in `extra_signatories`
- Create output to sender with ≥ locked value

## Testnet vs Mainnet

- Test on Preview/Preprod testnet first
- The validator hash changes if you modify the source — always rebuild and recalculate the script address
- Ensure adequate collateral UTxO for script execution

## Compliance Note

This is the audit-passed version. The contract has been reviewed, tested, and verified. See the `reports/` folder for the full audit trail.

# Parameters — Simple Escrow (Compliant)

## Datum Parameters

| Parameter | Type | Description | Constraints |
|-----------|------|-------------|-------------|
| `beneficiary` | `VerificationKeyHash` | 28-byte PKH of who can claim | Must be a valid payment key hash |
| `sender` | `VerificationKeyHash` | 28-byte PKH of who can reclaim | Must be a valid payment key hash |
| `deadline` | `Int` | POSIX milliseconds | Must be in the future when creating |
| `secret_hash` | `Hash<Blake2b_256, ByteArray>` | 32-byte blake2b_256 hash | Must match `blake2b_256(secret)` |

## Redeemer Parameters

### Claim
| Parameter | Type | Description |
|-----------|------|-------------|
| `secret` | `ByteArray` | Pre-image of `secret_hash` |

### Reclaim
No parameters (unit constructor).

## Configuration Decisions

- **Deadline:** Choose based on your use case. Consider timezone, slot length, and network propagation delays. Add a buffer (e.g., 1 hour) to avoid the dead zone at the exact deadline.
- **Secret size:** 32 random bytes recommended. Shorter secrets have lower entropy.
- **Value:** The locked value is whatever ADA you send to the script address. The validator enforces that the full value is paid out.

# Integration Points — Simple Escrow (Compliant)

## Off-Chain Components Needed

1. **Secret generation:** Generate and securely store the secret before creating the escrow. The secret is revealed on-chain during claim.
2. **Transaction builder:** Any Cardano-compatible TX builder (PyCardano, Lucid, cardano-cli, mesh).
3. **UTxO query:** Need to find the escrow UTxO at the script address by datum.
4. **Time oracle:** Convert wall-clock time to POSIX milliseconds for deadline setting.

## API Integration

### Query Escrow UTxOs
```
GET /utxos?address=<script_address>
→ Filter by datum to find specific escrows
```

### Submit Claim TX
```
POST /tx/submit
→ Must include: script UTxO as input, Claim redeemer, beneficiary signature, output to beneficiary
```

## Multi-Party Workflow

```
Sender                     Beneficiary
  │                            │
  ├── Generate secret ────────►│  (off-chain, secure channel)
  │                            │
  ├── Lock ADA at script       │
  │   (with secret_hash)       │
  │                            │
  │                      ◄─────┤  Claim (reveal secret)
  │                            │
  ├── [After deadline] ────────┤  
  │   Reclaim if unclaimed     │
```

## Webhook / Event Integration

Monitor the script address for:
- **New UTxO created** → escrow locked
- **UTxO consumed with Claim** → secret revealed, funds claimed
- **UTxO consumed with Reclaim** → deadline passed, funds returned

## Compliance Evidence

See `reports/` for audit reports and `tests/` for test results demonstrating all integration paths work correctly.

# Common Modifications — Simple Escrow (Compliant)

> **Note:** This is the audit-passed version. Any modifications will require re-auditing the changed code.

## 1. Add Single-Script-Input Enforcement

For additional double satisfaction protection, add:

```aiken
let script_input_count =
  list.count(tx.inputs, fn(i) { i.output.address == script_address })
expect script_input_count == 1
```

This is the strongest defense, proven in the vesting and DEX contracts.

## 2. Add Mutual Cancellation

Add a third redeemer variant for cooperative exit:

```aiken
pub type EscrowRedeemer {
  Claim { secret: ByteArray }
  Reclaim
  MutualCancel
}
```

In the validator, check that **both** sender and beneficiary have signed.

## 3. Add Partial Claims

Allow the beneficiary to claim a portion and leave the rest:

- Add a `claim_amount` field to the Claim redeemer
- Create a continuation UTxO at the script address with the remainder
- Compare continuation datum field-by-field (see vesting contract for the pattern)

## 4. Multi-Asset Support

The `assets_gte` helper already supports multi-asset values. To use with native tokens:

- Ensure the locked UTxO contains the tokens you want to escrow
- The validator already checks all assets, not just ADA

## 5. Multi-Beneficiary

Split into multiple beneficiaries with weighted shares:

- Change datum to include `List<(VerificationKeyHash, Int)>` for shares
- In the validator, verify each beneficiary receives their proportional share

## 6. Time-Extended Claim Window

Add a grace period after the deadline where both claim and reclaim work:

```aiken
let in_grace_period = current_time >= d.deadline && current_time <= d.deadline + grace_ms
```

# Gotchas and Edge Cases — Simple Escrow (Compliant)

## Critical

### Double Satisfaction Risk
The contract uses `list.any` to find outputs. If two escrow UTxOs share the same beneficiary and `value_A >= value_B`, a single output could satisfy both validators. Mitigated by the `assets_gte` check (each input's full value must be covered), but for maximum safety, add `script_input_count == 1`.

### Secret Visibility
Once the beneficiary claims, the secret is permanently visible on-chain in the transaction redeemer. Do not use secrets that have value beyond this single escrow.

## Important

### Dead Zone at Exact Deadline
At the exact deadline millisecond, neither Claim (`is_entirely_before` fails) nor Reclaim (`is_entirely_after` fails) works. Users should submit 1ms before or after. This is a 1ms window and not practically exploitable.

### Staking Credential Not Checked
The output address is checked by payment credential only. An attacker could redirect staking rewards by crafting an output with a different staking credential. Low impact for most use cases.

### Secret Must Be Pre-Shared Securely
The contract assumes the secret is shared off-chain between sender and beneficiary. If the secret channel is compromised, the escrow provides no protection.

## Edge Cases

### Datum Hijacking on Deposits
Anyone can send ADA to the script address with any datum. Off-chain tooling must verify the datum of UTxOs before interacting. The validator reads datum from its own spent input, so existing UTxOs are safe.

### Min-UTxO Requirements
The locked value must meet Cardano's minimum UTxO requirements (~1-2 ADA depending on datum size). If you try to lock less, the transaction will fail at the ledger level.

### Secret Hash Collisions
blake2b_256 is collision-resistant. Practical collision attacks are not feasible. However, very short secrets (< 16 bytes) may be brute-forceable.

### Validity Range Width
For Claim: the entire validity range must be before the deadline. Set a tight validity range (e.g., 5 minutes) for best results.
For Reclaim: the entire validity range must be after the deadline.
