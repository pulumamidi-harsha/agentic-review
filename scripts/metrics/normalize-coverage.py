#!/usr/bin/env python3
"""Build coverage findings for PR-changed files from lcov / cobertura / istanbul."""
from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def load_changed(path: Path) -> List[str]:
    if not path.is_file():
        return []
    return [ln.strip().lstrip("./") for ln in path.read_text().splitlines() if ln.strip()]


def parse_lcov(text: str) -> Dict[str, Tuple[int, int]]:
    """Return path -> (hit, found) line counts."""
    out: Dict[str, Tuple[int, int]] = {}
    current: Optional[str] = None
    hit = found = 0
    for line in text.splitlines():
        if line.startswith("SF:"):
            if current and found:
                out[current] = (hit, found)
            current = line[3:].strip().lstrip("./")
            hit = found = 0
        elif line.startswith("LF:"):
            try:
                found = int(line[3:])
            except ValueError:
                pass
        elif line.startswith("LH:"):
            try:
                hit = int(line[3:])
            except ValueError:
                pass
        elif line.strip() == "end_of_record":
            if current and found:
                out[current] = (hit, found)
            current = None
            hit = found = 0
    if current and found:
        out[current] = (hit, found)
    return out


def parse_cobertura(path: Path) -> Dict[str, Tuple[int, int]]:
    out: Dict[str, Tuple[int, int]] = {}
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return out
    for cls in root.iter("class"):
        filename = (cls.attrib.get("filename") or cls.attrib.get("name") or "").lstrip(
            "./"
        )
        lines = list(cls.iter("line"))
        if not lines or not filename:
            continue
        found = len(lines)
        hit = sum(1 for ln in lines if float(ln.attrib.get("hits") or 0) > 0)
        out[filename] = (hit, found)
    return out


def parse_istanbul(path: Path) -> Dict[str, Tuple[int, int]]:
    out: Dict[str, Tuple[int, int]] = {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return out
    # istanbul coverage-final.json: { absPath: { s: {..}, statementMap, ... } }
    for key, entry in data.items():
        if not isinstance(entry, dict):
            continue
        rel = key.lstrip("./")
        # Prefer path relative to cwd if absolute
        statement_map = entry.get("statementMap") or {}
        s = entry.get("s") or {}
        if not statement_map:
            continue
        found = len(statement_map)
        hit = sum(1 for k, v in s.items() if int(v or 0) > 0)
        out[rel] = (hit, found)
    return out


def discover_maps(search_roots: List[Path]) -> Dict[str, Tuple[int, int]]:
    merged: Dict[str, Tuple[int, int]] = {}
    candidates = [
        "lcov.info",
        "coverage/lcov.info",
        "coverage/lcov/lcov.info",
        "coverage.xml",
        "coverage/coverage.xml",
        "coverage/cobertura-coverage.xml",
        "coverage/coverage-final.json",
        "coverage-final.json",
    ]
    for root in search_roots:
        if not root.is_dir() and not root.is_file():
            continue
        for rel in candidates:
            p = root / rel if root.is_dir() else root
            if root.is_dir():
                p = root / rel
            if not p.is_file():
                continue
            if p.name.endswith(".info") or p.name == "lcov.info":
                merged.update(parse_lcov(p.read_text(encoding="utf-8", errors="replace")))
            elif p.suffix == ".xml":
                merged.update(parse_cobertura(p))
            elif p.suffix == ".json":
                merged.update(parse_istanbul(p))
        # Also scan shallow for lcov.info
        if root.is_dir():
            for p in list(root.glob("**/lcov.info"))[:20]:
                merged.update(parse_lcov(p.read_text(encoding="utf-8", errors="replace")))
    return merged


def match_coverage(
    changed: str, cov: Dict[str, Tuple[int, int]]
) -> Optional[Tuple[str, int, int]]:
    if changed in cov:
        h, f = cov[changed]
        return changed, h, f
    for key, (h, f) in cov.items():
        if key.endswith(changed) or changed.endswith(key):
            return key, h, f
        if Path(key).name == Path(changed).name and Path(changed).suffix:
            return key, h, f
    return None


def main() -> int:
    if len(sys.argv) < 5:
        print(
            "usage: normalize-coverage.py <changed.txt> <out.json> <threshold> "
            "<agentic_tmp> [workdir]",
            file=sys.stderr,
        )
        return 2
    changed_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    threshold = float(sys.argv[3])
    tmp = Path(sys.argv[4])
    work = Path(sys.argv[5]) if len(sys.argv) > 5 else Path.cwd()

    changed = load_changed(changed_path)
    code_ext = {
        ".js",
        ".jsx",
        ".ts",
        ".tsx",
        ".py",
        ".go",
        ".java",
        ".kt",
        ".rb",
        ".php",
        ".cs",
        ".rs",
    }
    code_files = [c for c in changed if Path(c).suffix.lower() in code_ext]
    if not code_files:
        out_path.write_text("[]\n", encoding="utf-8")
        print("  No PR code files for coverage — skip")
        return 0

    cov = discover_maps([tmp, work])
    if not cov:
        # Emit informational skip finding (warn only when gate asks for coverage)
        finding = [
            {
                "engine": "coverage",
                "rule_id": "coverage_report_missing",
                "severity": "info",
                "category": "coverage",
                "path": None,
                "start_line": None,
                "end_line": None,
                "message": (
                    "No coverage report found (lcov/cobertura/istanbul). "
                    "Run unit tests with coverage in checks to enable this gate."
                ),
                "remediation": "Ensure Pass 1 / checks emit coverage artifacts (e.g. lcov.info).",
                "in_pr_diff": True,
                "fingerprint": "coverage:missing",
                "raw": None,
            }
        ]
        out_path.write_text(json.dumps(finding, indent=2) + "\n", encoding="utf-8")
        print("  Coverage report missing — info finding emitted")
        return 0

    findings = []
    pcts = []
    for cf in code_files:
        m = match_coverage(cf, cov)
        if not m:
            continue
        key, hit, found = m
        if found <= 0:
            continue
        pct = 100.0 * hit / found
        pcts.append(pct)
        if pct + 1e-6 >= threshold:
            continue
        findings.append(
            {
                "engine": "coverage",
                "rule_id": "changed_file_coverage",
                "severity": "warning",
                "category": "coverage",
                "path": cf,
                "start_line": None,
                "end_line": None,
                "message": (
                    f"Changed-file line coverage is {pct:.1f}% "
                    f"(threshold {threshold:.0f}%; {hit}/{found} lines)."
                ),
                "remediation": "Add unit tests covering the new/changed branches in this file.",
                "in_pr_diff": True,
                "fingerprint": f"coverage:{cf}:{pct:.1f}",
                "raw": None,
            }
        )

    # Aggregate finding when we have overall changed-file average below threshold
    if pcts and (sum(pcts) / len(pcts)) < threshold and not findings:
        avg = sum(pcts) / len(pcts)
        findings.append(
            {
                "engine": "coverage",
                "rule_id": "changed_files_coverage_avg",
                "severity": "warning",
                "category": "coverage",
                "path": None,
                "start_line": None,
                "end_line": None,
                "message": (
                    f"Average coverage on matched changed files is {avg:.1f}% "
                    f"(threshold {threshold:.0f}%)."
                ),
                "remediation": "Add tests for uncovered changed code.",
                "in_pr_diff": True,
                "fingerprint": f"coverage:avg:{avg:.1f}",
                "raw": None,
            }
        )

    out_path.write_text(json.dumps(findings, indent=2) + "\n", encoding="utf-8")
    print(
        f"  Coverage: {len(cov)} files in reports · "
        f"{len(findings)} finding(s) under {threshold:.0f}%"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
