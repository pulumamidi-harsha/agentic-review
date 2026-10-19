#!/usr/bin/env bash
# Merge findings → evaluate hub quality-gate.yml → optional Sonar shadow.
# Exit code follows gate-result.exit_code (0 advisory; 1 soft/hard when blocking).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
METRICS_DIR="${SCRIPT_DIR}/metrics"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PIPELINE_DIR="${PIPELINE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
GATE_FILE="${PIPELINE_DIR}/config/quality-gate.yml"

bash "${METRICS_DIR}/merge-findings.sh"

NEW_LINES=0
if [[ -n "${AGENTIC_FORCE_NEW_LINES:-}" ]]; then
  NEW_LINES="${AGENTIC_FORCE_NEW_LINES}"
elif git rev-parse --verify "origin/${GITHUB_BASE_REF:-main}" >/dev/null 2>&1; then
  NEW_LINES=$(git diff --numstat "origin/${GITHUB_BASE_REF:-main}...HEAD" 2>/dev/null \
    | awk '{ add+=$1 } END { print add+0 }' || echo 0)
fi

python3 "${METRICS_DIR}/evaluate-gate.py" \
  "${AGENTIC_TMP}/findings.json" \
  "${GATE_FILE}" \
  "${AGENTIC_TMP}/gate-result.json" \
  "${AGENTIC_TMP}/quality-gate.md" \
  "${NEW_LINES}"

# Sonar shadow parity (best-effort; sonar-results.txt may arrive later in finalize)
if [[ -f "${AGENTIC_TMP}/sonar-results.txt" ]]; then
  python3 "${METRICS_DIR}/compare-sonar-shadow.py" \
    "${AGENTIC_TMP}/gate-result.json" \
    "${AGENTIC_TMP}/sonar-results.txt" \
    "${AGENTIC_TMP}/shadow-parity.json" || true
else
  python3 - <<'PY'
import json, os
from pathlib import Path
tmp = Path(os.environ.get("AGENTIC_TMP", "/tmp/agentic-review"))
gate = {}
gp = tmp / "gate-result.json"
if gp.is_file():
    gate = json.loads(gp.read_text(encoding="utf-8"))
out = {
    "hub_status": gate.get("status", "unknown"),
    "sonar_status": "absent",
    "agree": None,
    "sonar_present": False,
    "note": "Sonar results not yet available in this job; finalize re-runs shadow compare.",
}
(tmp / "shadow-parity.json").write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
print("  Shadow: sonar absent in metrics job (finalize will compare)")
PY
fi

STATUS=$(jq -r '.status' "${AGENTIC_TMP}/gate-result.json")
MODE=$(jq -r '.mode' "${AGENTIC_TMP}/gate-result.json")
BLOCKING=$(jq -r '.blocking' "${AGENTIC_TMP}/gate-result.json")
EXIT_CODE=$(jq -r '.exit_code // 0' "${AGENTIC_TMP}/gate-result.json")

write_github_output "gate_status" "$STATUS"
write_github_output "gate_mode" "$MODE"
write_github_output "gate_blocking" "$BLOCKING"

agentic_log "  Quality gate: status=${STATUS} mode=${MODE} blocking=${BLOCKING}"
exit "${EXIT_CODE}"
