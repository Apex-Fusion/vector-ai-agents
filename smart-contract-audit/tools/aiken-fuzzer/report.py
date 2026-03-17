"""
report.py — Generate a markdown fuzz session report.

The report covers:
- Session metadata (contract, seed, case count)
- Type schema summary
- Results breakdown (pass / fail / error / unexpected)
- Vulnerability flags (unexpected successes with invalid inputs)
- Edge case findings
- Recommendations
"""

from __future__ import annotations
import json
from datetime import datetime
from typing import Any, Optional
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------

@dataclass
class FuzzCase:
    case_id: int
    mode: str                          # "random", "edge_case", "invalid"
    input_value: Any                   # the generated value
    input_json: str                    # JSON representation
    expected_result: str               # "pass" or "fail"
    actual_result: str                 # "pass", "fail", "error", "timeout"
    is_unexpected: bool = False        # True if result != expected
    error_msg: str = ""
    notes: str = ""


@dataclass
class FuzzSessionResult:
    contract_dir: str
    validator_title: str
    seed: Optional[int]
    total_cases: int
    timestamp: str = field(default_factory=lambda: datetime.utcnow().isoformat())
    cases: list[FuzzCase] = field(default_factory=list)
    schema_summary: str = ""
    aiken_version: str = ""

    # Aggregates (computed in report)
    @property
    def passed(self) -> int:
        return sum(1 for c in self.cases if c.actual_result == "pass")

    @property
    def failed(self) -> int:
        return sum(1 for c in self.cases if c.actual_result == "fail")

    @property
    def errors(self) -> int:
        return sum(1 for c in self.cases if c.actual_result == "error")

    @property
    def unexpected(self) -> list[FuzzCase]:
        return [c for c in self.cases if c.is_unexpected]

    @property
    def vulnerabilities(self) -> list[FuzzCase]:
        """Cases where invalid input unexpectedly passed = potential vulnerability."""
        return [c for c in self.cases
                if c.is_unexpected and c.expected_result == "fail" and c.actual_result == "pass"]


# ---------------------------------------------------------------------------
# Report generator
# ---------------------------------------------------------------------------

class ReportGenerator:

    def generate(self, result: FuzzSessionResult) -> str:
        """Generate a complete markdown report for a fuzz session."""
        sections = [
            self._header(result),
            self._summary(result),
            self._schema_section(result),
            self._results_section(result),
            self._vulnerability_section(result),
            self._unexpected_section(result),
            self._edge_case_section(result),
            self._recommendations(result),
            self._footer(result),
        ]
        return "\n\n".join(s for s in sections if s)

    def _header(self, r: FuzzSessionResult) -> str:
        return f"""# Aiken Fuzzer Report

**Contract:** `{r.contract_dir}`
**Validator:** `{r.validator_title}`
**Generated:** {r.timestamp} UTC
**Seed:** {r.seed if r.seed is not None else "random (unreproducible)"}
**Aiken Version:** {r.aiken_version or "unknown"}
**Tool:** aiken-fuzzer v0.1.0"""

    def _summary(self, r: FuzzSessionResult) -> str:
        total = r.total_cases
        unexpected_count = len(r.unexpected)
        vuln_count = len(r.vulnerabilities)

        status = "✅ CLEAN" if vuln_count == 0 else f"🚨 {vuln_count} POTENTIAL VULNERABILITIES FOUND"

        return f"""## Summary

| Metric | Value |
|--------|-------|
| Total cases | {total} |
| Passed (expected ✓) | {r.passed} |
| Failed (expected ✗) | {r.failed} |
| Errors | {r.errors} |
| Unexpected results | {unexpected_count} |
| **Potential vulnerabilities** | **{vuln_count}** |

**Overall status:** {status}"""

    def _schema_section(self, r: FuzzSessionResult) -> str:
        if not r.schema_summary:
            return ""
        return f"""## Type Schema

```
{r.schema_summary}
```"""

    def _results_section(self, r: FuzzSessionResult) -> str:
        if not r.cases:
            return "## Results\n\n*No cases recorded.*"

        lines = ["## Results\n"]
        lines.append("| ID | Mode | Expected | Actual | Unexpected | Notes |")
        lines.append("|----|----- |----------|--------|------------|-------|")

        for c in r.cases[:50]:  # Cap display at 50 rows
            unexpected_flag = "⚠️" if c.is_unexpected else ""
            notes = c.notes[:60] + "..." if len(c.notes) > 60 else c.notes
            lines.append(
                f"| {c.case_id} | {c.mode} | {c.expected_result} | {c.actual_result} "
                f"| {unexpected_flag} | {notes} |"
            )

        if len(r.cases) > 50:
            lines.append(f"\n*... and {len(r.cases) - 50} more cases (showing first 50)*")

        return "\n".join(lines)

    def _vulnerability_section(self, r: FuzzSessionResult) -> str:
        vulns = r.vulnerabilities
        if not vulns:
            return "## Vulnerabilities\n\nNo vulnerabilities detected."

        lines = ["## 🚨 Potential Vulnerabilities\n"]
        lines.append(
            "> **These cases should have been REJECTED but were ACCEPTED.**\n"
            "> Review each one carefully — they may represent exploitable bugs.\n"
        )

        for i, c in enumerate(vulns, 1):
            lines.append(f"### Vulnerability #{i} (Case {c.case_id})")
            lines.append(f"- **Mode:** {c.mode}")
            lines.append(f"- **Expected:** FAIL (input is invalid)")
            lines.append(f"- **Actual:** PASS (contract accepted it)")
            if c.notes:
                lines.append(f"- **Notes:** {c.notes}")
            lines.append("\n**Input:**")
            lines.append(f"```json\n{c.input_json}\n```")
            lines.append("")

        return "\n".join(lines)

    def _unexpected_section(self, r: FuzzSessionResult) -> str:
        unexpected = [c for c in r.unexpected if c not in r.vulnerabilities]
        if not unexpected:
            return ""

        lines = ["## Unexpected Results (Non-Vulnerability)\n"]
        lines.append(
            "> These results were unexpected but are NOT necessarily vulnerabilities.\n"
            "> (e.g., valid inputs that failed — may indicate a test setup issue)\n"
        )

        for c in unexpected[:20]:
            lines.append(f"**Case {c.case_id}** (mode={c.mode})")
            lines.append(f"- Expected: {c.expected_result}, Got: {c.actual_result}")
            if c.error_msg:
                lines.append(f"- Error: `{c.error_msg[:200]}`")
            lines.append("")

        if len(unexpected) > 20:
            lines.append(f"*... and {len(unexpected) - 20} more*")

        return "\n".join(lines)

    def _edge_case_section(self, r: FuzzSessionResult) -> str:
        edge = [c for c in r.cases if c.mode == "edge_case"]
        if not edge:
            return ""

        lines = ["## Edge Case Results\n"]
        lines.append("| Case | Input Summary | Result | Unexpected |")
        lines.append("|------|---------------|--------|------------|")

        for c in edge:
            summary = c.input_json[:60].replace("\n", " ") + "..."
            flag = "⚠️" if c.is_unexpected else "✓"
            lines.append(f"| {c.case_id} | `{summary}` | {c.actual_result} | {flag} |")

        return "\n".join(lines)

    def _recommendations(self, r: FuzzSessionResult) -> str:
        vulns = r.vulnerabilities
        errors = r.errors

        lines = ["## Recommendations\n"]

        if vulns:
            lines.append("### 🔴 Critical — Investigate Immediately\n")
            lines.append(
                f"- {len(vulns)} inputs that should have been rejected were accepted.\n"
                "  Each one is a candidate exploit path. Review the validator logic\n"
                "  for the affected constructors and add explicit rejection tests."
            )
            lines.append("")

        if errors:
            lines.append("### 🟡 Warnings — Test Infrastructure\n")
            lines.append(
                f"- {errors} cases produced errors (not pass/fail). This may indicate\n"
                "  test infrastructure issues (malformed inputs, serialization bugs)\n"
                "  rather than contract bugs. Review the error messages above."
            )
            lines.append("")

        if not vulns and not errors:
            lines.append(
                "- No immediate issues found. Consider:\n"
                "  - Increasing `--cases` for deeper coverage\n"
                "  - Adding domain-specific invalid cases (e.g., negative lovelace,\n"
                "    wrong-length key hashes, expired deadlines)\n"
                "  - Running with different seeds: `--seed 0`, `--seed 1337`"
            )

        lines.append("\n### General\n")
        lines.append(
            "- Fuzzing complements but does not replace:\n"
            "  - Manual code review\n"
            "  - Property-based tests in Aiken (`test foo(x via fuzz.int())`)\n"
            "  - Attack-scenario unit tests (double-satisfaction, etc.)\n"
            "- See `research/smart-contract-testing-guide.md` for the full testing methodology."
        )

        return "\n".join(lines)

    def _footer(self, r: FuzzSessionResult) -> str:
        return (
            "---\n"
            f"*Generated by aiken-fuzzer v0.1.0 | "
            f"Seed: {r.seed if r.seed is not None else 'random'} | "
            f"{r.total_cases} cases | {r.timestamp} UTC*"
        )


# ---------------------------------------------------------------------------
# Convenience: write report to file
# ---------------------------------------------------------------------------

def write_report(result: FuzzSessionResult, output_path: str) -> str:
    """Generate and write report, return the markdown string."""
    gen = ReportGenerator()
    md = gen.generate(result)
    with open(output_path, "w") as f:
        f.write(md)
    return md


if __name__ == "__main__":
    # Quick demo with synthetic data
    result = FuzzSessionResult(
        contract_dir="/path/to/contract",
        validator_title="simple_escrow.simple_escrow.spend",
        seed=42,
        total_cases=10,
        schema_summary="EscrowRedeemer\n  [0] Claim\n    .secret: ByteArray\n  [1] Reclaim",
        aiken_version="v1.1.21",
    )
    result.cases = [
        FuzzCase(1, "random", {"constructor": 0, "fields": [b"abc"]},
                 '{"constructor": 0, ...}', "pass", "pass"),
        FuzzCase(2, "edge_case", {"constructor": 0, "fields": [b""]},
                 '{"constructor": 0, "fields": [{"bytes": ""}]}', "fail", "fail"),
        FuzzCase(3, "invalid", {"constructor": 99, "fields": []},
                 '{"constructor": 99, "fields": []}', "fail", "pass",
                 is_unexpected=True, notes="Invalid constructor index accepted!"),
    ]

    gen = ReportGenerator()
    print(gen.generate(result))
