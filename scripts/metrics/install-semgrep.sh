#!/usr/bin/env bash
# Install a pinned Semgrep version (reproducible across ~10k caller repos).
set -euo pipefail
# shellcheck source=../common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

SEMGREP_VERSION="${SEMGREP_VERSION:-1.97.0}"

if command -v semgrep >/dev/null 2>&1; then
  agentic_log "  Semgrep present: $(semgrep --version 2>/dev/null | head -1)"
  exit 0
fi

agentic_log "  Installing semgrep==${SEMGREP_VERSION}"
python3 -m pip install --quiet "semgrep==${SEMGREP_VERSION}" \
  || pip3 install --quiet "semgrep==${SEMGREP_VERSION}"
agentic_log "  Installed: $(semgrep --version 2>/dev/null | head -1)"
