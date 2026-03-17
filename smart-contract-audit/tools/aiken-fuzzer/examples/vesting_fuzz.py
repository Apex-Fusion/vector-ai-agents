#!/usr/bin/env python3
"""
examples/vesting_fuzz.py

Example fuzz configuration for the vesting contract.
Shows how to test a contract with more complex datum/redeemer types
and domain-specific invariants (time-based logic, output index pinning).

Run:
    cd tools/aiken-fuzzer
    python examples/vesting_fuzz.py

Or use the CLI:
    python fuzzer.py --contract ../../contracts \
        --validator "vesting.vesting.spend" \
        --cases 200 --seed 1337 --verbose

Key vesting invariants to fuzz:
  - Output index pinning: beneficiary_index and continuation_index
    must be valid (≥0) and different from each other
  - Double-satisfaction: two vesting UTxOs claiming the same output index
    is the critical bug found during audit
  - Datum: total_vesting_amount must be > 0; cliff_time < vesting_end_time
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from fuzzer import parse_blueprint, run_fuzz_session, find_blueprint
from generators import ValueGenerator, to_json_value, IntGenerator
from aiken_types import (
    BlueprintParser, SumType, IntType, ConstructorVariant,
    ConstructorField, describe_type
)
from report import FuzzCase, FuzzSessionResult, ReportGenerator
import json
import random

# ---------------------------------------------------------------------------
# Contract location
# ---------------------------------------------------------------------------

CONTRACTS_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "contracts")
)
VALIDATOR = "vesting.vesting.spend"

# ---------------------------------------------------------------------------
# VestingRedeemer schema (from plutus.json):
#
#   VestingRedeemer:
#     [0] Claim {
#           beneficiary_index: Int,
#           continuation_index: Int
#         }
#
# VestingDatum schema:
#   VestingDatum {
#     beneficiary: VerificationKeyHash (ByteArray, 28 bytes)
#     total_vesting_amount: Int  (MUST be > 0)
#     cliff_time: Int            (POSIX ms)
#     vesting_end_time: Int      (POSIX ms, should be >= cliff_time)
#   }
#
# Vulnerability from audit:
#   Double-satisfaction — beneficiary_index and continuation_index are
#   checked globally across all outputs. Two vesting UTxOs can share
#   output indices if not properly pinned.
# ---------------------------------------------------------------------------

# Domain constants
POSIX_2025 = 1_742_000_000_000
POSIX_2026 = 1_773_536_000_000
ONE_YEAR_MS = 365 * 24 * 60 * 60 * 1000

# ---------------------------------------------------------------------------
# Redeemer fuzz cases
# ---------------------------------------------------------------------------

REDEEMER_INVALID_CASES = [
    {
        "label": "Invalid constructor index 1",
        "description": "VestingRedeemer only has constructor 0 (Claim). Index 1 invalid.",
        "redeemer": {"constructor": 1, "fields": []},
        "expected": "fail",
    },
    {
        "label": "Claim with negative beneficiary_index",
        "description": "Output indices must be non-negative. Negative index is invalid.",
        "redeemer": {"constructor": 0, "fields": [{"int": -1}, {"int": 0}]},
        "expected": "fail",
    },
    {
        "label": "Claim with negative continuation_index",
        "description": "Continuation index must be non-negative.",
        "redeemer": {"constructor": 0, "fields": [{"int": 0}, {"int": -1}]},
        "expected": "fail",
    },
    {
        "label": "Claim with max int indices",
        "description": "Max int64 as output index — will never match any real output",
        "redeemer": {"constructor": 0, "fields": [{"int": 2**63 - 1}, {"int": 2**63 - 2}]},
        "expected": "fail",
    },
    {
        "label": "Claim with same index for both fields",
        "description": "beneficiary_index == continuation_index — double-satisfaction concern",
        "redeemer": {"constructor": 0, "fields": [{"int": 0}, {"int": 0}]},
        "expected": "fail",  # Good contracts should reject this
        "security_note": "Same index for both outputs is the double-satisfaction pattern!",
    },
    {
        "label": "Claim with missing fields",
        "description": "Claim requires 2 fields; providing 0 is structurally invalid",
        "redeemer": {"constructor": 0, "fields": []},
        "expected": "fail",
    },
    {
        "label": "Claim with extra fields",
        "description": "Too many fields — should be rejected",
        "redeemer": {"constructor": 0, "fields": [{"int": 0}, {"int": 1}, {"int": 2}]},
        "expected": "fail",
    },
    {
        "label": "Null redeemer",
        "description": "Completely absent redeemer",
        "redeemer": None,
        "expected": "fail",
    },
]

REDEEMER_VALID_CASES = [
    {
        "label": "Claim with output indices 0 and 1",
        "description": "Typical case: beneficiary at output 0, continuation at output 1",
        "redeemer": {"constructor": 0, "fields": [{"int": 0}, {"int": 1}]},
        "expected": "pass",
    },
    {
        "label": "Claim with output indices 1 and 0",
        "description": "Reversed order: continuation at 0, beneficiary at 1",
        "redeemer": {"constructor": 0, "fields": [{"int": 1}, {"int": 0}]},
        "expected": "pass",
    },
    {
        "label": "Claim with large output indices",
        "description": "Large but valid indices (in a large transaction)",
        "redeemer": {"constructor": 0, "fields": [{"int": 50}, {"int": 51}]},
        "expected": "pass",
    },
]

# ---------------------------------------------------------------------------
# Datum fuzz cases (for validator calls that take a datum)
# ---------------------------------------------------------------------------

DATUM_INVALID_CASES = [
    {
        "label": "Zero total_vesting_amount",
        "description": "Per spec: 'MUST be > 0'. Zero creates permanently unspendable UTxO.",
        "datum_field": "total_vesting_amount",
        "value": 0,
        "security_note": "Bug class: locking funds permanently (griefing / fund loss)",
    },
    {
        "label": "Negative total_vesting_amount",
        "description": "Negative amount — contract behavior undefined",
        "datum_field": "total_vesting_amount",
        "value": -1_000_000,
    },
    {
        "label": "vesting_end_time < cliff_time",
        "description": "End before start — immediate full vesting, no linear schedule",
        "datum_field": "vesting_end_time",
        "value": POSIX_2025 - ONE_YEAR_MS,  # end before cliff
    },
    {
        "label": "cliff_time = vesting_end_time",
        "description": "Zero-duration vesting: full amount available at cliff",
        "datum_field": "cliff_time",
        "value": POSIX_2026,  # same as end time
    },
    {
        "label": "Short beneficiary key hash (27 bytes)",
        "description": "Key hashes must be exactly 28 bytes",
        "datum_field": "beneficiary",
        "value": "aa" * 27,  # 27 bytes
    },
]


# ---------------------------------------------------------------------------
# Double-satisfaction simulation
# ---------------------------------------------------------------------------

def demonstrate_double_satisfaction():
    """
    Show the double-satisfaction attack pattern for vesting.

    Two UTxOs with vesting Claim redeemers, both pointing to the same
    beneficiary output. A well-written contract MUST prevent this.
    """
    print("\n" + "=" * 60)
    print("Double-Satisfaction Attack Pattern Demo")
    print("=" * 60)
    print("""
The audit found that vesting had a double-satisfaction vulnerability
where two UTxO spends could reference the same output indices.

Attack scenario:
  TX inputs:
    - Vesting UTxO #1 (value: 100 ADA)
      Redeemer: Claim { beneficiary_index: 0, continuation_index: 1 }
    - Vesting UTxO #2 (value: 200 ADA)  ← attacker controls this
      Redeemer: Claim { beneficiary_index: 0, continuation_index: 1 }  ← SAME indices!

  TX outputs:
    [0] Beneficiary: 200 ADA  ← Only pays for the larger one
    [1] Continuation: 100 ADA ← Continuation from UTxO #1

  Before fix: both validators check output[0] independently.
              Each sees a valid payment to beneficiary. BOTH PASS.
              Attacker steals 100 ADA (difference between UTxOs).

  After fix: each validator checks that ITS OWN input value is covered
             by output[beneficiary_index], preventing sharing.
""")
    print("Fuzzer redeemers that test this:")
    print()

    cases = [
        ("UTxO #1 redeemer", {"constructor": 0, "fields": [{"int": 0}, {"int": 1}]}),
        ("UTxO #2 redeemer (same indices!)", {"constructor": 0, "fields": [{"int": 0}, {"int": 1}]}),
    ]
    for label, r in cases:
        print(f"  {label}:")
        print(f"    {json.dumps(r)}")
    print()
    print("Note: Testing multi-UTxO interactions requires a full transaction context.")
    print("Use PyCardano + emulator or on-chain tests for full double-sat coverage.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("=" * 60)
    print("vesting Contract Fuzz Example")
    print("=" * 60)
    print()

    # Load blueprint
    try:
        blueprint_path = find_blueprint(CONTRACTS_DIR)
        parser = parse_blueprint(blueprint_path)
        info = parser.get_validator(VALIDATOR)
        redeemer_type = info["redeemer_type"]
        datum_type = info["datum_type"]

        print(f"Blueprint: {blueprint_path}")
        print("\nVestingRedeemer schema:")
        print(describe_type(redeemer_type, 1))
        print("\nVestingDatum schema:")
        print(describe_type(datum_type, 1))

    except (FileNotFoundError, KeyError) as e:
        print(f"Note: {e}")
        print("Running in demo mode...")
        redeemer_type = None

    print("\n" + "-" * 40)
    print("Redeemer invalid cases:")
    print("-" * 40)
    for case in REDEEMER_INVALID_CASES:
        note = case.get("security_note", "")
        sec = " 🚨 SECURITY" if note else ""
        print(f"\n  [EXPECT FAIL{sec}] {case['label']}")
        print(f"  {case['description']}")
        if note:
            print(f"  ⚠️  {note}")

    print("\n" + "-" * 40)
    print("Datum edge cases:")
    print("-" * 40)
    for case in DATUM_INVALID_CASES:
        print(f"\n  [DATUM] {case['label']}")
        print(f"  {case['description']}")
        if "security_note" in case:
            print(f"  ⚠️  {case['security_note']}")

    demonstrate_double_satisfaction()

    print("\n" + "=" * 60)
    print("Running fuzz session (50 cases, seed=1337)...")
    print("=" * 60)

    result = run_fuzz_session(
        contract_dir=CONTRACTS_DIR,
        num_cases=50,
        seed=1337,
        validator_title=VALIDATOR,
        output_dir="./fuzz-output-vesting",
        verbose=True,
    )

    gen = ReportGenerator()
    print()
    print(gen.generate(result))


if __name__ == "__main__":
    main()
