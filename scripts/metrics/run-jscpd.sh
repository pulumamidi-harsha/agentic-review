#!/usr/bin/env bash
# Detect copy-paste duplication (jscpd) on PR-changed paths / roots.
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

METRICS_DIR="$(cd "$(dirname "$0")" && pwd)"
JSCPD_VERSION="${JSCPD_VERSION:-4.0.5}"
RAW="${AGENTIC_TMP}/jscpd-raw.json"
OUT="${AGENTIC_TMP}/jscpd-findings.json"
LANG_FILE="${AGENTIC_TMP}/metrics-languages.json"
CHANGED="${AGENTIC_TMP}/pr-changed-files.txt"

mkdir -p "$AGENTIC_TMP"
echo '[]' > "$OUT"

agentic_log "┌─ jscpd (duplication) ─┐"

# Skip if no code files
CODE_COUNT=$(jq -r '.pr_code_file_count // 0' "$LANG_FILE" 2>/dev/null || echo 0)
if [[ "${CODE_COUNT}" -eq 0 ]]; then
  agentic_log "  No PR code files — skip jscpd"
  exit 0
fi

if ! command -v npx >/dev/null 2>&1; then
  agentic_log "  npx not available — installing node via apt is too heavy; skip jscpd"
  exit 0
fi

# Build path args: unique top-level dirs of changed files (monorepo-friendly)
PATHS_FILE="${AGENTIC_TMP}/jscpd-paths.txt"
: > "$PATHS_FILE"
if [[ -f "$CHANGED" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" || ! -e "$f" ]] && continue
    # Use file itself for precision
    echo "$f" >> "$PATHS_FILE"
  done < "$CHANGED"
fi
# Cap
if [[ -s "$PATHS_FILE" ]]; then
  head -n 300 "$PATHS_FILE" > "${PATHS_FILE}.trim" && mv "${PATHS_FILE}.trim" "$PATHS_FILE"
fi

if [[ ! -s "$PATHS_FILE" ]]; then
  agentic_log "  No on-disk paths — skip jscpd"
  exit 0
fi

REPORT_DIR="${AGENTIC_TMP}/jscpd-report"
rm -rf "$REPORT_DIR"
mkdir -p "$REPORT_DIR"

set +e
# jscpd writes jscpd-report.json into output dir
npx --yes "jscpd@${JSCPD_VERSION}" \
  --silent \
  --reporters json \
  --output "$REPORT_DIR" \
  --min-lines 10 \
  --min-tokens 50 \
  --ignore "**/node_modules/**,**/vendor/**,**/.git/**,**/dist/**,**/build/**,**/.terraform/**,**/coverage/**" \
  -- $(tr '\n' ' ' < "$PATHS_FILE") \
  >"${AGENTIC_TMP}/jscpd-stdout.txt" 2>"${AGENTIC_TMP}/jscpd-stderr.txt"
RC=$?
set -e

# Locate report
if [[ -f "${REPORT_DIR}/jscpd-report.json" ]]; then
  cp "${REPORT_DIR}/jscpd-report.json" "$RAW"
elif [[ -f "jscpd-report.json" ]]; then
  mv jscpd-report.json "$RAW"
else
  agentic_log "  jscpd produced no JSON (exit ${RC}) — empty findings"
  exit 0
fi

python3 "${METRICS_DIR}/normalize-jscpd.py" "$RAW" "$CHANGED" "$OUT"
exit 0
