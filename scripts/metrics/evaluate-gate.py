#!/usr/bin/env python3
"""Evaluate a findings bundle against hub quality-gate policy.

Modes (config/quality-gate.yml → mode):
  advisory  — report only; GitHub check always green (org-wide default)
  soft_fail — fail the check on fail_if violations (teams can override required check)
  hard_fail — fail the check on fail_if; warn_if also blocks (post-parity only)
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


def _strip_comment(line: str) -> str:
    if "#" in line:
        return line.split("#", 1)[0].rstrip()
    return line.rstrip()


def load_gate_config(gate_yml: Path) -> Dict[str, Any]:
    """Minimal YAML subset parser for quality-gate.yml (no PyYAML required)."""
    cfg: Dict[str, Any] = {
        "mode": "advisory",
        "min_new_lines_for_coverage_dup": 20,
        "fail_severities": ["error"],
        "fail_on_secrets": True,
        "warn_duplication": True,
        "warn_coverage": True,
        "coverage_threshold": 80.0,
        "complexity_threshold": 15,
        "warn_complexity": True,
    }
    if not gate_yml.is_file():
        return cfg

    section: Optional[str] = None
    for raw in gate_yml.read_text(encoding="utf-8").splitlines():
        line = _strip_comment(raw)
        if not line.strip():
            continue
        if re.match(r"^mode:\s*", line):
            cfg["mode"] = line.split(":", 1)[1].strip().strip("\"'")
            continue
        if "min_new_lines_for_coverage_dup:" in line:
            try:
                cfg["min_new_lines_for_coverage_dup"] = int(
                    line.split(":", 1)[1].strip()
                )
            except ValueError:
                pass
            continue
        if line.strip() == "fail_if:":
            section = "fail_if"
            continue
        if line.strip() == "warn_if:":
            section = "warn_if"
            continue
        if section == "fail_if":
            if "new_secrets:" in line:
                cfg["fail_on_secrets"] = "true" in line.lower()
            m = re.search(r"new_findings_severity:\s*\[([^\]]*)\]", line)
            if m:
                cfg["fail_severities"] = [
                    s.strip().strip("\"'") for s in m.group(1).split(",") if s.strip()
                ]
        if section == "warn_if":
            if "new_duplication_blocks" in line:
                cfg["warn_duplication"] = True
            if "changed_file_coverage_pct" in line:
                cfg["warn_coverage"] = True
                m = re.search(r"<\s*(\d+(?:\.\d+)?)", line)
                if m:
                    cfg["coverage_threshold"] = float(m.group(1))
            if "complexity_increase" in line or "complexity" in line:
                cfg["warn_complexity"] = True
                m = re.search(r">\s*(\d+)", line)
                if m:
                    cfg["complexity_threshold"] = int(m.group(1))
    # Env override for gradual rollout without editing hub YAML per caller
    env_mode = (os.environ.get("AGENTIC_GATE_MODE") or "").strip()
    if env_mode in {"advisory", "soft_fail", "hard_fail"}:
        cfg["mode"] = env_mode
    return cfg


def evaluate(
    findings: List[Dict[str, Any]], cfg: Dict[str, Any], new_lines: int
) -> Dict[str, Any]:
    mode = cfg["mode"]
    min_lines = int(cfg["min_new_lines_for_coverage_dup"])
    apply_dup_cov = new_lines >= min_lines

    in_diff = [f for f in findings if f.get("in_pr_diff")]
    # Secrets: count any (even outside PR hunk) — leaked creds must not merge
    secrets_in_diff = [f for f in findings if f.get("category") == "secret"]
    errors_in_diff = [
        f
        for f in in_diff
        if f.get("severity") in (cfg.get("fail_severities") or ["error"])
        and f.get("category") != "secret"
    ]
    dup_findings = [
        f for f in in_diff if f.get("category") == "duplication"
    ]
    cov_findings = [
        f
        for f in in_diff
        if f.get("category") == "coverage" and f.get("severity") != "info"
    ]
    # Missing coverage report is info — warn only when hard_fail wants evidence
    cov_missing = [
        f
        for f in findings
        if f.get("engine") == "coverage" and f.get("rule_id") == "coverage_report_missing"
    ]
    complexity = [f for f in in_diff if f.get("category") == "complexity"]
    warnings_other = [
        f
        for f in in_diff
        if f.get("severity") == "warning"
        and f.get("category")
        not in {"duplication", "coverage", "complexity", "secret"}
    ]

    fail_reasons: List[str] = []
    warn_reasons: List[str] = []

    if cfg.get("fail_on_secrets") and secrets_in_diff:
        fail_reasons.append(f"{len(secrets_in_diff)} secret finding(s)")
    if errors_in_diff:
        fail_reasons.append(
            f"{len(errors_in_diff)} error-severity finding(s) in PR diff"
        )

    if apply_dup_cov:
        if cfg.get("warn_duplication") and dup_findings:
            warn_reasons.append(
                f"{len(dup_findings)} duplication block(s) touching the PR"
            )
        if cfg.get("warn_coverage") and cov_findings:
            warn_reasons.append(
                f"{len(cov_findings)} changed-file coverage finding(s) "
                f"(threshold {cfg.get('coverage_threshold')}%)"
            )
        elif cfg.get("warn_coverage") and cov_missing and mode == "hard_fail":
            warn_reasons.append(
                "coverage report missing (required for hard_fail on large PRs)"
            )
        if cfg.get("warn_complexity") and complexity:
            warn_reasons.append(
                f"{len(complexity)} function(s) over complexity "
                f"{cfg.get('complexity_threshold')}"
            )
    else:
        if dup_findings or cov_findings or complexity:
            warn_reasons.append(
                f"skipped coverage/duplication/complexity gates "
                f"(new_lines={new_lines} < {min_lines})"
            )

    if warnings_other:
        warn_reasons.append(f"{len(warnings_other)} other warning(s) in PR diff")

    # Status from policy
    status = "pass"
    if fail_reasons:
        status = "fail"
    elif warn_reasons and not (
        len(warn_reasons) == 1 and warn_reasons[0].startswith("skipped")
    ):
        status = "warn"
    elif warn_reasons and warn_reasons[0].startswith("skipped"):
        # Tiny PR skip note alone → still pass
        status = "pass"

    # Blocking policy
    blocking = False
    exit_code = 0
    if mode == "soft_fail":
        blocking = status == "fail"
        exit_code = 1 if blocking else 0
    elif mode == "hard_fail":
        # warn_if becomes blocking under hard_fail
        if status == "warn":
            status = "fail"
            fail_reasons = fail_reasons + [
                f"[hard_fail] {r}" for r in warn_reasons if not r.startswith("skipped")
            ]
            warn_reasons = [r for r in warn_reasons if r.startswith("skipped")]
        blocking = status == "fail"
        exit_code = 1 if blocking else 0
    else:
        # advisory
        blocking = False
        exit_code = 0

    notes = {
        "advisory": "Advisory mode: GitHub check stays green. Flip to soft_fail after pilot.",
        "soft_fail": "Soft-fail: check fails on fail_if (secrets/errors). Teams may mark check non-required.",
        "hard_fail": "Hard-fail: fail_if and warn_if both block. Enable only when the org is ready.",
    }

    return {
        "mode": mode,
        "status": status,
        "blocking": blocking,
        "exit_code": exit_code,
        "new_lines": new_lines,
        "min_new_lines_for_coverage_dup": min_lines,
        "coverage_dup_gates_applied": apply_dup_cov,
        "counts": {
            "findings_total": len(findings),
            "in_pr_diff": len(in_diff),
            "errors_in_diff": len(errors_in_diff),
            "warnings_in_diff": sum(1 for f in in_diff if f.get("severity") == "warning"),
            "secrets": len(secrets_in_diff),
            "duplication": len(dup_findings),
            "coverage": len(cov_findings),
            "complexity": len(complexity),
        },
        "fail_reasons": fail_reasons,
        "warn_reasons": warn_reasons,
        "note": notes.get(mode, notes["advisory"]),
        "engines": sorted({f.get("engine") for f in findings if f.get("engine")}),
    }


def _condition_lines(result: Dict[str, Any], findings: List[Dict[str, Any]]) -> List[str]:
    """Sonar-style failed/warning conditions with thresholds."""
    out: List[str] = []
    c = result["counts"]
    status = result["status"]
    mark_fail = "❌" if status == "fail" else "⚠️"

    if c.get("errors_in_diff", 0) > 0:
        out.append(
            f"- {mark_fail} **{c['errors_in_diff']}** new error-severity issue(s) "
            f"(required = **0**)"
        )
    if c.get("secrets", 0) > 0:
        out.append(
            f"- {mark_fail} **{c['secrets']}** secret(s) in changed code "
            f"(required = **0**)"
        )
    if c.get("complexity", 0) > 0:
        for f in findings:
            if f.get("category") != "complexity" or not f.get("in_pr_diff"):
                continue
            raw = f.get("raw") or {}
            ccn = raw.get("ccn")
            thr = raw.get("threshold", 15)
            func = raw.get("function") or "function"
            loc = f.get("path") or "—"
            if f.get("start_line"):
                loc = f"{loc}:{f['start_line']}"
            if ccn is not None:
                out.append(
                    f"- {mark_fail} Complexity on `{loc}` — `{func}` is **{ccn}** "
                    f"(required ≤ **{thr}**)"
                )
            else:
                out.append(f"- {mark_fail} {f.get('message')}")
    if c.get("duplication", 0) > 0:
        out.append(
            f"- {mark_fail} **{c['duplication']}** duplication block(s) on new code "
            f"(required ≤ **0**)"
        )
    if c.get("coverage", 0) > 0 or any(
        f.get("category") == "coverage" and f.get("rule_id") == "coverage_report_missing"
        for f in findings
    ):
        missing = any(
            f.get("rule_id") == "coverage_report_missing" for f in findings
        )
        if missing:
            out.append(
                "- ⚠️ Coverage on new code: **no report** "
                "(required ≥ **80%** when tests emit lcov/cobertura/istanbul)"
            )
        else:
            out.append(
                f"- ⚠️ Coverage findings on changed files: **{c.get('coverage', 0)}** "
                f"(required ≥ **80%**)"
            )
    # Fall back to gate reasons if nothing structured matched
    if not out:
        for r in result.get("fail_reasons") or []:
            out.append(f"- {mark_fail} {r}")
        for r in result.get("warn_reasons") or []:
            out.append(f"- ⚠️ {r}")
    return out


def render_md(result: Dict[str, Any], findings: List[Dict[str, Any]]) -> str:
    status = result["status"]
    mode = result["mode"]
    blocking = result["blocking"]
    emoji = {"pass": "✅", "warn": "⚠️", "fail": "❌"}.get(status, "ℹ️")
    c = result["counts"]
    title = "Quality gate"
    if mode == "advisory":
        title += " (advisory)"
    elif mode == "soft_fail":
        title += " (soft-fail)"
    else:
        title += " (hard-fail)"

    lines = [
        f"### {emoji} {title}",
        "",
        f"**Status:** `{status}` · **Mode:** `{mode}` · **Blocking:** `{'yes' if blocking else 'no'}`",
        "",
    ]

    conditions = _condition_lines(result, findings)
    if conditions and status != "pass":
        lines.append("#### Failed conditions")
        lines.append("")
        lines.extend(conditions)
        lines.append("")
    elif status == "pass":
        lines.append("_All quality-gate conditions passed for this PR._")
        lines.append("")

    lines += [
        "| Metric | Count |",
        "|--------|------:|",
        f"| Findings (all) | {c['findings_total']} |",
        f"| In PR diff | {c['in_pr_diff']} |",
        f"| Errors in diff | {c['errors_in_diff']} |",
        f"| Secrets | {c['secrets']} |",
        f"| Duplication | {c['duplication']} |",
        f"| Coverage | {c['coverage']} |",
        f"| Complexity | {c['complexity']} |",
        f"| Engines | {', '.join(result.get('engines') or []) or '—'} |",
        "",
    ]

    top = sorted(
        findings,
        key=lambda f: (not f.get("in_pr_diff"), f.get("severity") != "error"),
    )[:20]
    lineable = [f for f in top if f.get("path") and f.get("start_line")]
    summary_only = [f for f in top if not (f.get("path") and f.get("start_line"))]

    if lineable:
        lines += [
            "#### Issues (open **Files changed** for line comments)",
            "",
            "| Sev | Where | What | How to fix |",
            "|:---:|-------|------|------------|",
        ]
        for f in lineable:
            sev = f.get("severity", "info")
            loc = f"{f.get('path')}:{f['start_line']}"
            msg = (f.get("message") or "").replace("|", "\\|").replace("\n", " ")[:140]
            fix = (f.get("remediation") or "See inline comment.").replace("|", "\\|").replace(
                "\n", " "
            )[:160]
            badge = "🔴" if sev == "error" else ("🟡" if sev == "warning" else "ℹ️")
            lines.append(f"| {badge} | `{loc}` | {msg} | {fix} |")
        lines.append("")

    if summary_only:
        lines += [
            "#### Other findings",
            "",
        ]
        for f in summary_only:
            sev = f.get("severity", "info")
            badge = "🔴" if sev == "error" else ("🟡" if sev == "warning" else "ℹ️")
            msg = (f.get("message") or "").replace("\n", " ")
            fix = f.get("remediation") or ""
            lines.append(f"- {badge} **{f.get('engine')}** — {msg}")
            if fix:
                lines.append(f"  - 💡 {fix}")
        lines.append("")

    if lineable:
        lines.append(
            "_Peer-style review comments are posted on the exact lines in "
            "**Files changed**._"
        )
        lines.append("")

    lines.append(f"_{result.get('note', '')}_")
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
    cfg = load_gate_config(Path(gate_yml))
    result = evaluate(findings, cfg, new_lines)
    Path(gate_out).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    Path(gate_md).write_text(render_md(result, findings), encoding="utf-8")
    print(
        f"  Gate status={result['status']} mode={result['mode']} "
        f"blocking={result['blocking']} exit={result['exit_code']}"
    )
    # Script always returns 0; apply-quality-gate.sh reads exit_code for soft/hard
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
