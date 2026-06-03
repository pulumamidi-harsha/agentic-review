#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

REVIEW_TYPE="${INPUT_REVIEW_TYPE:-${REVIEW_TYPE:-full}}"
SKIP_DOCKER="false"
SKIP_SECURITY="false"
SKIP_CHECKS="false"
MAX_DIFF_LINES="15000"

if [[ -f ".agentic-review.yml" ]]; then
  agentic_log "  Found .agentic-review.yml — loading config"
  write_github_output "has_config" "true"
  SKIP_DOCKER=$(grep -E "^skip_docker:" .agentic-review.yml 2>/dev/null | awk '{print $2}' || echo "false")
  SKIP_SECURITY=$(grep -E "^skip_security:" .agentic-review.yml 2>/dev/null | awk '{print $2}' || echo "false")
  SKIP_CHECKS=$(grep -E "^skip_checks:" .agentic-review.yml 2>/dev/null | awk '{print $2}' || echo "false")
  MAX_DIFF_LINES=$(grep -E "^max_diff_lines:" .agentic-review.yml 2>/dev/null | awk '{print $2}' || echo "15000")
  FILE_INSTRUCTIONS=$(sed -n '/^custom_instructions:/,/^[a-z_]*:/{ /^custom_instructions:/d; /^[a-z_]*:/d; s/^  //; p; }' .agentic-review.yml 2>/dev/null || echo "")
  if [[ -n "$FILE_INSTRUCTIONS" ]]; then
    echo "$FILE_INSTRUCTIONS" > "${AGENTIC_TMP}/repo-custom-instructions.txt"
  fi
else
  agentic_log "  No .agentic-review.yml found — using defaults"
  write_github_output "has_config" "false"
fi

if [[ -n "${INPUT_CUSTOM_INSTRUCTIONS:-}" ]]; then
  agentic_log "  Custom instructions provided via workflow input"
  echo "$INPUT_CUSTOM_INSTRUCTIONS" > "${AGENTIC_TMP}/caller-custom-instructions.txt"
fi

write_github_output "review_type" "$REVIEW_TYPE"
write_github_output "skip_docker" "$SKIP_DOCKER"
write_github_output "skip_security" "$SKIP_SECURITY"
write_github_output "skip_checks" "$SKIP_CHECKS"
write_github_output "max_diff_lines" "$MAX_DIFF_LINES"

# Persist for artifact consumers
cat > "${AGENTIC_TMP}/pipeline-flags.json" <<EOF
{"review_type":"${REVIEW_TYPE}","skip_docker":"${SKIP_DOCKER}","skip_security":"${SKIP_SECURITY}","skip_checks":"${SKIP_CHECKS}","max_diff_lines":${MAX_DIFF_LINES}}
EOF
