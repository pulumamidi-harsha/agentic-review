#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [[ "$REVIEW_TYPE" == "security" ]]; then
  echo '{"stack":{"language":"unknown"},"setup_commands":[],"check_commands":[],"dependency_audit":{"cmd":null,"purpose":""},"minimum_check_coverage":{"summary":"Skipped (security review mode)","categories":[]},"runtime_requirements":{}}' > "${AGENTIC_TMP}/ai-commands.json"
  for v in node python go ruby java dotnet php elixir terraform; do
    write_github_output "${v}_version" ""
  done
  exit 0
fi

if [[ -z "${AI_API_ENDPOINT:-}" || -z "${AI_API_KEY:-}" ]]; then
  echo "::error::AI_API_ENDPOINT or AI_API_KEY secret is not configured."
  echo '{"stack":{"language":"unknown"},"setup_commands":[],"check_commands":[],"dependency_audit":{"cmd":null,"purpose":""},"minimum_check_coverage":{"summary":"Skipped (AI not configured)","categories":[]},"runtime_requirements":{}}' > "${AGENTIC_TMP}/ai-commands.json"
  exit 0
fi

SCRIPT_DIR="$(dirname "$0")"
SYSTEM_PROMPT=$(cat "${SCRIPT_DIR}/prompts/pass1-system.txt")

FILE_TREE=$(head -c 6000 "${AGENTIC_TMP}/file-tree.txt" 2>/dev/null || echo "")
CONFIG_FILES=$(head -c 40000 "${AGENTIC_TMP}/config-files.txt" 2>/dev/null || echo "")
CUSTOM_PAYLOAD=$(cat "${AGENTIC_TMP}/validated-payload.txt" 2>/dev/null || echo "")

PR_META=""
if [[ -n "${PR_SIZE:-}" || -n "${DIFF_LINES:-}" ]]; then
  PR_META="## PR context
- Size class: ${PR_SIZE:-unknown}
- Diff lines (truncated to max_diff_lines=${MAX_DIFF_LINES}): ${DIFF_LINES:-unknown}
- Changed files (approx): ${CHANGED_FILES:-unknown}
- Pipeline review_type: ${REVIEW_TYPE:-full}
- Separate pipeline jobs (not in check_commands): dependency audit, security/hygiene scans, SonarQube poll, optional Docker/Trivy when configured
"
fi

PAYLOAD_SECTION=""
if [[ -n "$CUSTOM_PAYLOAD" ]]; then
  PAYLOAD_SECTION="
## REPOSITORY OWNER INSTRUCTIONS (HIGH PRIORITY — interpret into commands)
${CUSTOM_PAYLOAD}

Rules: Owner wins on conflict. Report payload_analysis with MATCH / OWNER ADDED / OWNER OVERRIDE.
Never output secret values — only map to ARTIFACTORY_USERNAME, ARTIFACTORY_AUTH_TOKEN, ORG_PAT names.
"
fi

USER_MSG="${PR_META}
## Repository File Tree
${FILE_TREE}

## Configuration Files
${CONFIG_FILES}
${PAYLOAD_SECTION}

Analyze this repository (monorepo-aware). Return the full JSON schema from the system prompt: stack, stacks, setup_commands, check_commands, dependency_audit, minimum_check_coverage, runtime_requirements, payload_analysis.
Every cmd MUST start with \"cd \${WORKDIR} && \" or \"cd \${WORKDIR}/<subdir> && \"."

if bash "${SCRIPT_DIR}/call-llm.sh" "${AGENTIC_TMP}/ai-pass1-raw.txt" "$SYSTEM_PROMPT" "$USER_MSG" 0 6144; then
  AI_OUTPUT=$(cat "${AGENTIC_TMP}/ai-pass1-raw.txt")
  CLEANED=$(echo "$AI_OUTPUT" | sed 's/^```json//;s/^```//;s/```$//')
  if echo "$CLEANED" | jq '.' > "${AGENTIC_TMP}/ai-commands.json" 2>/dev/null; then
    :
  else
    echo "::warning::AI Pass 1 returned non-JSON; storing raw output"
    echo "$CLEANED" > "${AGENTIC_TMP}/ai-commands.json"
  fi
else
  echo "::error::Pass 1 failed — LLM did not return valid commands. Check AI_API_ENDPOINT is the full URL (e.g. https://…/api/v2/chat/completions) and AI_API_KEY is valid."
  echo '{"stack":{"language":"unknown"},"setup_commands":[],"check_commands":[],"dependency_audit":{"cmd":null,"purpose":""},"minimum_check_coverage":{"summary":"Pass 1 failed — LLM call error (check AI_API_ENDPOINT and AI_API_KEY secrets)","categories":[]},"runtime_requirements":{}}' > "${AGENTIC_TMP}/ai-commands.json"
fi

bash "${SCRIPT_DIR}/format-check-coverage.sh"

log_pass1_summary() {
  local f="${AGENTIC_TMP}/ai-commands.json"
  [[ -f "$f" ]] || return 0

  agentic_log ""
  agentic_log "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
  agentic_log "┃          PASS 1: Detection & Command Plan               ┃"
  agentic_log "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"

  local src="none"
  [[ -f "${AGENTIC_TMP}/instruction-source.txt" ]] && src=$(cat "${AGENTIC_TMP}/instruction-source.txt")
  agentic_log ""
  agentic_log "── Custom instructions (priority: owner > auto-detect) ──"
  if [[ -s "${AGENTIC_TMP}/validated-payload.txt" ]]; then
    agentic_log "  Source: ${src}"
    agentic_log "  Accepted instructions sent to Pass 1:"
    sed 's/^/    /' "${AGENTIC_TMP}/validated-payload.txt"
  else
    agentic_log "  Source: none — Pass 1 uses repo config files only (auto-detect)"
  fi

  agentic_log ""
  agentic_log "── Detected stack ──"
  jq '.' "$f" | jq '{stack, stacks, runtime_requirements}' || true

  agentic_log ""
  agentic_log "── Setup commands ($(jq '.setup_commands | length' "$f")) ──"
  jq -r '.setup_commands[]? | "  [\(.purpose)]\n    \(.cmd)"' "$f" 2>/dev/null || agentic_log "  (none)"

  agentic_log ""
  agentic_log "── Check commands ($(jq '.check_commands | length' "$f")) ──"
  jq -r '.check_commands[]? | "  [\(.confidence)] \(.purpose)\n    \(.cmd)"' "$f" 2>/dev/null || agentic_log "  (none)"

  agentic_log ""
  agentic_log "── Dependency audit ──"
  jq -r '.dependency_audit | if .cmd == null or .cmd == "" then "  (skipped — no cmd from Pass 1)" else "  [\(.purpose)]\n    \(.cmd)" end' "$f" 2>/dev/null

  agentic_log ""
  agentic_log "── Minimum check coverage ──"
  jq -r '.minimum_check_coverage.summary // "not provided"' "$f" 2>/dev/null
  jq -r '.minimum_check_coverage.categories[]? | select(
      (.repo_configured == false or .repo_configured == "false")
      and (.pipeline_planned == false or .pipeline_planned == "false")
    ) | "  GAP: \(.label) — \(.recommendation)"' "$f" 2>/dev/null || true

  agentic_log ""
  agentic_log "── Pass 1 priority analysis (payload_analysis) ──"
  if jq -e '.payload_analysis' "$f" &>/dev/null; then
    jq -r '.payload_analysis | "  source: \(.source // "n/a")\n  accepted_count: \(.accepted_count // 0)\n  overrides:\n" + ((.overrides // []) | map("    - " + .) | join("\n"))' "$f" 2>/dev/null
  else
    agentic_log "  (not returned — model should include payload_analysis when custom instructions exist)"
  fi

  {
    echo "# Pass 1 detection summary"
    echo ""
    echo "## Custom instructions"
    echo "- Source: ${src}"
    if [[ -s "${AGENTIC_TMP}/validated-payload.txt" ]]; then
      echo '```'
      cat "${AGENTIC_TMP}/validated-payload.txt"
      echo '```'
    else
      echo "_Auto-detect from repository config only._"
    fi
    echo ""
    echo "## Commands JSON"
    echo '```json'
    jq '{stack,stacks,setup_commands,check_commands,dependency_audit,minimum_check_coverage,payload_analysis,runtime_requirements}' "$f" 2>/dev/null || cat "$f"
    echo '```'
  } > "${AGENTIC_TMP}/pass1-summary.md"
}

log_pass1_summary

for key in node python go ruby java dotnet php elixir terraform; do
  ver=$(jq -r ".runtime_requirements.${key}_version // empty" "${AGENTIC_TMP}/ai-commands.json" 2>/dev/null)
  write_github_output "${key}_version" "${ver:-}"
done
