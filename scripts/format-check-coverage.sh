#!/usr/bin/env bash
# Format minimum_check_coverage from Pass 1 (LLM) into PR comment artifacts.
# No stack detection and no hardcoded commands — only transforms JSON.
set -euo pipefail
source "$(dirname "$0")/common.sh"

OUT_JSON="${AGENTIC_TMP}/check-coverage.json"
OUT_MD="${AGENTIC_TMP}/check-coverage.md"
CMD_FILE="${AGENTIC_TMP}/ai-commands.json"

write_empty() {
  local summary="$1"
  jq -n --arg summary "$summary" \
    '{stack:"unknown",status:"not_assessed",summary:$summary,gap_count:0,expectations:[]}' > "$OUT_JSON"
  {
    echo "## Minimum check coverage"
    echo ""
    echo "$summary"
    echo ""
  } > "$OUT_MD"
  agentic_log "  Check coverage: not assessed"
}

[[ -f "$CMD_FILE" ]] || { write_empty "Check coverage not available (commands file missing)."; exit 0; }

if ! jq -e '.minimum_check_coverage' "$CMD_FILE" &>/dev/null; then
  write_empty "Check coverage was not returned by Pass 1. Re-run the pipeline or ensure AI Pass 1 completes successfully."
  exit 0
fi

STACK=$(jq -r '.stack.language // "unknown"' "$CMD_FILE")

jq --arg stack "$STACK" '
  .minimum_check_coverage as $c
  | ($c.categories // []) as $cats
  | ($cats | map(select(
      (.repo_configured == false or .repo_configured == "false")
      and (.pipeline_planned == false or .pipeline_planned == "false")
    ))) as $gaps
  | {
      stack: $stack,
      status: (if ($gaps | length) > 0 then "gaps" else "complete" end),
      summary: ($c.summary // ""),
      gap_count: ($gaps | length),
      expectations: [
        $cats[] | {
          id: (.id // ""),
          label: (.label // ""),
          repo_configured: (.repo_configured == true),
          pipeline_planned: (.pipeline_planned == true),
          recommendation: (.recommendation // ""),
          auto_note: (.notes // ""),
          is_gap: (
            (.repo_configured == false or .repo_configured == "false")
            and (.pipeline_planned == false or .pipeline_planned == "false")
          )
        }
      ]
    }
  ' --arg stack "$STACK" "$CMD_FILE" > "$OUT_JSON"

SUMMARY=$(jq -r '.summary' "$OUT_JSON")
GAP_COUNT=$(jq -r '.gap_count' "$OUT_JSON")
EXPECTATIONS=$(jq '.expectations' "$OUT_JSON")

{
  echo "## Minimum check coverage (${STACK})"
  echo ""
  echo "$SUMMARY"
  echo ""
  if [[ "$GAP_COUNT" -gt 0 ]]; then
    echo "### Action recommended for your team"
    echo ""
    echo "$EXPECTATIONS" | jq -r '.[] | select(.is_gap == true) | "- **\(.label)**: \(.recommendation)"'
    echo ""
  fi
  if [[ "$(echo "$EXPECTATIONS" | jq 'length')" -gt 0 ]]; then
    echo "### Coverage matrix"
    echo ""
    echo "| Check | Configured in repo | Planned in this pipeline run |"
    echo "|-------|-------------------|------------------------------|"
    echo "$EXPECTATIONS" | jq -r '.[] | "| \(.label) | \(if .repo_configured then "Yes" else "**No**" end) | \(if .pipeline_planned then "Yes" else "No" end) |"'
    echo ""
    notes=$(echo "$EXPECTATIONS" | jq -r '.[] | select(.auto_note != "") | "- \(.label): \(.auto_note)"' || true)
    if [[ -n "$notes" ]]; then
      echo "### Notes"
      echo ""
      echo "$notes"
      echo ""
    fi
  fi
} > "$OUT_MD"

agentic_log "  Check coverage: $(jq -r '.status' "$OUT_JSON") ($(jq -r '.gap_count' "$OUT_JSON") gap(s))"
