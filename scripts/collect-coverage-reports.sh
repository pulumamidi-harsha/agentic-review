#!/usr/bin/env bash
# After AI quality checks: gather lcov/cobertura/istanbul for PR Quality Gate.
set -euo pipefail
source "$(dirname "$0")/common.sh"

OUT_DIR="${AGENTIC_TMP}/coverage-reports"
mkdir -p "$OUT_DIR"

agentic_log "┌─ collect coverage reports (for quality-gate) ─┐"

FOUND=0
while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  base="$(basename "$f")"
  dest="${OUT_DIR}/${FOUND}-${base}"
  cp "$f" "$dest"
  if [[ "$base" == "lcov.info" && ! -f "${OUT_DIR}/lcov.info" ]]; then
    cp "$f" "${OUT_DIR}/lcov.info"
  fi
  agentic_log "  + $f"
  FOUND=$((FOUND + 1))
done < <(
  find . \
    -type f \
    \( -name 'lcov.info' -o -name 'coverage-final.json' -o -name 'cobertura-coverage.xml' -o -name 'coverage.xml' \) \
    -not -path '*/node_modules/*' \
    -not -path '*/.git/*' \
    2>/dev/null | head -40
)

jq -n --argjson n "$FOUND" '{coverage_files_found:$n}' > "${AGENTIC_TMP}/coverage-collect.json"

if [[ "$FOUND" -eq 0 ]]; then
  agentic_log "  No coverage report found — quality gate will skip coverage %."
else
  agentic_log "  Collected ${FOUND} coverage file(s) → ${OUT_DIR}"
fi
exit 0
