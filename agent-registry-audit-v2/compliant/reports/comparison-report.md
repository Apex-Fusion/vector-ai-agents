# Agent Registry — Methodology Comparison Report (v1 vs v2)

**Generated:** 2026-03-18
**Purpose:** Document the evolution in audit methodology between v1 and v2, and compare findings/evidence quality between the two runs against the same contracts.

---

## Methodology Overview

| Aspect | v1 | v2 |
|--------|----|----|
| **Workflow** | Audit → fix → test retrospectively | Test original first → fix → verify |
| **Test suite** | Written post-audit, mixed behavioral+exploit | Split behavioral/exploit from the start |
| **Behavioral gate** | None — checked only at end | Baked into every the security engineer iteration |
| **Code review** | Single pass after audit | Cold read before tests + delta review after fixes |
| **Red team** | Single pass against original | Early pass (feeds tests) + final pass (compliant version) |
| **Deployment validation** | Not included | the deployment validator validates Aiken build + `aiken check` passes |
| **Blind fixing** | the security engineer had v1 output as reference | the security engineer worked blind — independent derivation |
| **Finding provenance** | Tests written knowing the findings | the code reviewer's cold read feeds the test writer — grounded in intent |

---

## Workflow Comparison

### v1 Workflow
```
the research analyst → the security engineer (fix) → the test writer (tests, retrospective) → the red team → the report author → comparison
```

### v2 Workflow
```
the research analyst → the code reviewer (cold read) → the test writer (test original: behavioral + exploit split)
→ the red team (early red team) → the security engineer loop [fix → the code reviewer delta → the test writer behavioral check]
→ the deployment validator (deployment validation) → the red team (final red team) → the test writer (final sweep)
→ the report author → comparison
```

---

## Findings Comparison

### Findings in both v1 and v2
Both runs independently identified the same core vulnerabilities:

| Finding | v1 ID | v2 ID | Severity |
|---------|-------|-------|----------|
| Burn not coupled to deregister (orphan burn) | AR-03 | AR-ORPHAN-BURN | Critical |
| No owner signature on register | AR-05 | AR-NO-OWNER-AUTH | High |
| Script credential as owner (permanent lock) | AR-06 | AR-SCRIPT-OWNER | High |
| Ghost UTxO via list.any on outputs | AR-09 | AR-GHOST-UTXO | Medium |
| Deregister NFT name not verified | AR-10 | AR-NFT-NAME-MISMATCH | Medium |
| Burn quantity validation (positive qty) | AR-06 | (covered) | Medium |

### Findings unique to v2

| Finding | ID | Severity | How found |
|---------|-----|---------|-----------|
| Double satisfaction on dual Update | RT-DS | **Critical** | the red team's red team — eUTXO-specific attack |
| Ownership transfer to Script credential | AR-TRANSFER-LOCK | High | the code reviewer's cold read (intent vs implementation) |
| Front-run + impersonation chain | RT-01 | Medium | the red team attack chain analysis |
| Register + Burn in single TX | RT-02 | High | the red team eUTXO-specific analysis |
| Datum bloat / economic griefing | RT-03 | Low-Medium | the red team novel finding |
| Staking credential ghost UTxO variant | BORKA-FINAL-01 | Low | the red team final pass on compliant version |

### Findings unique to v1 (not surfaced in v2)
None — v2 is a superset of v1 findings.

---

## Key Differences in Evidence Quality

### Test suite structure

**v1:** Single mixed test file (100 tests total). Tests were written knowing the vulnerabilities, so they simultaneously document both intended behavior and exploit scenarios. The 61/100 pass rate on the compliant version required explanation.

**v2:** Explicit behavioral/exploit split:
- `behavioral/` (15 tests) — all pass on compliant. the report author can state: *"All 15 behavioral tests pass — functionality is unchanged."*
- `exploit/` (12 tests) — 9 blocked on compliant. the report author can state: *"9 of 12 exploit tests now fail — these vulnerabilities are patched."*

The split makes the evidence much cleaner for external readers.

### Finding provenance

**v1:** the test writer's tests were written with knowledge of the audit findings — tests were designed to prove the findings exist rather than to characterize original intent.

**v2:** the code reviewer's cold read compares DESIGN.md (stated intent) against the actual implementation *before* any testing. This grounds the test suite in the original author's intent rather than the auditor's findings. The `ownership transfer to Script credential` finding (AR-TRANSFER-LOCK) came specifically from the code reviewer reading D7 and noticing the implementation didn't guard against the degenerate case the design didn't explicitly exclude.

### Red team coverage

**v1:** Single red team pass against original. No final pass against compliant version.

**v2:** Early pass fed the test writer's exploit tests. Final pass confirmed fixes and found one residual Low (staking credential variant). The two-pass structure gives higher confidence in the compliant version.

### Blind fixing

**v1:** the security engineer had access to any previous work.

**v2:** the security engineer worked blind — she independently derived fixes that covered all 7 findings, with identical core approaches to v1 on most fixes but different implementation choices on the burn coupling (both correct, v2's slightly more explicit in its coupling mechanism).

---

## Test Results Comparison

### v1 Results (4-variant methodology)

| Variant | Contracts | Tests | Result |
|---------|-----------|-------|--------|
| original | Original | Original (30) | 30/30 ✅ |
| validated | Compliant | Original (30) | 25/30 ⚠️ (5 expected failures) |
| tested | Original | Extended (100) | 100/100 ✅ (exploits proven) |
| final | Compliant | Extended (100) | 61/100 🔒 (39 blocked) |

### v2 Results

| Suite | Contracts | Tests | Result |
|-------|-----------|-------|--------|
| Original (30) | Original | Original | 30/30 ✅ (baseline) |
| Behavioral (15) | Compliant | Behavioral | 15/15 ✅ (functionality preserved) |
| Exploit (12) | Compliant | Exploit | 9 blocked, 3 pass ✅ |
| Full `aiken check` | Compliant | All (26) | 26/26 ✅ (real compiler) |

**Key v2 advantage:** Tests were run on the actual Aiken compiler (`aiken check`) — not just analyzed. v1 comparison testing was conducted analytically.

---

## Methodology Verdict

v2 produces:
1. **Richer finding set** — 2 additional Critical/High findings (double satisfaction, transfer-to-script-credential) not surfaced in v1
2. **Cleaner evidence** — behavioral/exploit split makes the report clearer for external readers
3. **Higher confidence in fixes** — blind the security engineer run, the code reviewer delta, the red team final pass, the deployment validator real build all contribute
4. **Better grounding** — the code reviewer's cold read ties the test suite to original intent rather than to audit findings
5. **Deployment artifact** — the deployment validator's real `aiken check` run produces a verified build, not just analysis

The v1 4-variant comparison report remains a useful evidence artifact structure and is preserved in v2 as well. The two approaches are complementary — v2 subsumes v1's evidence while adding the richer workflow trail.

---

## What v2 Would Catch That v1 Missed

The double satisfaction finding (RT-DS) is the clearest example of v2's added value. It required:
- the red team's explicit focus on eUTXO-specific attack patterns
- Knowledge of `list.any` semantics at the validator level
- A multi-step attack scenario (two UTxOs in one TX)

In v1, the test writer wrote tests with knowledge of the specific vulnerabilities the security engineer had already fixed. In v2, the red team's red team was adversarial and found something new. The blind the security engineer run then had to fix it independently — and did.

**The double satisfaction finding alone justifies the v2 workflow for external contract audits.**
