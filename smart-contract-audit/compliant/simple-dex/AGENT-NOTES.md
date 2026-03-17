# Agent Notes — Simple Dex

# Deployment Guide — Simple DEX (Compliant)

## Prerequisites

- Aiken v1.1.21+ installed
- Cardano/Vector node or API access
- Off-chain transaction builder (PyCardano, Lucid, cardano-cli)

## Build

```bash
aiken build  # Produces plutus.json
```

## Deploy (Create a Swap Offer)

1. Extract the script address from `plutus.json`
2. Build a transaction that sends the offered token(s) to the script address with an inline `SwapDatum`:

```python
datum = {
    "constructor": 0,
    "fields": [
        {"bytes": maker_pkh_hex},           # maker
        {"constructor": 0, "fields": [      # offered_asset (AssetClass)
            {"bytes": offered_policy_id},
            {"bytes": offered_asset_name}
        ]},
        {"constructor": 0, "fields": [      # desired_asset (AssetClass)
            {"bytes": desired_policy_id},
            {"bytes": desired_asset_name}
        ]},
        {"int": rate_numerator},             # e.g., 1
        {"int": rate_denominator}            # e.g., 50 (1 token A = 50 token B)
    ]
}
```

**For ADA:** Use empty bytestrings for both `policy_id` and `asset_name` (`#""`).

## Take Offer Transaction

```python
redeemer = {
    "constructor": 0,  # Take
    "fields": [
        {"int": maker_output_index}  # index of the output paying the maker
    ]
}
```

The transaction must include:
- Input: the swap UTxO at the script address
- Output[maker_output_index]: maker's address with ≥ required token B
- No maker signature needed (open offers)

## Cancel Transaction

```python
redeemer = {
    "constructor": 1,  # Cancel
    "fields": []
}
```

- Include maker in `extra_signatories`
- Create output returning offered tokens to maker

## Testnet First

- Test on Preview/Preprod before mainnet
- Double-check exchange rate arithmetic — ceiling division favors the maker
- Ensure adequate collateral UTxO for script execution

## Compliance Note

This is the audit-passed version. See `reports/` for the full audit trail.

# Parameters — Simple DEX (Compliant)

## Datum Parameters

| Parameter | Type | Description | Constraints |
|-----------|------|-------------|-------------|
| `maker` | `VerificationKeyHash` | 28-byte PKH of the offer creator | Must be valid |
| `offered_asset` | `AssetClass` | Token being offered (policy_id + asset_name) | Policy ID: 28 bytes or empty for ADA |
| `desired_asset` | `AssetClass` | Token being requested | Policy ID: 28 bytes or empty for ADA |
| `rate_numerator` | `Int` | Numerator of the exchange rate | Must be > 0 |
| `rate_denominator` | `Int` | Denominator of the exchange rate | Must be > 0 |

### AssetClass

| Field | Type | Description |
|-------|------|-------------|
| `policy_id` | `ByteArray` | 28-byte minting policy hash, or `#""` for ADA |
| `asset_name` | `ByteArray` | Token name, or `#""` for ADA |

## Redeemer Parameters

### Take
| Parameter | Type | Description |
|-----------|------|-------------|
| `maker_output_index` | `Int` | Index into `tx.outputs` for maker payment |

### Cancel
No parameters (unit constructor).

## Exchange Rate Calculation

```
required_b = ceil(locked_a × rate_denominator / rate_numerator)
```

**Example:** Offering 100 tokens at rate 1:50 (numerator=1, denominator=50):
- `required_b = ceil(100 × 50 / 1) = 5000`
- Taker must pay at least 5000 units of token B

## Configuration Decisions

- **Rate precision:** Use larger numerator/denominator for finer granularity. E.g., `3:7` is coarser than `300:700` (same ratio but different rounding behavior).
- **ADA vs tokens:** For ADA, use empty bytestrings. The validator handles both via `get_asset_amount`.
- **Offer size:** The locked value IS the offer. There are no partial fills.

# Integration Points — Simple DEX (Compliant)

## Off-Chain Components Needed

1. **Order book indexer:** Query the script address for all swap UTxOs. Parse datums to display available offers.
2. **Transaction builder:** Build take/cancel transactions with correct redeemer and output pinning.
3. **Price feed (optional):** For UI display — convert rates to human-readable prices.
4. **UTxO selection:** When taking, select exactly one swap UTxO (the validator enforces single-script-input).

## API Integration

### List Open Offers
```
GET /utxos?address=<script_address>
→ Parse each UTxO's datum to extract: maker, offered/desired assets, rate
→ Calculate required payment: ceil(locked_a × rate_denominator / rate_numerator)
```

### Take an Offer
```
POST /tx/submit
→ Input: swap UTxO
→ Redeemer: Take { maker_output_index }
→ Output[maker_output_index]: maker address with ≥ required token B
→ No signature required from taker (open offers)
```

### Cancel an Offer
```
POST /tx/submit
→ Input: swap UTxO
→ Redeemer: Cancel
→ Signature: maker
```

## Multi-Party Workflow

```
Maker                          Taker
  │                              │
  ├── Lock token A at script     │
  │   (with SwapDatum)           │
  │                              │
  │                        ◄─────┤  Take: pay token B to maker
  │                              │  (receives token A from script)
  │                              │
  ├── [Optional] Cancel ────────►│
  │   (reclaim token A)          │
```

## Monitoring

- **New UTxO at script address** → new swap offer created
- **UTxO consumed with Take** → offer filled; check maker output for payment
- **UTxO consumed with Cancel** → offer withdrawn by maker

## Compliance Evidence

See `reports/` for audit reports and `tests/` for test results demonstrating all integration paths work correctly.

# Common Modifications — Simple DEX (Compliant)

> **Note:** This is the audit-passed version. Any modifications will require re-auditing the changed code.

## 1. Add Partial Fills

Allow takers to buy a portion of the offer:

```aiken
Take { maker_output_index, fill_amount } -> {
    // Verify fill_amount <= locked_amount_a
    // Compute required_b for fill_amount only
    // Create continuation UTxO with remaining tokens + same datum
}
```

Requires adding a continuation output check similar to the vesting contract pattern.

## 2. Add Offer Expiration

Add a deadline to the datum:

```aiken
pub type SwapDatum {
  maker: VerificationKeyHash,
  offered_asset: AssetClass,
  desired_asset: AssetClass,
  rate_numerator: Int,
  rate_denominator: Int,
  expires_at: Int,  // POSIX ms — offer invalid after this
}
```

In the Take handler, check `interval.is_entirely_before(tx.validity_range, d.expires_at)`.

## 3. Add Minimum Fill Amount

Prevent dust takes by requiring a minimum payment:

```aiken
let min_fill = 1_000_000  // 1 ADA minimum
expect required_b >= min_fill
```

## 4. Add Fee Mechanism

Deduct a protocol fee from each take:

```aiken
let fee_bps = 30  // 0.3%
let fee = required_b * fee_bps / 10000
// Require an additional output paying the fee to a protocol address
```

## 5. Support Multi-Asset Offers

Lock multiple tokens in a single offer with a basket rate. The current design supports one offered asset per UTxO — for multi-asset, create separate UTxOs per token pair.

## 6. Add Taker Signature Requirement

For private/OTC offers, restrict who can take:

```aiken
pub type SwapDatum {
  // ... existing fields ...
  allowed_taker: Option<VerificationKeyHash>,
}
```

If `Some(taker)`, require that PKH in `extra_signatories`.

# Gotchas and Edge Cases — Simple DEX (Compliant)

## Critical

### Single-Script-Input Constraint
The validator enforces `script_input_count == 1`. You **cannot** batch multiple swap takes in a single transaction. Each take requires its own transaction.

### Ceiling Division Favors Maker
The `ceiling_div` function rounds up, meaning the taker always pays at least the exact rational amount. This is intentional — it prevents rounding exploits where the taker could pay less than the fair rate.

## Important

### Policy ID Validation
The validator checks that policy IDs are either exactly 28 bytes (standard Blake2b-224 hash) or empty (for ADA). Invalid policy IDs cause the Take to fail. This is checked at take-time, not at offer creation — a malformed datum creates an untakeable (but cancellable) offer.

### Zero-Rate Rejection
Both `rate_numerator` and `rate_denominator` must be > 0. If either is zero or negative, the Take redeemer will fail. Cancel still works (only checks maker signature).

### All-or-Nothing Fills
There are no partial fills. The taker must pay for the entire locked amount. If the offer is too large, it cannot be partially consumed.

## Edge Cases

### Staking Credential on Maker Payment
The validator checks `payment_credential == VerificationKey(d.maker)` — it does NOT check the staking credential. A taker could attach any staking credential to the maker's payment output. This is acceptable (maker still receives funds) but means staking rewards could go elsewhere.

### Empty Offer
If the locked value at the script address does not contain the offered asset (e.g., only min-ADA), `locked_amount_a` will be 0 and the `expect locked_amount_a > 0` check fails. The offer cannot be taken but can be cancelled.

### ADA-to-ADA Swaps
The contract technically allows ADA-to-ADA swaps (both assets set to empty policy). This is economically pointless but not harmful — the maker would just be exchanging ADA at a rate.

### Token Dust at Script Address
Each UTxO is independent. Random tokens sent to the script address with unrelated datums do not affect existing offers. However, they will be locked there unless someone can satisfy the validator for that specific UTxO.

### MEV / Front-Running
Open offers can be taken by anyone. In a public mempool, a taker's transaction could be front-run by another party. This is inherent to open-order DEX designs.

### Min-UTxO Requirements
The offered tokens plus the datum must meet minimum UTxO requirements. For offers involving only native tokens, ensure enough ADA is included for the min-UTxO.
