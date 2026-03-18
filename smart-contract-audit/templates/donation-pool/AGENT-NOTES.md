# Agent Notes — Donation Pool

# Deployment Guide — Donation Pool (Compliant)

## Prerequisites

- Aiken v1.1.21+ installed
- Cardano/Vector node or API access
- Off-chain transaction builder (PyCardano, Lucid, cardano-cli)

## Build

```bash
aiken build  # Produces plutus.json
```

## Deploy (Create the Pool)

The pool is created implicitly — anyone sends ADA to the script address with an inline `DonationDatum`:

```python
datum = {
    "constructor": 0,
    "fields": [
        {"bytes": admin_pkh_hex}  # 28-byte verification key hash
    ]
}
```

1. Extract the script address from `plutus.json`
2. Build a transaction sending ADA to the script address with the inline datum above
3. Submit — the UTxO is now part of the donation pool

**Multiple donors:** Each donor sends their own transaction to the same script address with the same admin PKH in the datum.

## Distribute Transaction

The admin builds a distribution transaction:

```python
redeemer = {
    "constructor": 0,  # Distribute
    "fields": [
        {"list": [
            {"constructor": 0, "fields": [
                {"bytes": recipient_1_pkh},
                {"int": 5_000_000}  # 5 ADA
            ]},
            {"constructor": 0, "fields": [
                {"bytes": recipient_2_pkh},
                {"int": 10_000_000}  # 10 ADA
            ]}
        ]}
    ]
}
```

The transaction must include:
- Inputs: one or more pool UTxOs (all must share the same admin)
- Outputs: one per recipient with ≥ stated amount
- Optional: change output back to script address (must preserve admin datum)
- Extra signatories: admin PKH

## Testnet First

- Test on Preview/Preprod before mainnet
- Verify recipient addresses are correct — distributions are irreversible
- Ensure adequate collateral UTxO for script execution

## Compliance Note

This is the audit-passed version. See `reports/` for the full audit trail.

# Parameters — Donation Pool (Compliant)

## Datum Parameters

| Parameter | Type | Description | Constraints |
|-----------|------|-------------|-------------|
| `admin` | `VerificationKeyHash` | 28-byte PKH of the pool administrator | Must be a valid payment key hash |

## Redeemer Parameters

### Distribute

| Parameter | Type | Description |
|-----------|------|-------------|
| `distributions` | `List<Distribution>` | List of (recipient, amount) pairs |

### Distribution (within the list)

| Field | Type | Description |
|-------|------|-------------|
| `recipient` | `VerificationKeyHash` | 28-byte PKH of the recipient |
| `amount` | `Int` | Lovelace to send (must be > 0) |

## Configuration Decisions

- **Admin key:** This is the single point of authority. Choose carefully — there is no admin rotation mechanism on-chain.
- **Distribution granularity:** Each distribution entry maps 1:1 to a recipient. No duplicate recipients allowed in a single transaction.
- **Batch size:** Multiple pool UTxOs can be consumed in one transaction, but all must share the same admin. Total distributed must not exceed total input value.
- **Change handling:** Excess ADA can return to the script address as change, but the change output must carry the same admin datum.

# Integration Points — Donation Pool (Compliant)

## Off-Chain Components Needed

1. **Admin key management:** The admin's signing key must be available for distribution transactions.
2. **Transaction builder:** Any Cardano-compatible TX builder (PyCardano, Lucid, cardano-cli, mesh).
3. **UTxO query:** Query script address to find all pool UTxOs and their total value.
4. **Recipient registry:** Off-chain list of approved recipients and amounts.

## API Integration

### Query Pool Balance
```
GET /utxos?address=<script_address>
→ Filter by datum admin field to get pool UTxOs for a specific admin
→ Sum lovelace across all matching UTxOs for total pool balance
```

### Submit Donation
```
POST /tx/submit
→ Standard TX: send ADA to script address with inline DonationDatum { admin }
→ No script execution needed — just a regular payment to the script address
```

### Submit Distribution
```
POST /tx/submit
→ Inputs: pool UTxOs
→ Redeemer: Distribute { distributions }
→ Outputs: one per recipient + optional change to script
→ Signatures: admin
```

## Multi-Party Workflow

```
Donors                  Admin                   Recipients
  │                       │                         │
  ├── Send ADA to ───────►│                         │
  │   script address      │                         │
  │   (with admin datum)  │                         │
  │                       │                         │
  │                       ├── Build distribution ──►│
  │                       │   (sign + submit)       │
  │                       │                         │
  │                       ├── Change returns ──────►│ (self, as new pool UTxO)
```

## Monitoring

- **New UTxO created (non-script input)** → donation received
- **UTxO consumed with Distribute** → distribution executed; check outputs for recipient payments
- **Change UTxO created** → remaining pool balance

## Compliance Evidence

See `reports/` for audit reports and `tests/` for test results demonstrating all integration paths work correctly.

# Common Modifications — Donation Pool (Compliant)

> **Note:** This is the audit-passed version. Any modifications will require re-auditing the changed code.

## 1. Add Admin Key Rotation

Add a new redeemer variant for updating the admin:

```aiken
pub type DonationRedeemer {
  Distribute { distributions: List<Distribution> }
  RotateAdmin { new_admin: VerificationKeyHash }
}
```

In the validator, require the current admin's signature and produce a change output with the new admin in the datum.

## 2. Add On-Chain Recipient Allowlist

Embed allowed recipients in the datum or use a reference token:

```aiken
pub type DonationDatum {
  admin: VerificationKeyHash,
  allowed_recipients: List<VerificationKeyHash>,
}
```

Then validate that every distribution recipient is in the allowlist.

## 3. Add Minimum Donation Threshold

Prevent dust attacks by enforcing a minimum donation value off-chain or via a wrapper:

```aiken
expect lovelace_of(donation_value) >= min_donation
```

## 4. Add Multi-Sig Admin

Replace single admin with a threshold scheme:

```aiken
pub type DonationDatum {
  admins: List<VerificationKeyHash>,
  required_signatures: Int,
}
```

Count matching signatories against the admin list.

## 5. Add Distribution Limits

Cap per-distribution or per-transaction amounts:

```aiken
let max_per_recipient = 100_000_000  // 100 ADA
let all_within_limit = list.all(distributions, fn(d) { d.amount <= max_per_recipient })
```

## 6. Add Native Token Support

The current contract tracks ADA (lovelace) only. To support native tokens:

- Add token policy ID and asset name to the datum or distribution entries
- Use `quantity_of` instead of `lovelace_of` for balance checks
- Consider multi-asset change handling

# Gotchas and Edge Cases — Donation Pool (Compliant)

## Critical

### Admin Is Fully Trusted
The admin can distribute to any address, including themselves. There is no on-chain accountability mechanism. Governance and trust in the admin must be handled off-chain.

### No Single-Input Constraint (By Design)
Unlike the DEX and vesting contracts, the donation pool intentionally allows **multiple** script inputs in one transaction (batch consumption). Double satisfaction is mitigated differently: per-recipient payment verification and same-admin enforcement across all inputs.

## Important

### Cross-Pool Attack Prevention
All script inputs consumed in one transaction must share the same admin. If an attacker creates a pool UTxO with a different admin, the validator rejects the transaction. This prevents inflating the budget by mixing pools.

### Duplicate Recipients Blocked
The validator rejects distributions with duplicate recipients. This prevents a subtle attack where a single output to a recipient satisfies two distribution entries, allowing the admin to pocket the difference.

### Change Datum Must Match
Any output returning to the script address must carry the same admin datum. If this were bypassed, an attacker could hijack pool change outputs by substituting a different admin.

## Edge Cases

### Empty Distribution List
The validator explicitly rejects empty distribution lists (`has_distributions` check). The admin must distribute to at least one recipient.

### Zero or Negative Amounts
Each distribution amount must be positive (`amount > 0`). Zero-value distributions are rejected.

### Donation With Wrong Admin
Anyone can send ADA to the script address with any admin PKH. The admin of the UTxO is whoever is specified in the datum — not the sender. Off-chain tooling must verify datum contents before counting pool balances.

### Min-UTxO on Change
When distributing most of the pool, ensure the change output (if any) meets the minimum UTxO requirement (~1-2 ADA). Otherwise the transaction will fail at the ledger level.

### Native Tokens Ignored
The contract only tracks ADA (lovelace). If native tokens are accidentally sent to the pool, they will be locked and can only leave as part of a distribution transaction's outputs. The validator does not verify native token amounts.
