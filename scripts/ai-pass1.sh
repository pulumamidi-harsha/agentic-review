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
DOC_FILES=$(head -c 30000 "${AGENTIC_TMP}/doc-files.txt" 2>/dev/null || echo "")
PKGMGR_INVENTORY=$(cat "${AGENTIC_TMP}/pkgmgr-inventory.txt" 2>/dev/null || echo "")
IAC_INVENTORY=$(cat "${AGENTIC_TMP}/iac-context.txt" 2>/dev/null || echo "")
IAC_CONFIG=$(head -c 50000 "${AGENTIC_TMP}/iac-config-files.txt" 2>/dev/null || echo "")
CHANGED_FILES_LIST=$(head -n 80 "${AGENTIC_TMP}/pr-changed-files.txt" 2>/dev/null | sed 's/^/- /' || echo "- (none)")
CUSTOM_PAYLOAD=$(cat "${AGENTIC_TMP}/validated-payload.txt" 2>/dev/null || echo "")

PR_META=""
if [[ -n "${PR_SIZE:-}" || -n "${DIFF_LINES:-}" ]]; then
  PR_SCOPE_HINT=""
  if [[ -f "${AGENTIC_TMP}/pr-scope.txt" ]]; then
    PR_SCOPE_HINT="- PR scope: $(cat "${AGENTIC_TMP}/pr-scope.txt")"
  fi
  PR_META="## PR context
- Size class: ${PR_SIZE:-unknown}
- Diff lines (truncated to max_diff_lines=${MAX_DIFF_LINES}): ${DIFF_LINES:-unknown}
- Changed files (approx): ${CHANGED_FILES:-unknown}
${PR_SCOPE_HINT}
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

IAC_SECTION=""
if [[ -n "$IAC_INVENTORY" ]] && jq -e '.is_iac_repo == true' "${AGENTIC_TMP}/iac-inventory.json" &>/dev/null; then
  IAC_JSON=$(cat "${AGENTIC_TMP}/iac-inventory.json" 2>/dev/null || echo '{}')
  IAC_SECTION="
## IaC / Terraform inventory (authoritative — use for deploy roots and PR-affected validation)
${IAC_INVENTORY}

## IaC inventory JSON
${IAC_JSON}

## IaC configuration files (backend.tf, terraform.tfvars, CI workflows, deployment docs)
${IAC_CONFIG}
"
fi

USER_MSG="${PR_META}
## Changed files in this PR (use for PR-scoped checks — especially IaC deploy roots)
${CHANGED_FILES_LIST}

## Repository File Tree
${FILE_TREE}

## Configuration Files
${CONFIG_FILES}

## Node package manager evidence (lockfile + manifest paths across the repo — use to set stack.package_manager reliably in monorepos)
${PKGMGR_INVENTORY}

## Documentation (README / CONTRIBUTING / DEVELOPMENT / INSTALL — authoritative for documented bootstrap & install steps)
${DOC_FILES}
${IAC_SECTION}
${PAYLOAD_SECTION}

Analyze this repository (monorepo-aware, IaC-deep when Terraform/inventory present). Return the full JSON schema from the system prompt: stack, stacks, setup_commands, check_commands, dependency_audit, minimum_check_coverage, runtime_requirements, payload_analysis.
For IaC repos: validate pr_affected.deploy_roots from inventory; use -var-file=terraform.tfvars when tfvars exists; when shared modules/infrastructure change, validate all env deploy roots in that stack.
Every cmd MUST start with \"cd \${WORKDIR} && \" or \"cd \${WORKDIR}/<subdir> && \"."

# Stage prompts to disk to avoid ARG_MAX when context grows large (config + docs + IaC).
printf '%s' "$SYSTEM_PROMPT" > "${AGENTIC_TMP}/pass1-system.txt"
printf '%s' "$USER_MSG"      > "${AGENTIC_TMP}/pass1-user.txt"

if bash "${SCRIPT_DIR}/call-llm.sh" "${AGENTIC_TMP}/ai-pass1-raw.txt" "@${AGENTIC_TMP}/pass1-system.txt" "@${AGENTIC_TMP}/pass1-user.txt" 0 6144; then
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

# Workflow-only PRs: never run sandbox lint/test (repo CI is authoritative)
if [[ "$(cat "${AGENTIC_TMP}/pr-scope.txt" 2>/dev/null)" == "workflow_only" ]] \
  && [[ -f "${AGENTIC_TMP}/ai-commands.json" ]]; then
  jq '.setup_commands = []
    | .check_commands = []
    | .minimum_check_coverage.summary = "Sandbox lint/test skipped — workflow-only PR (use your repo CI; actionlint runs in security scans)"' \
    "${AGENTIC_TMP}/ai-commands.json" > "${AGENTIC_TMP}/ai-commands.json.tmp" \
    && mv "${AGENTIC_TMP}/ai-commands.json.tmp" "${AGENTIC_TMP}/ai-commands.json"
  agentic_log "  PR scope workflow_only — cleared Pass 1 sandbox commands"
fi

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
    # Coerce overrides to string (model sometimes returns objects); never fail the script.
    jq -r '.payload_analysis
      | "  source: \(.source // "n/a")\n  accepted_count: \(.accepted_count // 0)\n  overrides:\n"
        + ((.overrides // [])
            | map("    - " + (if type == "string" then . else tostring end))
            | join("\n"))' "$f" 2>/dev/null \
      || agentic_log "  (payload_analysis present but unparseable — non-string overrides)"
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

# Summary logging must never fail the pipeline — it's diagnostic only.
log_pass1_summary || echo "::warning::Pass 1 summary logging failed (non-fatal) — continuing"

for key in node python go ruby java dotnet php elixir terraform; do
  ver=$(jq -r ".runtime_requirements.${key}_version // empty" "${AGENTIC_TMP}/ai-commands.json" 2>/dev/null)
  write_github_output "${key}_version" "${ver:-}"
done
