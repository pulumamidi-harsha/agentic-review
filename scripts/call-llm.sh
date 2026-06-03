#!/usr/bin/env bash
# Call OpenAI-compatible chat API with retries. Writes raw message to $1 (output file).
set -euo pipefail

OUTPUT_FILE="${1:?output file required}"
SYSTEM_PROMPT="${2:?system prompt required}"
USER_MSG="${3:?user message required}"
TEMPERATURE="${4:-0.1}"
MAX_TOKENS="${5:-4096}"

source "$(dirname "$0")/common.sh"

if [[ -z "${AI_API_ENDPOINT:-}" || -z "${AI_API_KEY:-}" ]]; then
  echo "::warning::AI_API_ENDPOINT or AI_API_KEY not configured"
  exit 1
fi

RESPONSE=""
CURL_EXIT=1
for attempt in 1 2 3; do
  RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "${AI_API_ENDPOINT}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AI_API_KEY}" \
    --max-time 120 \
    -d "$(jq -n \
      --arg system "$SYSTEM_PROMPT" \
      --arg user "$USER_MSG" \
      --arg model "$AI_MODEL" \
      --argjson temp "$TEMPERATURE" \
      --argjson max_tokens "$MAX_TOKENS" \
      '{
        model: $model,
        messages: [
          {role: "system", content: $system},
          {role: "user", content: $user}
        ],
        temperature: $temp,
        max_tokens: $max_tokens
      }')" 2>/tmp/curl-error.txt) || true

  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')
  CURL_EXIT=0

  if [[ "$HTTP_CODE" =~ ^2 ]]; then
    CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    if [[ -n "$CONTENT" ]]; then
      echo "$CONTENT" > "$OUTPUT_FILE"
      exit 0
    fi
  fi

  if [[ "$HTTP_CODE" == "429" || "$HTTP_CODE" =~ ^5 ]]; then
    echo "::warning::LLM attempt ${attempt} failed (HTTP ${HTTP_CODE}), retrying..."
    sleep $((attempt * 5))
    continue
  fi

  echo "::warning::LLM call failed (HTTP ${HTTP_CODE})"
  cat /tmp/curl-error.txt 2>/dev/null || true
  echo "${BODY:0:500}"
  break
done

exit 1
