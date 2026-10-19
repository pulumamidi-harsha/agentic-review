#!/usr/bin/env bash
# Metrics orchestrator (thin): PR file list → Semgrep → advisory quality gate.
#
# Layout (each piece has one job — easy to extend for jscpd/lizard later):
#   filter-pr-diff.sh
#   run-semgrep.sh          → metrics/detect|select|install|scan|normalize
#   apply-quality-gate.sh   → metrics/merge-findings + evaluate-gate.py
#
# Always exits 0 in Phase 1 (advisory). Safe for org-wide rollout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

agentic_log ""
agentic_log "═══ Metrics pipeline (advisory · multi-stack / monorepo safe) ═══"

bash "${SCRIPT_DIR}/filter-pr-diff.sh"
bash "${SCRIPT_DIR}/run-semgrep.sh"
bash "${SCRIPT_DIR}/apply-quality-gate.sh"

agentic_log "═══ Done: findings.json · gate-result.json · quality-gate.md ═══"
exit 0
