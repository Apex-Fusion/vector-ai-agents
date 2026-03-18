# Simple Escrow — Red Team Report (Early Pass)

**Date:** 2026-03-18
**Pass:** Early — against original unmodified contract
**Live testnet:** Yes — 2 UTxOs at `addr1wyy922hxs80kd4upzm95u393ktvkfhdvxsmg6mfklax2h7sglxqqe`

---

## Summary

The Simple Escrow has a **confirmed Critical vulnerability**: double satisfaction via `list.any` output matching. The contract code comments claim this is mitigated, but the mitigation is incorrect. With 2 live UTxOs on testnet (10 + 5 AP3X), this is directly exploitable.

Beyond double satisfaction, the contract has several medium-severity gaps around credential validation and datum construction. The overall threat model assumes a well-behaved SDK, which is insufficient for adversarial conditions.

---

## Novel Attack Vectors

### RT-01: Double Satisfaction — Value Theft (Critical)

**The attack (theoretical, not executed on testnet):**

Two escrow UTxOs at the script address both have the same beneficiary PKH in their datum. The beneficiary constructs a TX that:
1. Spends BOTH escrow UTxOs (inputs contain both)
2. Provides the Claim redeemer with the correct secret for each
3. Creates ONE output paying 10 AP3X to the beneficiary

Both validator invocations see the same output list. Both call `list.any` and find the same 10 AP3X output. Both pass:
- First validator: 10 AP3X >= 10 AP3X ✅
- Second validator: 10 AP3X >= 5 AP3X ✅

The beneficiary receives 10 AP3X while consuming 15 AP3X of locked value. The 5 AP3X difference goes to the transaction's change output — effectively stolen from the escrow.

**Why the code comment is wrong:**

The comment says: *"This defends against double satisfaction: each input's value must be accounted for in a distinct output to the correct beneficiary."*

The word "distinct" is the error. `list.any` provides **no distinctness guarantee**. It finds the first matching output and returns True. The second validator call also finds the same first matching output and also returns True. There is no mechanism to mark an output as "already claimed" by another validator invocation in the same TX.

**Live testnet status:**

The 2 UTxOs at the script address (`6a2225de...#0` = 10 AP3X, `7ebb1933...#0` = 5 AP3X) are directly vulnerable to this attack IF they share the same beneficiary and secret. This needs to be verified by reading their datums.

### RT-02: Front-Running via Mempool Secret Extraction (Medium)

When the beneficiary broadcasts a Claim TX, the secret pre-image is visible in the TX's redeemer data in the mempool. An attacker can:

1. Monitor the mempool for Claim transactions at this script address
2. Extract the `secret` from the redeemer
3. Submit their own Claim TX with the same secret, higher fees, and a different beneficiary output

Wait — the validator checks `list.has(tx.extra_signatories, d.beneficiary)`. The attacker can't sign as the beneficiary. So direct front-running is blocked.

**Revised assessment:** Front-running is **not exploitable** because the beneficiary signature is required. The attacker would need the beneficiary's signing key. The README lists this as a known limitation but it's actually mitigated by the signature check. **Downgraded to Informational.**

### RT-03: Datum Construction Attack — Zero Secret (Medium)

An attacker (or careless SDK) can create an escrow with `secret_hash = blake2b_256("")`. This escrow is trivially claimable by the beneficiary providing `secret = ""`. If the attacker is the "sender" and locks funds for a victim "beneficiary," the victim can claim without knowing any real secret — which may or may not be the attacker's intent.

More critically, if the beneficiary reveals the secret `""` on-chain, anyone monitoring can see that the secret was empty and understand the hash commitment was trivial. This has social/trust implications.

### RT-04: Beneficiary/Sender Collision (Low)

If `d.beneficiary == d.sender`, the same person can both Claim (with secret) and Reclaim (after deadline). This isn't a vulnerability per se — it's a degenerate datum — but it means the escrow provides no counter-party guarantee.

---

## Confirmed Vectors

### RT-05: Script Credential Lockout (Medium)
Confirms exploit test findings. A `Script` hash as `d.beneficiary` permanently blocks Claim (signature check fails). A `Script` hash as `d.sender` permanently blocks Reclaim. If both are script hashes, the escrow is permanently locked.

### RT-06: Deadline Dead Zone (Low)
Confirms behavioral test findings. At the exact deadline millisecond, both `is_entirely_before` and `is_entirely_after` reject. The escrow is in limbo for exactly 1 ms.

---

## Live Testnet Attack Plan (for Final Red Team Pass)

To validate RT-01 on testnet:

1. **Query datums** of the 2 live UTxOs to determine if they share the same beneficiary
2. If same beneficiary: construct a double-satisfaction TX consuming both, paying only max(10, 5) = 10 AP3X
3. Submit to testnet via TX Submit endpoint
4. Verify TX is accepted — proving the exploit works on live chain

If different beneficiaries: need to deploy two new escrows with the same beneficiary to demonstrate.

**Required:** signing key for the beneficiary wallet, access to Ogmios for CBOR TX construction, TX Submit for broadcast.

---

## Severity Assessment

| Finding | ID | Severity | Novel? |
|---------|-----|---------|--------|
| Double satisfaction via list.any | RT-01 | **Critical** | Confirmed (documented but unfixed) |
| Front-running blocked by signature | RT-02 | Informational | Revised down (was Medium) |
| Zero secret hash | RT-03 | Medium | Yes |
| Beneficiary == sender | RT-04 | Low | Yes |
| Script credential lockout | RT-05 | Medium | Confirms test findings |
| Deadline dead zone | RT-06 | Low | Confirms test findings |

---

## Inputs for Security Engineer (Priority Order)

1. **[Critical] Fix double satisfaction** — replace `list.any` with per-input output pinning or `script_input_count == 1`
2. **[Medium] Validate credential type** — reject Script credentials in datum fields
3. **[Low] Consider deadline handling** — document or fix the 1ms dead zone
4. **[Informational] Document front-running non-issue** — signature check blocks it, worth noting explicitly
