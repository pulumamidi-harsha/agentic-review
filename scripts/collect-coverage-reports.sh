#!/usr/bin/env bash
# After AI quality checks: gather lcov/cobertura/istanbul for PR Quality Gate.
set -euo pipefail
source "$(dirname "$0")/common.sh"

OUT_DIR="${AGENTIC_TMP}/coverage-reports"
mkdir -p "$OUT_DIR"

agentic_log "┌─ collect coverage reports (for quality-gate) ─┐"

# Also publish canonical names the quality-gate staging + normalize scripts expect
# (numbered copies alone become 0-coverage-final.json and were previously missed).
stage_canonical() {
  local src="$1" base="$2"
  case "$base" in
    lcov.info)
      cp "$src" "${OUT_DIR}/lcov.info"
      cp "$src" "${AGENTIC_TMP}/lcov.info"
      ;;
    coverage-final.json)
      cp "$src" "${OUT_DIR}/coverage-final.json"
      cp "$src" "${AGENTIC_TMP}/coverage-final.json"
      ;;
    cobertura-coverage.xml|coverage.xml)
      cp "$src" "${OUT_DIR}/${base}"
      cp "$src" "${AGENTIC_TMP}/${base}"
      ;;
  esac
}

FOUND=0
while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  base="$(basename "$f")"
  dest="${OUT_DIR}/${FOUND}-${base}"
  cp "$f" "$dest"
  stage_canonical "$f" "$base"
  agentic_log "  + $f"
  FOUND=$((FOUND + 1))
done < <(
  find . \
    -type f \
    \( -name 'lcov.info' -o -name 'coverage-final.json' -o -name 'cobertura-coverage.xml' -o -name 'coverage.xml' \) \
    -not -path '*/node_modules/*' \
    -not -path '*/.git/*' \
    -not -path '*/coverage-reports/*' \
    2>/dev/null | head -40
)

jq -n --argjson n "$FOUND" '{coverage_files_found:$n}' > "${AGENTIC_TMP}/coverage-collect.json"

if [[ "$FOUND" -eq 0 ]]; then
  agentic_log "  No coverage report found — quality gate will skip coverage %."
else
  agentic_log "  Collected ${FOUND} coverage file(s) → ${OUT_DIR}"
fi
exit 0
