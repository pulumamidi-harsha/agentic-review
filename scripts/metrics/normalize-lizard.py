#!/usr/bin/env python3
"""Normalize Lizard CSV into finding.schema.json rows (complexity)."""
from __future__ import annotations

import csv
import io
import json
import re
import sys
from pathlib import Path


LOC_RE = re.compile(r"@(\d+)-(\d+)@")


def to_repo_path(raw: str, changed: set[str]) -> str:
    """Normalize absolute or relative lizard paths to repo-relative."""
    p = (raw or "").strip().lstrip("./")
    if not p:
        return ""
    path = Path(p)
    try:
        return str(path.resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        pass
    # Match against PR changed files by suffix / basename
    for c in changed:
        if p.endswith(c) or c.endswith(p) or Path(c).name == path.name:
            return c
    return p


def parse_lines(location: str, row: list[str]) -> tuple[int | None, int | None]:
    """Lizard CSV: location is name@start-end@path; trailing cols may be start,end."""
    m = LOC_RE.search(location or "")
    if m:
        return int(m.group(1)), int(m.group(2))
    if len(row) >= 11:
        try:
            return int(row[9]), int(row[10])
        except ValueError:
            pass
    # Legacy: file:start-end or bare start-end
    loc = location or ""
    if ":" in loc and "@" not in loc:
        loc = loc.rsplit(":", 1)[-1]
    if re.fullmatch(r"\d+-\d+", loc or ""):
        left, right = loc.split("-", 1)
        return int(left), int(right)
    return None, None


def remediation(func: str, ccn: int, threshold: int) -> str:
    return (
        f"Refactor `{func}` so cyclomatic complexity is ≤ {threshold} "
        f"(currently {ccn}). Prefer: (1) extract each major branch into a "
        f"named helper, (2) replace deep nesting with early returns or a "
        f"lookup/map, (3) keep each function doing one job. Add unit tests "
        f"for the extracted helpers."
    )


def main() -> int:
    if len(sys.argv) != 5:
        print(
            "usage: normalize-lizard.py <lizard.csv> <pr-changed-files.txt> "
            "<out.json> <threshold>",
            file=sys.stderr,
        )
        return 2
    raw_path, changed_path, out_path, threshold_s = sys.argv[1:5]
    threshold = int(threshold_s or 15)
    changed: set[str] = set()
    if Path(changed_path).is_file():
        changed = {
            ln.strip().lstrip("./")
            for ln in Path(changed_path).read_text(encoding="utf-8").splitlines()
            if ln.strip()
        }

    text = Path(raw_path).read_text(encoding="utf-8", errors="replace")
    rows: list[dict] = []
    reader = csv.reader(io.StringIO(text))
    for row in reader:
        if len(row) < 8:
            continue
        # CSV: nloc,ccn,token,param,length,location,file,function,canonical[,start,end]
        try:
            if row[0].lower() in {"nloc", "file"}:
                continue
            nloc, ccn = int(float(row[0])), int(float(row[1]))
            location = row[5] if len(row) > 5 else ""
            path = to_repo_path(row[6] if len(row) > 6 else "", changed)
            func = row[7] if len(row) > 7 else "function"
        except (ValueError, IndexError):
            continue
        if not path:
            continue
        if path not in changed and not any(
            path.endswith(c) or c.endswith(path) for c in changed
        ):
            base = Path(path).name
            if not any(Path(c).name == base for c in changed):
                continue
        if ccn <= threshold:
            continue
        start_line, end_line = parse_lines(location, row)
        rows.append(
            {
                "engine": "lizard",
                "rule_id": "cyclomatic_complexity",
                "severity": "warning" if ccn < threshold * 2 else "error",
                "category": "complexity",
                "path": path,
                "start_line": start_line,
                "end_line": end_line,
                "message": (
                    f"Function `{func}` complexity is {ccn} "
                    f"(threshold {threshold}, NLOC {nloc})."
                ),
                "remediation": remediation(func, ccn, threshold),
                "in_pr_diff": True,
                "fingerprint": f"lizard:{path}:{func}:{ccn}",
                "raw": {"function": func, "ccn": ccn, "threshold": threshold, "nloc": nloc},
            }
        )

    Path(out_path).write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    print(f"  Normalized lizard: {len(rows)} complexity finding(s) over {threshold}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
