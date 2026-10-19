#!/usr/bin/env bash
# Cyclomatic complexity via Lizard on PR-changed code files.
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

METRICS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIZARD_VERSION="${LIZARD_VERSION:-1.17.10}"
RAW="${AGENTIC_TMP}/lizard-raw.csv"
OUT="${AGENTIC_TMP}/lizard-findings.json"
LANG_FILE="${AGENTIC_TMP}/metrics-languages.json"
CHANGED="${AGENTIC_TMP}/pr-changed-files.txt"
THRESHOLD="${LIZARD_COMPLEXITY_THRESHOLD:-15}"

mkdir -p "$AGENTIC_TMP"
echo '[]' > "$OUT"

agentic_log "┌─ lizard (complexity) ─┐"

CODE_COUNT=$(jq -r '.pr_code_file_count // 0' "$LANG_FILE" 2>/dev/null || echo 0)
if [[ "${CODE_COUNT}" -eq 0 ]]; then
  agentic_log "  No PR code files — skip lizard"
  exit 0
fi

if ! command -v lizard >/dev/null 2>&1; then
  agentic_log "  Installing lizard==${LIZARD_VERSION}"
  python3 -m pip install --quiet "lizard==${LIZARD_VERSION}" \
    || pip3 install --quiet "lizard==${LIZARD_VERSION}"
fi

TARGETS_FILE="${AGENTIC_TMP}/lizard-targets.txt"
: > "$TARGETS_FILE"
jq -r '.pr_code_files[]?' "$LANG_FILE" 2>/dev/null | while read -r f; do
  [[ -f "$f" ]] && echo "$f"
done > "$TARGETS_FILE"

if [[ ! -s "$TARGETS_FILE" ]]; then
  agentic_log "  No on-disk targets — skip lizard"
  exit 0
fi
head -n 400 "$TARGETS_FILE" > "${TARGETS_FILE}.trim" && mv "${TARGETS_FILE}.trim" "$TARGETS_FILE"

set +e
# CSV: file, function, long_name, nloc, ccn, token, param, length, location
lizard -C 0 --csv $(tr '\n' ' ' < "$TARGETS_FILE") > "$RAW" 2>"${AGENTIC_TMP}/lizard-stderr.txt"
RC=$?
set -e

if [[ ! -s "$RAW" ]]; then
  agentic_log "  lizard produced no output (exit ${RC})"
  exit 0
fi

python3 "${METRICS_DIR}/normalize-lizard.py" "$RAW" "$CHANGED" "$OUT" "$THRESHOLD"
exit 0
