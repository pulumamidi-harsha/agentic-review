#!/usr/bin/env python3
"""Normalize Semgrep JSON into finding.schema.json rows."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def map_severity(raw: str | None) -> str:
    s = (raw or "WARNING").upper()
    if s in {"ERROR", "CRITICAL", "HIGH"}:
        return "error"
    if s in {"WARNING", "MEDIUM"}:
        return "warning"
    return "info"


def map_category(rule_id: str) -> str:
    rid = rule_id.lower()
    if any(k in rid for k in ("secret", "credential", "password", "api-key", "api.key")):
        return "secret"
    if any(
        k in rid
        for k in (
            "security",
            "vuln",
            "injection",
            "xss",
            "sqli",
            "crypto",
            "github-actions",
            "gha.",
            "unpinned",
        )
    ):
        return "security"
    return "bug"


def normalize(raw: dict[str, Any], changed: set[str]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for r in raw.get("results") or []:
        path = (r.get("path") or "").lstrip("./")
        rule_id = r.get("check_id") or "unknown"
        extra = r.get("extra") or {}
        start = r.get("start") or {}
        end = r.get("end") or {}
        start_line = start.get("line")
        fix = extra.get("fix") or (extra.get("metadata") or {}).get("fix")
        out.append(
            {
                "engine": "semgrep",
                "rule_id": rule_id,
                "severity": map_severity(extra.get("severity") or r.get("severity")),
                "category": map_category(rule_id),
                "path": path or None,
                "start_line": start_line,
                "end_line": end.get("line"),
                "message": extra.get("message") or rule_id,
                "remediation": fix
                or "Review the Semgrep rule and fix or suppress with justification.",
                "in_pr_diff": bool(path) and path in changed,
                "fingerprint": extra.get("fingerprint")
                or f"{rule_id}:{path}:{start_line or 0}",
                "raw": None,
            }
        )
    return out


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: normalize-semgrep.py <semgrep-raw.json> <pr-changed-files.txt> <out.json>",
            file=sys.stderr,
        )
        return 2
    raw_path, changed_path, out_path = sys.argv[1:4]
    changed: set[str] = set()
    p = Path(changed_path)
    if p.is_file():
        changed = {ln.strip().lstrip("./") for ln in p.read_text().splitlines() if ln.strip()}

    raw_file = Path(raw_path)
    if not raw_file.is_file():
        Path(out_path).write_text("[]\n", encoding="utf-8")
        return 0
    try:
        raw = json.loads(raw_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        Path(out_path).write_text("[]\n", encoding="utf-8")
        return 0

    findings = normalize(raw if isinstance(raw, dict) else {"results": []}, changed)
    Path(out_path).write_text(json.dumps(findings, indent=2) + "\n", encoding="utf-8")
    in_diff = sum(1 for f in findings if f.get("in_pr_diff"))
    print(f"  Normalized Semgrep: {len(findings)} findings ({in_diff} in PR diff)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
