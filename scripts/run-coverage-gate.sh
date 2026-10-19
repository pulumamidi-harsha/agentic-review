#!/usr/bin/env bash
# Thin entrypoint: coverage reports → coverage-findings.json
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
bash "${SCRIPT_DIR}/metrics/run-coverage-gate.sh"
exit 0
