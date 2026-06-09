#!/usr/bin/env bash
# Agentic self-healing: when a setup_command fails, call the LLM with the
# failed command + captured output + a tiny repo fingerprint, and ask for a
# minimal repair (extra commands to prepend, or a corrected retry command).
#
# Usage:
#   ai-fix-setup.sh <failed_cmd> <stderr_file> <out_json>
#
# Writes JSON to <out_json> with schema:
#   { diagnosis, repair_commands[], retry_cmd, give_up, reason }
#
# Returns 0 on a usable repair plan (give_up=false), 1 on give_up=true or any
# transport error. Caller decides how to act on the JSON.
set -uo pipefail

FAILED_CMD="${1:?failed command required}"
STDERR_FILE="${2:?stderr file required}"
OUT_JSON="${3:?output json path required}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPAIR_SYS="$SCRIPT_DIR/prompts/repair-system.txt"

if [[ ! -f "$REPAIR_SYS" ]]; then
  echo "::warning::repair-system.txt missing — agentic repair disabled" >&2
  printf '{"give_up":true,"reason":"repair prompt missing","repair_commands":[],"retry_cmd":"","diagnosis":""}\n' > "$OUT_JSON"
  exit 1
fi

if [[ -z "${AI_API_ENDPOINT:-}" || -z "${AI_API_KEY:-}" ]]; then
  echo "::notice::agentic repair skipped — AI_API_ENDPOINT/AI_API_KEY not set" >&2
  printf '{"give_up":true,"reason":"AI credentials not available","repair_commands":[],"retry_cmd":"","diagnosis":""}\n' > "$OUT_JSON"
  exit 1
fi

# Tiny repo fingerprint — under 1 KB so total prompt stays cheap.
fingerprint() {
  local f
  for f in package.json pnpm-lock.yaml yarn.lock package-lock.json \
           pyproject.toml uv.lock poetry.lock Pipfile requirements.txt \
           go.mod Cargo.toml Gemfile pom.xml build.gradle Chart.yaml \
           Dockerfile compose.yaml docker-compose.yml \
           .terraform-version .tflint.hcl .checkov.yml \
           .nvmrc .python-version .ruby-version .tool-versions \
           Makefile; do
    [[ -e "$f" ]] && echo "$f"
  done | sort -u
  # Top-level dirs that suggest a monorepo
  find . -mindepth 1 -maxdepth 1 -type d \
    \( -name 'apps' -o -name 'packages' -o -name 'services' -o -name 'modules' \
       -o -name 'backend' -o -name 'frontend' -o -name 'infrastructure' \
       -o -name 'terraform' -o -name 'k8s' -o -name 'charts' \) \
    2>/dev/null | sort -u | head -10
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Trim stderr to last 80 lines (model only needs the tail; full log can be huge).
TAIL_FILE="$TMP_DIR/stderr.tail"
if [[ -f "$STDERR_FILE" ]]; then
  tail -n 80 "$STDERR_FILE" > "$TAIL_FILE"
else
  : > "$TAIL_FILE"
fi

FP_FILE="$TMP_DIR/fingerprint.txt"
fingerprint > "$FP_FILE" 2>/dev/null || true

USER_FILE="$TMP_DIR/user.txt"
{
  echo "FAILED_CMD:"
  printf '%s\n' "$FAILED_CMD"
  echo ""
  echo "STDERR_TAIL (last 80 lines):"
  cat "$TAIL_FILE"
  echo ""
  echo "REPO_FINGERPRINT (files/dirs present at repo root):"
  cat "$FP_FILE"
  echo ""
  echo "Respond with the single JSON repair object as specified in the system prompt."
} > "$USER_FILE"

RAW_OUT="$TMP_DIR/llm.txt"
# Use call-llm.sh's @file form to avoid ARG_MAX. Low temp, small max_tokens — repair is tiny.
if ! bash "$SCRIPT_DIR/call-llm.sh" "$RAW_OUT" "@$REPAIR_SYS" "@$USER_FILE" 0 1024 >/dev/null 2>&1; then
  echo "::warning::agentic repair LLM call failed" >&2
  printf '{"give_up":true,"reason":"LLM call failed","repair_commands":[],"retry_cmd":"","diagnosis":""}\n' > "$OUT_JSON"
  exit 1
fi

# Extract the first {...} JSON object even if the model adds stray prose/fences.
EXTRACTED=$(python3 - "$RAW_OUT" <<'PY' 2>/dev/null
import json, re, sys
raw = open(sys.argv[1], encoding='utf-8', errors='replace').read().strip()
# Strip ```json ... ``` fences if present
m = re.search(r'```(?:json)?\s*(\{.*?\})\s*```', raw, re.DOTALL)
candidate = m.group(1) if m else raw
# Otherwise take from first { to matching }
if not candidate.startswith('{'):
    i = candidate.find('{')
    if i >= 0:
        candidate = candidate[i:]
try:
    obj = json.loads(candidate)
except Exception:
    # Best-effort: trim trailing junk after the last }
    end = candidate.rfind('}')
    if end > 0:
        try:
            obj = json.loads(candidate[:end+1])
        except Exception:
            print('', end=''); sys.exit(0)
    else:
        print('', end=''); sys.exit(0)
# Normalize schema fields & coerce types so the bash caller doesn't crash on nulls.
out = {
  "diagnosis": str(obj.get("diagnosis") or "")[:300],
  "reason":    str(obj.get("reason") or "")[:300],
  "give_up":   bool(obj.get("give_up", False)),
  "repair_commands": [str(c) for c in (obj.get("repair_commands") or []) if c][:6],
  "retry_cmd": str(obj.get("retry_cmd") or ""),
}
print(json.dumps(out))
PY
)

if [[ -z "$EXTRACTED" ]]; then
  echo "::warning::agentic repair: could not parse LLM JSON response" >&2
  printf '{"give_up":true,"reason":"unparseable repair response","repair_commands":[],"retry_cmd":"","diagnosis":""}\n' > "$OUT_JSON"
  exit 1
fi

echo "$EXTRACTED" > "$OUT_JSON"

# Exit 0 if we have a usable plan, 1 if model gave up.
if [[ "$(jq -r '.give_up' "$OUT_JSON")" == "true" ]]; then
  exit 1
fi
exit 0
