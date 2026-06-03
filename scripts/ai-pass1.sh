#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [[ "$REVIEW_TYPE" == "security" ]]; then
  echo '{"stack":{"language":"unknown"},"setup_commands":[],"check_commands":[],"runtime_requirements":{}}' > "${AGENTIC_TMP}/ai-commands.json"
  for v in node python go ruby java dotnet php elixir terraform; do
    write_github_output "${v}_version" ""
  done
  exit 0
fi

if [[ -z "${AI_API_ENDPOINT:-}" || -z "${AI_API_KEY:-}" ]]; then
  echo "::error::AI_API_ENDPOINT or AI_API_KEY secret is not configured."
  echo '{"stack":{"language":"unknown"},"setup_commands":[],"check_commands":[],"runtime_requirements":{}}' > "${AGENTIC_TMP}/ai-commands.json"
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

Analyze this repository (monorepo-aware). Detect all stacks. Emit setup_commands and check_commands.
Every cmd MUST start with \"cd \${WORKDIR} && \" or \"cd \${WORKDIR}/<subdir> && \".
Examples:
- cd \${WORKDIR} && pnpm install
- cd \${WORKDIR}/backend && pytest"

if bash "${SCRIPT_DIR}/call-llm.sh" "${AGENTIC_TMP}/ai-pass1-raw.txt" "$SYSTEM_PROMPT" "$USER_MSG" 0 4096; then
  AI_OUTPUT=$(cat "${AGENTIC_TMP}/ai-pass1-raw.txt")
  CLEANED=$(echo "$AI_OUTPUT" | sed 's/^```json//;s/^```//;s/```$//')
  if echo "$CLEANED" | jq '.' > "${AGENTIC_TMP}/ai-commands.json" 2>/dev/null; then
    :
  else
    echo "::warning::AI Pass 1 returned non-JSON; storing raw output"
    echo "$CLEANED" > "${AGENTIC_TMP}/ai-commands.json"
  fi
else
  echo '{"stack":{"language":"unknown"},"setup_commands":[],"check_commands":[],"runtime_requirements":{}}' > "${AGENTIC_TMP}/ai-commands.json"
fi

jq '.stack' "${AGENTIC_TMP}/ai-commands.json" 2>/dev/null || true

for key in node python go ruby java dotnet php elixir terraform; do
  ver=$(jq -r ".runtime_requirements.${key}_version // empty" "${AGENTIC_TMP}/ai-commands.json" 2>/dev/null)
  write_github_output "${key}_version" "${ver:-}"
done
