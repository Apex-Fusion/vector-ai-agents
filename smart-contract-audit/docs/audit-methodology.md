# Smart Contract Audit Methodology

**Version:** 2.0  
**Author:** Apex Security Audit Team  
**Date:** March 2026  

---

## Executive Summary

This document describes the Apex v2 smart contract audit methodology — a structured, reproducible workflow for security auditing on-chain validators. The methodology was developed through iterative refinement across real-world audits and is designed for AI agent teams, though the workflow is equally applicable to human audit teams.

The core insight driving v2 is: **test the original contract first, then fix, then verify**. This reversal of the traditional audit-fix-test pipeline produces richer findings, cleaner evidence, and higher confidence in remediation. The methodology was validated against the Agent Registry audit (an Aiken-based multi-validator on a Cardano-compatible chain), where v2 independently surfaced all findings from the v1 methodology plus two additional Critical/High vulnerabilities that v1 missed entirely.

The workflow comprises 10 phases, 4 quality gates, and a standardized artifact structure that produces audit-ready deliverables regardless of the source contract's language or toolchain.

---

## Principles

### Test Before Fix (not after)

Traditional audit workflows test after fixing: the auditor finds vulnerabilities, the engineer patches them, and tests are written to confirm the patches work. This creates a confirmation bias — tests are designed to validate known fixes rather than characterize the contract's actual behavior.

The v2 methodology inverts this. The test suite is written against the **original, unmodified contract**. Behavioral tests document what the contract *should* do (based on design intent). Exploit tests document what the contract *shouldn't* do (but currently allows). Both suites are authored before any fixes are applied. This grounds the test suite in the contract's reality, not the auditor's expectations.

When fixes are later applied, the test suite becomes an independent verification tool: behavioral tests must still pass (functionality preserved), and exploit tests must now fail (vulnerabilities blocked). No test rewriting is needed to validate fixes — the evidence is clean by construction.

### Behavioral/Exploit Test Split

Every test in the suite is explicitly classified as either **behavioral** or **exploit**:

- **Behavioral tests** document intended functionality — properties that must hold on both the original and compliant contracts. These are derived from design documentation, stated invariants, and the code reviewer's intent analysis.
- **Exploit tests** document vulnerabilities — attack scenarios that succeed on the original contract. On the compliant (fixed) contract, these tests should fail, confirming the vulnerability is blocked.

This split eliminates the ambiguity inherent in mixed test suites. In the Agent Registry audit, the v1 mixed suite produced a 61/100 pass rate on the compliant contract — a number that required extensive explanation. The v2 split produced two unambiguous statements: "15/15 behavioral tests pass — functionality unchanged" and "9/12 exploit tests now blocked — vulnerabilities patched." External readers immediately understand the evidence.

### Blind Fixing

The security engineer who implements fixes works **without access to previous audit results or fix implementations**. They receive only the finding descriptions and the original contract. This forces independent derivation of fixes, which serves two purposes:

1. **Validation of findings.** If the security engineer independently arrives at the same fix approach, it confirms the finding and its remediation are well-understood.
2. **Discovery of alternatives.** Independent work sometimes produces different (and occasionally superior) implementation choices. In the Agent Registry audit, the v2 security engineer's burn-coupling mechanism was slightly more explicit than the v1 approach — both correct, but the blind derivation surfaced a design variant that enriched the audit's analysis.

### Baked-in Drift Detection

Every fix iteration runs through a behavioral gate: the full behavioral test suite must pass after each change. This catches functionality regressions immediately, not at the end of the audit. The security engineer cannot proceed to the next fix if any behavioral test fails — the drift is caught within the same iteration where it was introduced.

In the Agent Registry audit, 8 of 15 behavioral tests required transaction-construction updates (adding `extra_signatories`) after the owner-signature fix was applied. These were orthogonal to the behavioral properties being tested — the tests adapted to the new security constraint without changing what they verified. One behavioral test was replaced entirely because it documented the vulnerability itself (orphan burn acceptance), which was no longer valid behavior. The methodology treats this as expected: security fixes that change behavior produce explicit, trackable test updates.

### Multiple Review Passes

No single review pass catches everything. The methodology uses at least four distinct review events:

1. **Cold code review** — line-by-line analysis before any testing, grounded in design intent.
2. **Early red team** — adversarial analysis of the original contract, focused on attack chains and platform-specific exploitation patterns.
3. **Delta code review** — review of the security engineer's fixes for correctness, new attack surface, and unintended side effects.
4. **Final red team** — adversarial analysis of the compliant contract, systematically attempting to bypass each fix.

Each pass has a different perspective and catches different classes of issues. The early red team found the double-satisfaction vulnerability in the Agent Registry — a Critical finding that required eUTXO-specific attack knowledge and was not surfaced by the code review alone. The final red team found a Low-severity staking credential variant that only became relevant after the ghost UTxO fix was applied.

---

## Workflow

### Phase 1: Context and Research

**Performed by:** Researcher  
**Input:** Contract source code, design documentation, architecture diagrams, deployment context  
**Deliverable:** Context report (`context.md`)

The researcher establishes the audit's foundation by analyzing the contract's purpose, architecture, threat model, and deployment environment. This phase produces a risk surface map that guides all subsequent work.

**Activities:**
- Review design documentation for stated invariants, trust assumptions, and architectural decisions
- Map the contract's interaction surface (on-chain handlers, off-chain dependencies, external integrations)
- Identify platform-specific properties relevant to security (e.g., eUTXO concurrency model, validator execution semantics, script credential behavior)
- Catalogue trust boundaries: what is enforced on-chain vs. off-chain, who are the authorized actors, what are the asset flows
- Establish a risk framework: which attack categories are relevant given the contract's architecture

*Illustrative example:* In the Agent Registry audit, the researcher identified that the contract relied on a multi-validator pattern where `policy_id == script_hash == payment_credential`. This architectural property became critical context for the code reviewer and red team — it meant NFT presence could be verified without cross-script references, but also that the spend and mint validators shared a single script address with specific implications for output filtering.

**Exit criteria:**
- Risk surface map covers all in-scope components
- Trust boundaries and assumptions are documented
- Platform-specific security properties relevant to the contract are identified
- Context report is reviewed and accepted by the audit lead

---

### Phase 2: Code Review (Cold Read)

**Performed by:** Code reviewer  
**Input:** Contract source code, design documentation, context report  
**Deliverable:** Code review report (`code-review.md`)

The code reviewer performs a line-by-line analysis of all validator logic, comparing the implementation against stated design intent. This is a "cold read" — performed before any testing and without knowledge of specific vulnerabilities. The reviewer's job is to find gaps between what the design says and what the code does.

**Activities:**
- Trace every execution path through each validator handler
- Map each design decision to its implementation and verify completeness
- Identify missing checks, unconstrained fields, and implicit assumptions
- Catalogue specific test scenarios that should verify each finding (prescriptive, not just descriptive)
- Flag code quality issues (e.g., `expect` panics vs. clean `False` returns) separate from security findings

*Illustrative example:* The code reviewer identified that design decision D7 (ownership transfer) was implemented without guarding against the degenerate case of transferring to a Script credential. The design document didn't explicitly exclude it, but the implementation's reliance on `has_credential_signed` (which always returns `False` for Script credentials) meant such a transfer would permanently lock the UTxO. This gap between intent and implementation produced finding AR-TRANSFER-LOCK (High severity).

**Exit criteria:**
- Every validator function has been reviewed line-by-line
- Each design decision is mapped to implementation with gap analysis
- Findings include specific, actionable test scenarios for the test writer
- Code review report is complete with severity classifications

---

### Phase 3: Test Suite (Original Contract)

**Performed by:** Test writer  
**Input:** Code review report (with prescribed test scenarios), design documentation, original contract source  
**Deliverable:** Behavioral test suite, exploit test suite (`tests/behavioral/`, `tests/exploit/`)

The test writer creates two distinct test suites against the **original, unmodified contract**. Both suites must pass on the original contract — behavioral tests confirm intended behavior exists, and exploit tests confirm vulnerabilities are exploitable.

**Activities:**
- Write behavioral tests from design documentation and code reviewer's intent analysis
- Write exploit tests from code reviewer's findings and prescribed attack scenarios
- Verify all tests pass on the original contract (behavioral tests confirm functionality; exploit tests confirm vulnerabilities)
- Ensure each finding has at least one corresponding exploit test
- Document test rationale: what property each test verifies and which finding it relates to

**Behavioral test design principles:**
- Test intended behavior, not implementation details
- Cover edge cases from the design document (empty fields, boundary values, legitimate transfers)
- Include tests for accepted design trade-offs (these document intentional behavior, not bugs)

**Exploit test design principles:**
- Each exploit test demonstrates a specific attack scenario
- Tests should be self-contained: a reader can understand the attack from the test alone
- Include multi-step attack chains where relevant (e.g., front-run + impersonation)

*Illustrative example:* The test writer created 15 behavioral tests covering datum flexibility, deposit handling, ownership transfer, and NFT uniqueness. The 12 exploit tests covered orphan burns, ghost UTxOs, missing owner signatures, script credential attacks, and NFT name mismatches. All 27 tests passed on the original contract, establishing the baseline.

**Exit criteria:**
- All behavioral tests pass on the original contract
- All exploit tests pass on the original contract (confirming vulnerabilities are real)
- Every code review finding has corresponding exploit test coverage
- Test suite is clearly organized into `behavioral/` and `exploit/` directories

---

### Phase 4: Adversarial Analysis (Early Red Team)

**Performed by:** Red team  
**Input:** Original contract source, context report, code review report  
**Deliverable:** Red team report (`red-team-report.md`)

The red team conducts an adversarial analysis of the original contract, looking for attack vectors beyond what the code review identified. This phase is specifically designed to find novel vulnerabilities through attacker-mindset analysis, multi-step attack chains, and platform-specific exploitation patterns.

**Activities:**
- Construct adversarial transaction scenarios that exploit validator logic
- Analyze platform-specific attack patterns (e.g., eUTXO double satisfaction, staking credential variants, multi-input/multi-output edge cases)
- Build multi-step attack chains that combine multiple weaknesses
- Attempt economic attacks (deposit extraction, griefing, front-running)
- Identify attack surfaces that only emerge under concurrent transaction processing

*Illustrative example:* The red team discovered the double-satisfaction vulnerability (RT-DS, Critical) — a finding that required understanding eUTXO-specific properties. If a transaction spent two agent UTxOs simultaneously with Update redeemers, a single continuing output could satisfy both validators' `list.any` checks, allowing deposit extraction. This finding was not surfaced by the code review alone and represents the highest-value contribution of the early red team phase.

**Exit criteria:**
- All identified attack vectors are documented with step-by-step transaction construction
- Severity classifications are assigned based on exploitability and impact
- New findings are fed back to the test writer for exploit test coverage
- Red team report distinguishes between findings already known from code review and novel discoveries

---

### Phase 5: Security Engineering (Fix Loop)

**Performed by:** Security engineer, code reviewer, test writer (iterative)  
**Input:** All findings (code review + red team), original contract, test suites  
**Deliverable:** Fixed contract source, fix notes (`fix-notes.md`), delta review (`delta-review.md`)

The security engineer implements fixes for all findings marked for remediation. This phase operates as an iterative loop: fix → delta review → behavioral check → next fix. The security engineer works **blind** — without access to previous fix implementations.

**Fix loop iteration:**
1. Security engineer implements a targeted fix for one finding
2. Code reviewer performs delta review of the change
3. Test writer runs the behavioral test suite — all tests must pass
4. If behavioral tests fail, the security engineer adjusts the fix
5. Repeat for the next finding

**Activities:**
- Implement minimal, surgical fixes (one finding per change where possible)
- Document each fix: what was changed, why, and what the expected behavioral impact is
- Delta review verifies fix correctness and checks for new attack surface
- Behavioral gate enforces functionality preservation at every iteration
- Update behavioral tests if the fix legitimately changes expected behavior (document the change explicitly)

*Illustrative example:* The security engineer implemented 7 fixes across 4 validation functions. The burn-coupling fix (AR-01) added a `has_script_input` check. The singleton-output fix (AR-02/AR-07) replaced `list.any` with `list.filter` + singleton pattern match. After the owner-signature fix (AR-03), 8 behavioral tests required transaction-construction updates (adding `extra_signatories`) — the test writer updated these with explicit documentation that the underlying behavioral properties were unchanged.

**Exit criteria:**
- All findings marked for remediation have fixes implemented
- Delta review confirms no new attack surface introduced
- All behavioral tests pass on the compliant contract
- Fix notes document every change with rationale
- Any behavioral test modifications are documented and justified

---

### Phase 6: Delta Review

**Performed by:** Code reviewer  
**Input:** Original contract, compliant contract (diff), fix notes  
**Deliverable:** Delta review report (`delta-review.md`)

The code reviewer performs a focused review of all changes between the original and compliant contracts. This is distinct from the fix-loop delta reviews (which are per-fix) — this is a holistic review of the complete diff.

**Activities:**
- Review every line changed between original and compliant versions
- Verify each fix addresses its intended finding without over-correction
- Check for interactions between fixes (e.g., fix A's constraint combined with fix B's constraint creating unintended behavior)
- Identify any new code patterns that warrant additional testing
- Document design trade-offs introduced by fixes (e.g., batching restrictions)

*Illustrative example:* The delta review identified that the singleton-output constraint (AR-02/AR-07 fixes) meant only one Register or Update operation could occur per transaction. This was flagged as a deliberate and justified trade-off — batching was the double-satisfaction attack vector. The review also noted that the `and {}` short-circuit behavior in Aiken was load-bearing for the safety of `expect` statements in new helper functions.

**Exit criteria:**
- Complete diff reviewed between original and compliant contracts
- No unintended interactions between fixes identified
- Design trade-offs documented
- Any newly identified concerns fed back to the security engineer or test writer

---

### Phase 7: Deployment Validation

**Performed by:** Deployment validator  
**Input:** Compliant contract source, toolchain configuration  
**Deliverable:** Deployment validation report (`deployment-validation.md`)

The deployment validator verifies that the compliant contract compiles successfully with the target toolchain and produces a deployable artifact. This phase catches build issues, dependency problems, and configuration mismatches that could prevent deployment.

**Activities:**
- Compile the compliant contract with the target compiler and version
- Run the full test suite through the compiler's native test framework
- Verify all dependencies are present and at correct versions
- Document the build environment (compiler version, stdlib version, target platform)
- Produce the deployment artifact (e.g., Plutus blueprint, compiled bytecode)
- Verify deployment configuration (network settings, address construction, script hash)

*Illustrative example:* The deployment validator compiled the compliant Agent Registry contract using Aiken v1.1.21. The `aiken check` command executed all 26 tests (14 behavioral + 12 exploit), confirming the test suite ran on the actual compiler — not just analytically. The validator documented the Aiken binary path, stdlib v3.0.0 dependency, and Vector testnet configuration (networkId, address format).

**Exit criteria:**
- Contract compiles without errors
- All tests pass through the compiler's native test framework
- Deployment artifact is generated
- Build environment is documented for reproducibility
- Pre-deployment checklist is complete

---

### Phase 8: Final Red Team

**Performed by:** Red team  
**Input:** Compliant contract source, all finding reports, fix notes  
**Deliverable:** Final red team report (`final-red-team-report.md`)

The red team conducts a second adversarial analysis, this time against the **compliant (security-hardened) contract**. The focus shifts from finding new vulnerabilities to systematically attempting to bypass the applied fixes.

**Activities:**
- For each fix, construct transactions that attempt to circumvent the new constraint
- Test edge cases of fix implementations (e.g., staking credential variants for address-based filters)
- Analyze whether fixes interact to create new attack surfaces
- Attempt multi-step attacks that combine original weaknesses with fix limitations
- Report any new findings discovered against the compliant version

*Illustrative example:* The final red team confirmed all 7 fixes were sound — no bypass vectors were found for any Critical, High, or Medium remediation. One new Low-severity finding emerged: the ghost UTxO fix filtered by exact address equality (`stake_credential: None`), but outputs with a non-None staking credential could escape the filter while still being locked by the spend validator. This was classified as Informational given its minimal real-world impact.

**Exit criteria:**
- Every fix has been tested with bypass attempts
- No new Critical or High findings against the compliant contract
- Any new findings are classified and documented
- Final red team report confirms fix soundness or identifies gaps

---

### Phase 9: Final Test Sweep

**Performed by:** Test writer  
**Input:** Final red team report, compliant contract, both test suites  
**Deliverable:** Updated test suites, test report (`test-report.md`)

The test writer performs a final reconciliation of the test suites against the compliant contract. Any new findings from the final red team are incorporated as additional exploit tests. The complete test suite is run and documented.

**Activities:**
- Add exploit tests for any new findings from the final red team
- Run the complete behavioral test suite against the compliant contract — all must pass
- Run the complete exploit test suite against the compliant contract — blocked exploits must fail
- Document any exploit tests that still pass on the compliant contract (accepted design trade-offs)
- Produce the final test report with summary statistics

**Expected results on the compliant contract:**
- Behavioral tests: all pass (functionality preserved)
- Exploit tests: most fail (vulnerabilities blocked); some may pass by design (accepted trade-offs)

*Illustrative example:* The final sweep produced 15 behavioral tests (all passing) and 15 exploit tests (13 blocked, 2 passing by design). The 2 passing exploit tests documented the accepted deposit-destination trade-off and the script-credential consequence tests (negated assertions proving the lock condition). The test report included a summary table mapping each test to its finding, severity, and fix status.

**Exit criteria:**
- All behavioral tests pass on the compliant contract
- Exploit test results are documented with explanations for any that still pass
- Test report includes complete summary table
- Test suite is organized and ready for inclusion in the audit deliverables

---

### Phase 10: Audit Report

**Performed by:** Report author  
**Input:** All phase deliverables (context, code review, red team reports, fix notes, delta review, deployment validation, test report)  
**Deliverable:** Final audit report (`audit-report.md`)

The report author synthesizes all findings, evidence, and analysis into a comprehensive audit report suitable for external publication. This is a writing and synthesis phase — no new analysis is performed.

**Activities:**
- Compile all findings into a unified findings table with consistent severity classifications
- Write detailed descriptions for each finding (description, impact, fix applied, status)
- Document the methodology used (scope, tools, process)
- Summarize behavioral verification results (functionality preserved)
- List accepted trade-offs with rationale
- Produce deployment readiness assessment with pre-deployment checklist
- Write executive summary and conclusion

**Report structure:**
1. Executive summary and overall verdict
2. Scope and methodology
3. Contract overview (architecture, data model, key design decisions)
4. Findings summary table
5. Detailed findings (each with description, impact, fix, status)
6. Functionality verification (behavioral properties confirmed unchanged)
7. Accepted trade-offs with rationale
8. Deployment readiness (build verification, pre-deployment checklist)
9. Conclusion

*Illustrative example:* The Agent Registry audit report documented 10 findings (2 Critical, 3 High, 2 Medium, 3 Low/Informational), 7 fixes, 2 accepted trade-offs, and 1 informational item. The report's behavioral verification section confirmed all 14 design properties were preserved by the security fixes, with explicit documentation of the 8 tests that required transaction-construction updates.

**Exit criteria:**
- All findings are documented with consistent format and severity
- Evidence references specific test results and review reports
- Deployment readiness assessment is complete
- Executive summary accurately reflects the audit's conclusions
- Report is self-contained — an external reader can understand the audit without accessing other artifacts

---

## Artifact Structure

### Folder Layout (original / build / compliant)

The audit produces a three-directory structure that separates concerns:

```
audit-project/
├── original/           ← Verbatim, untouched copy of the submitted contract
│   ├── contracts/      ← Source files in their original format
│   ├── docs/           ← Design documentation, specs, intent documents
│   ├── tests/          ← Original test suite (if provided)
│   └── config          ← Original project configuration
├── build/              ← Toolchain-specific build environment
│   ├── contracts/      ← Fixed contracts in toolchain layout
│   ├── tests/          ← Full test suite in toolchain format
│   └── config          ← Build configuration
├── compliant/          ← Standardized audit output
│   ├── contracts/      ← Fixed contract sources (flat, readable)
│   ├── tests/
│   │   ├── behavioral/ ← Functional tests (must pass on compliant)
│   │   └── exploit/    ← Exploit tests (must fail on compliant)
│   └── reports/        ← All audit reports
└── README.md           ← Project overview and build verification instructions
```

**`original/`** — Chain of custody. This directory is never modified after initial population. Whatever format the external submission uses, it is preserved verbatim. This allows anyone to verify the audit was conducted against the actual submitted code.

**`build/`** — Toolchain-specific. This directory contains the contract in whatever layout the compiler requires. It is the working directory for `aiken check`, `forge test`, or equivalent. It can be regenerated from `compliant/` if needed.

**`compliant/`** — Standardized output. This directory has a consistent structure regardless of the source language. Reports, tests, and fixed contracts are organized in a predictable layout. This is what gets published.

### Report Documents

All reports are written in Markdown and stored in `compliant/reports/`:

| Report | Phase | Author | Purpose |
|--------|-------|--------|---------|
| `context.md` | Phase 1 | Researcher | Risk surface map, trust boundaries, platform properties |
| `code-review.md` | Phase 2 | Code reviewer | Line-by-line analysis, intent vs. implementation gaps |
| `red-team-report.md` | Phase 4 | Red team | Adversarial analysis of original contract |
| `fix-notes.md` | Phase 5 | Security engineer | Documentation of each fix with rationale |
| `delta-review.md` | Phase 6 | Code reviewer | Review of complete diff, interaction analysis |
| `deployment-validation.md` | Phase 7 | Deployment validator | Build verification, environment documentation |
| `final-red-team-report.md` | Phase 8 | Red team | Bypass attempts against compliant contract |
| `test-report.md` | Phase 9 | Test writer | Final test results with summary statistics |
| `audit-report.md` | Phase 10 | Report author | Comprehensive final report for external publication |
| `comparison-report.md` | Optional | Report author | Methodology comparison (if applicable) |

### Test Suite Organization

Tests are organized by type, not by finding:

```
compliant/tests/
├── behavioral/
│   ├── register_tests.ak      ← Registration behavior (datum flexibility, deposit, owner)
│   ├── update_tests.ak        ← Update behavior (transfer, deposit changes)
│   ├── deregister_tests.ak    ← Deregistration behavior (deposit destination, NFT burn)
│   └── utility_tests.ak       ← Helper function behavior (NFT naming, credential checks)
└── exploit/
    ├── critical_exploits.ak   ← Critical severity attack scenarios
    ├── high_exploits.ak       ← High severity attack scenarios
    └── medium_exploits.ak     ← Medium severity attack scenarios
```

Each test file includes comments documenting:
- Which finding the test relates to (by ID)
- What property or vulnerability is being tested
- Expected behavior on original vs. compliant contracts

---

## Quality Gates

Four quality gates enforce rigor throughout the audit. Each gate must pass before work proceeds.

### Behavioral Gate (functionality preserved)

**When:** After every fix iteration (Phase 5) and during final sweep (Phase 9)  
**Criterion:** All behavioral tests pass on the compliant contract  
**Failure action:** Security engineer must adjust the fix to preserve functionality before proceeding

The behavioral gate is the methodology's primary defense against regressions. It runs after every individual fix, not just at the end. This means functionality drift is caught within the iteration that introduced it.

A behavioral test failure after a fix indicates one of two situations:
1. The fix inadvertently broke intended functionality → the fix must be adjusted
2. The fix legitimately changes expected behavior → the behavioral test must be updated with explicit documentation of why

Both outcomes require deliberate action. Silent regressions are structurally impossible.

### Exploit Gate (vulnerabilities blocked)

**When:** During final sweep (Phase 9)  
**Criterion:** Exploit tests targeting fixed vulnerabilities fail on the compliant contract (exploit is blocked)  
**Failure action:** Security engineer must strengthen the fix; finding is not resolved until the exploit test fails

An exploit test that still passes on the compliant contract means the fix is incomplete. The only exception is an explicit "accepted" designation — the finding was evaluated and deliberately left unfixed with documented rationale.

### Build Gate (compilation + tests pass)

**When:** During deployment validation (Phase 7)  
**Criterion:** Contract compiles without errors; all tests pass through the compiler's native test framework  
**Failure action:** Security engineer must resolve compilation or test failures before proceeding

The build gate verifies that the compliant contract is a real, deployable artifact — not just an analytically-reviewed document. Tests must run on the actual compiler, not just be reviewed for correctness.

### Red Team Gate (no new Critical/High findings)

**When:** After final red team (Phase 8)  
**Criterion:** No new Critical or High severity findings against the compliant contract  
**Failure action:** New Critical/High findings re-enter the fix loop (Phase 5) for remediation

If the final red team discovers new Critical or High findings, the audit loops back to Phase 5. The fix loop repeats: fix → delta review → behavioral check. After fixes, a targeted red team pass confirms the new fixes are sound. Only when the red team gate passes cleanly does the audit proceed to final sweep and reporting.

---

## Methodology Evolution (v1 → v2)

The v2 methodology was developed in response to specific limitations observed in v1 audits.

**v1 workflow:** Researcher → Security engineer (fix) → Test writer (tests, retrospective) → Red team → Report author

**v2 workflow:** Researcher → Code reviewer (cold read) → Test writer (test original) → Red team (early) → Security engineer loop [fix → delta review → behavioral check] → Deployment validator → Red team (final) → Test writer (final sweep) → Report author

| Aspect | v1 | v2 |
|--------|----|----|
| Test timing | Written after fixes, knowing vulnerabilities | Written before fixes, against original contract |
| Test structure | Single mixed suite | Explicit behavioral/exploit split |
| Behavioral gate | End-of-audit check only | Every fix iteration |
| Code review | Single pass after audit | Cold read before tests + delta review after fixes |
| Red team | Single pass against original | Early pass (feeds tests) + final pass (verifies fixes) |
| Deployment validation | Not included | Real compiler build verification |
| Fix independence | Engineer had prior audit context | Engineer works blind |
| Finding provenance | Tests designed to prove known findings | Code reviewer grounds tests in design intent |

**Key v2 advantages validated in practice:**

1. **Richer finding set.** v2 surfaced 2 additional Critical/High findings not found in v1 (double satisfaction, ownership transfer to script credential). v2 was a strict superset of v1 findings.
2. **Cleaner evidence.** The behavioral/exploit split produces unambiguous statistics for external readers.
3. **Higher fix confidence.** Blind engineering, delta review, and final red team provide three independent verification layers.
4. **Better grounding.** The cold code review ties the test suite to the original author's design intent rather than the auditor's findings.
5. **Deployable artifact.** The deployment validator produces a verified build, not just analysis.

---

## Applying This Methodology

### For Internal Contracts

When auditing contracts developed by your own team:

1. **Enforce separation.** The security engineer who fixes the contract must not be the original developer. The code reviewer must not have been involved in the contract's design. Fresh eyes catch what familiarity hides.
2. **Treat design docs as ground truth.** The cold read compares implementation against the design document. If the design document is incomplete, completing it is Phase 1 work — the researcher interviews the development team and produces a design document before the code review begins.
3. **Use the full workflow.** It is tempting to skip phases for internal contracts ("we know our own code"). Don't. The Agent Registry audit found Critical vulnerabilities in code written by experienced developers who followed sound architectural patterns. The vulnerabilities emerged from implicit assumptions, not incompetence.
4. **Preserve the original.** Even for internal contracts, the `original/` directory must contain the pre-audit code. This provides the baseline for behavioral testing and the chain of custody for the audit record.

### For External Contract Review

When auditing contracts submitted by external parties:

1. **Chain of custody is paramount.** The `original/` directory is the authoritative record of what was submitted. Hash the contents at intake and include the hash in the audit report. Any discrepancy between the submitted code and the audited code invalidates the audit.
2. **Demand design documentation.** If the submitter does not provide design documentation, the researcher must produce it during Phase 1 — but flag this in the audit report. An audit without design context can identify implementation bugs but cannot identify intent violations.
3. **Scope carefully.** Define what is in scope (on-chain validators) and out of scope (off-chain SDK, infrastructure, integrations) explicitly. Out-of-scope components should be noted where they affect the trust model (e.g., "spend limits are enforced only off-chain").
4. **Include deployment validation.** External submitters may have untested build configurations. Phase 7 catches issues that would prevent deployment and documents the exact build environment for reproducibility.

### Scaling to Multiple Contracts

When auditing a system of multiple interacting contracts:

1. **One audit project per contract, shared context.** Each contract gets its own `original/build/compliant` structure, but the researcher's context report covers the entire system. Cross-contract interactions are documented in the context report and tested as part of the red team phases.
2. **Sequence by dependency.** Audit contracts in dependency order: the contract that others reference is audited first. Its compliant version becomes a known-good component for subsequent audits.
3. **Cross-contract red team.** The early and final red team phases should include attack scenarios that span multiple contracts (e.g., exploiting interactions between a minting policy and a spending validator). These tests may require a dedicated integration test suite beyond the per-contract behavioral/exploit split.
4. **Parallelize where independent.** Contracts with no cross-references can be audited in parallel. The researcher and code reviewer phases can run concurrently for independent contracts, with the red team phase covering cross-contract scenarios after individual reviews are complete.

---

*This methodology is a living document. It will be updated as the team conducts additional audits and identifies further refinements.*
