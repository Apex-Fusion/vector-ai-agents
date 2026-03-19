# Smart Contract Audit

Security audit pipeline for Aiken smart contracts on the Vector/Cardano blockchain. Each contract goes through a structured audit process with on-chain verification on Vector testnet.

## Contracts

| Contract | Description | Findings | Status |
|----------|-------------|:--------:|--------|
| simple-escrow | Two-party escrow with hash-locked release | 5 (1 Critical) | ✅ Compliant |
| donation-pool | Pooled donation collection and distribution | 5 (1 High) | ✅ Compliant |
| vesting | Token vesting with time-locked withdrawals | 6 (2 Critical) | ✅ Compliant |
| simple-dex | Limit order DEX with token swaps | 5 (1 Critical, 1 High) | ✅ Compliant |

**210/210 tests passing** across all 4 contracts.

## Folder Structure

```
smart-contract-audit/
├── original/                  ← Contracts as received (pre-audit)
│   ├── simple-escrow/
│   ├── donation-pool/
│   ├── vesting/
│   └── simple-dex/
├── compliant/                 ← Audit-passed versions with full evidence
│   ├── simple-escrow/
│   │   ├── simple_escrow.ak
│   │   ├── reports/
│   │   └── tests/
│   ├── donation-pool/
│   ├── vesting/
│   └── simple-dex/
├── deploy/                    ← Mainnet-ready deployment files
│   ├── simple-escrow/
│   │   ├── DEPLOY.md          ← Script hash, testnet TX, version history
│   │   └── plutus.json        ← Compiled Plutus V3 blueprint
│   ├── donation-pool/
│   ├── vesting/
│   └── simple-dex/
├── docs/                      ← Audit methodology & knowledge base
│   ├── single-agent-audit-guide.md   ← Portable 10-check audit methodology
│   ├── audit-checklist.md            ← Explicit doctrine + applicability matrix
│   ├── audit-methodology.md          ← v2 methodology overview
│   ├── eutxo-security-patterns.md    ← eUTxO design patterns
│   ├── utxo-attack-vectors.md        ← 18 attack vectors with examples
│   ├── utxo-attack-surface.md        ← Attack surface analysis
│   ├── testing-on-vector.md          ← Testnet deployment guide
│   └── aiken-security-checklist.md   ← Quick reference
└── README.md                  ← This file
```

## Audit Methodology (Apex v2)

1. **Cold Read** — Independent code review against 10-check vulnerability checklist
2. **Test Writing** — Behavioral tests (functionality preserved) + exploit tests (attacks blocked)
3. **Fix & Re-review** — Blind fixing, independent re-review
4. **Red Team** — Adversarial testing (code-level + on-chain)
5. **Testnet Verification** — Deploy to Vector testnet, execute exploit TXs, verify rejections
6. **Report** — Publication-quality audit deliverable

## Live Testnet Proof

All 4 contracts are deployed on Vector testnet with on-chain exploit evidence:

| Contract | Compliant Hash | Testnet Status |
|----------|---------------|----------------|
| simple-escrow | `6f1cc128...` | ✅ Deployed — double satisfaction exploit TX rejected |
| donation-pool | `34c4cca4...` | ✅ Deployed |
| vesting | `5e84a9e0...` | ✅ Deployed |
| simple-dex | `a30e2317...` | ✅ Deployed |

See individual `deploy/<contract>/DEPLOY.md` for TX hashes and version history.

## Documentation (docs/)

The `docs/` folder contains a complete context package for AI-agent-driven smart contract auditing. Point any capable agent at this folder with a contract source and it has everything needed to perform a structured security audit:

- **10 first-pass vulnerability checks** (double satisfaction, output-index pinning, cross-input consistency, integer arithmetic, token identity, tautological datum validation, datum injection, continuation value leakage, UTxO fragmentation, value comparison asymmetry)
- **Applicability matrix** — which checks apply to which contract architecture
- **Role-based naming convention** — Admin, Attacker, Beneficiary (no personal names)
- **Report template** — copy-paste ready audit report structure

## Key Finding: `list.any` = Exploitable

Every Aiken validator using `list.any` over `tx.outputs` is **presumed vulnerable to double satisfaction** until proven otherwise. Found in **5/5 audited contracts**. The fix is always `script_input_count == 1`.

## Technology

- **Language:** Aiken v1.1.21
- **Target:** Plutus V3 (Conway era)
- **Network:** Vector testnet (protocol v10.0)
