# aiken-fuzzer

A reusable fuzzing tool for Aiken smart contracts on Cardano/Vector.

Generates random and edge-case redeemer/datum inputs from a compiled Plutus
blueprint (`plutus.json`), analyzes structural validity, and reports any
unexpected behavior that may indicate vulnerabilities.

**Built by the test engineering team** (UTxO QA Engineer) as part of the Apex Security Audit.

---

## Quick Start

```bash
# List all validators in a contract
python fuzzer.py --contract /path/to/contracts --list-validators

# Fuzz the default (.spend) validator — 100 random cases
python fuzzer.py --contract /path/to/contracts

# Fuzz a specific validator, 500 cases, reproducible seed
python fuzzer.py --contract /path/to/contracts \
    --validator "simple_escrow.simple_escrow.spend" \
    --cases 500 --seed 42

# Show the type schema (useful before writing domain cases)
python fuzzer.py --contract /path/to/contracts --describe-schema

# Verbose output with custom output directory
python fuzzer.py --contract /path/to/contracts \
    --output ./my-fuzz-results --verbose
```

Output goes to `{contract_dir}/fuzz-output/` by default:
- `fuzz-report.md` — full markdown report
- `fuzz-cases.json` — all case inputs and results
- `fuzz_unexpected_scaffold.ak` — Aiken test stubs for unexpected cases

---

## What It Does

### 1. Parses the Blueprint

Reads `plutus.json` produced by `aiken build` and extracts the full
datum/redeemer type schema for each validator:

```
EscrowRedeemer (variants=2)
  [0] Claim
    .secret:
      ByteArray
  [1] Reclaim
```

### 2. Generates Random and Edge-Case Inputs

For each Aiken type, it generates:

| Type | Edge Cases |
|------|-----------|
| `Int` | 0, 1, -1, max_int64, min_int64, max_lovelace, POSIX timestamps |
| `ByteArray` | empty, 1 byte, 27 bytes, 28 bytes (key hash), 32 bytes (hash), all-zeros, all-0xFF |
| `List` | empty, single item, 2 items, 100 items, duplicates |
| `Constructor` | every valid variant, invalid variant index, wrong field types |

Plus N random cases for each type.

### 3. Analyzes Validity

For each generated input, the fuzzer determines:
- **Structurally valid**: right constructor index, right field count, right types
- **Structurally invalid**: wrong index, missing fields, wrong types

Structural invalidity = expected `fail`. If a structurally invalid input
somehow *passes* on-chain, that's a potential vulnerability.

### 4. Runs Existing Tests

Runs `aiken check` against the contract to confirm the existing test suite
still passes. A regression here is a red flag.

### 5. Reports Results

Generates a markdown report with:
- Summary table (pass/fail counts)
- All unexpected results flagged
- Vulnerability section (invalid inputs that passed)
- Recommendations

---

## Requirements

- Python 3.9+
- `aiken` in PATH (v1.1.21 or later)
- A compiled Aiken contract with `plutus.json`

No extra Python packages needed — uses only stdlib.

---

## File Structure

```
tools/aiken-fuzzer/
├── README.md          — this file
├── fuzzer.py          — main CLI entry point
├── generators.py      — type-specific value generators
├── aiken_types.py     — blueprint parser / type model
├── report.py          — markdown report generator
└── examples/
    ├── simple_escrow_fuzz.py   — escrow-specific fuzz config
    └── vesting_fuzz.py         — vesting-specific fuzz config (with double-sat demo)
```

---

## Understanding the Output

### fuzz-report.md

```markdown
# Aiken Fuzzer Report

**Validator:** simple_escrow.simple_escrow.spend
**Seed:** 42
**Cases:** 100

## Summary
| Metric | Value |
|--------|-------|
| Total cases | 100 |
| Passed (expected ✓) | 63 |
| Failed (expected ✗) | 35 |
| Unexpected results | 2 |
| Potential vulnerabilities | 0 |

Overall status: ✅ CLEAN
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Clean — no vulnerabilities detected |
| `2` | Potential vulnerabilities found — review report |

This makes it suitable for CI pipelines:
```bash
python fuzzer.py --contract ./contracts --cases 200
if [ $? -eq 2 ]; then
    echo "Fuzzer found potential issues!"
    cat contracts/fuzz-output/fuzz-report.md
fi
```

---

## Programmatic API

```python
from fuzzer import parse_blueprint, run_fuzz_session
from generators import ValueGenerator, to_json_value
from aiken_types import BlueprintParser

# Parse blueprint
parser = BlueprintParser.from_file("plutus.json")
info = parser.get_validator("simple_escrow.simple_escrow.spend")
redeemer_type = info["redeemer_type"]

# Generate values
gen = ValueGenerator(seed=42)
random_redeemer = gen.generate(redeemer_type)
edge_cases = gen.generate_edge_cases(redeemer_type)

# Serialize to JSON-compatible form
print(to_json_value(random_redeemer))
# → {"constructor": 0, "fields": [{"bytes": "aabb..."}]}

# Full fuzz session
result = run_fuzz_session(
    contract_dir="/path/to/contracts",
    num_cases=200,
    seed=42,
    validator_title="simple_escrow.simple_escrow.spend",
    output_dir="./results",
    verbose=True,
)
print(f"Vulnerabilities: {len(result.vulnerabilities)}")
```

---

## Limitations

This fuzzer performs **structural** analysis. It checks:
- Correct constructor index (valid variant)
- Correct field count and types
- Boundary values that often trigger edge cases

It does **NOT** check:
- Business logic (e.g., "deadline must be in the future")
- Multi-UTxO interactions (double-satisfaction requires transaction context)
- Cryptographic validity (hash preimages, signatures)

For full coverage, combine with:
1. **Aiken property tests** — `test foo(x via fuzz.int())` inside Aiken
2. **Attack-scenario tests** — explicit double-satisfaction, wrong-signer cases
3. **PyCardano integration tests** — real transaction construction + emulator

See `research/smart-contract-testing-guide.md` for the complete methodology.

---

## Example: Domain-Specific Cases

The examples show how to write contract-specific invalid cases beyond
what the schema can tell us:

```python
# vesting: same output index = double-satisfaction risk
REDEEMER_INVALID_CASES = [
    {
        "label": "Same index for beneficiary and continuation",
        "description": "beneficiary_index == continuation_index is the double-sat pattern",
        "redeemer": {"constructor": 0, "fields": [{"int": 0}, {"int": 0}]},
        "expected": "fail",
        "security_note": "This is exactly the audit-found vulnerability pattern!",
    },
    # ...
]
```

Run the examples directly:
```bash
cd tools/aiken-fuzzer
python examples/vesting_fuzz.py
python examples/simple_escrow_fuzz.py
```

---

## Adapting to a New Contract

1. Build your contract: `aiken build` → produces `plutus.json`
2. List validators: `python fuzzer.py --contract ./mycontract --list-validators`
3. Inspect schema: `python fuzzer.py --contract ./mycontract --describe-schema`
4. Run basic fuzz: `python fuzzer.py --contract ./mycontract --cases 200 --seed 42`
5. Create domain cases: copy `examples/simple_escrow_fuzz.py` and customize

---

*aiken-fuzzer v0.1.0 — Part of the Apex Security Audit toolchain*
*Apex project: `./`*
