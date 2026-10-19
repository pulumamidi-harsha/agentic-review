#!/usr/bin/env bash
# Phase 1 metrics orchestrator: PR diff list → Semgrep → quality gate (advisory).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

agentic_log ""
agentic_log "═══ Phase 1 metrics (advisory quality gate) ═══"

bash "${SCRIPT_DIR}/filter-pr-diff.sh"
bash "${SCRIPT_DIR}/run-semgrep.sh"
bash "${SCRIPT_DIR}/apply-quality-gate.sh"

agentic_log "═══ Metrics complete → findings.json + gate-result.json + quality-gate.md ═══"
exit 0
