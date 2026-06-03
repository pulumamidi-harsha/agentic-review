#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if ! should_run_dep_audit; then
  echo "  Dependency audit skipped (quick review_type)"
  echo "" > "${AGENTIC_TMP}/audit-results.txt"
  exit 0
fi

set +e
echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  Dependency Vulnerability Audit                      │"
echo "└─────────────────────────────────────────────────────┘"
echo ""

AUDIT_RESULTS=""
STACK=$(jq -r '.stack.language // "unknown"' ${AGENTIC_TMP}/ai-commands.json 2>/dev/null)
PKG_MGR=$(jq -r '.stack.package_manager // "unknown"' ${AGENTIC_TMP}/ai-commands.json 2>/dev/null)

case "$PKG_MGR" in
  npm|pnpm|yarn)
    echo "  Running npm audit..."
    AUDIT_OUTPUT=$(npm audit --production 2>&1) && AUDIT_EXIT=0 || AUDIT_EXIT=$?
    if [[ $AUDIT_EXIT -ne 0 ]]; then
      VULN_COUNT=$(echo "$AUDIT_OUTPUT" | grep -c "Severity:" 2>/dev/null || echo "?")
      echo "  ⚠ Found vulnerabilities"
      AUDIT_RESULTS="### Dependency Audit (npm) -- ⚠ Vulnerabilities Found"$'\n'
      AUDIT_RESULTS+='```'$'\n'
      AUDIT_RESULTS+="${AUDIT_OUTPUT:0:3000}"$'\n'
      AUDIT_RESULTS+='```'$'\n\n'
    else
      echo "  ✅ No known vulnerabilities"
      AUDIT_RESULTS="### Dependency Audit (npm) -- ✅ PASSED"$'\n\n'
    fi
    ;;
  pip)
    if command -v pip-audit &>/dev/null || pip install pip-audit -q 2>/dev/null; then
      echo "  Running pip-audit..."
      AUDIT_OUTPUT=$(pip-audit 2>&1) && AUDIT_EXIT=0 || AUDIT_EXIT=$?
      if [[ $AUDIT_EXIT -ne 0 ]]; then
        echo "  ⚠ Found vulnerabilities"
        AUDIT_RESULTS="### Dependency Audit (pip) -- ⚠ Vulnerabilities Found"$'\n'
        AUDIT_RESULTS+='```'$'\n'
        AUDIT_RESULTS+="${AUDIT_OUTPUT:0:3000}"$'\n'
        AUDIT_RESULTS+='```'$'\n\n'
      else
        echo "  ✅ No known vulnerabilities"
        AUDIT_RESULTS="### Dependency Audit (pip) -- ✅ PASSED"$'\n\n'
      fi
    else
      echo "  Skipping pip-audit (not available)"
      AUDIT_RESULTS="### Dependency Audit (pip) -- SKIPPED"$'\n\n'
    fi
    ;;
  *)
    if [[ -f go.mod ]]; then
      if command -v govulncheck &>/dev/null || go install golang.org/x/vuln/cmd/govulncheck@latest 2>/dev/null; then
        echo "  Running govulncheck..."
        AUDIT_OUTPUT=$(govulncheck ./... 2>&1) && AUDIT_EXIT=0 || AUDIT_EXIT=$?
        if [[ $AUDIT_EXIT -ne 0 ]]; then
          AUDIT_RESULTS="### Dependency Audit (go) -- ⚠ Vulnerabilities Found"$'\n```\n'"${AUDIT_OUTPUT:0:3000}"$'\n```\n\n'
        else
          AUDIT_RESULTS="### Dependency Audit (go) -- ✅ PASSED"$'\n\n'
        fi
      else
        AUDIT_RESULTS="### Dependency Audit (go) -- SKIPPED"$'\n\n'
      fi
    elif [[ -f Cargo.toml ]]; then
      if command -v cargo-audit &>/dev/null || cargo install cargo-audit --quiet 2>/dev/null; then
        echo "  Running cargo audit..."
        AUDIT_OUTPUT=$(cargo audit 2>&1) && AUDIT_EXIT=0 || AUDIT_EXIT=$?
        if [[ $AUDIT_EXIT -ne 0 ]]; then
          AUDIT_RESULTS="### Dependency Audit (cargo) -- ⚠ Vulnerabilities Found"$'\n```\n'"${AUDIT_OUTPUT:0:3000}"$'\n```\n\n'
        else
          AUDIT_RESULTS="### Dependency Audit (cargo) -- ✅ PASSED"$'\n\n'
        fi
      else
        AUDIT_RESULTS="### Dependency Audit (cargo) -- SKIPPED"$'\n\n'
      fi
    else
      echo "  No dependency audit available for: $PKG_MGR"
      AUDIT_RESULTS="### Dependency Audit -- SKIPPED (unsupported: $PKG_MGR)"$'\n\n'
    fi
    ;;
esac

echo "$AUDIT_RESULTS" > "${AGENTIC_TMP}/audit-results.txt"
