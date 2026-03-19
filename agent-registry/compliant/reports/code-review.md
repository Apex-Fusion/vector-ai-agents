# Agent Registry — Code Review (Cold Read)

**Reviewer:** Code Review
**Date:** 2026-03-18
**Source:** `original/agent-registry/` — verbatim external submission
**Files reviewed:**
- `lib/agent_registry/types.ak`
- `lib/agent_registry/validation.ak`
- `validators/registry.ak`
- `lib/agent_registry/validation_tests.ak`
- `docs/DESIGN.md` (intent reference)

---

## Executive Summary

The contract is structurally clean and the architecture is well-thought-out. The extraction of validation logic into a testable library (D8) is good practice. The multi-validator design with `policy_id == script_hash == payment_credential` is a sound eUTXO pattern.

However, there are several significant divergences between stated intent and actual implementation, plus structural gaps that create exploitable conditions. The most critical:

1. **Burn is not coupled to Deregister at the contract level** — `validate_burn` can succeed in a transaction that uses the `Burn` mint redeemer *without* any spend action, leaving the agent UTxO permanently locked with its deposit trapped.
2. **Script credential as `owner` in registration is not prevented** — `validate_register` does not check the owner type, but `has_credential_signed` always returns `False` for script credentials, making any such registration permanently unspendable.
3. **`find_nft_name` uses `expect` with a pattern that panics** — if a UTxO somehow holds multiple tokens under the policy, this crashes the validator rather than failing gracefully.
4. **`list.any` output matching in update/register** — a transaction can include additional outputs at the script address alongside the valid one; the validator accepts as long as one output is valid, potentially creating unspendable "ghost" UTxOs.

---

## Per-Function Analysis

### `validate_register`

**What it checks:**
- Seed UTxO consumed
- Exactly one NFT minted with the correct asset name
- One output at script address with inline datum, the NFT, and ≥ 10 AP3X

**Gaps vs DESIGN.md:**

- **No owner type check.** DESIGN.md D4 states "The validator only authorizes key-based credentials." But `validate_register` stores whatever `owner` value is in the datum without validating it. If a script credential is stored as owner (by constructing a transaction with a script-credential datum), the agent UTxO becomes permanently locked — `has_credential_signed` will always return `False` for a script credential, so Update and Deregister can never succeed.

- **No datum content validation.** The validator checks `has_inline_datum` (presence of *any* inline datum) but not that the datum is a valid `AgentDatum` or that any fields are non-empty. Zero-length `name`, `endpoint`, or `capabilities` are accepted on-chain.

- **`list.any` on outputs.** The check passes if *any* output at the script address satisfies the conditions. A malicious or misconfigured transaction could create two outputs at the script address — one valid (passes the check), one with only lovelace and no NFT. The second output would be permanently unspendable since there is no NFT in it to satisfy `find_nft_name` in a future spend.

- **`registered_at` is not validated.** The field is described as a "POSIX timestamp" but the contract accepts any integer, including 0 or negative values.

### `validate_burn`

**What it checks:**
- Exactly one token under this policy is burned (quantity == -1)

**Critical gap:**

- **Burn is not coupled to the spend validator.** The `Burn` mint redeemer can be used in a transaction that does *not* spend the agent UTxO. The burn succeeds (NFT destroyed) but the UTxO remains at the script address with its lovelace deposit and a now-invalid datum (no matching NFT). This deposit is permanently locked — there is no validator path that can spend a UTxO whose NFT no longer exists, because `find_nft_name` will `expect`-panic on an empty token map.

  DESIGN.md documents the intended flow as "Burn the identity NFT to retire the identity" (always in conjunction with Deregister), but this coupling is never enforced on-chain.

- **Burn does not check that the burned NFT belongs to an existing agent UTxO.** A burn of an arbitrary asset name under this policy would succeed if the quantity is -1. Since NFT asset names are derived deterministically, this is primarily a theoretical concern — you cannot burn a name you haven't minted — but it means the burn validator is entirely stateless with respect to what it's destroying.

### `validate_update`

**What it checks:**
- Owner signed
- Continuing output at same script address with inline datum, same NFT, ≥ 10 AP3X

**Gaps:**

- **`list.any` on outputs** (same issue as register). Two outputs at the script address could exist: one valid, one ghost.
- **Datum content not validated on continuation.** The owner field can be changed to a script credential during an update (D7 by design permits ownership transfer, but doesn't prevent transfer to an unspendable credential). After such a transfer, the UTxO is permanently locked.
- **No NFT asset name continuity check beyond quantity.** The check `assets.quantity_of(output.value, own_policy, input_nft_name) == 1` correctly uses `input_nft_name` derived from the input — this is correct. However, if `find_nft_name` panics on the input (e.g., somehow holding 2 NFTs under the policy), the validator fails with an `expect` error rather than a clean `False`.

### `validate_deregister`

**What it checks:**
- Owner signed
- Some token under the policy is burned with quantity == -1

**Gaps:**

- **Does not verify the burned NFT is the one in the current UTxO.** `validate_deregister` gets the policy from the current UTxO's address, checks that something under that policy is burned at -1, but does not verify the asset name matches the NFT actually held in the UTxO. In practice this is hard to exploit (you'd need to have minted two NFTs under the same policy, which is constrained per-registration), but it's a loose check.
- **Deposit return is not enforced on-chain.** DESIGN.md states "AP3X deposit returned to owner" as part of Deregister. The validator does not check this — a transaction could burn the NFT with owner signature but send the lovelace anywhere. This is an economic finding, not a security one (the owner is signing, so they're authorizing this), but it means the contract doesn't protect owners from badly-constructed SDK transactions.

### `get_policy_from_address` and `find_nft_name`

Both use `expect` patterns that will panic (validator error, not clean `False`) on unexpected input:

```
expect Script(hash) = addr.payment_credential  // panics if key address
expect [Pair(name, 1)] = dict.to_pairs(tokens) // panics if 0 or >1 tokens
```

The `get_own_address` and `get_own_value` helpers similarly use `expect Some(input)` which panics if `own_utxo` is not found in inputs. In practice the spend validator is only called when the UTxO is being spent (so it will always be in inputs), but the panic-on-unexpected pattern is a code quality concern — failures should produce `False`, not runtime errors that may surface differently in some contexts.

### `registry.ak` (multi-validator wrapper)

Clean and correct. The `else(_ctx) { fail }` catch-all is good practice. The `expect Some(agent_datum) = datum` in the spend handler correctly handles the case where no datum is present (it panics, which is correct behavior — spending a UTxO with no datum should not be allowed).

One observation: the `else` handler uses `fail` with an explicit error string. In production Plutus, this is slightly more expensive than a bare `fail` but is acceptable.

---

## Intent vs Implementation Divergences

| # | Design Intent (DESIGN.md) | Actual Implementation | Severity |
|---|--------------------------|----------------------|----------|
| 1 | D4: Only key-based credentials as owner | `validate_register` stores any `Credential` without checking type | High — script credential as owner = permanent lock |
| 2 | Deregister burns NFT AND returns deposit | Burn enforced; deposit destination not enforced | Medium — economic risk, owner is signing |
| 3 | Burn happens as part of Deregister flow | Burn redeemer can fire independently of spend | Critical — orphan UTxO with locked deposit |
| 4 | D7: Update allows ownership transfer (intentional) | No guard against transferring to non-signable credential | Medium — permanent lock risk on transfer |
| 5 | `registered_at` is a POSIX timestamp | Accepted as any integer including 0 or negative | Low — data quality only |
| 6 | Soulbound: NFT lives at script address | No check preventing multiple outputs at script address | Low-Medium — ghost UTxO creation possible |
| 7 | D5: Spend limits off-chain | No mention of this in validator | Acknowledged by design, noted for audit completeness |

---

## Test Gap Analysis

The existing 30 tests in `validation_tests.ak` cover the happy path and basic failure modes well. The following areas are **not tested**:

| Gap | Risk Level |
|-----|------------|
| Burn redeemer without spending agent UTxO (orphan burn) | Critical |
| Register with script credential as owner | High |
| Update transferring ownership to script credential | High |
| Multiple outputs at script address in one TX (ghost UTxO) | Medium |
| Deregister where burned NFT asset name differs from held NFT | Medium |
| `find_nft_name` behavior when UTxO holds 0 or 2 NFTs under policy | Medium |
| Empty/zero-length datum fields (name, endpoint, etc.) | Low |
| Negative or zero `registered_at` timestamp | Low |
| Deregister where deposit goes to attacker address | Medium |
| Burn of a different NFT name than what's in the agent UTxO | Medium |

---

## Inputs for the test writer (numbered list)

The following are explicit test areas the test writer should cover, in priority order:

1. **Orphan burn test** — construct a TX with `Burn` mint redeemer that does NOT spend any agent UTxO. Verify this succeeds against the original contract (proving the vulnerability). The behavioral suite should assert this fails on the compliant version.

2. **Script credential as owner on register** — register an agent with `Script(some_hash)` as the `owner` field in the datum. Verify the register succeeds (it will on the original), then verify that Update and Deregister subsequently fail because `has_credential_signed` returns `False` for script credentials.

3. **Ownership transfer to script credential via update** — start with a valid key-credential owner, then update to change the datum's `owner` to a `Script` credential. Verify the update succeeds (owner signed), then verify the UTxO is now permanently unspendable.

4. **Multiple outputs at script address** — construct a register TX that produces two outputs at the script address: one valid, one with only lovelace and no NFT. Verify the register succeeds (it will — `list.any` finds the valid one). Verify the second output is permanently unspendable.

5. **Deregister with mismatched NFT burn** — if the agent UTxO holds NFT `name_A`, construct a deregister TX that burns a different `name_B` under the same policy. Verify whether this passes or fails.

6. **Deregister deposit destination** — construct a deregister TX where the deposit lovelace is sent to an attacker address rather than the owner. Verify this passes (it will — not enforced). This is a behavioral documentation test.

7. **Burn with no agent UTxO spent** — already covered in #1 but worth having as a standalone behavioral test labeled explicitly.

8. **`find_nft_name` with 0 tokens** — construct an update/deregister where the input UTxO somehow holds no tokens under the policy. Document whether this produces a clean `False` or a validator panic.

9. **`find_nft_name` with 2 tokens** — construct an input UTxO holding two NFTs under the policy. Document whether this produces a clean `False` or a validator panic.

10. **Empty datum fields** — register with empty `name` (`""`), empty `endpoint`, empty `capabilities` list. Verify all pass (they will). Mark as behavioral documentation: "contract accepts empty fields."

11. **Register with zero `registered_at`** — verify the contract accepts `registered_at: 0`. Behavioral documentation.

12. **Minimum deposit boundary (existing, keep)** — the 30 existing tests cover this well. Keep in behavioral suite as-is.

13. **NFT asset name derivation collision resistance** — verify that 100+ different seed UTxOs all produce distinct asset names. Property test / fuzz candidate.

14. **`get_policy_from_address` with key address** — if `get_own_address` returns a key address (shouldn't happen in practice but worth testing), verify the behavior (will panic via `expect Script(hash)`).

Items 1–3 are the highest-priority novel findings to test. Items 4–7 are important behavioral documentation. Items 8–14 are coverage completeness and edge cases.
