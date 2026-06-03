#!/usr/bin/env bash
# Supplemental scans: actionlint, hadolint, tfsec, shellcheck, merge conflict markers.
set -euo pipefail
source "$(dirname "$0")/common.sh"

EXTRA_RESULTS=""
EXTRA_EXIT=0

CHANGED=$(pr_changed_files)
[[ -z "$CHANGED" ]] && exit 0

# Merge conflict markers in PR diff
if grep -nE '^\+.*<<<<<<<|^\+.*=======|^\+.*>>>>>>>' "${AGENTIC_TMP}/pr-diff.txt" 2>/dev/null | head -10 | grep -q . 2>/dev/null; then
  MARKERS=$(grep -nE '^\+.*<<<<<<<|^\+.*=======|^\+.*>>>>>>>' "${AGENTIC_TMP}/pr-diff.txt" | head -15)
  EXTRA_RESULTS+="### Merge Conflict Markers -- ❌ FOUND"$'\n'
  EXTRA_RESULTS+='```'$'\n'"${MARKERS}"$'\n''```'$'\n\n'
  EXTRA_EXIT=1
fi

# actionlint on changed workflow files
GHA_CHANGED=$(echo "$CHANGED" | grep -E '^\.github/workflows/.*\.(ya?ml)$' || true)
if [[ -n "$GHA_CHANGED" ]]; then
  if command -v actionlint &>/dev/null || {
    curl -sSfL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash | bash -s -- 1.7.7 2>/dev/null
    sudo mv actionlint /usr/local/bin/ 2>/dev/null || mv actionlint /usr/local/bin/ 2>/dev/null
  }; then
    agentic_log "  Running actionlint on changed workflows..."
    AL_OUT=$(echo "$GHA_CHANGED" | xargs -r actionlint 2>&1) && AL_EXIT=0 || AL_EXIT=$?
    if [[ $AL_EXIT -ne 0 ]]; then
      EXTRA_RESULTS+="### actionlint (GitHub Actions) -- ⚠ Issues"$'\n'
      EXTRA_RESULTS+='```'$'\n'"${AL_OUT:0:3000}"$'\n''```'$'\n\n'
      EXTRA_EXIT=1
    else
      EXTRA_RESULTS+="### actionlint (GitHub Actions) -- ✅ PASSED"$'\n\n'
    fi
  fi
fi

# hadolint on changed Dockerfiles
DOCKER_CHANGED=$(echo "$CHANGED" | grep -iE 'dockerfile' || true)
if [[ -n "$DOCKER_CHANGED" ]]; then
  curl -sSfL https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64 -o /usr/local/bin/hadolint 2>/dev/null && chmod +x /usr/local/bin/hadolint || true
  if command -v hadolint &>/dev/null; then
    agentic_log "  Running hadolint..."
    HL_OUT=""
    while IFS= read -r df; do
      [[ -f "$df" ]] || continue
      HL_OUT+=$(hadolint "$df" 2>&1)$'\n'
    done <<< "$DOCKER_CHANGED"
    if [[ -n "$HL_OUT" ]]; then
      EXTRA_RESULTS+="### hadolint (Dockerfile) -- ⚠ Findings"$'\n'
      EXTRA_RESULTS+='```'$'\n'"${HL_OUT:0:3000}"$'\n''```'$'\n\n'
    else
      EXTRA_RESULTS+="### hadolint (Dockerfile) -- ✅ PASSED"$'\n\n'
    fi
  fi
fi

# tfsec on changed terraform
TF_CHANGED=$(echo "$CHANGED" | grep '\.tf$' || true)
if [[ -n "$TF_CHANGED" ]]; then
  curl -sSfL https://github.com/aquasecurity/tfsec/releases/download/v1.28.11/tfsec-linux-amd64 -o /usr/local/bin/tfsec 2>/dev/null && chmod +x /usr/local/bin/tfsec || true
  if command -v tfsec &>/dev/null; then
    agentic_log "  Running tfsec..."
    TF_OUT=$(tfsec . --minimum-severity HIGH 2>&1) && TF_EXIT=0 || TF_EXIT=$?
    if [[ $TF_EXIT -ne 0 ]]; then
      EXTRA_RESULTS+="### tfsec (Terraform) -- ⚠ Findings"$'\n'
      EXTRA_RESULTS+='```'$'\n'"${TF_OUT:0:3000}"$'\n''```'$'\n\n'
      EXTRA_EXIT=1
    else
      EXTRA_RESULTS+="### tfsec (Terraform) -- ✅ PASSED"$'\n\n'
    fi
  fi
fi

# shellcheck on changed shell scripts
SH_CHANGED=$(echo "$CHANGED" | grep -E '\.(sh|bash)$' || true)
if [[ -n "$SH_CHANGED" ]] && command -v shellcheck &>/dev/null; then
  SC_OUT=$(echo "$SH_CHANGED" | xargs -r shellcheck 2>&1) && SC_EXIT=0 || SC_EXIT=$?
  if [[ $SC_EXIT -ne 0 ]]; then
    EXTRA_RESULTS+="### ShellCheck -- ⚠ Findings"$'\n'
    EXTRA_RESULTS+='```'$'\n'"${SC_OUT:0:2000}"$'\n''```'$'\n\n'
  else
    EXTRA_RESULTS+="### ShellCheck -- ✅ PASSED"$'\n\n'
  fi
fi

if [[ -n "$EXTRA_RESULTS" ]]; then
  echo "$EXTRA_RESULTS" >> "${AGENTIC_TMP}/security-results.txt"
fi

write_github_output "extra_scans_exit" "$EXTRA_EXIT"
