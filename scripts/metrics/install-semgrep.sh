#!/usr/bin/env bash
# Install a pinned Semgrep into AGENTIC_TMP (isolated) so GHA Python images
# with broken/missing setuptools do not break the scan.
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

SEMGREP_VERSION="${SEMGREP_VERSION:-1.97.0}"
SEMGREP_PREFIX="${AGENTIC_TMP}/semgrep-prefix"
SEMGREP_ENV="${AGENTIC_TMP}/semgrep.env"

semgrep_ok() {
  set +e
  # shellcheck disable=SC1090
  [[ -f "$SEMGREP_ENV" ]] && source "$SEMGREP_ENV"
  local out
  out="$(python3 -m semgrep --version 2>/dev/null | head -1)"
  local rc=$?
  set -e
  [[ $rc -eq 0 && -n "$out" ]]
}

if semgrep_ok; then
  # shellcheck disable=SC1090
  source "$SEMGREP_ENV"
  agentic_log "  Semgrep present: $(python3 -m semgrep --version 2>/dev/null | head -1)"
  exit 0
fi

agentic_log "  Installing semgrep==${SEMGREP_VERSION} into ${SEMGREP_PREFIX}"
rm -rf "$SEMGREP_PREFIX"
mkdir -p "$SEMGREP_PREFIX"

set +e
python3 -m pip install --target "$SEMGREP_PREFIX" --quiet \
  "setuptools>=75" wheel "semgrep==${SEMGREP_VERSION}"
PIP_RC=$?
set -e
if [[ $PIP_RC -ne 0 ]]; then
  agentic_log "  quiet pip failed — retrying with logs"
  python3 -m pip install --target "$SEMGREP_PREFIX" \
    "setuptools>=75" wheel "semgrep==${SEMGREP_VERSION}"
fi

# Persist env for scan-semgrep.sh (same job)
{
  echo "export PYTHONPATH=\"${SEMGREP_PREFIX}\${PYTHONPATH:+:\$PYTHONPATH}\""
  echo "export PATH=\"${SEMGREP_PREFIX}/bin\${PATH:+:\$PATH}\""
} > "$SEMGREP_ENV"
# shellcheck disable=SC1090
source "$SEMGREP_ENV"

if ! semgrep_ok; then
  agentic_log "  ⚠ Semgrep still not runnable after isolated install:"
  set +e
  PYTHONPATH="$SEMGREP_PREFIX" python3 -m semgrep --version 2>&1 | tail -n 25 | while IFS= read -r line; do
    agentic_log "    $line"
  done
  set -e
  exit 0
fi
agentic_log "  Installed: $(python3 -m semgrep --version 2>/dev/null | head -1)"
