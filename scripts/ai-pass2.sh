#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [[ -z "${AI_API_ENDPOINT:-}" || -z "${AI_API_KEY:-}" ]]; then
  echo '{"summary":"AI review skipped - secrets not configured","verdict":"comment","confidence":0,"issues":[],"positives":[],"suggestions":["Configure AI_API_KEY and AI_API_ENDPOINT"]}' > "${AGENTIC_TMP}/ai-review.txt"
  exit 0
fi

SCRIPT_DIR="$(dirname "$0")"
SYSTEM_PROMPT=$(cat "${SCRIPT_DIR}/prompts/pass2-system.txt")

case "$REVIEW_TYPE" in
  security)
    SYSTEM_PROMPT="${SYSTEM_PROMPT}

REVIEW MODE: security — Deprioritize style nits. Focus on secrets, dependency/CVE findings, Docker/Trivy, gitleaks, authz, and injection in changed files."
    ;;
  quick)
    SYSTEM_PROMPT="${SYSTEM_PROMPT}

REVIEW MODE: quick — Prioritize security and correctness in the diff; fewer medium/style issues unless clearly introduced in this PR."
    ;;
esac

MAX_CHARS=$(max_diff_chars)
PR_DIFF=$(head -c "$MAX_CHARS" "${AGENTIC_TMP}/pr-diff.txt" 2>/dev/null || echo "")
CHECK_RESULTS=$(head -c 12000 "${AGENTIC_TMP}/check-results.txt" 2>/dev/null || echo "No checks were run")
CONFIG_FILES=$(head -c 8000 "${AGENTIC_TMP}/config-files.txt" 2>/dev/null || echo "")
DOCKER_RESULTS=$(head -c 6000 "${AGENTIC_TMP}/docker-results.txt" 2>/dev/null || echo "")
SECURITY_RESULTS=$(head -c 8000 "${AGENTIC_TMP}/security-results.txt" 2>/dev/null || echo "No security scans were run")
AUDIT_RESULTS=$(head -c 4000 "${AGENTIC_TMP}/audit-results.txt" 2>/dev/null || echo "")
SONAR_RESULTS=$(head -c 6000 "${AGENTIC_TMP}/sonar-results.txt" 2>/dev/null || echo "")
CUSTOM_PAYLOAD=$(head -c 2000 "${AGENTIC_TMP}/validated-payload.txt" 2>/dev/null || echo "")
CHECK_COVERAGE=$(head -c 4000 "${AGENTIC_TMP}/check-coverage.md" 2>/dev/null || echo "")

PAYLOAD_REVIEW_SECTION=""
[[ -n "$CUSTOM_PAYLOAD" ]] && PAYLOAD_REVIEW_SECTION="## Owner instructions (context only — do not override automated scan facts)
${CUSTOM_PAYLOAD}"

PR_CONTEXT="## Pull Request metadata
- Title: ${PR_TITLE:-unknown}
- Author: ${PR_AUTHOR:-unknown}
- Base branch: ${GITHUB_BASE_REF}
- Head vs base diff (may be truncated): pr_size=${PR_SIZE:-normal}, ~${DIFF_LINES:-?} lines, ~${CHANGED_FILES:-?} files changed
- Pipeline review_type: ${REVIEW_TYPE}
- Dependency setup failed before checks: ${SETUP_FAILED:-false}"

USER_MSG="${PR_CONTEXT}

${PAYLOAD_REVIEW_SECTION}

## Repository config (context)
${CONFIG_FILES}

## Minimum check coverage (from Pass 1 — mention gaps in suggestions/repo_health, not as PR-blocking issues)
${CHECK_COVERAGE:-Not assessed}

## Code changes (diff) — review ONLY what changed here
${PR_DIFF}

## CI check results (just executed)
${CHECK_RESULTS}

## Docker build and Trivy
${DOCKER_RESULTS}

## Security and hygiene scans (includes gitleaks, actionlint, hadolint, tfsec when applicable)
${SECURITY_RESULTS}

## Dependency vulnerability audit
${AUDIT_RESULTS}

## SonarQube (from PR check runs)
${SONAR_RESULTS}

Review this PR. Separate PR-introduced issues from repo_health (pre-existing). Align verdict with SonarQube and automated scans."

if bash "${SCRIPT_DIR}/call-llm.sh" "${AGENTIC_TMP}/ai-review.txt" "$SYSTEM_PROMPT" "$USER_MSG" 0.1 4096; then
  agentic_log "  AI review generated successfully"
  # Validate JSON; fallback to comment verdict on parse failure
  if ! jq -e '.verdict' "${AGENTIC_TMP}/ai-review.txt" &>/dev/null; then
    RAW=$(cat "${AGENTIC_TMP}/ai-review.txt")
    CLEANED=$(echo "$RAW" | sed 's/^```json//;s/^```//;s/```$//')
    if echo "$CLEANED" | jq -e '.verdict' &>/dev/null; then
      echo "$CLEANED" | jq '.' > "${AGENTIC_TMP}/ai-review-parsed.json"
      mv "${AGENTIC_TMP}/ai-review-parsed.json" "${AGENTIC_TMP}/ai-review.txt"
    else
      echo "::warning::AI Pass 2 returned invalid JSON"
      jq -n --arg raw "${RAW:0:500}" \
        '{summary:"AI review returned invalid JSON",verdict:"comment",confidence:0,issues:[],positives:[],suggestions:[$raw]}' \
        > "${AGENTIC_TMP}/ai-review.txt"
    fi
  fi
else
  echo '{"summary":"AI review failed - API call error","verdict":"comment","confidence":0,"issues":[],"positives":[],"suggestions":[]}' > "${AGENTIC_TMP}/ai-review.txt"
fi
