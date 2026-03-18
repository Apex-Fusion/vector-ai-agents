# Simple Escrow — Deployment Validation

**Date:** 2026-03-18
**Aiken version:** v1.1.21

---

## Build Result

```
aiken check: 24 checks, 0 errors, 2 warnings
  - 17 behavioral tests: PASS
  - 7 exploit tests: PASS (proving vulnerabilities in original logic)
```

Warnings are cosmetic (unused imports in test files).

## Project Structure

```
build/
├── aiken.toml
├── aiken.lock
├── build/packages/         ← stdlib v3.0.0
├── lib/
│   ├── escrow_types.ak     ← type definitions
│   ├── simple_escrow_behavioral_test.ak
│   └── simple_escrow_exploit_test.ak
└── validators/
    └── simple_escrow.ak    ← compliant contract
```

## Fix Verification

The `script_input_count == 1` guard compiles correctly and is placed before the Claim/Reclaim branch, applying to both paths.

## Testnet Status

### Original contract (deployed)
- Script hash: `08552ae681df66d78116cb4e44b1b2d964ddac34368d6d36ff4cabfa`
- Script address: `addr1wyy922hxs80kd4upzm95u393ktvkfhdvxsmg6mfklax2h7sglxqqe`
- Live UTxOs: 2 (10 AP3X + 5 AP3X)

### Compliant contract
- Needs `aiken build` to generate new `plutus.json` with updated script hash
- Script hash will differ from original (validation logic changed)
- Not yet deployed to testnet

## Verdict

**Build passes.** Ready for final red team testing on testnet (against the original contract to prove the exploit), then deployment of the compliant version.
