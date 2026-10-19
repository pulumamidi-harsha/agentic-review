#!/usr/bin/env bash
# Merge per-engine finding arrays into findings.json bundle (schema v1).
# Today: Semgrep only. Later: jscpd / lizard / coverage drop files here.
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

BUNDLE_OUT="${AGENTIC_TMP}/findings.json"
SEMGREP="${AGENTIC_TMP}/semgrep-findings.json"
# Future engines (empty → ignored):
# JSCPD="${AGENTIC_TMP}/jscpd-findings.json"
# LIZARD="${AGENTIC_TMP}/lizard-findings.json"

mkdir -p "$AGENTIC_TMP"
[[ -f "$SEMGREP" ]] || echo '[]' > "$SEMGREP"

REPO="${GITHUB_REPOSITORY:-unknown/unknown}"
SHA="${GITHUB_EVENT_PULL_REQUEST_HEAD_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
PR_NUM="${GITHUB_EVENT_PULL_REQUEST_NUMBER:-}"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Merge all * -findings.json arrays present
python3 - "$AGENTIC_TMP" "$BUNDLE_OUT" "$REPO" "$SHA" "$PR_NUM" "$NOW" <<'PY'
import json, sys
from pathlib import Path

tmp, out, repo, sha, pr, now = sys.argv[1:7]
findings = []
for path in sorted(Path(tmp).glob("*-findings.json")):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, list):
            findings.extend(data)
    except Exception as exc:
        print(f"  skip {path.name}: {exc}")

bundle = {
    "schema_version": "1.0.0",
    "generated_at": now,
    "repository": repo,
    "head_sha": sha,
    "pr_number": int(pr) if pr.isdigit() else None,
    "findings": findings,
}
Path(out).write_text(json.dumps(bundle, indent=2) + "\n", encoding="utf-8")
engines = sorted({f.get("engine") for f in findings if f.get("engine")})
print(f"  Merged {len(findings)} findings from engines: {', '.join(engines) or '(none)'}")
PY
