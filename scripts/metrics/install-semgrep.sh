#!/usr/bin/env bash
# Install a pinned Semgrep version (reproducible across ~10k caller repos).
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

SEMGREP_VERSION="${SEMGREP_VERSION:-1.97.0}"

# Ensure user-site scripts are on PATH (macOS / --user pip installs)
USER_BIN="$(python3 -c 'import site; print(site.USER_BASE + "/bin")' 2>/dev/null || true)"
[[ -n "$USER_BIN" && -d "$USER_BIN" ]] && export PATH="${USER_BIN}:${PATH}"

semgrep_ok() {
  # Must actually invoke Semgrep — a broken install can still be on PATH.
  set +e
  local out
  out="$(semgrep --version 2>/dev/null | head -1)"
  local rc=$?
  if [[ $rc -ne 0 || -z "$out" ]]; then
    out="$(python3 -m semgrep --version 2>/dev/null | head -1)"
    rc=$?
  fi
  set -e
  [[ $rc -eq 0 && -n "$out" ]]
}

if semgrep_ok; then
  agentic_log "  Semgrep present: $(semgrep --version 2>/dev/null | head -1 || python3 -m semgrep --version 2>/dev/null | head -1)"
  exit 0
fi

agentic_log "  Installing semgrep==${SEMGREP_VERSION} (+ setuptools for pkg_resources)"
# setuptools provides pkg_resources — required by opentelemetry-instrumentation
# on some GitHub runner Python 3.12 images (semgrep import otherwise crashes).
python3 -m pip install --quiet "setuptools>=65" "semgrep==${SEMGREP_VERSION}" \
  || pip3 install --quiet "setuptools>=65" "semgrep==${SEMGREP_VERSION}"
[[ -n "$USER_BIN" && -d "$USER_BIN" ]] && export PATH="${USER_BIN}:${PATH}"

if ! semgrep_ok; then
  agentic_log "  ⚠ Semgrep install completed but --version still fails"
  exit 1
fi
agentic_log "  Installed: $(semgrep --version 2>/dev/null | head -1 || python3 -m semgrep --version 2>/dev/null | head -1)"
