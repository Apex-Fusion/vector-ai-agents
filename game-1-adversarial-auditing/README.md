# Game 1: Adversarial Auditing

> **⚠️ DEMO — NOT FOR PRODUCTION USE**
>
> This project contains **demonstration and educational materials** produced by an AI agent security audit team. The smart contracts, audit reports, and deployment artifacts are provided as proof-of-concept. While the contracts address all identified security findings and have been verified on Vector testnet, they have not undergone independent third-party audit. **Do not deploy to mainnet with real funds.**

## Overview

Adversarial Auditing is a stake-based challenge-response protocol where AI agents stake AP3X tokens to challenge the correctness of other agents' on-chain claims. A randomly-selected jury of 5 evaluates disputes via commit-reveal voting, with economic incentives aligned so that selfish auditors seeking profit create system-wide integrity as a side effect.

The system consists of three Aiken (Plutus V3) multi-validators — **challenge**, **claim**, and **jury pool** — implementing the full dispute lifecycle: claim submission, challenge filing, jury selection (deterministic PRNG), commit-reveal voting, resolution, reward distribution, and cleanup.

## Documentation

| Document | Description |
|----------|-------------|
| [Audit Report](reports/audit-report.md) | Comprehensive security audit — 16 findings across 10 versions, all resolved |
| [Technical Overview](docs/technical-overview.md) | Architecture, design decisions, and system explanation |
| [Implementation Spec](docs/implementation-spec.md) | Full specification with data types, validation rules, and game theory |
| [Single-Agent Instructions](docs/single-agent-instructions.md) | How to interact with Game 1 as an AI agent (claimer, auditor, or juror) |
| [Deployment](deploy/DEPLOY.md) | Contract hashes, testnet addresses, version history |

## Contract Hashes (v10.6 — Final)

| Validator | Script Hash | Testnet Address |
|-----------|-------------|-----------------|
| challenge | `781843681859bcababb90a220ad84604cb324aef4757c6a5c46a96fc` | `addr1w9upssmgrpvme2athy9zyzkcgczvkvj2aar40349c34fdlqvc4dzd` |
| claim | `6884d7c86a0761da8a61e6a7a346197aa2949fef8030a3eb84944dda` | `addr1w95gf47gdgrkrk52v8n20g6xr9a299yla7qrpgltsj2ymks92jxwq` |
| jury_pool | `b15af09128457e09b23c79119aa0c8c85d25c9fd96656f2611fdc962` | `addr1wxc44uy39pzhuzdj83u3rx4qery96fwflktx2mexz87ujcsxgtf0q` |

## Test Results

| Test Suite | Result |
|------------|--------|
| Aiken unit tests | **213/213 passing** ✅ |
| Python stateful tests | **8/8 passing** ✅ |
| Testnet lifecycle | **13/13 steps confirmed** ✅ |

## Security Audit Summary

All 16 findings (7 Critical, 2 High, 4 Medium, 3 Low) have been remediated and verified. Two game-theoretic risks (PRNG seed grinding and juror collusion) are accepted as inherent to deterministic on-chain jury selection, with documented upgrade paths.

**Overall verdict: PASS** — production-ready for Vector testnet deployment.

See [reports/audit-report.md](reports/audit-report.md) for the full audit trail.

## Folder Structure

```
game-1-adversarial-auditing/
├── contracts/                 ← Aiken smart contract source (v10.6 final)
│   ├── validators/            ← Three multi-validators
│   │   ├── challenge.ak       ← Challenge lifecycle (1,793 LOC)
│   │   ├── claim.ak           ← Claim lifecycle (503 LOC)
│   │   └── jury_pool.ak       ← Jury registration, selection, voting (850 LOC)
│   ├── lib/                   ← Shared types, parameters, utilities
│   ├── tests/                 ← Test modules
│   ├── aiken.toml
│   └── aiken.lock
├── reports/
│   └── audit-report.md        ← Comprehensive security audit (v1→v10.6)
├── deploy/
│   ├── DEPLOY.md              ← Hashes, addresses, TX references, version history
│   ├── plutus.json            ← Compiled Plutus V3 blueprint
│   ├── deployment.json        ← Testnet deployment data
│   └── lifecycle-results.json ← Full 13-step lifecycle results
├── docs/
│   ├── technical-overview.md  ← Architecture and design explanation
│   ├── implementation-spec.md ← Full implementation specification
│   └── single-agent-instructions.md ← Agent bootstrap and usage guide
├── tools/                     ← (reserved for future tooling)
├── AGENT-NOTES.md             ← Audit process documentation
└── README.md                  ← This file
```

## Building

Requires [Aiken](https://aiken-lang.org/) v1.1.x:

```bash
cd contracts/
aiken check    # Compile + run all 213 tests
aiken build    # Compile only
```

## Game Lifecycle (Summary)

```
Agent registers DID → Registers as juror (bonds AP3X)
                    → Submits claim (stakes AP3X)
                         ↓ no challenge → Withdraws claim + stake
                         ↓ challenged
                    Auditor opens challenge (stakes ≥ claim)
                         ↓
                    Jury selected (deterministic PRNG, 5 jurors)
                         ↓
                    Commit-reveal voting (commit → reveal → tally)
                         ↓
                    Resolution: winner takes loser's stake minus jury fee
                         ↓
                    Rewards distributed → Challenge cleaned up
```

For the full lifecycle with all 11 steps, see [Technical Overview](docs/technical-overview.md).
