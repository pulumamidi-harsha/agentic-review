#!/usr/bin/env bash
# Run Semgrep and normalize results into finding.schema.json rows.
# Advisory Phase 1: never fails the job on findings (exit 0).
set -euo pipefail
source "$(dirname "$0")/common.sh"

SEMGREP_VERSION="${SEMGREP_VERSION:-1.97.0}"
RAW="${AGENTIC_TMP}/semgrep-raw.json"
NORM="${AGENTIC_TMP}/semgrep-findings.json"
CHANGED_LIST="${AGENTIC_TMP}/pr-changed-files.txt"

mkdir -p "$AGENTIC_TMP"

install_semgrep() {
  if command -v semgrep >/dev/null 2>&1; then
    agentic_log "  Semgrep already installed: $(semgrep --version 2>/dev/null | head -1)"
    return 0
  fi
  agentic_log "  Installing semgrep==${SEMGREP_VERSION}"
  python3 -m pip install --quiet "semgrep==${SEMGREP_VERSION}" || \
    pip3 install --quiet "semgrep==${SEMGREP_VERSION}"
}

map_severity() {
  # Semgrep: ERROR -> error, WARNING -> warning, INFO/others -> info
  local s
  s=$(echo "$1" | tr '[:lower:]' '[:upper:]')
  case "$s" in
    ERROR|CRITICAL|HIGH) echo "error" ;;
    WARNING|MEDIUM) echo "warning" ;;
    *) echo "info" ;;
  esac
}

normalize() {
  local changed_json='[]'
  if [[ -f "$CHANGED_LIST" ]]; then
    changed_json=$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$CHANGED_LIST" 2>/dev/null || echo '[]')
  fi

  if [[ ! -f "$RAW" ]] || ! jq -e '.results' "$RAW" >/dev/null 2>&1; then
    echo '[]' > "$NORM"
    return 0
  fi

  jq --argjson changed "$changed_json" '
    .results // [] | map(
      . as $r |
      ($r.path // $r.extra.fingerprint // "") as $path |
      {
        engine: "semgrep",
        rule_id: ($r.check_id // "unknown"),
        severity: (
          ($r.extra.severity // $r.severity // "WARNING")
          | ascii_upcase
          | if . == "ERROR" or . == "CRITICAL" or . == "HIGH" then "error"
            elif . == "WARNING" or . == "MEDIUM" then "warning"
            else "info" end
        ),
        category: (
          if (($r.check_id // "") | test("security|vuln|injection|xss|sqli"; "i")) then "security"
          elif (($r.check_id // "") | test("secret|credential|password|api.key"; "i")) then "secret"
          else "bug" end
        ),
        path: (if ($path | length) > 0 then $path else null end),
        start_line: ($r.start.line // null),
        end_line: ($r.end.line // null),
        message: ($r.extra.message // $r.check_id // "Semgrep finding"),
        remediation: (
          ($r.extra.fix // $r.extra.metadata.fix // null)
          | if . == null or . == "" then "Review the Semgrep rule and fix or suppress with justification." else . end
        ),
        in_pr_diff: (
          if ($path | length) == 0 then false
          else ($changed | index($path) != null)
          end
        ),
        fingerprint: ($r.extra.fingerprint // "\($r.check_id):\($path):\($r.start.line // 0)"),
        raw: null
      }
    )
  ' "$RAW" > "$NORM"
}

agentic_log ""
agentic_log "┌─────────────────────────────────────────────────────┐"
agentic_log "│  Semgrep (normalized → finding schema)               │"
agentic_log "└─────────────────────────────────────────────────────┘"

install_semgrep

# Prefer security-ish packs that work offline in CI; fall back to p/ci
CONFIGS=("p/ci" "p/security-audit")
SCAN_OK=0
for cfg in "${CONFIGS[@]}"; do
  agentic_log "  Scanning with --config ${cfg}"
  set +e
  semgrep scan --config "$cfg" --json --quiet --error --timeout 30 \
    --exclude='node_modules' --exclude='.git' --exclude='dist' --exclude='build' \
    --exclude='vendor' --exclude='.terraform' \
    . > "$RAW" 2>"${AGENTIC_TMP}/semgrep-stderr.txt"
  RC=$?
  set -e
  # 0 = clean, 1 = findings, other = tool error
  if [[ $RC -eq 0 || $RC -eq 1 ]]; then
    SCAN_OK=1
    break
  fi
  agentic_log "  Semgrep config ${cfg} failed (exit ${RC}); trying next…"
done

if [[ $SCAN_OK -ne 1 ]]; then
  agentic_log "  ⚠ Semgrep could not run; emitting empty findings"
  echo '{"results":[]}' > "$RAW"
fi

normalize
COUNT=$(jq 'length' "$NORM" 2>/dev/null || echo 0)
IN_DIFF=$(jq '[.[] | select(.in_pr_diff == true)] | length' "$NORM" 2>/dev/null || echo 0)
agentic_log "  Semgrep findings: ${COUNT} total · ${IN_DIFF} in PR diff"
write_github_output "semgrep_findings" "$COUNT"
write_github_output "semgrep_in_diff" "$IN_DIFF"
exit 0
