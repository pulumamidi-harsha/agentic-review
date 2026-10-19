#!/usr/bin/env python3
"""Compare hub gate status to Sonar check text (shadow parity evidence)."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def parse_sonar_status(text: str) -> str:
    t = (text or "").lower()
    if not t.strip():
        return "absent"
    if "quality gate" in t and ("passed" in t or "ok" in t or "success" in t):
        return "pass"
    if "failed" in t or "error" in t:
        return "fail"
    if "warning" in t or "warn" in t:
        return "warn"
    if "passed" in t or "success" in t:
        return "pass"
    return "unknown"


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: compare-sonar-shadow.py <gate-result.json> <sonar-results.txt> <out.json>",
            file=sys.stderr,
        )
        return 2
    gate_path, sonar_path, out_path = sys.argv[1:4]
    gate = {}
    if Path(gate_path).is_file():
        gate = json.loads(Path(gate_path).read_text(encoding="utf-8"))
    sonar_text = ""
    if Path(sonar_path).is_file():
        sonar_text = Path(sonar_path).read_text(encoding="utf-8", errors="replace")

    hub = gate.get("status") or "unknown"
    sonar = parse_sonar_status(sonar_text)
    agree = hub == sonar or (hub == "warn" and sonar in {"pass", "warn"})
    # Map hub fail vs sonar pass as disagreement
    if hub == "fail" and sonar == "pass":
        agree = False
    if hub == "pass" and sonar == "fail":
        agree = False

    result = {
        "hub_status": hub,
        "sonar_status": sonar,
        "agree": agree,
        "sonar_present": sonar != "absent",
        "note": (
            "Shadow only — Sonar is not the source of truth. "
            "Log this JSON across PRs for parity evidence before hard_fail."
        ),
    }
    Path(out_path).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    # Append short block to quality-gate.md if present
    md_path = Path(gate_path).parent / "quality-gate.md"
    if md_path.is_file():
        block = [
            "",
            "### Sonar shadow comparison",
            "",
            f"| Hub gate | Sonar (shadow) | Agree? |",
            f"|----------|----------------|:------:|",
            f"| `{hub}` | `{sonar}` | {'yes' if agree else 'no'} |",
            "",
            "_Parity log artifact: `shadow-parity.json`. Use across many PRs before enabling hard_fail._",
            "",
        ]
        with md_path.open("a", encoding="utf-8") as f:
            f.write("\n".join(block))
    print(
        f"  Shadow: hub={hub} sonar={sonar} agree={agree}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
