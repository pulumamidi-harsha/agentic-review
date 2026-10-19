#!/usr/bin/env bash
# Map detected languages → Semgrep config IDs (multi-stack / monorepo safe).
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

LANG_FILE="${AGENTIC_TMP}/metrics-languages.json"
OUT="${AGENTIC_TMP}/semgrep-configs.json"

mkdir -p "$AGENTIC_TMP"
if [[ ! -f "$LANG_FILE" ]]; then
  echo '{"configs":["p/ci"],"reason":"no_language_file"}' > "$OUT"
  exit 0
fi

python3 - "$LANG_FILE" "$OUT" <<'PY'
import json, sys

lang_path, out_path = sys.argv[1:3]
data = json.load(open(lang_path))
langs = set(data.get("languages") or [])

# Language → official Semgrep registry packs (keep small for CI time at scale)
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
    "yaml": ["p/yaml"],
    "bash": ["p/bash"],
}

configs = []
seen = set()
for lang in sorted(langs):
    for pack in PACKS.get(lang, []):
        if pack not in seen:
            seen.add(pack)
            configs.append(pack)

# Always include a light security baseline when we have any code language
if configs and "p/security-audit" not in seen:
    configs.append("p/security-audit")

# Fallback: generic CI pack (Semgrep auto-picks applicable rules per file)
if not configs:
    configs = ["p/ci"]

payload = {
    "configs": configs,
    "languages": sorted(langs),
    "reason": "language_map" if langs else "fallback_p_ci",
}
with open(out_path, "w") as f:
    json.dump(payload, f, indent=2)
print("  Semgrep configs: " + ", ".join(configs))
PY
