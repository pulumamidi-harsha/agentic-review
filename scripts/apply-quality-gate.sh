#!/usr/bin/env bash
# Thin entrypoint: merge findings → evaluate hub quality-gate.yml (advisory).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
METRICS_DIR="${SCRIPT_DIR}/metrics"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PIPELINE_DIR="${PIPELINE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
GATE_FILE="${PIPELINE_DIR}/config/quality-gate.yml"

bash "${METRICS_DIR}/merge-findings.sh"

NEW_LINES=0
if git rev-parse --verify "origin/${GITHUB_BASE_REF:-main}" >/dev/null 2>&1; then
  NEW_LINES=$(git diff --numstat "origin/${GITHUB_BASE_REF:-main}...HEAD" 2>/dev/null \
    | awk '{ add+=$1 } END { print add+0 }' || echo 0)
fi

python3 "${METRICS_DIR}/evaluate-gate.py" \
  "${AGENTIC_TMP}/findings.json" \
  "${GATE_FILE}" \
  "${AGENTIC_TMP}/gate-result.json" \
  "${AGENTIC_TMP}/quality-gate.md" \
  "${NEW_LINES}"

write_github_output "gate_status" "$(jq -r '.status' "${AGENTIC_TMP}/gate-result.json")"
write_github_output "gate_mode" "$(jq -r '.mode' "${AGENTIC_TMP}/gate-result.json")"
exit 0
