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

# Normalize common endpoint misconfigurations (missing /chat/completions path → HTTP 302).
resolve_llm_endpoint() {
  local url="${AI_API_ENDPOINT}"
  url="${url%/}"
  if [[ "$url" == *"/chat/completions" ]]; then
    echo "$url"
    return
  fi
  case "$url" in
    */api/v2|*/api/v1|*/v1|*/v2)
      echo "${url}/chat/completions"
      ;;
    *)
      echo "$url"
      ;;
  esac
}

LLM_ENDPOINT=$(resolve_llm_endpoint)
if [[ "$LLM_ENDPOINT" != "${AI_API_ENDPOINT%/}" ]]; then
  echo "::notice::AI_API_ENDPOINT normalized to ${LLM_ENDPOINT} (append /chat/completions if your provider uses a different path)"
fi

CURL_OPTS=(
  -sS
  -L
  --post301
  --post302
  --post303
  --max-time 120
  -w "\n%{http_code}"
  -X POST "${LLM_ENDPOINT}"
  -H "Content-Type: application/json"
  -H "Authorization: Bearer ${AI_API_KEY}"
)

REQUEST_BODY=$(jq -n \
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
  }')

for attempt in 1 2 3; do
  RESPONSE=$(curl "${CURL_OPTS[@]}" -d "$REQUEST_BODY" 2>/tmp/curl-error.txt) || true

  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" =~ ^2 ]]; then
    CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    if [[ -n "$CONTENT" ]]; then
      echo "$CONTENT" > "$OUTPUT_FILE"
      exit 0
    fi
    echo "::warning::LLM HTTP ${HTTP_CODE} but response missing choices[0].message.content"
    echo "${BODY:0:400}"
  fi

  if [[ "$HTTP_CODE" == "302" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "307" ]]; then
    echo "::warning::LLM attempt ${attempt} got redirect (HTTP ${HTTP_CODE}). Set AI_API_ENDPOINT to the full chat completions URL (e.g. …/v1/chat/completions or …/api/v2/chat/completions)."
  elif [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    echo "::error::LLM auth failed (HTTP ${HTTP_CODE}) — check AI_API_KEY."
    echo "${BODY:0:300}"
    exit 1
  elif [[ "$HTTP_CODE" == "429" || "$HTTP_CODE" =~ ^5 ]]; then
    echo "::warning::LLM attempt ${attempt} failed (HTTP ${HTTP_CODE}), retrying..."
    sleep $((attempt * 5))
    continue
  else
    echo "::warning::LLM call failed (HTTP ${HTTP_CODE}) endpoint=${LLM_ENDPOINT}"
    cat /tmp/curl-error.txt 2>/dev/null || true
    echo "${BODY:0:500}"
  fi

  break
done

exit 1
