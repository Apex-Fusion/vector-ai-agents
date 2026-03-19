# Agent Registry — Security Audit

> **⚠️ DEMO — NOT FOR PRODUCTION USE.** This is a demonstration of AI-driven security audit methodology. Do not deploy to mainnet with real funds without independent third-party review.

**Date:** 2026-03-18 (audit), 2026-03-19 (testnet deployment)
**Methodology:** Apex v2 — cold read, behavioral/exploit test split, red team, on-chain verification
**Status:** ✅ Compliant — deployed and verified on Vector testnet

## Overview

The Vector Agent Registry is an Aiken multi-validator implementing soulbound NFT identity for AI agents on the Cardano/Vector chain. Agents can register (mint identity NFT), update their profile, and deregister (burn NFT).

The audit found **11 findings** (2 Critical, 2 High, 3 Medium, 3 Low, 1 Info), all resolved in the compliant version. Red team validation confirmed no bypasses — both on code level (24 attack vectors) and on live Vector testnet (AR-01 double satisfaction blocked, AR-03 unauthorized burn blocked).

## Folder Structure

```
agent-registry/
├── original/                              ← Untouched source as received
│   ├── contracts/agent-registry/          ← Aiken project (validators, lib, plutus.json)
│   ├── docs/                              ← DESIGN.md, TESTS.md
│   └── python/                            ← Off-chain SDK + tests
├── compliant/                             ← Security-audited version
│   ├── contracts/                         ← Fixed sources (registry.ak, types.ak, validation.ak)
│   ├── tests/
│   │   ├── behavioral/                    ← Functional tests (must pass)
│   │   └── exploit/                       ← Exploit tests (must fail = attacks blocked)
│   └── reports/                           ← Full audit trail (10 reports)
├── deploy/agent-registry/                 ← Mainnet-ready deployment files
│   ├── DEPLOY.md                          ← Script hash, testnet TX hashes, Conway CBOR note
│   └── plutus.json                        ← Compiled Plutus V3 blueprint
└── README.md                              ← This file
```

## Key Results

| Severity | Findings | Status |
|----------|:--------:|--------|
| Critical | 2 | ✅ Fixed |
| High | 2 | ✅ Fixed |
| Medium | 3 | ✅ Fixed |
| Low | 3 | ✅ Fixed |
| Info | 1 | Acknowledged |

## Testnet Deployment

| Item | Value |
|------|-------|
| **Script Hash** | `be1a0a2912da180757ed3cd61b56bb8eab0188c19dc3c0e3912d2c01` |
| **Script Address** | `addr1wxlp5z3fztdpsp6ha57dvx6khw82kqvgcxwu8s8rjykjcqghprf42` |
| **Registration TX** | [`9ccd9243...`](https://vector.testnet.apexscan.org/en/transaction/9ccd924359267692aa6a698609a19280ca7a70fad51f2fb4f1a78e2c5758d79d) |
| **Update TX** | [`4f2c31c4...`](https://vector.testnet.apexscan.org/en/transaction/4f2c31c48f16ac8f8e3b8b97fd972f7e05b1bb2032c64ac6acaa22f10de8352f) |

### On-Chain Red Team

| Attack | Finding | Result |
|--------|---------|--------|
| Double satisfaction (spend 2 UTxOs) | AR-01 | ✅ **Blocked** |
| Unauthorized burn (no owner signature) | AR-03 | ✅ **Blocked** |
| Legitimate update (with authorization) | — | ✅ **Passed** |

## Audit Reports

| Report | Description |
|--------|-------------|
| `compliant/reports/audit-report.md` | Consolidated security audit — all 11 findings |
| `compliant/reports/final-red-team-report.md` | Adversarial analysis — 0 bypasses found |
| `compliant/reports/code-review.md` | Cold read code review |
| `compliant/reports/test-report.md` | Full test results |
| `compliant/reports/deployment-validation.md` | Build verification + on-chain constants |
| `compliant/reports/comparison-report.md` | Original vs compliant comparison |

## Technology

- **Language:** Aiken v1.1.21
- **Target:** Plutus V3 (Conway era)
- **Standard Library:** aiken-lang/stdlib v3.0.0
- **Network:** Vector testnet (protocol v10.0, mainnet-style addresses)

## ⚠️ Conway CBOR Note

The Conway ledger encodes Plutus Data constructors using **indefinite-length CBOR arrays** (`9F...FF`). Off-chain tooling that derives values from `cbor.serialise()` (e.g., asset name derivation) must match this encoding. See `deploy/agent-registry/DEPLOY.md` for details.
