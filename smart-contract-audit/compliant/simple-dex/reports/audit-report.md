# Simple DEX — Security Audit Report (v2)

**Date:** 2026-03-18
**Methodology:** v2 — cold read, behavioral/exploit split
**Contract:** Peer-to-peer token swap on Vector testnet

---

## Executive Summary

The Simple DEX passes the v2 audit with **no Critical or High findings**. One Medium finding (DEX-01) identifies a structural gap in value conservation — the validator does not enforce that the taker receives the offered tokens, though this is not exploitable by third parties since the taker controls the transaction.

## Findings

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| DEX-01 | No value conservation on Take (taker tokens not enforced) | Medium | Informational — taker is TX builder |
| DEX-02 | Script credential as maker | Low | Informational — off-chain concern |
| DEX-03 | Taker can overpay | Informational | By design |
| DEX-04 | `expect` panics in ceiling_div | Informational | Defended by prior checks |
| DEX-05 | ADA-for-ADA swap possible | Informational | Degenerate case |

## Live Testnet Assessment

**No exploit attempted** — the contract's defenses are sound. `script_input_count == 1` prevents the double satisfaction attack proven on escrow and donation pool. Output-index pinning provides additional defense.

The live UTxO at `addr1wx3sugchs...` (10 AP3X) is secure.

## Security Controls Verified

- Double satisfaction: ✅ blocked (`script_input_count == 1`)
- Output sharing: ✅ blocked (index pinning)
- Rate manipulation: ✅ blocked (rate in datum, not redeemer)
- Division by zero: ✅ blocked (rate > 0 checks)
- Cancel authorization: ✅ maker signature required
- Take authorization: ✅ open by design (anyone can fill)

## Recommendation

**No code changes required for security.** 

DEX-01 is a design consideration: adding `taker receives locked tokens` check would complete the swap semantics but isn't needed for security (taker builds the TX). Worth discussing with the protocol team for V2 of the contract.

SDK developers should validate:
- `maker` is a valid VKH (not script hash)
- `rate_numerator > 0` and `rate_denominator > 0`
- `offered_asset != desired_asset` (unless intentional)
