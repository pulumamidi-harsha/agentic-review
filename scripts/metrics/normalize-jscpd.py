#!/usr/bin/env python3
"""Normalize jscpd JSON into finding.schema.json rows (duplication)."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: normalize-jscpd.py <jscpd-raw.json> <pr-changed-files.txt> <out.json>",
            file=sys.stderr,
        )
        return 2
    raw_path, changed_path, out_path = sys.argv[1:4]
    changed = set()
    if Path(changed_path).is_file():
        changed = {
            ln.strip().lstrip("./")
            for ln in Path(changed_path).read_text(encoding="utf-8").splitlines()
            if ln.strip()
        }

    try:
        raw: Any = json.loads(Path(raw_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        Path(out_path).write_text("[]\n", encoding="utf-8")
        return 0

    duplicates = []
    if isinstance(raw, dict):
        duplicates = raw.get("duplicates") or raw.get("duplications") or []
    elif isinstance(raw, list):
        duplicates = raw

    findings: list[dict[str, Any]] = []
    for dup in duplicates:
        if not isinstance(dup, dict):
            continue
        # jscpd format: firstFile / secondFile with name + startLoc
        first = dup.get("firstFile") or dup.get("fragment") or {}
        second = dup.get("secondFile") or {}
        path = (first.get("name") or first.get("path") or "").lstrip("./")
        start = first.get("start") or first.get("startLoc") or 0
        if isinstance(start, dict):
            start_line = start.get("line") or start.get("startLine")
        else:
            start_line = start or None
        lines_count = dup.get("lines") or dup.get("lineCount") or 0
        tokens = dup.get("tokens") or 0
        other = (second.get("name") or second.get("path") or "").lstrip("./")
        in_diff = (path in changed) or (other in changed)
        # Only emit when at least one side is in the PR
        if not in_diff:
            continue
        findings.append(
            {
                "engine": "jscpd",
                "rule_id": "duplication",
                "severity": "warning",
                "category": "duplication",
                "path": path or other or None,
                "start_line": start_line,
                "end_line": (int(start_line) + int(lines_count) - 1)
                if start_line and lines_count
                else None,
                "message": (
                    f"Duplicated block ({lines_count} lines"
                    f"{f', {tokens} tokens' if tokens else ''})"
                    + (f" also in `{other}`" if other and other != path else "")
                    + "."
                ),
                "remediation": (
                    "Extract the shared logic into one helper and call it from "
                    "both places (or delete the copy). Keep a single source of "
                    "truth so future fixes land once."
                    + (f" Duplicate also appears in `{other}`." if other and other != path else "")
                ),
                "in_pr_diff": True,
                "fingerprint": f"jscpd:{path}:{start_line}:{other}:{lines_count}",
                "raw": {
                    "lines": lines_count,
                    "other_path": other or None,
                    "tokens": tokens,
                },
            }
        )

    Path(out_path).write_text(json.dumps(findings, indent=2) + "\n", encoding="utf-8")
    print(f"  Normalized jscpd: {len(findings)} duplication finding(s) in PR")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
