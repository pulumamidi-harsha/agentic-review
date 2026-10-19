#!/usr/bin/env bash
# Execute Semgrep with language-selected configs.
# Default: scan PR-changed code files (fast, monorepo-safe at scale).
# METRICS_SCAN_MODE=full_repo → scan tree with excludes (slower).
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

METRICS_DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="${AGENTIC_TMP}/semgrep-raw.json"
LANG_FILE="${AGENTIC_TMP}/metrics-languages.json"
CFG_FILE="${AGENTIC_TMP}/semgrep-configs.json"
TARGETS_FILE="${AGENTIC_TMP}/semgrep-targets.txt"

mkdir -p "$AGENTIC_TMP"

SCAN_MODE=$(jq -r '.scan_mode // "skip"' "$LANG_FILE" 2>/dev/null || echo skip)
if [[ "$SCAN_MODE" == "skip" ]]; then
  agentic_log "  No scannable code languages/files — skipping Semgrep"
  echo '{"results":[]}' > "$RAW"
  exit 0
fi

# Build config args (portable; no mapfile)
CFG_ARGS=()
while IFS= read -r c; do
  [[ -n "$c" ]] || continue
  CFG_ARGS+=(--config "$c")
done < <(jq -r '.configs[]?' "$CFG_FILE" 2>/dev/null || true)
if [[ ${#CFG_ARGS[@]} -eq 0 ]]; then
  CFG_ARGS=(--config p/ci)
fi
CONFIGS_LOG=$(jq -r '.configs // ["p/ci"] | join(" ")' "$CFG_FILE" 2>/dev/null || echo "p/ci")

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

# Target list
: > "$TARGETS_FILE"
if [[ "${METRICS_SCAN_MODE:-}" == "full_repo" || "$SCAN_MODE" == "full_repo" ]]; then
  agentic_log "  Scan mode: full_repo"
  TARGETS=(.)
else
  agentic_log "  Scan mode: changed_files (PR-scoped; monorepo-safe)"
  jq -r '.pr_code_files[]?' "$LANG_FILE" 2>/dev/null | while read -r f; do
    [[ -f "$f" ]] && echo "$f"
  done > "$TARGETS_FILE"
  if [[ ! -s "$TARGETS_FILE" ]]; then
    agentic_log "  No existing code files on disk from PR list — skipping"
    echo '{"results":[]}' > "$RAW"
    exit 0
  fi
  # Cap targets for huge PRs
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

agentic_log "  Configs: ${CONFIGS_LOG}"
agentic_log "  Targets: ${#TARGETS[@]} path(s)"

set +e
semgrep scan "${CFG_ARGS[@]}" --json --quiet --timeout 30 \
  "${EXCLUDE_ARGS[@]}" \
  "${TARGETS[@]}" > "$RAW" 2>"${AGENTIC_TMP}/semgrep-stderr.txt"
RC=$?
set -e

# 0 clean, 1 findings — both OK. Other = retry with p/ci once.
if [[ $RC -ne 0 && $RC -ne 1 ]]; then
  agentic_log "  Semgrep exit ${RC}; retrying with p/ci only"
  set +e
  semgrep scan --config p/ci --json --quiet --timeout 30 \
    "${EXCLUDE_ARGS[@]}" \
    "${TARGETS[@]}" > "$RAW" 2>"${AGENTIC_TMP}/semgrep-stderr.txt"
  RC=$?
  set -e
fi

if [[ $RC -ne 0 && $RC -ne 1 ]]; then
  agentic_log "  ⚠ Semgrep failed; empty results"
  echo '{"results":[]}' > "$RAW"
fi

exit 0
