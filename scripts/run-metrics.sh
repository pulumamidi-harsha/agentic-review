#!/usr/bin/env bash
# Metrics orchestrator: load quality-gate package → run enabled engines → gate.
#
# Package (config/packages/<name>.yml) owns which engines/packs run.
# quality-gate.yml owns pass/fail policy. Callers never list scanners.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PIPELINE_DIR="${PIPELINE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
PKG_JSON="${AGENTIC_TMP}/quality-package.json"

agentic_log ""
agentic_log "═══ Quality gate package (PR-scoped · multi-stack) ═══"

bash "${SCRIPT_DIR}/filter-pr-diff.sh"

python3 "${SCRIPT_DIR}/metrics/load-package.py" \
  "${PIPELINE_DIR}/config/quality-gate.yml" \
  "${PIPELINE_DIR}/config/packages" \
  "${PKG_JSON}"

SEMGREP_ON=$(jq -r '.semgrep_enabled // true' "$PKG_JSON")
DUP_ON=$(jq -r '.duplication // true' "$PKG_JSON")
COMPLEX_ON=$(jq -r '.complexity // true' "$PKG_JSON")
COV_ON=$(jq -r '.coverage // true' "$PKG_JSON")

if [[ "$COMPLEX_ON" == "true" ]]; then
  export LIZARD_COMPLEXITY_THRESHOLD
  LIZARD_COMPLEXITY_THRESHOLD=$(jq -r '.complexity_threshold // 15' "$PKG_JSON")
fi
if [[ "$COV_ON" == "true" ]]; then
  export COVERAGE_THRESHOLD_PCT
  COVERAGE_THRESHOLD_PCT=$(jq -r '.coverage_threshold // 80' "$PKG_JSON")
fi

# Semgrep entrypoint runs language detect + package-driven configs
if [[ "$SEMGREP_ON" == "true" ]]; then
  bash "${SCRIPT_DIR}/run-semgrep.sh"
else
  mkdir -p "$AGENTIC_TMP"
  echo '[]' > "${AGENTIC_TMP}/semgrep-findings.json"
  bash "${SCRIPT_DIR}/metrics/detect-languages.sh"
fi

if [[ "$DUP_ON" == "true" ]]; then
  bash "${SCRIPT_DIR}/run-jscpd.sh"
else
  echo '[]' > "${AGENTIC_TMP}/jscpd-findings.json"
fi

if [[ "$COMPLEX_ON" == "true" ]]; then
  bash "${SCRIPT_DIR}/run-lizard.sh"
else
  echo '[]' > "${AGENTIC_TMP}/lizard-findings.json"
fi

if [[ "$COV_ON" == "true" ]]; then
  bash "${SCRIPT_DIR}/run-coverage-gate.sh"
else
  echo '[]' > "${AGENTIC_TMP}/coverage-findings.json"
fi

set +e
bash "${SCRIPT_DIR}/apply-quality-gate.sh"
GATE_RC=$?
set -e

agentic_log "═══ Done: findings.json · gate-result.json · quality-gate.md ═══"
exit "$GATE_RC"
