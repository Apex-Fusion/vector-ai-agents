# Aiken Smart Contract Security Checklist

**Version:** 1.0 — March 2026
**Chains:** Vector/ApexFusion, Cardano (eUTxO)
**Language:** Aiken v1.1+
**Derived from:** Real audit findings across 5 contracts (Agent Registry, Simple Escrow, Donation Pool, Vesting, Simple DEX)

> Print this. Pin it next to your monitor. Check every box before you deploy.

---

## How to Use This Checklist

1. **During development** — review each section as you implement the corresponding logic.
2. **Before code review** — self-audit against every checkbox. If you can't check it, fix it or document why.
3. **During audit** — the auditor walks through each item. Unchecked boxes become findings.
4. **Before deployment** — every box must be ✅ or have a documented, accepted exception.

Each item includes a **one-line rationale** (the "why"). Items marked with 🔴 have caused real exploitable vulnerabilities in audited contracts.

---

## Pre-Deployment Checklist

### Validator Logic

- [ ] **All mint/spend handlers are coupled where operations are logically linked** 🔴
  *Why: Uncoupled burn allows NFT destruction without spending the UTxO, permanently locking deposits.*

- [ ] **Output matching uses exact count (`list.filter` + length), not `list.any`** 🔴
  *Why: `list.any` accepts one valid output among many — enables ghost UTxOs and double satisfaction.*

- [ ] **Credential types are validated (VerificationKey vs Script)**  🔴
  *Why: Script credentials as owner make UTxOs permanently unspendable — `has_credential_signed` always returns False for scripts.*

- [ ] **Authorization checks: owner/signer verified for ALL state-changing operations** 🔴
  *Why: Without owner signature on registration, anyone can register agents claiming arbitrary identities.*

- [ ] **Datum shape validated (not just InlineDatum presence)**
  *Why: Checking `has_inline_datum` only confirms a datum exists, not that it's the correct type or has valid fields.*

- [ ] **NFT identity verified by name, not just quantity**
  *Why: Checking only `qty == -1` under a policy allows burning the wrong NFT when multiple tokens exist under the same policy.*

- [ ] **Deposit amounts enforced on all relevant paths**
  *Why: Every output that should hold a minimum deposit must explicitly check it — register AND update paths.*

- [ ] **Deposit return destination enforced where required**
  *Why: Without enforcement, a signed deregister TX can send the deposit anywhere. Decide if this is acceptable for your trust model.*

- [ ] **Single-script-input constraint applied where double satisfaction is possible** 🔴
  *Why: Output-index pinning alone is NOT sufficient — two inputs can specify identical redeemer indices. The canonical defense is `script_input_count == 1`.*

- [ ] **Full address comparison (including stake credential) where funds are directed**
  *Why: Comparing only payment credentials allows an attacker to redirect funds via stake credential manipulation.*

### Error Handling

- [ ] **`expect` patterns reviewed for unintended panics**
  *Why: `expect` crashes the validator on mismatch instead of returning False. This may hide bugs or produce confusing errors.*

- [ ] **All failure paths return `False` (not expect-crash)**
  *Why: A clean `False` is deterministic and testable. A panic from `expect` is an implicit failure mode that's harder to reason about.*

- [ ] **Edge cases handled: empty token maps, zero quantities, missing inputs**
  *Why: `dict.to_pairs` on an empty map returns `[]` — if your `expect` pattern assumes at least one entry, the validator panics.*

### Testing

- [ ] **Behavioral tests (what SHOULD work)**
  *Why: Verify all happy paths — register, update, deregister, mint, burn with correct parameters.*

- [ ] **Exploit tests (what should NOT work)** 🔴
  *Why: Every finding from audit must have a corresponding test that proves the attack is blocked. Tests are the proof.*

- [ ] **Boundary conditions (exact minimum, one below)**
  *Why: Off-by-one in deposit checks (`>=` vs `>`) can lock or leak funds. Test 10_000_000 AND 9_999_999.*

- [ ] **Property-based / fuzz tests for critical paths**
  *Why: Randomized inputs find edge cases humans miss. Aim for 1,000+ samples per critical function.*

- [ ] **Test that every `expect` pattern has a corresponding failure test**
  *Why: If you can't trigger the expect-failure in a test, you don't understand when it fires.*

### Multi-Validator Specific

- [ ] **Burn coupled to spend (orphan burn prevented)** 🔴
  *Why: If burn can fire without spend, the NFT is destroyed but the UTxO (and deposit) remains permanently locked.*

- [ ] **Double satisfaction prevented (exact output count per handler)** 🔴
  *Why: Two simultaneous spends sharing one output lets an attacker steal one deposit entirely.*

- [ ] **Ghost UTxO creation prevented** 🔴
  *Why: Extra outputs at the script address without NFTs are permanently unspendable — funds locked forever.*

- [ ] **Mint redeemer validated against spend context**
  *Why: Stateless mint validators that don't verify what's being spent allow arbitrary minting/burning.*

### Deployment

- [ ] **`aiken check` passes with zero warnings**
  *Why: Warnings often indicate unused variables, unreachable paths, or type mismatches that hide bugs.*

- [ ] **`plutus.json` generated and hash verified**
  *Why: The on-chain script must match what you audited. Hash drift means you're deploying unreviewed code.*

- [ ] **Testnet lifecycle verified (register → update → deregister or equivalent full lifecycle)**
  *Why: Unit tests run in a harness, not on-chain. Ledger-level constraints (value preservation, signatures) can surface new failures.*

- [ ] **Off-chain transaction builders validated against on-chain constraints**
  *Why: A correct validator can't protect against a buggy SDK that constructs malformed transactions.*

---

## Common Vulnerability Patterns (Quick Reference)

### 1. Double Satisfaction — The #1 eUTxO Vulnerability 🔴

Found in **every contract** audited. The most persistent and dangerous pattern.

**The bug:** Two script inputs share one output, so one deposit is stolen.

```aiken
// ❌ BAD — list.any accepts one valid output among many
let has_valid_output =
  list.any(tx.outputs, fn(output) {
    output.address == own_address &&
    assets.lovelace_of(output.value) >= min_deposit
  })
```

```aiken
// ✅ GOOD — exactly one output at script address, and it must be valid
let script_outputs =
  list.filter(tx.outputs, fn(output) { output.address == own_address })

let has_valid_output =
  when script_outputs is {
    [output] ->
      assets.lovelace_of(output.value) >= min_deposit
    _ -> False
  }
```

**Defense layers (use both):**
1. Exact output count via `list.filter` + singleton match
2. Single-script-input constraint: `script_input_count == 1`

---

### 2. Uncoupled Mint/Burn — Orphan Operations 🔴

**The bug:** Burn redeemer fires without a corresponding spend, destroying the NFT while the UTxO and deposit remain locked forever.

```aiken
// ❌ BAD — burn is completely stateless
pub fn validate_burn(policy_id: PolicyId, tx: Transaction) -> Bool {
  let minted_tokens = assets.tokens(tx.mint, policy_id)
  when dict.to_pairs(minted_tokens) is {
    [Pair(_, qty)] -> qty == -1
    _ -> False
  }
}
```

```aiken
// ✅ GOOD — burn requires a script input (coupling burn to spend)
pub fn validate_burn(policy_id: PolicyId, tx: Transaction) -> Bool {
  let burn_check =
    when dict.to_pairs(assets.tokens(tx.mint, policy_id)) is {
      [Pair(_, qty)] -> qty == -1
      _ -> False
    }

  // Ensure an agent UTxO is being spent in this same TX
  let has_script_input =
    list.any(tx.inputs, fn(input) {
      input.output.address.payment_credential == Script(policy_id)
    })

  burn_check && has_script_input
}
```

---

### 3. Script Credential as Owner — Permanent Lock 🔴

**The bug:** A Script credential stored as `owner` makes the UTxO permanently unspendable because `has_credential_signed` always returns `False` for non-key credentials.

```aiken
// ❌ BAD — accepts any credential type as owner
pub fn validate_register(...) -> Bool {
  // ... stores whatever owner is in the datum without checking type
  has_inline_datum(output)  // only checks datum exists
}
```

```aiken
// ✅ GOOD — explicitly reject Script credentials
fn validate_output_owner(output: Output, tx: Transaction) -> Bool {
  expect InlineDatum(raw_datum) = output.datum
  expect datum: AgentDatum = raw_datum
  when datum.owner is {
    VerificationKey(_) -> has_credential_signed(tx, datum.owner)
    Script(_) -> False  // Reject — would permanently lock the UTxO
  }
}
```

**Also applies to update/transfer:** If ownership transfer is allowed, validate the *new* owner is also a VerificationKey.

---

### 4. NFT Identity by Quantity Only — Wrong Token Burned 🔴

**The bug:** Checking only that *some* token under the policy has `qty == -1` without verifying the asset name allows burning the wrong NFT.

```aiken
// ❌ BAD — any token under the policy with -1 quantity passes
let nft_burned =
  when dict.to_pairs(assets.tokens(tx.mint, own_policy)) is {
    [Pair(_, qty)] -> qty == -1
    _ -> False
  }
```

```aiken
// ✅ GOOD — verify the burned token name matches the input UTxO's NFT
let input_nft_name = find_nft_name(input_value, own_policy)
let nft_burned =
  when dict.to_pairs(assets.tokens(tx.mint, own_policy)) is {
    [Pair(name, qty)] -> name == input_nft_name && qty == -1
    _ -> False
  }
```

---

### 5. `expect` Panics Instead of Clean Failure

**The bug:** `expect` crashes the validator on unexpected input instead of returning `False`. This makes failures non-deterministic and harder to test.

```aiken
// ❌ BAD — panics if address is key-based or if 0 or 2+ tokens exist
pub fn get_policy_from_address(addr: Address) -> PolicyId {
  expect Script(hash) = addr.payment_credential  // PANIC if VerificationKey
  hash
}

pub fn find_nft_name(value: Value, policy_id: PolicyId) -> ByteArray {
  let tokens = assets.tokens(value, policy_id)
  expect [Pair(name, 1)] = dict.to_pairs(tokens)  // PANIC if 0 or 2+ tokens
  name
}
```

```aiken
// ✅ BETTER — return Option or Bool, let caller decide
pub fn find_nft_name(value: Value, policy_id: PolicyId) -> Option<ByteArray> {
  let tokens = assets.tokens(value, policy_id)
  when dict.to_pairs(tokens) is {
    [Pair(name, 1)] -> Some(name)
    _ -> None
  }
}

// Caller:
when find_nft_name(input_value, own_policy) is {
  Some(name) -> // proceed with name
  None -> False // clean failure
}
```

**Pragmatic note:** In practice, `expect` in spend validators is often safe because the UTxO is guaranteed to be in inputs. But the pattern is fragile — if any assumption changes, the panic becomes a hidden bug. Prefer explicit handling in new code.

---

## eUTxO Security Mental Model

```
┌─────────────────────────────────────────────────────┐
│                  TRANSACTION                         │
│                                                      │
│  Inputs (spent UTxOs)          Outputs (new UTxOs)   │
│  ┌──────────────┐              ┌──────────────┐      │
│  │ Script UTxO A │──validate──▶│ Output 1     │      │
│  └──────────────┘              └──────────────┘      │
│  ┌──────────────┐              ┌──────────────┐      │
│  │ Script UTxO B │──validate──▶│ Output 2     │      │
│  └──────────────┘              └──────────────┘      │
│                                ┌──────────────┐      │
│  ⚠️ Each validator runs        │ Ghost Output │ ← 🔴 │
│  INDEPENDENTLY — they don't   └──────────────┘      │
│  see each other's results!                           │
│                                                      │
│  Mint policy ──── also runs independently            │
└─────────────────────────────────────────────────────┘

Key insight: Validators are pure functions that say Yes/No.
They CANNOT prevent other validators from also saying Yes
to the SAME output. This is why double satisfaction exists.
```

---

## Quick Decision Tree

```
Is this a multi-validator contract (mint + spend)?
├── YES → Are mint and spend coupled? (burn requires script input?)
│         ├── NO → 🔴 STOP. Fix this first.
│         └── YES → ✓
│
Does the validator produce continuing outputs?
├── YES → Using list.filter + exact count (not list.any)?
│         ├── NO → 🔴 STOP. Double satisfaction risk.
│         └── YES → Also enforcing single-script-input?
│                   ├── NO → ⚠️ Consider adding it.
│                   └── YES → ✓
│
Does the contract store credentials in datum?
├── YES → Validating credential type (VK only)?
│         ├── NO → 🔴 STOP. Permanent lock risk.
│         └── YES → Also checking on update/transfer?
│                   ├── NO → 🔴 STOP.
│                   └── YES → ✓
│
Does the contract use expect patterns?
├── YES → Each one tested for the failure case?
│         ├── NO → ⚠️ Add failure tests.
│         └── YES → ✓
└── NO → ✓
```

---

## Related Documents

| Document | Description |
|----------|-------------|
| [Agent Registry Code Review](../../agent-registry-audit-v2/compliant/reports/code-review.md) | Detailed per-function analysis of a multi-validator registry contract |
| [Agent Registry Fix Notes](../../agent-registry-audit-v2/compliant/reports/fix-notes.md) | Security fixes applied with rationale and exploit tests blocked |
| [Cross-Contract Audit Summary](../compliant/summary-audit.md) | Audit of 4 contracts — escrow, donation, vesting, DEX |
| [Aiken Documentation](https://aiken-lang.org) | Official Aiken language reference |
| [CIP-57: Plutus Contract Blueprint](https://cips.cardano.org/cip/CIP-0057) | Standard for `plutus.json` generation and verification |

---

*This checklist is a living document. Update it as new vulnerability patterns emerge from audits and real-world incidents.*
