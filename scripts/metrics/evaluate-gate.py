#!/usr/bin/env python3
"""Evaluate a findings bundle against hub quality-gate policy (advisory-safe)."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def load_mode(gate_yml: Path) -> str:
    if not gate_yml.is_file():
        return "advisory"
    for line in gate_yml.read_text(encoding="utf-8").splitlines():
        if line.startswith("mode:"):
            return line.split(":", 1)[1].strip().strip("\"'")
    return "advisory"


def evaluate(findings: list[dict[str, Any]], mode: str, new_lines: int) -> dict[str, Any]:
    errors_in_diff = [
        f for f in findings if f.get("in_pr_diff") and f.get("severity") == "error"
    ]
    secrets_in_diff = [
        f for f in findings if f.get("category") == "secret" and f.get("in_pr_diff")
    ]
    warnings_in_diff = [
        f for f in findings if f.get("in_pr_diff") and f.get("severity") == "warning"
    ]

    fail_reasons: list[str] = []
    warn_reasons: list[str] = []
    if secrets_in_diff:
        fail_reasons.append(f"{len(secrets_in_diff)} new secret finding(s) in PR diff")
    non_secret_errors = [f for f in errors_in_diff if f.get("category") != "secret"]
    if non_secret_errors:
        fail_reasons.append(
            f"{len(non_secret_errors)} error-severity finding(s) in PR diff"
        )
    if warnings_in_diff:
        warn_reasons.append(f"{len(warnings_in_diff)} warning finding(s) in PR diff")

    status = "fail" if fail_reasons else ("warn" if warn_reasons else "pass")
    return {
        "mode": mode,
        "status": status,
        "blocking": False,  # Phase 1: never block
        "new_lines": new_lines,
        "counts": {
            "findings_total": len(findings),
            "in_pr_diff": sum(1 for f in findings if f.get("in_pr_diff")),
            "errors_in_diff": len(errors_in_diff),
            "warnings_in_diff": len(warnings_in_diff),
            "secrets_in_diff": len(secrets_in_diff),
        },
        "fail_reasons": fail_reasons,
        "warn_reasons": warn_reasons,
        "note": "Advisory mode: GitHub check always passes. Sonar remains shadow-only.",
    }


def render_md(result: dict[str, Any], findings: list[dict[str, Any]]) -> str:
    status = result["status"]
    mode = result["mode"]
    emoji = {"pass": "✅", "warn": "⚠️", "fail": "❌"}.get(status, "ℹ️")
    c = result["counts"]
    lines = [
        f"### {emoji} Quality gate (advisory)",
        "",
        f"**Status:** `{status}` · **Mode:** `{mode}` (does not block merge)",
        "",
        "| Metric | Count |",
        "|--------|------:|",
        f"| Findings (all) | {c['findings_total']} |",
        f"| In PR diff | {c['in_pr_diff']} |",
        f"| Errors in diff | {c['errors_in_diff']} |",
        f"| Warnings in diff | {c['warnings_in_diff']} |",
        f"| Secrets in diff | {c['secrets_in_diff']} |",
        "",
    ]
    if result["fail_reasons"]:
        lines.append("**Would fail (when hard_fail enabled):**")
        lines.extend(f"- {r}" for r in result["fail_reasons"])
        lines.append("")
    if result["warn_reasons"]:
        lines.append("**Warnings:**")
        lines.extend(f"- {r}" for r in result["warn_reasons"])
        lines.append("")

    top = sorted(
        findings,
        key=lambda f: (not f.get("in_pr_diff"), f.get("severity") != "error"),
    )[:15]
    if top:
        lines += [
            "| Sev | Engine | File | Message |",
            "|:---:|--------|------|---------|",
        ]
        for f in top:
            sev = f.get("severity", "info")
            loc = f.get("path") or "—"
            if f.get("start_line"):
                loc = f"{loc}:{f['start_line']}"
            msg = (f.get("message") or "").replace("|", "\\|").replace("\n", " ")[:120]
            badge = "🔴" if sev == "error" else ("🟡" if sev == "warning" else "ℹ️")
            diff = " · PR" if f.get("in_pr_diff") else ""
            lines.append(
                f"| {badge} | `{f.get('engine')}` | `{loc}`{diff} | {msg} |"
            )
        lines.append("")

    lines.append(
        "_Hub gate (`config/quality-gate.yml` + Semgrep). "
        "SonarQube, if present, is shadow-only._"
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    if len(sys.argv) != 6:
        print(
            "usage: evaluate-gate.py <findings.json> <quality-gate.yml> "
            "<gate-result.json> <quality-gate.md> <new_lines>",
            file=sys.stderr,
        )
        return 2
    bundle_path, gate_yml, gate_out, gate_md, new_lines_s = sys.argv[1:6]
    new_lines = int(new_lines_s or 0)
    bundle = json.loads(Path(bundle_path).read_text(encoding="utf-8"))
    findings = bundle.get("findings") or []
    mode = load_mode(Path(gate_yml))
    result = evaluate(findings, mode, new_lines)
    Path(gate_out).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    Path(gate_md).write_text(render_md(result, findings), encoding="utf-8")
    print(f"  Gate status={result['status']} mode={mode} (advisory → never blocking)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
