# Smart Contract Audit

Security audit pipeline for Aiken smart contracts on the Cardano blockchain. Each contract goes through a structured process: original review, template creation, and compliance verification.

## Contracts

| Contract | Description |
|----------|-------------|
| simple-escrow | Two-party escrow with conditional release |
| vesting | Token vesting with time-locked withdrawals |
| donation-pool | Pooled donation collection and distribution |
| simple-dex | Basic decentralized exchange with swap functionality |

## Directory Layout

```
smart-contract-audit/
├── original/          ← contracts as received from authors
│   └── <contract>/
│       ├── <contract>.ak
│       └── README.md
├── templates/         ← from-scratch reference implementations
│   └── <contract>/
│       ├── <contract>.ak
│       ├── README.md
│       └── agent-notes/
└── compliant/         ← audit-passed versions with evidence
    └── <contract>/
        ├── <contract>.ak
        ├── README.md
        ├── agent-notes/
        ├── tests/
        ├── reports/
        └── tools/
```

## Workflow

1. **Receive** — Original contract placed in `original/<contract>/`
2. **Analyze** — Function analysis and intent documentation
3. **Template** — Clean reference implementation in `templates/<contract>/`
4. **Audit** — Security review, testing, red team analysis
5. **Certify** — Compliant version with full evidence in `compliant/<contract>/`
