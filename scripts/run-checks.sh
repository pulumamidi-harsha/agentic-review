#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

set +e
echo ""
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃          STAGE 3: Running Code Quality Checks         ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""

# Ensure ai-commands.json exists
if [[ ! -f ${AGENTIC_TMP}/ai-commands.json ]]; then
  echo "::warning::No AI commands file found — skipping checks"
  echo "" > ${AGENTIC_TMP}/check-results.txt
  echo "exit_code=0" >> "$GITHUB_OUTPUT"
  echo "passed=0" >> "$GITHUB_OUTPUT"
  echo "failed=0" >> "$GITHUB_OUTPUT"
  echo "setup_failed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

RESULTS=""
OVERALL_EXIT=0
PASSED_COUNT=0
FAILED_COUNT=0
SETUP_FAILED=false

# WORKDIR is the repo root — AI commands use ${WORKDIR} prefix for all paths
WORKDIR="$PWD"
export WORKDIR

echo "--- SETUP: Installing dependencies ---"
SETUP_CMDS=$(jq -r '.setup_commands[]?.cmd // empty' ${AGENTIC_TMP}/ai-commands.json)
REPO_ROOT="$PWD"
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  # Substitute ${WORKDIR} with actual path; also handle commands without it
  cmd="${cmd//\$\{WORKDIR\}/$WORKDIR}"
  cmd="${cmd//\$WORKDIR/$WORKDIR}"
  echo ""
  echo "  > $cmd"
  # Run in subshell so 'cd' commands don't affect subsequent steps
  if (eval "$cmd") 2>&1; then
    echo "  OK: Setup command succeeded"
  else
    echo "  FAIL: Setup command failed (exit $?)"
    SETUP_FAILED=true
  fi
  # Always return to repo root after each setup command
  cd "$REPO_ROOT"
done <<< "$SETUP_CMDS"
echo ""

CHECK_COUNT=$(jq '.check_commands | length' ${AGENTIC_TMP}/ai-commands.json)
echo "--- CHECKS: Running ${CHECK_COUNT} commands ---"

for i in $(seq 0 $((CHECK_COUNT - 1))); do
  CMD=$(jq -r ".check_commands[$i].cmd" ${AGENTIC_TMP}/ai-commands.json)
  PURPOSE=$(jq -r ".check_commands[$i].purpose" ${AGENTIC_TMP}/ai-commands.json)
  CONFIDENCE=$(jq -r ".check_commands[$i].confidence" ${AGENTIC_TMP}/ai-commands.json)
  [[ -z "$CMD" || "$CMD" == "null" ]] && continue
  if [[ "$CONFIDENCE" == "low" ]]; then
    echo "  SKIP (low confidence): ${PURPOSE}"
    RESULTS+="### ${PURPOSE} -- SKIPPED (low confidence)"$'\n\n'
    continue
  fi

  # Substitute ${WORKDIR} with actual repo root path
  CMD="${CMD//\$\{WORKDIR\}/$WORKDIR}"
  CMD="${CMD//\$WORKDIR/$WORKDIR}"

  echo ""
  echo "  [$((i+1))/${CHECK_COUNT}] ${PURPOSE} [${CONFIDENCE}]"
  echo "  > ${CMD}"

  # Run in subshell so 'cd' in commands doesn't affect subsequent checks
  CMD_OUTPUT=$(eval "$CMD" 2>&1) && CMD_EXIT=0 || CMD_EXIT=$?
  cd "$REPO_ROOT"

  if [[ $CMD_EXIT -ne 0 ]]; then
    OVERALL_EXIT=1
    FAILED_COUNT=$((FAILED_COUNT + 1))
    STATUS="FAILED (exit $CMD_EXIT)"
    echo "  RESULT: ${STATUS}"
    echo "$CMD_OUTPUT" | head -30
  else
    PASSED_COUNT=$((PASSED_COUNT + 1))
    STATUS="PASSED"
    echo "  RESULT: ${STATUS}"
    echo "$CMD_OUTPUT" | tail -5
  fi

  RESULTS+="### ${PURPOSE} -- ${STATUS}"$'\n'
  RESULTS+='```'$'\n'
  RESULTS+='$ '"${CMD}"$'\n'
  RESULTS+="${CMD_OUTPUT:0:4000}"$'\n'
  RESULTS+='```'$'\n\n'
done

echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  CHECKS COMPLETE: ${PASSED_COUNT} passed, ${FAILED_COUNT} failed        │"
echo "└─────────────────────────────────────────────────────┘"
if [[ "$SETUP_FAILED" == "true" ]]; then
  echo "⚠ WARNING: Some checks may have failed due to dependency installation failure"
fi

{
  echo "**Summary:** ${PASSED_COUNT} passed, ${FAILED_COUNT} failed"
  if [[ "$SETUP_FAILED" == "true" ]]; then
    echo ""
    echo "> WARNING: Dependency installation failed. Failures below may be due to missing packages, not actual code issues."
    echo ""
  fi
  echo ""
  echo "$RESULTS"
} > ${AGENTIC_TMP}/check-results.txt

echo "exit_code=$OVERALL_EXIT" >> "$GITHUB_OUTPUT"
echo "passed=$PASSED_COUNT" >> "$GITHUB_OUTPUT"
echo "failed=$FAILED_COUNT" >> "$GITHUB_OUTPUT"
echo "setup_failed=$SETUP_FAILED" >> "$GITHUB_OUTPUT"
