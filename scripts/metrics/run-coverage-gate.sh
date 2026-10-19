#!/usr/bin/env bash
# Derive coverage findings for PR-changed files from artifacts or workspace reports.
# Looks in AGENTIC_TMP (checks artifacts) and common coverage output paths.
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

METRICS_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${AGENTIC_TMP}/coverage-findings.json"
CHANGED="${AGENTIC_TMP}/pr-changed-files.txt"
THRESHOLD="${COVERAGE_THRESHOLD_PCT:-80}"

mkdir -p "$AGENTIC_TMP"
echo '[]' > "$OUT"

agentic_log "┌─ coverage (changed files) ─┐"

python3 "${METRICS_DIR}/normalize-coverage.py" \
  "$CHANGED" \
  "$OUT" \
  "$THRESHOLD" \
  "$AGENTIC_TMP" \
  "$(pwd)"

exit 0
