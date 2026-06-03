#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

agentic_log ""
agentic_log "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
agentic_log "┃          PAYLOAD: Custom Instructions Analysis         ┃"
agentic_log "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
agentic_log ""

PAYLOAD=""
SOURCE="none"
if [[ -f "${AGENTIC_TMP}/caller-custom-instructions.txt" ]]; then
  PAYLOAD=$(cat "${AGENTIC_TMP}/caller-custom-instructions.txt")
  SOURCE="workflow_input"
elif [[ -f "${AGENTIC_TMP}/repo-custom-instructions.txt" ]]; then
  PAYLOAD=$(cat "${AGENTIC_TMP}/repo-custom-instructions.txt")
  SOURCE="agentic_review_yml"
fi

if [[ -z "$PAYLOAD" ]]; then
  agentic_log "  No custom payload provided — AI will auto-detect everything"
  write_github_output "has_payload" "false"
  echo "" > "${AGENTIC_TMP}/validated-payload.txt"
  exit 0
fi

agentic_log "  Source: ${SOURCE}"
VALIDATED=""
REJECTED=""
WARNINGS=""

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue
  LOWER=$(echo "$line" | tr '[:upper:]' '[:lower:]')

  if echo "$LOWER" | grep -qE "(don.?t run|do not run|skip|ignore|disable|never run|exclude|bypass|suppress|hide|don.?t check|do not check|don.?t scan|do not scan|don.?t report|do not report)"; then
    REJECTED="${REJECTED}    REJECTED (suppression attempt): ${line}\n"
    continue
  fi
  if echo "$LOWER" | grep -qE "(password|token|key|secret)\s*[:=]\s*['\"]?[A-Za-z0-9+/=_-]{8,}"; then
    REJECTED="${REJECTED}    REJECTED (contains credential value): ${line}\n"
    continue
  fi
  if echo "$LOWER" | grep -qE "(always approve|must approve|force approve|never reject|auto.?approve|verdict.?must.?be)"; then
    REJECTED="${REJECTED}    REJECTED (verdict manipulation): ${line}\n"
    continue
  fi
  if echo "$LOWER" | grep -qE "(curl.*post|wget.*post|send.*to|upload.*to|exfil)"; then
    REJECTED="${REJECTED}    REJECTED (data exfiltration attempt): ${line}\n"
    continue
  fi
  if echo "$LOWER" | grep -qE "(run |use |pass |build |install |set |add |include |configure |enable |docker.?build|--build-arg|--secret|npm |pnpm |yarn |pip |go |cargo |mvn |gradle )"; then
    VALIDATED="${VALIDATED}${line}\n"
    continue
  fi
  if echo "$LOWER" | grep -qE "(this (repo|project|app)|we use|our |needs |requires |depends on|dockerfile|docker.?compose|environment|variable|argument|artifactory|registry|npm.?rc)"; then
    VALIDATED="${VALIDATED}${line}\n"
    continue
  fi
  WARNINGS="${WARNINGS}    UNCLEAR (included with caution): ${line}\n"
  VALIDATED="${VALIDATED}${line}\n"
done <<< "$PAYLOAD"

[[ -n "$REJECTED" ]] && echo -e "  ⚠️  REJECTED instructions:\n$REJECTED"
[[ -n "$WARNINGS" ]] && echo -e "  ⚡ UNCLEAR instructions:\n$WARNINGS"

if [[ -n "$VALIDATED" ]]; then
  echo -e "$VALIDATED" > "${AGENTIC_TMP}/validated-payload.txt"
  write_github_output "has_payload" "true"
else
  echo "" > "${AGENTIC_TMP}/validated-payload.txt"
  write_github_output "has_payload" "false"
fi
