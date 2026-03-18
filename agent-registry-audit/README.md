# Agent Registry — Security Audit

Full security audit of the Vector Agent Registry, an Aiken multi-validator implementing soulbound NFT identity for AI agents on the Cardano/Vector chain.

## Overview

The Agent Registry contract allows AI agents to:
- **Register** with a unique soulbound NFT identity and on-chain profile
- **Update** their profile while preserving identity
- **Deregister** by burning the NFT and reclaiming the deposit

The audit found **11 findings** (2 Critical, 2 High, 3 Medium, 3 Low, 1 Info), all resolved in the compliant version. Red team validation confirmed no bypasses exist.

**Final verdict: Cleared for mainnet deployment.**

## Structure

```
agent-registry-audit/
├── README.md                          ← this file
├── original/
│   └── agent-registry/
│       ├── registry.ak                ← original multi-validator entry point
│       ├── types.ak                   ← on-chain type definitions
│       ├── validation.ak              ← original validation logic (pre-audit)
│       └── README.md                  ← contract function description
├── compliant/
│   └── agent-registry/
│       ├── registry.ak                ← compliant multi-validator entry point
│       ├── types.ak                   ← on-chain type definitions
│       ├── validation.ak              ← compliant validation logic (all fixes applied)
│       ├── README.md                  ← contract function description (compliant)
│       ├── AGENT-NOTES.md             ← deployment, parameters, integration, gotchas
│       ├── reports/
│       │   ├── audit-report.md        ← consolidated security audit report
│       │   └── test-report.md         ← consolidated test report
│       └── tests/
│           ├── agent_registry_test.ak      ← 44 unit tests (exploit + happy path)
│           ├── agent_registry_prop_test.ak ← 15 property-based tests
│           └── agent_registry_fuzz_test.ak ← 12 fuzz tests
```

## Key Files

| File | Description |
|------|-------------|
| `original/agent-registry/validation.ak` | Pre-audit contract — contains all 11 vulnerabilities |
| `compliant/agent-registry/validation.ak` | Post-audit contract — all findings addressed with `AR-XX` annotations |
| `compliant/agent-registry/reports/audit-report.md` | Full audit report with findings, reproductions, and resolutions |
| `compliant/agent-registry/AGENT-NOTES.md` | Practical deployment and integration guidance |

## Audit Highlights

| ID | Finding | Severity | Fix |
|----|---------|----------|-----|
| AR-01 | Double satisfaction on Update | Critical | Single script input enforcement |
| AR-03 | Burn has no authorization check | Critical | Independent owner signature required |
| AR-02 | Double satisfaction on Register | High | Explicit single-output enforcement |
| AR-04 | Datum hijacking on Update | High | Type validation + immutable `registered_at` |
| AR-09 | Value draining on Update | Medium | Input value preservation |

See the [full audit report](compliant/agent-registry/reports/audit-report.md) for all 11 findings and 3 red team findings.

## Technology

- **Language:** Aiken v1.1.21
- **Target:** Plutus V3
- **Standard Library:** Aiken stdlib v3.0.0
- **Test Framework:** Aiken `test` blocks
