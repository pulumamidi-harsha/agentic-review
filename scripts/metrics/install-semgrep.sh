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
  command -v semgrep >/dev/null 2>&1 || python3 -m semgrep --help >/dev/null 2>&1
}

if semgrep_ok; then
  agentic_log "  Semgrep present: $(semgrep --version 2>/dev/null | head -1 || python3 -m semgrep --version 2>/dev/null | head -1)"
  exit 0
fi

agentic_log "  Installing semgrep==${SEMGREP_VERSION}"
python3 -m pip install --quiet "semgrep==${SEMGREP_VERSION}" \
  || pip3 install --quiet "semgrep==${SEMGREP_VERSION}"
[[ -n "$USER_BIN" && -d "$USER_BIN" ]] && export PATH="${USER_BIN}:${PATH}"
agentic_log "  Installed: $(semgrep --version 2>/dev/null | head -1 || python3 -m semgrep --version 2>/dev/null | head -1)"
