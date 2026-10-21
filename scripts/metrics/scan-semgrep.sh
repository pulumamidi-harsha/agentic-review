#!/usr/bin/env bash
# Execute Semgrep with language-selected configs.
# Registry packs can 404 / fail; local package rules must still run.
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

RAW="${AGENTIC_TMP}/semgrep-raw.json"
LANG_FILE="${AGENTIC_TMP}/metrics-languages.json"
CFG_FILE="${AGENTIC_TMP}/semgrep-configs.json"
TARGETS_FILE="${AGENTIC_TMP}/semgrep-targets.txt"
STDERR_FILE="${AGENTIC_TMP}/semgrep-stderr.txt"

mkdir -p "$AGENTIC_TMP"

SCAN_MODE=$(jq -r '.scan_mode // "skip"' "$LANG_FILE" 2>/dev/null || echo skip)
if [[ "$SCAN_MODE" == "skip" ]]; then
  agentic_log "  No scannable code languages/files — skipping Semgrep"
  echo '{"results":[]}' > "$RAW"
  exit 0
fi

EXCLUDE_ARGS=(
  --exclude='node_modules'
  --exclude='.git'
  --exclude='dist'
  --exclude='build'
  --exclude='vendor'
  --exclude='.terraform'
  --exclude='coverage'
  --exclude='.next'
  --exclude='target'
)

: > "$TARGETS_FILE"
if [[ "${METRICS_SCAN_MODE:-}" == "full_repo" || "$SCAN_MODE" == "full_repo" ]]; then
  agentic_log "  Scan mode: full_repo"
  TARGETS=(.)
else
  agentic_log "  Scan mode: changed_files (PR-scoped; monorepo-safe)"
  while IFS= read -r f; do
    [[ -z "$f" || ! -f "$f" ]] && continue
    echo "$f" >> "$TARGETS_FILE"
  done < <(jq -r '.pr_code_files[]?' "$LANG_FILE" 2>/dev/null || true)
  if [[ ! -s "$TARGETS_FILE" ]]; then
    agentic_log "  No existing code files on disk from PR list — skipping"
    echo '{"results":[]}' > "$RAW"
    exit 0
  fi
  TARGET_COUNT=$(wc -l < "$TARGETS_FILE" | tr -d ' ')
  if [[ "$TARGET_COUNT" -gt 400 ]]; then
    agentic_log "  Truncating targets ${TARGET_COUNT} → 400"
    head -n 400 "$TARGETS_FILE" > "${TARGETS_FILE}.trim"
    mv "${TARGETS_FILE}.trim" "$TARGETS_FILE"
  fi
  TARGETS=()
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    TARGETS+=("$t")
  done < "$TARGETS_FILE"
fi

REGISTRY_CONFIGS=()
LOCAL_CONFIGS=()

is_local_config() {
  local c="$1"
  [[ "$c" == /* || "$c" == ./* || "$c" == ../* ]] && return 0
  [[ -e "$c" ]] && return 0
  return 1
}

while IFS= read -r c; do
  [[ -n "$c" ]] || continue
  if is_local_config "$c"; then
    LOCAL_CONFIGS+=("$c")
  else
    REGISTRY_CONFIGS+=("$c")
  fi
done < <(jq -r '.configs[]?' "$CFG_FILE" 2>/dev/null || true)

while IFS= read -r c; do
  [[ -n "$c" ]] || continue
  already=false
  if [[ ${#LOCAL_CONFIGS[@]} -gt 0 ]]; then
    for x in "${LOCAL_CONFIGS[@]}"; do
      [[ "$x" == "$c" ]] && already=true && break
    done
  fi
  if [[ "$already" == false ]] && is_local_config "$c"; then
    LOCAL_CONFIGS+=("$c")
  elif [[ "$already" == false ]]; then
    LOCAL_CONFIGS+=("$c")
  fi
done < <(jq -r '.local_rules[]?' "$CFG_FILE" 2>/dev/null || true)

if [[ ${#REGISTRY_CONFIGS[@]} -eq 0 && ${#LOCAL_CONFIGS[@]} -eq 0 ]]; then
  REGISTRY_CONFIGS=(p/ci)
fi

agentic_log "  Configs: $(printf '%s ' "${REGISTRY_CONFIGS[@]+"${REGISTRY_CONFIGS[@]}"}")$(printf '%s ' "${LOCAL_CONFIGS[@]+"${LOCAL_CONFIGS[@]}"}")"
agentic_log "  Targets: ${#TARGETS[@]} path(s)"
agentic_log "  Local rule paths: ${#LOCAL_CONFIGS[@]}"

USER_BIN="$(python3 -c 'import site; print(site.USER_BASE + "/bin")' 2>/dev/null || true)"
[[ -n "$USER_BIN" && -d "$USER_BIN" ]] && export PATH="${USER_BIN}:${PATH}"
if command -v semgrep >/dev/null 2>&1; then
  SEMGREP=(semgrep)
else
  SEMGREP=(python3 -m semgrep)
fi

json_usable() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file() or p.stat().st_size < 2:
    raise SystemExit(1)
try:
    data = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
# Fatal config download errors → treat as unusable even if exit code was 0
for err in data.get("errors") or []:
    msg = str(err.get("message") or "").lower()
    code = err.get("code")
    if code in (2, 7) or "failed to download" in msg or "invalid configuration" in msg:
        raise SystemExit(2)
raise SystemExit(0)
PY
}

# NOTE: never `return` non-zero under `set -e` — bash will abort the whole script.
# Always return 0 and set SCAN_RC for the caller.
run_scan() {
  local out="$1"
  shift
  local cfg_args=()
  local c
  SCAN_RC=0
  for c in "$@"; do
    [[ -n "$c" ]] || continue
    cfg_args+=(--config "$c")
  done
  if [[ ${#cfg_args[@]} -eq 0 ]]; then
    echo '{"results":[]}' > "$out"
    SCAN_RC=0
    return 0
  fi
  set +e
  "${SEMGREP[@]}" scan "${cfg_args[@]}" --json --quiet --timeout 30 \
    "${EXCLUDE_ARGS[@]}" \
    "${TARGETS[@]}" > "$out" 2>>"$STDERR_FILE"
  local rc=$?
  set -e
  # Semgrep: 0 clean, 1 findings — both OK
  if [[ $rc -ne 0 && $rc -ne 1 ]]; then
    SCAN_RC=$rc
    return 0
  fi
  set +e
  json_usable "$out"
  local usable=$?
  set -e
  if [[ $usable -eq 2 ]]; then
    SCAN_RC=7
    return 0
  fi
  if [[ $usable -ne 0 ]]; then
    SCAN_RC=3
    return 0
  fi
  SCAN_RC=0
  return 0
}

: > "$STDERR_FILE"
PARTIALS=()

# Registry packs — batch first, then one-by-one if batch invalid
if [[ ${#REGISTRY_CONFIGS[@]} -gt 0 ]]; then
  REG_OUT="${AGENTIC_TMP}/semgrep-registry.json"
  run_scan "$REG_OUT" "${REGISTRY_CONFIGS[@]}"
  if [[ "${SCAN_RC:-1}" -eq 0 ]]; then
    PARTIALS+=("$REG_OUT")
    agentic_log "  Registry scan ok"
  else
    agentic_log "  Registry batch failed (exit ${SCAN_RC}); trying packs individually"
    for pack in "${REGISTRY_CONFIGS[@]}"; do
      safe=$(echo "$pack" | tr -c 'A-Za-z0-9._-' '_')
      one="${AGENTIC_TMP}/semgrep-pack-${safe}.json"
      run_scan "$one" "$pack"
      if [[ "${SCAN_RC:-1}" -eq 0 ]]; then
        PARTIALS+=("$one")
        agentic_log "    ✓ $pack"
      else
        agentic_log "    ✗ $pack (skipped)"
      fi
    done
  fi
fi

# Local package rules — always (eval / hotspot parity lives here)
if [[ ${#LOCAL_CONFIGS[@]} -gt 0 ]]; then
  LOC_OUT="${AGENTIC_TMP}/semgrep-local.json"
  run_scan "$LOC_OUT" "${LOCAL_CONFIGS[@]}"
  if [[ "${SCAN_RC:-1}" -eq 0 ]]; then
    PARTIALS+=("$LOC_OUT")
    agentic_log "  Local rules scan ok"
  else
    agentic_log "  ⚠ Local rules scan failed (exit ${SCAN_RC})"
    if [[ -s "$STDERR_FILE" ]]; then
      tail -n 15 "$STDERR_FILE" | while IFS= read -r line; do
        agentic_log "    $line"
      done
    fi
  fi
fi

python3 - "$RAW" "${PARTIALS[@]+"${PARTIALS[@]}"}" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
merged = {"results": [], "errors": []}
seen = set()
for arg in sys.argv[2:]:
    if not arg:
        continue
    path = Path(arg)
    if not path.is_file():
        continue
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        continue
    if not isinstance(data, dict):
        continue
    for err in data.get("errors") or []:
        # Keep informational errors only
        msg = str(err.get("message") or "").lower()
        if "failed to download" in msg or "invalid configuration" in msg:
            continue
        merged["errors"].append(err)
    for r in data.get("results") or []:
        key = (
            r.get("check_id"),
            r.get("path"),
            (r.get("start") or {}).get("line"),
            (r.get("end") or {}).get("line"),
        )
        if key in seen:
            continue
        seen.add(key)
        merged["results"].append(r)
out.write_text(json.dumps(merged) + "\n", encoding="utf-8")
print(f"  Semgrep merged results: {len(merged['results'])}")
PY

exit 0
