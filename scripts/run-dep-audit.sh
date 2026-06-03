#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if ! should_run_dep_audit; then
  echo "  Dependency audit skipped (quick review_type)"
  echo "" > "${AGENTIC_TMP}/audit-results.txt"
  exit 0
fi

set +e
echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  Dependency Vulnerability Audit                      │"
echo "└─────────────────────────────────────────────────────┘"
echo ""

AUDIT_RESULTS=""
WORKDIR="${GITHUB_WORKSPACE:-$PWD}"
export WORKDIR

AUDIT_CMD=""
AUDIT_PURPOSE=""
if [[ -f "${AGENTIC_TMP}/ai-commands.json" ]]; then
  AUDIT_CMD=$(jq -r '.dependency_audit.cmd // empty' "${AGENTIC_TMP}/ai-commands.json" 2>/dev/null)
  AUDIT_PURPOSE=$(jq -r '.dependency_audit.purpose // "Dependency audit"' "${AGENTIC_TMP}/ai-commands.json" 2>/dev/null)
fi

if [[ -z "$AUDIT_CMD" || "$AUDIT_CMD" == "null" ]]; then
  echo "  No dependency_audit command from Pass 1 — skipping"
  AUDIT_RESULTS="### Dependency Audit -- SKIPPED (not configured by Pass 1 for this repository)"$'\n\n'
  echo "$AUDIT_RESULTS" > "${AGENTIC_TMP}/audit-results.txt"
  exit 0
fi

AUDIT_CMD="${AUDIT_CMD//\$\{WORKDIR\}/$WORKDIR}"
AUDIT_CMD="${AUDIT_CMD//\$WORKDIR/$WORKDIR}"

echo "  ${AUDIT_PURPOSE}"
echo "  > ${AUDIT_CMD}"
AUDIT_OUTPUT=$(eval "$AUDIT_CMD" 2>&1) && AUDIT_EXIT=0 || AUDIT_EXIT=$?

if [[ $AUDIT_EXIT -ne 0 ]]; then
  echo "  ⚠ Audit reported issues or failures (exit ${AUDIT_EXIT})"
  AUDIT_RESULTS="### Dependency Audit -- ⚠ Issues or failures"$'\n'
  AUDIT_RESULTS+='```'$'\n'
  AUDIT_RESULTS+='$ '"${AUDIT_CMD}"$'\n'
  AUDIT_RESULTS+="${AUDIT_OUTPUT:0:3000}"$'\n'
  AUDIT_RESULTS+='```'$'\n\n'
else
  echo "  ✅ Audit completed successfully"
  AUDIT_RESULTS="### Dependency Audit -- ✅ PASSED"$'\n'
  AUDIT_RESULTS+='```'$'\n'
  AUDIT_RESULTS+='$ '"${AUDIT_CMD}"$'\n'
  AUDIT_RESULTS+="${AUDIT_OUTPUT:0:1500}"$'\n'
  AUDIT_RESULTS+='```'$'\n\n'
fi

echo "$AUDIT_RESULTS" > "${AGENTIC_TMP}/audit-results.txt"
