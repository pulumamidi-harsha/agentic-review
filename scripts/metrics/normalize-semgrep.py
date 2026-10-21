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


def map_category(rule_id: str, metadata: dict[str, Any] | None = None) -> str:
    rid = rule_id.lower()
    if any(
        k in rid
        for k in (
            "secret",
            "hardcoded-secret",
            "credential",
            "password",
            "api-key",
            "api.key",
        )
    ):
        return "secret"
    meta_cat = str((metadata or {}).get("category") or "").lower()
    if meta_cat == "security":
        return "security"
    if any(
        k in rid
        for k in (
            "security",
            "vuln",
            "injection",
            "eval",
            "rce",
            "xss",
            "sqli",
            "crypto",
            "github-actions",
            "gha.",
            "unpinned",
            "regexp",
            "redos",
        )
    ):
        return "security"
    return "bug"


def default_remediation(rule_id: str, message: str) -> str:
    rid = rule_id.lower()
    if "eval" in rid or "function(...)" in message.lower():
        return (
            "(1) Remove eval / new Function (2) use JSON.parse, a whitelist map, "
            "or a vetted expression library (3) never pass user input into dynamic execution"
        )
    if "regexp" in rid or "redos" in rid:
        return (
            "(1) Prefer a literal RegExp (2) allow-list dynamic patterns "
            "(3) reject untrusted nested quantifiers"
        )
    return "Review the Semgrep rule and fix or suppress with justification."


def normalize(raw: dict[str, Any], changed: set[str]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for r in raw.get("results") or []:
        path = (r.get("path") or "").lstrip("./")
        rule_id = r.get("check_id") or "unknown"
        # Semgrep prefixes check_id with config path; keep full id for fingerprint
        extra = r.get("extra") or {}
        metadata = extra.get("metadata") or {}
        start = r.get("start") or {}
        end = r.get("end") or {}
        start_line = start.get("line")
        message = (extra.get("message") or rule_id).strip()
        fix = (
            extra.get("fix")
            or metadata.get("fix")
            or metadata.get("agentic_fix")
            or default_remediation(rule_id, message)
        )
        # Prefer short rule id for display (strip path prefix from local rules)
        short_id = rule_id
        if "." in rule_id and "agentic." in rule_id:
            short_id = rule_id[rule_id.find("agentic.") :]
        out.append(
            {
                "engine": "semgrep",
                "rule_id": short_id,
                "severity": map_severity(extra.get("severity") or r.get("severity")),
                "category": map_category(short_id, metadata),
                "path": path or None,
                "start_line": start_line,
                "end_line": end.get("line"),
                "message": message,
                "remediation": str(fix).strip(),
                "in_pr_diff": bool(path) and path in changed,
                "fingerprint": extra.get("fingerprint")
                or f"{short_id}:{path}:{start_line or 0}",
                "raw": {
                    "check_id": rule_id,
                    "snippet": (extra.get("lines") or "").strip() or None,
                    "cwe": metadata.get("cwe"),
                    "owasp": metadata.get("owasp"),
                },
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
