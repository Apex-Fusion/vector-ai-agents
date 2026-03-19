# Agent Registry — Security Audit v2

**Date:** 2026-03-18
**Methodology:** v2 — Enhanced workflow with behavioral/exploit test split, baked-in drift detection, and delta code review

## Folder Structure

```
agent-registry-audit-v2/
├── original/                        ← Verbatim, untouched copy of external submission
│   ├── lib/agent_registry/          ← Original Aiken contracts
│   ├── validators/                  ← Original multi-validator wrapper
│   ├── docs/                        ← DESIGN.md + TESTS.md (intent documentation)
│   ├── python/                      ← Off-chain SDK + original tests
│   ├── aiken.toml                   ← Original project config
│   └── plutus.json                  ← Original compiled blueprint
├── build/                           ← Toolchain-specific build environment
│   ├── lib/agent_registry/          ← Fixed contracts + tests (Aiken layout)
│   ├── validators/                  ← Fixed multi-validator wrapper
│   ├── aiken.toml                   ← Project config
│   └── build/                       ← Stdlib dependencies
├── compliant/                       ← Standardized audit output
│   ├── contracts/                   ← Fixed contract sources (flat, readable)
│   │   ├── types.ak
│   │   ├── validation.ak
│   │   └── registry.ak
│   ├── tests/
│   │   ├── behavioral/             ← Functional tests (must pass on compliant)
│   │   └── exploit/                ← Exploit tests (must fail on compliant)
│   └── reports/
│       ├── audit-report.md         ← Final security audit report
│       ├── code-review.md          ← Cold read code review
│       ├── delta-review.md         ← Review of security fixes
│       ├── red-team-report.md      ← Early adversarial analysis
│       ├── final-red-team-report.md ← Final adversarial analysis
│       ├── test-report.md          ← Test results
│       ├── context.md              ← Research context and risk surface
│       ├── deployment-validation.md ← Build verification
│       ├── fix-notes.md            ← Security fix documentation
│       └── comparison-report.md    ← v1 vs v2 methodology comparison
└── README.md
```

## Separation of Concerns

- **`original/`** — Chain of custody. Never modified. Whatever format the external submission uses.
- **`build/`** — Toolchain-specific. Run `aiken check` here to verify. Disposable — can be regenerated.
- **`compliant/`** — Standardized output. Same structure regardless of source language. This is what gets published.

## Build Verification

```bash
cd build
aiken check
# Expected: 26 checks, 14 behavioral PASS, 9 exploit FAIL (blocked), 3 exploit PASS (expected), 0 warnings
```

## Key Results

- **7 security fixes** applied (2 Critical, 3 High, 2 Medium)
- **14/14 behavioral tests pass** — functionality fully preserved
- **9/12 exploit tests now blocked** — vulnerabilities patched
- **0 new Critical/High/Medium vulnerabilities** in final red team pass
- **Residual risk: Low** — ready for deployment
