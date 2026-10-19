#!/usr/bin/env python3
"""Resolve quality-gate package → engines JSON for the metrics orchestrator."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List


def _simple_yaml_list(block_lines: List[str]) -> List[str]:
    out: List[str] = []
    for ln in block_lines:
        s = ln.split("#", 1)[0].strip()
        if s.startswith("- "):
            out.append(s[2:].strip().strip("\"'"))
    return out


def parse_package(text: str) -> Dict[str, Any]:
    """Minimal YAML subset for packages/default.yml (no PyYAML required)."""
    pkg: Dict[str, Any] = {
        "name": "default",
        "semgrep_enabled": True,
        "language_packs": True,
        "always_packs": [],
        "local_rules": [],
        "duplication": True,
        "complexity": True,
        "complexity_threshold": 15,
        "coverage": True,
        "coverage_threshold": 80.0,
    }
    lines = text.splitlines()
    i = 0
    section = ""
    while i < len(lines):
        raw = lines[i]
        line = raw.split("#", 1)[0].rstrip()
        stripped = line.strip()
        if not stripped:
            i += 1
            continue
        if line.startswith("name:"):
            pkg["name"] = line.split(":", 1)[1].strip().strip("\"'")
        if stripped == "semgrep:":
            section = "semgrep"
            i += 1
            continue
        if stripped == "duplication:":
            section = "duplication"
            i += 1
            continue
        if stripped == "complexity:":
            section = "complexity"
            i += 1
            continue
        if stripped == "coverage:":
            section = "coverage"
            i += 1
            continue
        indent = len(line) - len(line.lstrip(" "))
        if section == "semgrep" and indent >= 2:
            if "enabled:" in stripped:
                pkg["semgrep_enabled"] = "true" in stripped.lower()
            elif "language_packs:" in stripped:
                pkg["language_packs"] = "true" in stripped.lower()
            elif stripped == "always_packs:":
                block = []
                i += 1
                while i < len(lines) and (
                    lines[i].startswith("      -") or lines[i].startswith("        -")
                ):
                    block.append(lines[i])
                    i += 1
                pkg["always_packs"] = _simple_yaml_list(block)
                continue
            elif stripped == "local_rules:":
                block = []
                i += 1
                while i < len(lines) and (
                    lines[i].startswith("      -") or lines[i].startswith("        -")
                ):
                    block.append(lines[i])
                    i += 1
                pkg["local_rules"] = _simple_yaml_list(block)
                continue
        if section == "duplication" and "enabled:" in stripped:
            pkg["duplication"] = "true" in stripped.lower()
        if section == "complexity":
            if "enabled:" in stripped:
                pkg["complexity"] = "true" in stripped.lower()
            if "threshold:" in stripped:
                try:
                    pkg["complexity_threshold"] = int(stripped.split(":", 1)[1].strip())
                except ValueError:
                    pass
        if section == "coverage":
            if "enabled:" in stripped:
                pkg["coverage"] = "true" in stripped.lower()
            if "threshold_pct:" in stripped:
                try:
                    pkg["coverage_threshold"] = float(
                        stripped.split(":", 1)[1].strip()
                    )
                except ValueError:
                    pass
        i += 1
    return pkg


def load_gate_package_name(gate_yml: Path) -> str:
    if not gate_yml.is_file():
        return "default"
    for ln in gate_yml.read_text(encoding="utf-8").splitlines():
        if ln.startswith("package:"):
            return ln.split(":", 1)[1].strip().strip("\"'")
    return "default"


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: load-package.py <quality-gate.yml> <packages-dir> <out.json>",
            file=sys.stderr,
        )
        return 2
    gate_yml = Path(sys.argv[1])
    packages_dir = Path(sys.argv[2])
    out = Path(sys.argv[3])
    name = load_gate_package_name(gate_yml)
    pkg_path = packages_dir / f"{name}.yml"
    if not pkg_path.is_file():
        print(f"  Package not found: {pkg_path}", file=sys.stderr)
        return 1
    pkg = parse_package(pkg_path.read_text(encoding="utf-8"))
    pkg["package_file"] = str(pkg_path)
    out.write_text(json.dumps(pkg, indent=2) + "\n", encoding="utf-8")
    print(
        f"  Quality package: {pkg['name']} "
        f"(semgrep={pkg['semgrep_enabled']} dup={pkg['duplication']} "
        f"complexity={pkg['complexity']} coverage={pkg['coverage']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
