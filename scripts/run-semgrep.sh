#!/usr/bin/env bash
# Thin entrypoint: language detect → configs → install → scan → normalize.
# Suitable for single-stack and monorepo callers (~10k repos).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
METRICS_DIR="${SCRIPT_DIR}/metrics"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

agentic_log ""
agentic_log "┌─────────────────────────────────────────────────────┐"
agentic_log "│  Semgrep metrics (stack-aware · PR-scoped)            │"
agentic_log "└─────────────────────────────────────────────────────┘"

bash "${METRICS_DIR}/detect-languages.sh"
bash "${METRICS_DIR}/select-semgrep-configs.sh"
bash "${METRICS_DIR}/install-semgrep.sh"
bash "${METRICS_DIR}/scan-semgrep.sh"

python3 "${METRICS_DIR}/normalize-semgrep.py" \
  "${AGENTIC_TMP}/semgrep-raw.json" \
  "${AGENTIC_TMP}/pr-changed-files.txt" \
  "${AGENTIC_TMP}/semgrep-findings.json"

COUNT=$(jq 'length' "${AGENTIC_TMP}/semgrep-findings.json" 2>/dev/null || echo 0)
IN_DIFF=$(jq '[.[] | select(.in_pr_diff == true)] | length' "${AGENTIC_TMP}/semgrep-findings.json" 2>/dev/null || echo 0)
write_github_output "semgrep_findings" "$COUNT"
write_github_output "semgrep_in_diff" "$IN_DIFF"
exit 0
