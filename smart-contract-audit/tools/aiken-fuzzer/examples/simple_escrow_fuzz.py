#!/usr/bin/env python3
"""
examples/simple_escrow_fuzz.py

Example fuzz configuration for the simple-escrow contract.
Shows how to use aiken-fuzzer programmatically with domain-specific
invalid cases tailored to escrow logic.

Run:
    cd tools/aiken-fuzzer
    python examples/simple_escrow_fuzz.py

Or use the CLI:
    python fuzzer.py --contract ../../contracts \
        --validator "simple_escrow.simple_escrow.spend" \
        --cases 200 --seed 42 --verbose
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from fuzzer import parse_blueprint, run_fuzz_session, find_blueprint
from generators import ValueGenerator, to_json_value
from aiken_types import BlueprintParser, SumType, BytesType
from report import FuzzCase, FuzzSessionResult, ReportGenerator
import json

# ---------------------------------------------------------------------------
# Contract location (relative to this file)
# ---------------------------------------------------------------------------

CONTRACTS_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "contracts")
)
VALIDATOR = "simple_escrow.simple_escrow.spend"

# ---------------------------------------------------------------------------
# Domain-specific invalid inputs for simple-escrow
#
# EscrowRedeemer has two variants:
#   [0] Claim  { secret: ByteArray }  — beneficiary reveals preimage
#   [1] Reclaim {}                    — sender reclaims after deadline
#
# Attack cases to test:
#   - Empty secret (hash mismatch guaranteed)
#   - Wrong-length secret hash in datum
#   - Invalid constructor index (3rd variant doesn't exist)
#   - Claim with no fields (missing secret)
#   - Reclaim with extra fields (shouldn't matter but check it)
# ---------------------------------------------------------------------------

DOMAIN_INVALID_CASES = [
    {
        "label": "Claim with empty secret",
        "description": "Empty ByteArray will never match blake2b_256 hash of real secret",
        "redeemer": {"constructor": 0, "fields": [{"bytes": ""}]},
        "expected": "fail",
    },
    {
        "label": "Invalid constructor index 2",
        "description": "Only indices 0 (Claim) and 1 (Reclaim) are valid",
        "redeemer": {"constructor": 2, "fields": []},
        "expected": "fail",
    },
    {
        "label": "Invalid constructor index 99",
        "description": "Far-out-of-range constructor",
        "redeemer": {"constructor": 99, "fields": [{"int": 0}]},
        "expected": "fail",
    },
    {
        "label": "Claim with integer instead of ByteArray",
        "description": "Wrong field type — secret should be bytes not int",
        "redeemer": {"constructor": 0, "fields": [{"int": 42}]},
        "expected": "fail",
    },
    {
        "label": "Claim with too-short secret (27 bytes)",
        "description": "Blake2b-256 output is 32 bytes; 27-byte input creates mismatch",
        "redeemer": {"constructor": 0, "fields": [{"bytes": "aa" * 27}]},
        "expected": "fail",
    },
    {
        "label": "Claim with exactly 32 random bytes",
        "description": "Random 32-byte secret — almost certainly wrong hash",
        "redeemer": {"constructor": 0, "fields": [{"bytes": "deadbeef" * 8}]},
        "expected": "fail",
    },
    {
        "label": "Reclaim with extra fields",
        "description": "Reclaim() takes no fields; extras may or may not be ignored",
        "redeemer": {"constructor": 1, "fields": [{"bytes": "aa" * 28}]},
        "expected": "fail",  # Plutus constructors are positional; extra fields = type mismatch
    },
    {
        "label": "Null / empty redeemer",
        "description": "Completely empty redeemer",
        "redeemer": None,
        "expected": "fail",
    },
]

DOMAIN_VALID_CASES = [
    {
        "label": "Claim constructor (structural)",
        "description": "Structurally valid Claim — business logic validation happens on-chain",
        "redeemer": {"constructor": 0, "fields": [{"bytes": "aa" * 28}]},
        "expected": "pass",  # structurally valid; may fail business logic
    },
    {
        "label": "Reclaim constructor (structural)",
        "description": "Structurally valid Reclaim — no fields required",
        "redeemer": {"constructor": 1, "fields": []},
        "expected": "pass",
    },
]

# ---------------------------------------------------------------------------
# Run the example
# ---------------------------------------------------------------------------

def main():
    print("=" * 60)
    print("simple-escrow Fuzz Example")
    print("=" * 60)
    print()

    # 1. Load blueprint and show schema
    try:
        blueprint_path = find_blueprint(CONTRACTS_DIR)
    except FileNotFoundError as e:
        print(f"Blueprint not found: {e}")
        print(f"Expected contracts at: {CONTRACTS_DIR}")
        print("Running schema demo with hardcoded types instead...")
        _run_schema_demo()
        return

    parser = parse_blueprint(blueprint_path)

    print(f"Blueprint: {blueprint_path}")
    print(f"Validators: {parser.list_validators()}")
    print()

    try:
        info = parser.get_validator(VALIDATOR)
    except KeyError as e:
        print(f"Validator not found: {e}")
        _run_schema_demo()
        return

    from aiken_types import describe_type
    redeemer_type = info["redeemer_type"]
    print("EscrowRedeemer schema:")
    print(describe_type(redeemer_type, 1))
    print()

    # 2. Show domain-specific invalid cases
    print("-" * 40)
    print("Domain-specific invalid cases:")
    print("-" * 40)
    for case in DOMAIN_INVALID_CASES:
        label = case["label"]
        desc = case["description"]
        print(f"\n  [{case['expected'].upper()}] {label}")
        print(f"  {desc}")
        print(f"  Input: {json.dumps(case['redeemer'])[:80]}")

    print()
    print("-" * 40)
    print("Domain-specific valid cases:")
    print("-" * 40)
    for case in DOMAIN_VALID_CASES:
        print(f"\n  [{case['expected'].upper()}] {case['label']}")
        print(f"  {case['description']}")

    print()
    print("=" * 60)
    print("Running automated fuzz session (50 cases, seed=42)...")
    print("=" * 60)

    result = run_fuzz_session(
        contract_dir=CONTRACTS_DIR,
        num_cases=50,
        seed=42,
        validator_title=VALIDATOR,
        output_dir="./fuzz-output-escrow",
        verbose=True,
    )

    gen = ReportGenerator()
    report = gen.generate(result)
    print()
    print(report)


def _run_schema_demo():
    """Demo mode: show generated values without needing the blueprint."""
    print("Running in demo mode (no blueprint found)...")
    from aiken_types import SumType, ConstructorVariant, ConstructorField, BytesType

    # Manually reconstruct EscrowRedeemer type
    escrow_redeemer = SumType(
        title="EscrowRedeemer",
        variants=[
            ConstructorVariant(
                title="Claim",
                description="Beneficiary claims by revealing the secret",
                index=0,
                fields=[ConstructorField(title="secret", description="", field_type=BytesType())]
            ),
            ConstructorVariant(
                title="Reclaim",
                description="Sender reclaims after deadline",
                index=1,
                fields=[],
            ),
        ]
    )

    gen = ValueGenerator(seed=42)
    print("\n10 random EscrowRedeemer values:")
    for i in range(10):
        val = gen.generate(escrow_redeemer)
        print(f"  {i+1}: {json.dumps(to_json_value(val), default=str)}")

    print("\nEdge cases:")
    for val in gen.generate_edge_cases(escrow_redeemer):
        print(f"  {json.dumps(to_json_value(val), default=str)[:100]}")


if __name__ == "__main__":
    main()
