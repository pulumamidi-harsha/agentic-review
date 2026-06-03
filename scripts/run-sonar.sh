#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

set +e
echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  SonarQube Results (from PR checks)                  │"
echo "└─────────────────────────────────────────────────────┘"
echo ""

SONAR_RESULTS=""
PR_NUMBER="${GITHUB_EVENT_PULL_REQUEST_NUMBER:-}"
HEAD_SHA="${GITHUB_EVENT_PULL_REQUEST_HEAD_SHA:-}"
REPO="${GITHUB_REPOSITORY:-}"
SONAR_POLL_ATTEMPTS="${SONAR_POLL_ATTEMPTS:-4}"
SONAR_POLL_INTERVAL="${SONAR_POLL_INTERVAL:-30}"

# Strategy: Fetch SonarQube results from the check runs already on this PR
# The SonarQube job runs separately (on self-hosted runner with internal access)
# We query GitHub Checks API to get its results

echo "  Checking for SonarQube results on PR #${PR_NUMBER} (SHA: ${HEAD_SHA:0:7})..."

fetch_check_runs() {
  curl -sS \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/commits/${HEAD_SHA}/check-runs?per_page=100" \
    2>/dev/null
}

for attempt in $(seq 1 "$SONAR_POLL_ATTEMPTS"); do
  CHECK_RUNS=$(fetch_check_runs)
  if ! echo "$CHECK_RUNS" | jq -e '.check_runs' &>/dev/null; then
    echo "  ⚠ Could not fetch check runs (attempt ${attempt})"
    [[ $attempt -lt $SONAR_POLL_ATTEMPTS ]] && sleep "$SONAR_POLL_INTERVAL"
    continue
  fi

  TOTAL_CHECKS=$(echo "$CHECK_RUNS" | jq '.total_count // 0')
  echo "  Attempt ${attempt}/${SONAR_POLL_ATTEMPTS}: ${TOTAL_CHECKS} check runs on commit"

  SONAR_CHECKS=$(echo "$CHECK_RUNS" | jq '[.check_runs[] | select(.app.slug != "github-actions") | select(.name | test("sonar|quality.?gate"; "i"))]')
  SONAR_CHECK_COUNT=$(echo "$SONAR_CHECKS" | jq 'length')

  if [[ "$SONAR_CHECK_COUNT" -eq 0 ]]; then
    [[ $attempt -lt $SONAR_POLL_ATTEMPTS ]] && sleep "$SONAR_POLL_INTERVAL"
    continue
  fi

  SONAR_CHECK=$(echo "$SONAR_CHECKS" | jq '.[0]')
  CHECK_STATUS=$(echo "$SONAR_CHECK" | jq -r '.status')
  if [[ "$CHECK_STATUS" == "in_progress" || "$CHECK_STATUS" == "queued" ]]; then
    echo "  SonarQube still ${CHECK_STATUS} — waiting ${SONAR_POLL_INTERVAL}s..."
    [[ $attempt -lt $SONAR_POLL_ATTEMPTS ]] && sleep "$SONAR_POLL_INTERVAL"
    continue
  fi
  break
done

if ! echo "$CHECK_RUNS" | jq -e '.check_runs' &>/dev/null; then
  echo "" > "${AGENTIC_TMP}/sonar-results.txt"
  write_github_output "sonar_exit" "0"
  exit 0
fi

SONAR_CHECKS=$(echo "$CHECK_RUNS" | jq '[.check_runs[] | select(.app.slug != "github-actions") | select(.name | test("sonar|quality.?gate"; "i"))]')
SONAR_CHECK_COUNT=$(echo "$SONAR_CHECKS" | jq 'length')

if [[ "$SONAR_CHECK_COUNT" -gt 0 ]]; then
  echo "  ✓ Found ${SONAR_CHECK_COUNT} SonarQube check run(s)"

  # Get the most recent SonarQube check
  SONAR_CHECK=$(echo "$SONAR_CHECKS" | jq '.[0]')
  CHECK_NAME=$(echo "$SONAR_CHECK" | jq -r '.name')
  CHECK_STATUS=$(echo "$SONAR_CHECK" | jq -r '.status')
  CHECK_CONCLUSION=$(echo "$SONAR_CHECK" | jq -r '.conclusion // "pending"')
  CHECK_URL=$(echo "$SONAR_CHECK" | jq -r '.html_url // ""')
  CHECK_DETAILS_URL=$(echo "$SONAR_CHECK" | jq -r '.details_url // ""')
  CHECK_OUTPUT_TITLE=$(echo "$SONAR_CHECK" | jq -r '.output.title // ""')
  CHECK_OUTPUT_SUMMARY=$(echo "$SONAR_CHECK" | jq -r '.output.summary // ""')
  CHECK_OUTPUT_TEXT=$(echo "$SONAR_CHECK" | jq -r '.output.text // ""')

  echo "  Check: ${CHECK_NAME}"
  echo "  Status: ${CHECK_STATUS} | Conclusion: ${CHECK_CONCLUSION}"

  if [[ "$CHECK_STATUS" == "completed" ]]; then
    if [[ "$CHECK_CONCLUSION" == "success" ]]; then
      SONAR_RESULTS="### 📊 SonarQube Quality Gate — ✅ PASSED"$'\n\n'
    elif [[ "$CHECK_CONCLUSION" == "failure" ]]; then
      SONAR_RESULTS="### 📊 SonarQube Quality Gate — ❌ FAILED"$'\n\n'
    elif [[ "$CHECK_CONCLUSION" == "neutral" ]]; then
      SONAR_RESULTS="### 📊 SonarQube Quality Gate — ⚠️ WARNING"$'\n\n'
    else
      SONAR_RESULTS="### 📊 SonarQube — ${CHECK_CONCLUSION}"$'\n\n'
    fi

    # Add output title/summary if available
    if [[ -n "$CHECK_OUTPUT_TITLE" && "$CHECK_OUTPUT_TITLE" != "null" ]]; then
      SONAR_RESULTS+="**${CHECK_OUTPUT_TITLE}**"$'\n\n'
    fi

    if [[ -n "$CHECK_OUTPUT_SUMMARY" && "$CHECK_OUTPUT_SUMMARY" != "null" ]]; then
      # Truncate if too long
      SUMMARY_TRUNCATED="${CHECK_OUTPUT_SUMMARY:0:3000}"
      SONAR_RESULTS+="${SUMMARY_TRUNCATED}"$'\n\n'
    fi

    if [[ -n "$CHECK_OUTPUT_TEXT" && "$CHECK_OUTPUT_TEXT" != "null" && ${#CHECK_OUTPUT_TEXT} -gt 5 ]]; then
      TEXT_TRUNCATED="${CHECK_OUTPUT_TEXT:0:2000}"
      SONAR_RESULTS+="<details><summary>Detailed Analysis</summary>"$'\n\n'
      SONAR_RESULTS+="${TEXT_TRUNCATED}"$'\n\n'
      SONAR_RESULTS+="</details>"$'\n\n'
    fi

    # Add link to full results
    if [[ -n "$CHECK_DETAILS_URL" && "$CHECK_DETAILS_URL" != "null" ]]; then
      SONAR_RESULTS+="🔗 [View full SonarQube analysis](${CHECK_DETAILS_URL})"$'\n\n'
    fi
  elif [[ "$CHECK_STATUS" == "in_progress" || "$CHECK_STATUS" == "queued" ]]; then
    SONAR_RESULTS="### 📊 SonarQube — ⏳ In Progress"$'\n\n'
    SONAR_RESULTS+="SonarQube analysis is still running. Results will be available after completion."$'\n\n'
  fi
else
  echo "  ℹ No SonarQube check runs found on this commit"

  # 2. Fallback: Check commit statuses (some SonarQube integrations use statuses instead of checks)
  echo "  Checking commit statuses..."
  STATUSES=$(curl -sS \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/commits/${HEAD_SHA}/statuses" \
    2>/dev/null)

  SONAR_STATUSES=$(echo "$STATUSES" | jq '[.[] | select(.context | test("sonar|quality.?gate"; "i"))]' 2>/dev/null)
  SONAR_STATUS_COUNT=$(echo "$SONAR_STATUSES" | jq 'length' 2>/dev/null || echo "0")

  if [[ "$SONAR_STATUS_COUNT" -gt 0 ]]; then
    echo "  ✓ Found ${SONAR_STATUS_COUNT} SonarQube status(es)"

    SONAR_STATUS=$(echo "$SONAR_STATUSES" | jq '.[0]')
    STATUS_STATE=$(echo "$SONAR_STATUS" | jq -r '.state')
    STATUS_DESC=$(echo "$SONAR_STATUS" | jq -r '.description // ""')
    STATUS_URL=$(echo "$SONAR_STATUS" | jq -r '.target_url // ""')
    STATUS_CONTEXT=$(echo "$SONAR_STATUS" | jq -r '.context')

    echo "  Context: ${STATUS_CONTEXT}"
    echo "  State: ${STATUS_STATE}"

    if [[ "$STATUS_STATE" == "success" ]]; then
      SONAR_RESULTS="### 📊 SonarQube Quality Gate — ✅ PASSED"$'\n\n'
    elif [[ "$STATUS_STATE" == "failure" || "$STATUS_STATE" == "error" ]]; then
      SONAR_RESULTS="### 📊 SonarQube Quality Gate — ❌ FAILED"$'\n\n'
    elif [[ "$STATUS_STATE" == "pending" ]]; then
      SONAR_RESULTS="### 📊 SonarQube — ⏳ Pending"$'\n\n'
    fi

    if [[ -n "$STATUS_DESC" && "$STATUS_DESC" != "null" ]]; then
      SONAR_RESULTS+="${STATUS_DESC}"$'\n\n'
    fi

    if [[ -n "$STATUS_URL" && "$STATUS_URL" != "null" ]]; then
      SONAR_RESULTS+="🔗 [View full SonarQube analysis](${STATUS_URL})"$'\n\n'
    fi
  else
    echo "  ℹ No SonarQube statuses found either"
    echo "  ℹ SonarQube may not be configured for this repository, or the job hasn't run yet"
  fi
fi

# Write results
if [[ -z "$SONAR_RESULTS" ]]; then
  echo "  ℹ No SonarQube results available yet"
  echo "  ℹ Ensure SonarQube job runs on this PR (may need a separate workflow with self-hosted runner)"
fi
echo "$SONAR_RESULTS" > ${AGENTIC_TMP}/sonar-results.txt
echo "sonar_exit=0" >> "$GITHUB_OUTPUT"
