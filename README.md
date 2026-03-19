# Vector AI Agents

> **⚠️ DEMO — NOT FOR PRODUCTION USE**
>
> This repository contains **demonstration and educational materials** produced by an AI agent security audit team. The smart contracts, audit reports, and deployment artifacts are provided as proof-of-concept examples of AI-driven security audit methodology.
>
> **Do not deploy these contracts to mainnet with real funds.** While the compliant versions address all identified security findings and have been verified on Vector testnet, they have not undergone independent third-party audit. Use at your own risk.

## Overview

Public deliverables from AI agent teams — demonstrating capability in smart contract security auditing on the Cardano/Vector blockchain using Aiken.

## Projects

| Project | Description | Status |
|---------|-------------|--------|
| [smart-contract-audit](smart-contract-audit/) | Aiken smart contract security audit pipeline (4 contracts) | ✅ Complete |
| [agent-registry](agent-registry/) | Agent Registry soulbound NFT identity — full security audit | ✅ Complete |

## What's Here

- **Security audits** of 5 Aiken smart contracts with full evidence trail
- **10-check vulnerability checklist** for eUTxO/Aiken contracts
- **Single-agent audit guide** — portable methodology any AI agent can follow
- **On-chain proof** — testnet TX hashes showing exploits blocked by compliant versions
- **Conway CBOR encoding discovery** — critical finding for Aiken deployments on Conway-era chains

## Structure

Each project follows a consistent layout:

```
project/
├── original/     ← Contracts as received, untouched
├── compliant/    ← Audit-passed versions with tests and reports
├── deploy/       ← Mainnet-ready files (plutus.json + DEPLOY.md)
└── docs/         ← Methodology, checklists, attack vectors
```

## Key Finding

Every Aiken validator using `list.any` over `tx.outputs` is **presumed vulnerable to double satisfaction** until proven otherwise. Found in **5/5 audited contracts**. The fix is always `script_input_count == 1`. See `smart-contract-audit/docs/audit-checklist.md`.

## Technology

- **Language:** Aiken v1.1.21
- **Target:** Plutus V3 (Conway era)
- **Network:** Vector testnet (protocol v10.0)
- **Audit methodology:** Apex v2

## License

MIT

---

*⚠️ DEMO — NOT FOR PRODUCTION USE. See disclaimer above.*
