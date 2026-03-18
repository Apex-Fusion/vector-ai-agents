# Agent Registry — Red Team Report (Early Pass)

**Date:** 2026-03-18
**Pass:** Early — against original unmodified contract
**Scope:** Adversarial analysis; attack vectors beyond the code reviewer's code review

---

## Summary

The contract has a structurally weak threat model: it was designed assuming a well-behaved SDK is the only transaction builder. The validator does not defend against adversarial transaction construction. Most findings stem from this root assumption. The most dangerous attack surface is the mint handler, which is almost entirely stateless with respect to the spend validator — the two handlers share a policy ID but have no enforced coupling at the transaction level.

**Novel findings not in the code reviewer's review or the test writer's exploit tests: 4**
**Confirmed findings (attacker perspective added): 6**

---

## Novel Attack Vectors

### RT-01: Double-Spend via Concurrent Registration (eUTXO Concurrency)
**Severity: Medium**

In eUTXO, two transactions can race to consume the same seed UTxO. The first to land on-chain succeeds; the second fails (seed already consumed). This is not a vulnerability per se — it's expected eUTXO behavior. However, an attacker can deliberately front-run a legitimate registration:

1. Alice broadcasts a register TX using seed UTxO `X`
2. Attacker sees it in the mempool, extracts seed `X`
3. Attacker broadcasts their own register TX consuming `X` with higher fees
4. Attacker's TX lands first — Alice's TX is invalidated
5. Attacker's registration (with arbitrary datum content, claiming any owner) is on-chain

This is a griefing attack. Combined with `exploit_register_without_owner_signature` (no owner signature required), the attacker can register with Alice's VKH as owner — creating a polluted registry entry Alice didn't authorize and can't easily distinguish from her legitimate one.

**Mitigation needed:** Owner signature on registration prevents the impersonation half of this attack.

---

### RT-02: Register + Burn in Single Transaction (Instant Orphan)
**Severity: High**

The mint handler handles both `Register` and `Burn` redeemers. In Cardano/Plutus, a single transaction can invoke the same policy multiple times with different redeemers — but only if the policy is a multi-asset policy with different asset names. In this contract, a single TX could theoretically:

1. Mint 1 NFT (Register redeemer, asset name A)
2. Burn 1 NFT (Burn redeemer, asset name B — a previously registered NFT)

The `validate_register` check passes (NFT A minted correctly, output at script address).
The `validate_burn` check passes (NFT B burned, quantity -1).

Result: A legitimate registration TX secretly destroys another agent's NFT in the same transaction, triggering the orphan burn on that agent's UTxO. The victim's deposit is permanently locked.

**Note:** In Aiken/Plutus V3, invoking the same validator script twice in one TX with different redeemers requires careful handling. Whether this is possible depends on the Aiken multi-validator compilation model — worth verifying. If possible, it is a critical vector.

---

### RT-03: Datum Hash Collision via Large ByteArray Fields
**Severity: Low-Medium**

The contract accepts arbitrary-length `name`, `description`, `endpoint`, and `capabilities` fields with no size constraints. An attacker can:

1. Register with an extremely large datum (megabytes of data in `description`)
2. The registration succeeds (no size check)
3. Result: Bloated chain state, high indexer costs, potential DoS on any tool that reads all registry UTxOs

This is an economic griefing attack against the registry ecosystem, not against individual users. The 10 AP3X minimum deposit does not scale with datum size, so large-datum registrations cost the same as minimal ones.

**Mitigation:** On-chain byte length limits on string fields, or a deposit formula proportional to datum size.

---

### RT-04: Staking Credential Injection
**Severity: Low**

`script_address_from_policy` constructs the script address with `stake_credential: None`. The `validate_register` and `validate_update` checks verify `output.address == script_address` — exact equality including staking credential.

However, an attacker who controls the off-chain SDK could construct a register TX with the output going to `Address { payment_credential: Script(policy_id), stake_credential: Some(attacker_stake_key) }`. This would NOT match `test_script_address()` and the register would correctly fail.

**Assessment:** This is NOT a vulnerability — the strict equality check correctly rejects staking-credential-injected addresses. Noting it as a confirmed non-issue for the report.

---

## Confirmed Vectors (Attacker Perspective Added)

### RT-05: Orphan Burn — Attacker Perspective
**Confirms: exploit_orphan_burn_no_spend**

From an attacker's perspective, this is useful for griefing a competitor: burn their NFT without spending their UTxO. Their deposit is permanently locked, their DID is destroyed, but their UTxO remains as dead weight on-chain. The attack only requires the attacker to somehow obtain or mint a token under the policy with the victim's NFT asset name — which they cannot do without consuming the original seed UTxO. So in practice, only the legitimate NFT holder can trigger an orphan burn (accidentally or through a malicious SDK). This makes it a self-harm risk rather than a direct attack vector against third parties.

**Revised severity: Medium** (self-harm, not third-party attack) — but the deposit loss is permanent and irrecoverable.

### RT-06: Script Credential Owner — Targeted Attack Chain
**Confirms: exploit_script_credential_owner_register_succeeds**

Attack chain:
1. Attacker identifies a target (Alice) who they want to grief
2. Attacker constructs a register TX with `owner: Script(some_hash)` and uses Alice's wallet address as the fee payer (social engineering — tricks Alice into signing what looks like a legitimate transaction)
3. Alice's seed UTxO is consumed, 10 AP3X deposited, but the resulting UTxO is permanently unspendable
4. Alice loses her seed UTxO and 10 AP3X with no recourse

This requires Alice to sign a malformed TX — but if Alice is using an untrusted SDK or front-end, this is realistic.

### RT-07: No Owner Auth on Register — Identity Pollution
**Confirms: exploit_register_without_owner_signature**

An attacker can register multiple agents claiming prominent VKHs (known validators, exchanges, protocol teams) as owners. These pollute the registry with fake entries under legitimate identities. Since there is no on-chain ownership proof at registration, off-chain indexers cannot distinguish legitimate from fake registrations without additional metadata. This is a reputation attack against the registry's trustworthiness as a directory service.

### RT-08: Ghost UTxO as Dust Attack
**Confirms: exploit_ghost_utxo_register_succeeds**

An attacker can register an agent while simultaneously creating N ghost UTxOs at the script address (each with only lovelace). Each ghost costs only the minimum lovelace for a UTxO but permanently clutters the script address. Over time, a registry with many ghost UTxOs becomes expensive to query (every indexer must process them) and creates confusion for users browsing the registry. The attacker pays only the minimum deposit for the one valid registration — the ghost UTxOs cost only their own lovelace minimum (recoverable if there were a way to spend them, which there isn't).

---

## Attack Chains (Multi-Step Scenarios)

### Chain A: Registry Pollution + Reputation Attack
1. Attacker registers 100 agents with no owner signature (RT-07) using public VKHs of known entities
2. Each registration costs 10 AP3X + fees
3. Registry is polluted with fake entries under legitimate identities
4. Off-chain tools show these entities as "registered agents" when they are not
5. Damage: Confusion, loss of trust in registry as identity layer

### Chain B: Orphan Burn + Ghost UTxO Combination
1. Attacker registers a legitimate agent (get a foothold)
2. Creates a ghost UTxO during registration (RT-08)
3. Later triggers an orphan burn on the ghost UTxO — wait, there's no NFT in the ghost, so burn can't reference it
4. **Revised:** Attacker registers legitimately, then triggers orphan burn on their own NFT deliberately — locks their own deposit but destroys the NFT, leaving ghost UTxO from step 2 permanently. The orphan burn + ghost are independent vectors that compound on-chain clutter.

### Chain C: Front-Run + Impersonation
1. Alice announces she will register as agent "AliceBot" (off-chain)
2. Attacker front-runs (RT-01) with Alice's expected name/details but different (attacker-controlled) owner VKH
3. Alice's registration attempt fails (seed consumed)
4. Registry has an "AliceBot" entry controlled by attacker
5. Alice registers again with different seed — now two "AliceBot" entries exist
6. Off-chain tools and users cannot determine which is legitimate without additional signals

---

## eUTXO-Specific Risks

### Reference Input Abuse
Plutus V3 supports reference inputs (UTxOs read without spending). The contract doesn't use reference inputs currently, but if a future upgrade added a configuration UTxO as a reference input, any caller could substitute a fake reference input. Not relevant to current contract, noted for future upgrades.

### Concurrency and Registry Scale
As the registry grows to hundreds or thousands of agents, `aiken check` tests remain fast (unit tests, no chain state). But on-chain operations that query the full script address UTxO set (like indexers iterating all agents) become expensive. This is not a validator concern but an ecosystem concern.

### Double Satisfaction
In eUTXO, "double satisfaction" occurs when one output satisfies two validators' checks simultaneously. In this contract, the `list.any` output matching in `validate_update` creates a theoretical double satisfaction risk: if a TX spends two different agent UTxOs simultaneously (both with Update redeemer), and produces only one continuing output, that single output might satisfy both validators' `list.any` checks. The deposit would effectively be halved.

**This is a potential High severity finding.** Concrete scenario:
1. Owner controls two agent UTxOs (agent A and agent B), each with 10 AP3X
2. Constructs a TX spending both with Update redeemer
3. Produces only one continuing output with 10 AP3X (not 20)
4. Both `validate_update` calls succeed (each finds the one valid output via `list.any`)
5. 10 AP3X is effectively stolen from the registry (the second deposit disappears)

This requires owning both UTxOs, so it's primarily a self-attack for deposit recovery — but it means an owner can recover one deposit without deregistering either agent.

---

## Severity Assessment

| Finding | ID | Severity | Novel? |
|---------|-----|---------|--------|
| Double satisfaction — dual update deposit extraction | RT-DS | **Critical** | ✅ Novel |
| Register + Burn in single TX (instant orphan) | RT-02 | High | ✅ Novel |
| Front-run + impersonation (no owner sig) | RT-01 | Medium | ✅ Novel (chain) |
| Large datum bloat / economic griefing | RT-03 | Low-Medium | ✅ Novel |
| Orphan burn (self-harm) | RT-05 | Medium | Confirms the test writer |
| Script credential owner (targeted) | RT-06 | High | Confirms the test writer |
| No owner auth — registry pollution | RT-07 | Medium | Confirms the test writer |
| Ghost UTxO dust attack | RT-08 | Low-Medium | Confirms the test writer |

---

## Inputs for the security engineer (Priority Order)

1. **[Critical] Double satisfaction on dual Update** — add `own_utxo` to the continuing output check so each spend validator call requires a *distinct* output. Common fix: check that `output.reference_script` or a datum field uniquely identifies the UTxO being continued. Better fix: enumerate inputs, find own input, verify exactly one continuing output at own address.

2. **[High] Burn must be coupled to Deregister spend** — `validate_burn` must verify that a corresponding agent UTxO is being spent in the same TX with Deregister redeemer.

3. **[High] Register must require owner signature** — add `has_credential_signed(tx, agent_datum.owner)` check (read datum from the output, verify owner signed).

4. **[High] Register must validate owner credential type** — reject `Script` credential as owner at registration time.

5. **[Medium] Update must validate new owner credential type** — reject ownership transfer to `Script` credential.

6. **[Medium] Deregister must verify burned NFT name matches UTxO's NFT** — extract NFT name from input, verify same name is in mint field.

7. **[Low-Medium] Limit outputs at script address per TX** — prevent ghost UTxO creation by enforcing at most one output to the script address per register/update.

8. **[Low] Datum field size limits** — consider max byte lengths for name, description, endpoint to prevent datum bloat attacks.
