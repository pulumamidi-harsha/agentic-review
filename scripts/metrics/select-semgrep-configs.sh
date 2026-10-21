#!/usr/bin/env bash
# Build Semgrep config list from quality-gate package + detected languages.
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE_DIR="${PIPELINE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
LANG_FILE="${AGENTIC_TMP}/metrics-languages.json"
PKG_FILE="${AGENTIC_TMP}/quality-package.json"
OUT="${AGENTIC_TMP}/semgrep-configs.json"

mkdir -p "$AGENTIC_TMP"
if [[ ! -f "$LANG_FILE" ]]; then
  echo '{"configs":["p/ci"],"reason":"no_language_file"}' > "$OUT"
  exit 0
fi
if [[ ! -f "$PKG_FILE" ]]; then
  echo '{"configs":["p/ci"],"reason":"no_package_file"}' > "$OUT"
  exit 0
fi

python3 - "$LANG_FILE" "$PKG_FILE" "$PIPELINE_DIR" "$OUT" <<'PY'
import json, sys
from pathlib import Path

lang_path, pkg_path, pipeline, out_path = sys.argv[1:5]
data = json.load(open(lang_path))
pkg = json.load(open(pkg_path))
langs = set(data.get("languages") or [])
root = Path(pipeline)

PACKS = {
    "javascript": ["p/javascript", "p/typescript"],
    "typescript": ["p/typescript", "p/javascript"],
    "python": ["p/python"],
    "go": ["p/golang"],
    "java": ["p/java"],
    "kotlin": ["p/kotlin"],
    "ruby": ["p/ruby"],
    "php": ["p/php"],
    "csharp": ["p/csharp"],
    "rust": ["p/rust"],
    "terraform": ["p/terraform"],
    "docker": ["p/docker"],
    # p/yaml 404s on semgrep.dev — workflow rules come from p/github-actions (always_packs)
    "yaml": [],
    "bash": ["p/bash"],
}

configs = []
seen = set()

def add(c: str) -> None:
    if c and c not in seen:
        seen.add(c)
        configs.append(c)

if pkg.get("language_packs", True):
    for lang in sorted(langs):
        for pack in PACKS.get(lang, []):
            add(pack)

for pack in pkg.get("always_packs") or []:
    add(pack)

# Local Semgrep rules from the quality package (e.g. GHA pin-to-SHA)
local_configs = []
for rel in pkg.get("local_rules") or []:
    p = root / rel
    if p.is_dir() or p.is_file():
        local_configs.append(str(p))
        add(str(p))

if not configs:
    add("p/ci")

payload = {
    "configs": configs,
    "local_rules": local_configs,
    "languages": sorted(langs),
    "package": pkg.get("name", "default"),
    "reason": "quality_package",
}
Path(out_path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print("  Semgrep configs: " + ", ".join(configs))
PY
