#!/usr/bin/env python3
"""Normalize Lizard CSV into finding.schema.json rows (complexity)."""
from __future__ import annotations

import csv
import io
import json
import sys
from pathlib import Path


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
    changed = set()
    if Path(changed_path).is_file():
        changed = {
            ln.strip().lstrip("./")
            for ln in Path(changed_path).read_text(encoding="utf-8").splitlines()
            if ln.strip()
        }

    text = Path(raw_path).read_text(encoding="utf-8", errors="replace")
    # Skip summary lines; keep CSV rows
    rows = []
    reader = csv.reader(io.StringIO(text))
    for row in reader:
        if len(row) < 8:
            continue
        # Typical: NLOC,CCN,token,PARAM,length,location,file,function_name,...
        # lizard --csv columns vary by version; detect file-like fields
        try:
            # Common format: nloc,ccn,token,param,length,location,file,function,canonical
            if row[0].lower() in {"nloc", "file"}:
                continue
            nloc, ccn = int(float(row[0])), int(float(row[1]))
            location = row[5] if len(row) > 5 else ""
            path = (row[6] if len(row) > 6 else "").lstrip("./")
            func = row[7] if len(row) > 7 else "function"
        except (ValueError, IndexError):
            continue
        if not path:
            continue
        if path not in changed and not any(path.endswith(c) or c.endswith(path) for c in changed):
            # still allow if basename match in changed
            base = Path(path).name
            if not any(Path(c).name == base for c in changed):
                continue
        if ccn <= threshold:
            continue
        # Parse start line from location "file:start-end" or "start-end"
        start_line = None
        loc = location or ""
        if ":" in loc:
            loc = loc.rsplit(":", 1)[-1]
        if "-" in loc:
            try:
                start_line = int(loc.split("-", 1)[0])
            except ValueError:
                start_line = None
        rows.append(
            {
                "engine": "lizard",
                "rule_id": "cyclomatic_complexity",
                "severity": "warning" if ccn < threshold * 2 else "error",
                "category": "complexity",
                "path": path,
                "start_line": start_line,
                "end_line": None,
                "message": (
                    f"Function `{func}` complexity is {ccn} "
                    f"(threshold {threshold}, NLOC {nloc})."
                ),
                "remediation": "Split into smaller functions before merge.",
                "in_pr_diff": True,
                "fingerprint": f"lizard:{path}:{func}:{ccn}",
                "raw": None,
            }
        )

    Path(out_path).write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    print(f"  Normalized lizard: {len(rows)} complexity finding(s) over {threshold}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
