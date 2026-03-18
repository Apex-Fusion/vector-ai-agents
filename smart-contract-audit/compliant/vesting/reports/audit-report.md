# Vesting — Security Audit Report (v2)

**Date:** 2026-03-18
**Methodology:** v2 — cold read, behavioral/exploit split
**Contract:** Time-locked linear vesting on Vector testnet

---

## Executive Summary

The Vesting contract passes the v2 audit with **no Critical, High, or Medium findings**. The contract demonstrates best-practice eUTXO security patterns: single-script-input guard, output-index pinning, datum continuity verification, and conservative timing. It is the strongest contract in the audit set.

## Findings

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| V-01 | Degenerate datum creates permanent lock | Low | Informational — off-chain concern |
| V-02 | Script credential as beneficiary | Low | Informational — off-chain concern |
| V-03 | `expect` panic on missing lower bound | Informational | By design |
| V-04 | Integer division truncation | Informational | By design, documented |
| V-05 | No cancellation mechanism | Informational | Design choice |

## Live Testnet Assessment

**No exploit attempted** — the contract's defenses are sound. The `script_input_count == 1` guard prevents the double satisfaction attack that was proven on escrow and donation pool. Output-index pinning provides additional defense-in-depth.

The live UTxO at `addr1w90gf20qq...` (10 AP3X) is secure.

## Functionality Verification

All security controls confirmed working via code review:
- Double satisfaction: blocked by `script_input_count == 1`
- Output sharing: blocked by index pinning
- Datum hijacking: blocked by 4-field equality check
- Timing manipulation: blocked by lower-bound-only approach
- Value extraction: blocked by lovelace accounting

## Recommendation

**No code changes required.** SDK developers should validate datums off-chain:
- `total_vesting_amount > 0`
- `vesting_end_time > cliff_time`
- `beneficiary` is a valid VKH (not a script hash)
