#!/usr/bin/env bash
# Metrics orchestrator (production): PR scope → scanners → quality gate.
#
# Engines (each isolated; empty findings on skip):
#   Semgrep (SAST) · jscpd (duplication) · Lizard (complexity) · coverage
#
# Mode from config/quality-gate.yml or AGENTIC_GATE_MODE:
#   advisory (default) | soft_fail | hard_fail
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

agentic_log ""
agentic_log "═══ Metrics pipeline (multi-stack · monorepo · PR-scoped) ═══"

bash "${SCRIPT_DIR}/filter-pr-diff.sh"

# Scanners — each always exits 0; normalize into *-findings.json
# Semgrep entrypoint runs language detect first (shared by jscpd/lizard).
bash "${SCRIPT_DIR}/run-semgrep.sh"
bash "${SCRIPT_DIR}/run-jscpd.sh"
bash "${SCRIPT_DIR}/run-lizard.sh"
bash "${SCRIPT_DIR}/run-coverage-gate.sh"

# Merge + evaluate (may exit non-zero under soft_fail / hard_fail)
set +e
bash "${SCRIPT_DIR}/apply-quality-gate.sh"
GATE_RC=$?
set -e

agentic_log "═══ Done: findings.json · gate-result.json · quality-gate.md ═══"
exit "$GATE_RC"
