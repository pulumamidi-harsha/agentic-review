#!/usr/bin/env bash
# Write the list of files changed in this PR (for metrics / in_pr_diff).
set -euo pipefail
source "$(dirname "$0")/common.sh"

OUT="${AGENTIC_TMP}/pr-changed-files.txt"
mkdir -p "$AGENTIC_TMP"

BASE_REF="${GITHUB_BASE_REF:-main}"
# Prefer origin/base...HEAD; fall back to merge-base with HEAD~ if shallow.
if git rev-parse --verify "origin/${BASE_REF}" >/dev/null 2>&1; then
  git diff --name-only "origin/${BASE_REF}...HEAD" 2>/dev/null | sort -u > "$OUT" || true
elif git rev-parse --verify "${BASE_REF}" >/dev/null 2>&1; then
  git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null | sort -u > "$OUT" || true
else
  git diff --name-only HEAD~1...HEAD 2>/dev/null | sort -u > "$OUT" || true
fi

# Drop empty lines
sed -i.bak '/^$/d' "$OUT" 2>/dev/null || sed -i '' '/^$/d' "$OUT" 2>/dev/null || true
rm -f "${OUT}.bak" 2>/dev/null || true

COUNT=$(wc -l < "$OUT" | tr -d ' ')
agentic_log "  PR changed files: ${COUNT} → ${OUT}"
write_github_output "changed_file_count" "$COUNT"
