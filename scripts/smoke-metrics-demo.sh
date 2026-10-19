#!/usr/bin/env bash
# End-to-end metrics smoke against examples/monorepo-demo (no GitHub / no LLM).
# Simulates a PR that touches Node + Python + Terraform paths.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="${ROOT}/scripts"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

DEMO="${ROOT}/examples/monorepo-demo"
# Always use a workspace-local dir (ignore ambient AGENTIC_TMP from prior runs)
export AGENTIC_TMP="${ROOT}/.tmp-metrics-smoke"
export PIPELINE_DIR="${ROOT}"
export GITHUB_BASE_REF="${GITHUB_BASE_REF:-main}"
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-bayer-int/agentic-review}"
export COVERAGE_THRESHOLD_PCT="${COVERAGE_THRESHOLD_PCT:-80}"
export LIZARD_COMPLEXITY_THRESHOLD="${LIZARD_COMPLEXITY_THRESHOLD:-15}"
# Keep smoke non-blocking
export AGENTIC_GATE_MODE="${AGENTIC_GATE_MODE:-advisory}"

# Prefer user-site CLIs after pip --user
USER_BIN="$(python3 -c 'import site; print(site.USER_BASE + "/bin")' 2>/dev/null || true)"
[[ -n "$USER_BIN" && -d "$USER_BIN" ]] && export PATH="${USER_BIN}:${PATH}"

rm -rf "$AGENTIC_TMP"
mkdir -p "$AGENTIC_TMP"

agentic_log "═══ Smoke: metrics on monorepo-demo → ${AGENTIC_TMP} ═══"

# Fake PR file list (repo-relative paths as CI would see them)
cat > "${AGENTIC_TMP}/pr-changed-files.txt" <<EOF
examples/monorepo-demo/apps/web/src/index.ts
examples/monorepo-demo/apps/web/test/smoke.test.js
examples/monorepo-demo/services/api/app/main.py
examples/monorepo-demo/services/api/tests/test_health.py
examples/monorepo-demo/infra/main.tf
EOF

# Plant a low-coverage lcov so coverage gate exercises (paths match changed files)
mkdir -p "${AGENTIC_TMP}/coverage"
cat > "${AGENTIC_TMP}/coverage/lcov.info" <<EOF
TN:
SF:examples/monorepo-demo/services/api/app/main.py
LF:10
LH:3
end_of_record
TN:
SF:examples/monorepo-demo/apps/web/src/index.ts
LF:8
LH:8
end_of_record
EOF

# Fake Sonar shadow text
echo "SonarQube Quality Gate passed" > "${AGENTIC_TMP}/sonar-results.txt"

cd "$ROOT"

bash "${SCRIPT_DIR}/metrics/detect-languages.sh"
bash "${SCRIPT_DIR}/run-semgrep.sh"
bash "${SCRIPT_DIR}/run-jscpd.sh"
bash "${SCRIPT_DIR}/run-lizard.sh"
bash "${SCRIPT_DIR}/run-coverage-gate.sh"
bash "${SCRIPT_DIR}/apply-quality-gate.sh"

agentic_log ""
agentic_log "── Artifacts ──"
for f in findings.json gate-result.json quality-gate.md shadow-parity.json \
         semgrep-findings.json jscpd-findings.json lizard-findings.json \
         coverage-findings.json metrics-languages.json; do
  if [[ -f "${AGENTIC_TMP}/${f}" ]]; then
    agentic_log "  ✓ ${f} ($(wc -c < "${AGENTIC_TMP}/${f}" | tr -d ' ') bytes)"
  else
    agentic_log "  ✗ missing ${f}"
    exit 1
  fi
done

jq -e '.schema_version and (.findings | type=="array")' "${AGENTIC_TMP}/findings.json" >/dev/null
jq -e '.mode and .status' "${AGENTIC_TMP}/gate-result.json" >/dev/null
jq -e '.hub_status and (.sonar_present==true)' "${AGENTIC_TMP}/shadow-parity.json" >/dev/null
jq -e '.pr_code_file_count >= 1' "${AGENTIC_TMP}/metrics-languages.json" >/dev/null

# Coverage planted at 30% → expect ≥1 coverage finding
COV=$(jq '[.[] | select(.engine=="coverage" and .severity!="info")] | length' \
  "${AGENTIC_TMP}/coverage-findings.json")
[[ "$COV" -ge 1 ]] || { agentic_log "Expected coverage finding, got ${COV}"; exit 1; }

agentic_log ""
agentic_log "Gate: $(jq -c '{status,mode,blocking,counts}' "${AGENTIC_TMP}/gate-result.json")"
agentic_log "Shadow: $(jq -c . "${AGENTIC_TMP}/shadow-parity.json")"
agentic_log "Engines: $(jq -r '[.findings[].engine] | unique | join(", ")' "${AGENTIC_TMP}/findings.json")"
agentic_log "═══ Smoke PASSED ═══"
exit 0
