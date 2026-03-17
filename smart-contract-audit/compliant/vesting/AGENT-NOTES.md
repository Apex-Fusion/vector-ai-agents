# Agent Notes — Vesting

# Deployment Guide — Vesting (Compliant)

## Prerequisites

- Aiken v1.1.21+ installed
- Cardano/Vector node or API access
- Off-chain transaction builder (PyCardano, Lucid, cardano-cli)

## Build

```bash
aiken build  # Produces plutus.json
```

## Deploy (Lock Vesting Funds)

1. Extract the script address from `plutus.json`
2. Build a transaction sending ADA to the script address with inline `VestingDatum`:

```python
cliff_time = now_ms + 30 * 24 * 3600 * 1000      # 30 days from now
vesting_end = cliff_time + 365 * 24 * 3600 * 1000  # 1 year cliff-to-end

datum = {
    "constructor": 0,
    "fields": [
        {"bytes": beneficiary_pkh},
        {"int": 1_000_000_000},  # 1000 ADA in lovelace
        {"int": cliff_time},
        {"int": vesting_end}
    ]
}
```

**Critical:** The `total_vesting_amount` in the datum should match the actual locked lovelace. Mismatches are safe but create inefficiency (excess requires a second transaction).

## Partial Claim Transaction

```python
redeemer = {
    "constructor": 0,  # Claim
    "fields": [
        {"int": 0},  # beneficiary_index — output index for beneficiary payment
        {"int": 1}   # continuation_index — output index for script continuation
    ]
}
```

The transaction must include:
- Input: the vesting UTxO
- Output[0]: beneficiary address with ≥ claimable lovelace
- Output[1]: script address with ≥ remaining lovelace + identical datum
- Validity range: set tight lower bound (this determines vested amount)
- Extra signatories: beneficiary PKH

## Full Claim Transaction

After `vesting_end_time`, claim everything:
- Same as partial claim, but no continuation output needed
- `continuation_index` is ignored when `must_remain == 0`

## Compliance Note

This is the audit-passed version. See `reports/` for the full audit trail.

# Parameters — Vesting (Compliant)

## Datum Parameters

| Parameter | Type | Description | Constraints |
|-----------|------|-------------|-------------|
| `beneficiary` | `VerificationKeyHash` | 28-byte PKH of who can claim | Must be valid |
| `total_vesting_amount` | `Int` | Total lovelace for proportional computation | Must be > 0 or UTxO is permanently unspendable |
| `cliff_time` | `Int` | POSIX ms — no claims before this | Should be in the future |
| `vesting_end_time` | `Int` | POSIX ms — full vesting at or after this | Should be > cliff_time |

## Redeemer Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `beneficiary_index` | `Int` | Index into `tx.outputs` for beneficiary payment |
| `continuation_index` | `Int` | Index into `tx.outputs` for script continuation |

## Configuration Decisions

- **Cliff duration:** Typical: 3-12 months. Set to 0 for immediate linear vesting.
- **Vesting duration:** Typical: 1-4 years. Shorter = faster access.
- **Locked amount:** Should match `total_vesting_amount`. If more ADA is locked, excess requires a separate claim after full vesting.
- **Validity range:** Set a tight lower bound when claiming. The lower bound determines how much is vested — a wider range means less precision.

## Degenerate Cases

- `total_vesting_amount <= 0` → UTxO permanently unspendable
- `vesting_end_time <= cliff_time` → Full vesting occurs immediately at cliff
- `vesting_end_time == cliff_time` → Same as above (instant vesting at cliff)

# Integration Points — Vesting (Compliant)

## Off-Chain Components Needed

1. **Transaction builder:** Any Cardano-compatible TX builder (PyCardano, Lucid, cardano-cli, mesh).
2. **UTxO query:** Find the vesting UTxO at the script address, parse datum for schedule details.
3. **Time service:** Convert wall-clock time to POSIX ms for computing claimable amounts off-chain.
4. **Output index management:** The redeemer requires exact output indices — your TX builder must track these.

## API Integration

### Query Vesting Schedule
```
GET /utxos?address=<script_address>
→ Parse datum to extract: beneficiary, total_vesting_amount, cliff_time, vesting_end_time
→ Compute current vested amount off-chain for display
```

### Submit Partial Claim
```
POST /tx/submit
→ Input: vesting UTxO
→ Redeemer: Claim { beneficiary_index, continuation_index }
→ Output[beneficiary_index]: beneficiary PKH with ≥ claimable lovelace
→ Output[continuation_index]: script address with ≥ remaining lovelace + same datum
→ Validity range: tight lower bound at desired claim time
→ Signatories: beneficiary
```

### Submit Full Claim
```
POST /tx/submit
→ Same as partial, but no continuation output needed after vesting_end_time
```

## Multi-Party Workflow

```
Funder                     Beneficiary
  │                            │
  ├── Lock ADA at script       │
  │   (with VestingDatum)      │
  │                            │
  │                      ◄─────┤  Partial claim (between cliff and end)
  │                            │  → Continuation UTxO holds remainder
  │                            │
  │                      ◄─────┤  Full claim (after vesting_end)
  │                            │  → All remaining funds released
```

## Monitoring

- **New UTxO at script address** → vesting position created
- **UTxO consumed + new script UTxO created** → partial claim executed
- **UTxO consumed, no script UTxO created** → full claim (vesting complete)

# Common Modifications — Vesting (Compliant)

> **Note:** This is the audit-passed version. Any modifications will require re-auditing the changed code.

## 1. Add Cancellation/Revocation

Allow the funder to revoke unvested tokens:

```aiken
pub type VestingRedeemer {
  Claim { beneficiary_index: Int, continuation_index: Int }
  Revoke  // funder cancels remaining vesting
}
```

Add a `funder` field to the datum and require their signature for Revoke. Unvested amount returns to funder; vested amount goes to beneficiary.

## 2. Add Multi-Token Vesting

Support native tokens alongside ADA:

- Track `total_vesting_value` as a `Value` instead of just lovelace
- Use `quantity_of` for each asset in the value
- Proportional calculation applies to each asset independently

## 3. Add Cliff Amount (Step Vesting)

Release a fixed percentage at the cliff, then linear for the remainder:

```aiken
pub type VestingDatum {
  beneficiary: VerificationKeyHash,
  total_vesting_amount: Int,
  cliff_time: Int,
  cliff_amount: Int,  // released immediately at cliff
  vesting_end_time: Int,
}
```

## 4. Add Multiple Milestones

Replace linear vesting with milestone-based releases:

```aiken
pub type Milestone {
  time: Int,
  cumulative_amount: Int,
}
```

The validator checks which milestones have passed and sums accordingly.

## 5. Allow Batched Claims

Remove the `script_input_count == 1` constraint to allow batching. Replace with output-index pinning per input (more complex but higher throughput). Requires careful anti-double-satisfaction design.

## 6. Add Beneficiary Transfer

Allow the beneficiary to transfer their vesting position:

```aiken
Transfer { new_beneficiary: VerificationKeyHash } -> {
  // Require current beneficiary signature
  // Create continuation with new_beneficiary in datum
}
```

# Gotchas and Edge Cases — Vesting (Compliant)

## Critical

### Single-Script-Input Constraint
The validator enforces `script_input_count == 1`. You **cannot** batch multiple vesting claims in a single transaction. Each claim requires its own transaction.

### Degenerate Datums Create Unspendable UTxOs
If `total_vesting_amount <= 0`, the `claimable` will be ≤ 0 and the `beneficiary_paid` check fails (requires `claimable > 0`). The UTxO becomes permanently locked. Validate datums off-chain before creating.

## Important

### Lower-Bound Timing
The vested amount is computed from the **lower bound** of the validity range. This is conservative — the beneficiary always gets at most what's vested at the earliest possible execution time. Set a tight lower bound for maximum claim precision.

### No Finite Lower Bound = Transaction Fails
The validator calls `get_lower_bound` which expects `Finite(t)`. If no lower bound is set on the validity range, the transaction aborts. Always set an explicit lower bound.

### Integer Truncation
Linear interpolation uses integer division, which truncates (rounds down). This slightly favors the contract (beneficiary gets marginally less). The difference is negligible for most schedules.

### Datum Must Be Identical on Continuation
The continuation UTxO must carry an **identical** datum (all four fields match). If any field differs — even by 1ms — the transaction fails. Do not attempt to "update" the vesting schedule via continuation.

## Edge Cases

### Instant Vesting at Cliff
If `vesting_end_time <= cliff_time`, the full amount vests immediately at `cliff_time`. The `elapsed / duration` formula would divide by zero, but the `if current_time >= d.vesting_end_time` branch catches this first.

### Locked Amount > total_vesting_amount
The `claimable` is clamped to `min(vested_amount, locked_lovelace)`. If you lock more ADA than `total_vesting_amount`, the excess remains at the script address after the full vesting period. You'll need a final claim transaction where the full amount is vested.

### Locked Amount < total_vesting_amount
The vested amount may exceed what's actually locked. The clamping handles this safely — beneficiary can only claim what's there.

### Output Index Collision
`beneficiary_index` and `continuation_index` must be different integers. If they match, the validator rejects the transaction. The off-chain builder must place these at distinct output positions.

### Slot-to-POSIX Drift
If chain parameters change (slot length), vesting schedules created before the change may drift. This is a known limitation of all time-based Cardano contracts.
