# Agent Notes — Vesting

# Deployment Guide — Vesting

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

# Parameters — Vesting

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

# Integration Points — Vesting

## Off-Chain Components Needed

1. **Time service:** Convert wall-clock time to POSIX milliseconds. Account for slot length and chain parameters.
2. **Transaction builder:** Must support inline datums and script spending.
3. **UTxO query:** Find vesting UTxOs by script address + datum (beneficiary PKH).
4. **Vesting calculator:** Replicate the on-chain math off-chain to show users their claimable balance.

## Vesting Calculator (Off-Chain)

```python
def compute_claimable(total, cliff, end, current_time, locked):
    if current_time < cliff:
        return 0
    if current_time >= end:
        vested = total
    else:
        elapsed = current_time - cliff
        duration = end - cliff
        vested = total * elapsed // duration  # integer division, matches on-chain
    return min(vested, locked)
```

## Multi-Beneficiary Workflow

Each beneficiary gets their own UTxO at the script address. To vest for N people:

```
Funder → N transactions → N UTxOs at script address
Each UTxO has its own VestingDatum with different beneficiary
```

## Dashboard Integration

Monitor the script address and compute:
- Total locked across all vesting UTxOs
- Per-beneficiary claimable amount (based on current time)
- Claimed vs remaining per beneficiary
- Next significant vesting event (cliff, 25%, 50%, 75%, full)

## Event Hooks

- **Cliff reached:** Alert beneficiary they can start claiming
- **Claim transaction:** Log the amount claimed and update dashboard
- **Full vesting:** Alert that all funds are now claimable

# Common Modifications — Vesting

## 1. Add Cancellation/Revocation

The template has no cancellation path. To add one:

```aiken
pub type VestingRedeemer {
  Claim { beneficiary_index: Int, continuation_index: Int }
  Revoke  // new: sender can revoke unvested portion
}
```

In the validator:
- Add a `sender` field to the datum
- For `Revoke`: require sender signature, return only the **unvested** portion to sender, and pay the **vested** portion to beneficiary

## 2. Multi-Asset Vesting

To vest native tokens proportionally alongside ADA:

- Track each asset separately in the datum
- Compute vested amount per asset using the same time-based formula
- Verify continuation UTxO holds the correct remaining amount of each asset

## 3. Milestone-Based Vesting

Replace linear interpolation with discrete milestones:

```aiken
pub type VestingDatum {
  beneficiary: VerificationKeyHash,
  milestones: List<(Int, Int)>,  // (time, cumulative_amount)
}
```

Find the latest milestone before `current_time` and use its cumulative amount.

## 4. Batched Claims (Advanced)

The current contract enforces `script_input_count == 1`. To allow batching:

- Use NFT thread tokens instead of single-input enforcement
- Each vesting UTxO gets a unique NFT minted at creation
- The redeemer references the NFT to identify "its" output
- This allows multiple vesting claims in one transaction

⚠️ This is significantly more complex. Only do this if batch efficiency is critical.

## 5. Admin Override

Add an admin who can modify the schedule or redirect funds:

- Add `admin: VerificationKeyHash` to datum
- Add `AdminOverride { new_beneficiary }` redeemer variant
- Require admin signature
- Be careful: this introduces centralization risk

# Gotchas and Edge Cases — Vesting

## Critical

### No Batched Claims
The `script_input_count == 1` constraint means each claim requires its own transaction. If a beneficiary has multiple vesting UTxOs (e.g., from different funders), each must be claimed separately. This is a deliberate security trade-off.

### Degenerate Datums Are Permanent
If `total_vesting_amount <= 0`, the UTxO is permanently unspendable. There is no recovery mechanism. **Always validate datums off-chain before creating the UTxO.**

### No Cancellation
Once funds are locked, only the beneficiary can ever claim them. There is no sender reclaim or admin override. Plan accordingly.

## Important

### Validity Range Matters
The vested amount is computed from the **lower bound** of the validity range. A wider range means a lower (earlier) lower bound, which means less claimable. Set a tight validity range (e.g., 5-10 minutes) for optimal claims.

### Integer Truncation
Vested amounts round down (integer division). At 1/3 of the vesting period, a 100 ADA vesting gives 33.333... → 33 ADA claimable. The last fraction is claimable only after full vesting. This is by design (conservative, favors the contract).

### Min-UTxO on Continuation
When making a partial claim, the continuation UTxO must hold at least Cardano's minimum UTxO value (~1-2 ADA). If the remaining amount is below min-UTxO, the off-chain code must handle this (e.g., leave extra ADA or claim the full remaining amount).

### Excess Lovelace
If more ADA is locked than `total_vesting_amount`, the excess remains at the script after full vesting. The beneficiary needs a second transaction to claim it (because `must_remain` will be > 0 due to `locked - claimable`).

## Edge Cases

### Slot-to-POSIX Drift
If chain parameters change (slot length), vesting schedules created before the change may drift. This is a fundamental Cardano limitation, not specific to this contract.

### Concurrent Claims
Two transactions claiming from the same UTxO will conflict — one will fail (normal eUTxO contention). This is harmless: the losing transaction simply doesn't execute.

### Lower Bound Assumed Inclusive
The validator assumes the lower bound of the validity range is inclusive (standard for Cardano). If an exclusive lower bound were ever produced, the time is off by 1ms in the conservative direction.
