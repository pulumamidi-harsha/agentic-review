#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if ! should_run_docker; then
  echo "  Docker build skipped (skip_docker or review_type)"
  echo "" > "${AGENTIC_TMP}/docker-results.txt"
  write_github_output "docker_found" "false"
  write_github_output "docker_exit" "0"
  exit 0
fi

set +e
echo ""
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃          STAGE 4: Docker Build & Trivy Scan           ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""

# Auto-detect Dockerfiles in the repo
DOCKERFILES=$(find . -maxdepth 3 \( -name "Dockerfile" -o -name "Dockerfile.*" -o -name "*.Dockerfile" \) \
  -not -path './.git/*' -not -path './node_modules/*' -not -path './.venv/*' 2>/dev/null)

if [[ -z "$DOCKERFILES" ]]; then
  echo "  No Dockerfile found — skipping Docker build & scan"
  echo "docker_found=false" >> "$GITHUB_OUTPUT"
  echo "" > ${AGENTIC_TMP}/docker-results.txt
  exit 0
fi

echo "docker_found=true" >> "$GITHUB_OUTPUT"
DOCKER_RESULTS=""
DOCKER_EXIT=0
MISSING_SECRETS=""

# Build a lookup map of available secrets (env vars starting with SECRET_)
# This allows automatic mapping of Dockerfile ARG names to real values
declare -A SECRET_MAP
SECRET_MAP["ARTIFACTORY_USERNAME"]="${SECRET_ARTIFACTORY_USERNAME:-}"
SECRET_MAP["ARTIFACTORY_AUTH_TOKEN"]="${SECRET_ARTIFACTORY_AUTH_TOKEN:-}"
SECRET_MAP["ORG_PAT"]="${SECRET_ORG_PAT:-}"
SECRET_MAP["GITHUB_TOKEN"]="${SECRET_ORG_PAT:-}"
SECRET_MAP["NPM_TOKEN"]="${SECRET_ARTIFACTORY_AUTH_TOKEN:-}"

# Install Trivy for container scanning
echo "--- Installing Trivy scanner ---"
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin 2>&1 || {
  echo "::warning::Failed to install Trivy — skipping security scan"
  TRIVY_AVAILABLE=false
}
TRIVY_AVAILABLE=${TRIVY_AVAILABLE:-true}

while IFS= read -r dockerfile; do
  [[ -z "$dockerfile" ]] && continue
  echo ""
  echo "  === Building: ${dockerfile} ==="

  # Determine build context (directory containing the Dockerfile)
  BUILD_CONTEXT=$(dirname "$dockerfile")
  IMAGE_TAG="agentic-review-scan:$(echo "$dockerfile" | md5sum | cut -c1-8)"

  # Smart ARG detection: Parse ALL ARG statements from Dockerfile
  # Includes multi-stage builds — scan entire file
  ALL_ARGS=$(grep -E "^ARG " "$dockerfile" 2>/dev/null | awk '{print $2}' | cut -d'=' -f1)
  ARGS_WITHOUT_DEFAULTS=$(grep -E "^ARG " "$dockerfile" 2>/dev/null | grep -v "=" | awk '{print $2}' | cut -d'=' -f1)

  BUILD_ARGS=""
  ARGS_PROVIDED=""
  ARGS_MISSING=""

  if [[ -n "$ALL_ARGS" ]]; then
    echo "  Detected build ARGs in Dockerfile:"
    while IFS= read -r arg; do
      [[ -z "$arg" ]] && continue

      # Check if we have a matching secret for this ARG
      SECRET_VALUE="${SECRET_MAP[$arg]:-}"

      if [[ -n "$SECRET_VALUE" ]]; then
        # We have the secret — pass real value
        BUILD_ARGS+=" --build-arg ${arg}=${SECRET_VALUE}"
        ARGS_PROVIDED+="    ✓ ${arg} (provided from secrets)\n"
      elif echo "$ARGS_WITHOUT_DEFAULTS" | grep -qx "$arg"; then
        # ARG has no default AND we don't have the secret — this might cause build failure
        BUILD_ARGS+=" --build-arg ${arg}=__MISSING__"
        ARGS_MISSING+="    ⚠ ${arg} (REQUIRED but not available in secrets)\n"
        MISSING_SECRETS+="- \`${arg}\` required by \`${dockerfile}\`\n"
      else
        # ARG has a default value — skip, Docker will use default
        ARGS_PROVIDED+="    ○ ${arg} (has default in Dockerfile)\n"
      fi
    done <<< "$ALL_ARGS"

    # Print summary
    if [[ -n "$ARGS_PROVIDED" ]]; then
      echo -e "$ARGS_PROVIDED"
    fi
    if [[ -n "$ARGS_MISSING" ]]; then
      echo -e "  ⚠ Missing secrets (build may fail):"
      echo -e "$ARGS_MISSING"
    fi
  fi

  # Smart BuildKit secret detection: Parse --mount=type=secret,id=XXX patterns
  # Handles Dockerfiles that use BuildKit secrets (more secure than ARGs for credentials)
  BUILDKIT_SECRETS=$(grep -oP 'mount=type=secret,id=\K[a-zA-Z0-9_-]+' "$dockerfile" 2>/dev/null | sort -u)
  SECRET_FLAGS=""
  SECRETS_PROVIDED=""
  SECRETS_MISSING_BK=""
  USE_BUILDKIT=false

  # Map of BuildKit secret IDs to env var names (covers common naming patterns)
  declare -A BUILDKIT_SECRET_MAP
  BUILDKIT_SECRET_MAP["artifactory_user"]="SECRET_ARTIFACTORY_USERNAME"
  BUILDKIT_SECRET_MAP["artifactory_token"]="SECRET_ARTIFACTORY_AUTH_TOKEN"
  BUILDKIT_SECRET_MAP["artifactory_username"]="SECRET_ARTIFACTORY_USERNAME"
  BUILDKIT_SECRET_MAP["artifactory_auth_token"]="SECRET_ARTIFACTORY_AUTH_TOKEN"
  BUILDKIT_SECRET_MAP["npm_token"]="SECRET_ARTIFACTORY_AUTH_TOKEN"
  BUILDKIT_SECRET_MAP["github_token"]="SECRET_ORG_PAT"
  BUILDKIT_SECRET_MAP["org_pat"]="SECRET_ORG_PAT"

  if [[ -n "$BUILDKIT_SECRETS" ]]; then
    USE_BUILDKIT=true
    echo "  Detected BuildKit secrets (--mount=type=secret):"
    while IFS= read -r secret_id; do
      [[ -z "$secret_id" ]] && continue

      # Look up the env var for this secret ID
      ENV_VAR="${BUILDKIT_SECRET_MAP[$secret_id]:-}"
      SECRET_VALUE=""
      if [[ -n "$ENV_VAR" ]]; then
        SECRET_VALUE="${!ENV_VAR:-}"
      fi

      if [[ -n "$SECRET_VALUE" ]]; then
        # Write secret to a temp file for --secret flag
        TMPFILE="${AGENTIC_TMP}/docker-secret-${secret_id}"
        echo -n "$SECRET_VALUE" > "$TMPFILE"
        SECRET_FLAGS+=" --secret id=${secret_id},src=${TMPFILE}"
        SECRETS_PROVIDED+="    ✓ ${secret_id} (mapped from secrets)\n"
      else
        # Secret not available — create placeholder (build will likely fail)
        TMPFILE="${AGENTIC_TMP}/docker-secret-${secret_id}"
        echo -n "" > "$TMPFILE"
        SECRET_FLAGS+=" --secret id=${secret_id},src=${TMPFILE}"
        SECRETS_MISSING_BK+="    ⚠ ${secret_id} (REQUIRED but not available)\n"
        MISSING_SECRETS+="- BuildKit secret \`${secret_id}\` required by \`${dockerfile}\`\n"
      fi
    done <<< "$BUILDKIT_SECRETS"

    if [[ -n "$SECRETS_PROVIDED" ]]; then
      echo -e "$SECRETS_PROVIDED"
    fi
    if [[ -n "$SECRETS_MISSING_BK" ]]; then
      echo -e "  ⚠ Missing BuildKit secrets (build may fail):"
      echo -e "$SECRETS_MISSING_BK"
    fi
  fi

  # Detect if Dockerfile uses BuildKit syntax directive (# syntax=docker/dockerfile:*)
  if grep -q "^# syntax=docker/" "$dockerfile" 2>/dev/null; then
    USE_BUILDKIT=true
  fi

  # Run Docker build (with BuildKit if secrets or syntax directive detected)
  if [[ "$USE_BUILDKIT" == "true" ]]; then
    echo "  Using Docker BuildKit (secrets detected)"
    echo "  > DOCKER_BUILDKIT=1 docker build -t ${IMAGE_TAG} -f ${dockerfile} [secrets] ${BUILD_CONTEXT}"
    BUILD_OUTPUT=$(DOCKER_BUILDKIT=1 docker build -t "${IMAGE_TAG}" -f "${dockerfile}" ${BUILD_ARGS} ${SECRET_FLAGS} "${BUILD_CONTEXT}" 2>&1)
    BUILD_EXIT=$?
  else
    echo "  > docker build -t ${IMAGE_TAG} -f ${dockerfile} ${BUILD_CONTEXT}"
    BUILD_OUTPUT=$(docker build -t "${IMAGE_TAG}" -f "${dockerfile}" ${BUILD_ARGS} "${BUILD_CONTEXT}" 2>&1)
    BUILD_EXIT=$?
  fi

  # Clean up secret files
  rm -f ${AGENTIC_TMP}/docker-secret-* 2>/dev/null

  if [[ $BUILD_EXIT -ne 0 ]]; then
    DOCKER_EXIT=1
    echo "  RESULT: BUILD FAILED (exit ${BUILD_EXIT})"

    # Check if failure is due to missing secrets (ARG or BuildKit)
    if [[ -n "$ARGS_MISSING" || -n "$SECRETS_MISSING_BK" ]] && echo "$BUILD_OUTPUT" | grep -qiE "401|403|unauthorized|authentication|forbidden|npm ERR|pip.*401|could not read"; then
      DOCKER_RESULTS+="### Docker Build: ${dockerfile} — ⚠️ FAILED (missing credentials)"$'\n'
      DOCKER_RESULTS+="The build requires secrets that were not provided:"$'\n'
      DOCKER_RESULTS+="${MISSING_SECRETS}"$'\n'
      DOCKER_RESULTS+="**Action:** Add these secrets to your caller workflow's \`secrets:\` block."$'\n\n'
      DOCKER_RESULTS+='<details><summary>Build output</summary>'$'\n\n```\n'
      DOCKER_RESULTS+="${BUILD_OUTPUT:(-2000)}"$'\n'
      DOCKER_RESULTS+='```\n\n</details>'$'\n\n'
    else
      DOCKER_RESULTS+="### Docker Build: ${dockerfile} — ❌ FAILED (exit ${BUILD_EXIT})"$'\n'
      DOCKER_RESULTS+='```'$'\n'
      DOCKER_RESULTS+="${BUILD_OUTPUT:(-3000)}"$'\n'
      DOCKER_RESULTS+='```'$'\n\n'
    fi
  else
    echo "  RESULT: BUILD PASSED"
    DOCKER_RESULTS+="### Docker Build: ${dockerfile} — ✅ PASSED"$'\n\n'

    # Run Trivy vulnerability scan on the built image
    if [[ "$TRIVY_AVAILABLE" == "true" ]]; then
      echo "  --- Running Trivy security scan on ${IMAGE_TAG} ---"
      TRIVY_OUTPUT=$(trivy image --severity HIGH,CRITICAL --no-progress --exit-code 1 "${IMAGE_TAG}" 2>&1)
      TRIVY_EXIT=$?

      if [[ $TRIVY_EXIT -ne 0 ]]; then
        echo "  RESULT: TRIVY FOUND VULNERABILITIES"
        # Filter to vulnerability detail lines + summary; trivy lists thousands of
        # clean package rows first, so a head-truncation hides the actual findings.
        TRIVY_FILTERED=$(echo "$TRIVY_OUTPUT" | awk '
          /^Report Summary/ { in_summary=1 }
          in_summary && /^[A-Z]/ && !/^Report Summary/ && !/^Total:/ { in_summary=0 }
          in_summary { print; next }
          /CRITICAL|HIGH|Total:|Severity:|^[┌├└]/ { print }
        ' | tail -c 6000)
        [[ -z "$TRIVY_FILTERED" ]] && TRIVY_FILTERED="${TRIVY_OUTPUT:(-6000)}"
        DOCKER_RESULTS+="### Trivy Scan: ${dockerfile} — ⚠️ VULNERABILITIES FOUND"$'\n'
        DOCKER_RESULTS+='```'$'\n'
        DOCKER_RESULTS+="${TRIVY_FILTERED}"$'\n'
        DOCKER_RESULTS+='```'$'\n\n'
      else
        echo "  RESULT: TRIVY PASSED (no HIGH/CRITICAL vulnerabilities)"
        DOCKER_RESULTS+="### Trivy Scan: ${dockerfile} — ✅ PASSED (no HIGH/CRITICAL)"$'\n\n'
      fi
    fi
  fi

  # Clean up image
  docker rmi "${IMAGE_TAG}" 2>/dev/null || true

done <<< "$DOCKERFILES"

# Summary of missing secrets (for the PR comment)
if [[ -n "$MISSING_SECRETS" ]]; then
  DOCKER_RESULTS+="---"$'\n'
  DOCKER_RESULTS+="### ⚠️ Missing Build Secrets"$'\n\n'
  DOCKER_RESULTS+="The following build arguments are required but not available:"$'\n'
  DOCKER_RESULTS+="${MISSING_SECRETS}"$'\n'
  DOCKER_RESULTS+="**To fix:** Add these as secrets in your repository and pass them in the caller workflow:"$'\n'
  DOCKER_RESULTS+='```yaml'$'\n'
  DOCKER_RESULTS+="secrets:"$'\n'
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    arg_name=$(echo "$line" | grep -oP '`\K[^`]+')
    if [[ -n "$arg_name" ]]; then
      DOCKER_RESULTS+="  ${arg_name}: \$"
      DOCKER_RESULTS+="{{"
      DOCKER_RESULTS+=" secrets.${arg_name} "
      DOCKER_RESULTS+="}}"$'\n'
    fi
  done <<< "$MISSING_SECRETS"
  DOCKER_RESULTS+='```'$'\n\n'
fi

echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  DOCKER RESULTS: build exit=$DOCKER_EXIT             │"
echo "└─────────────────────────────────────────────────────┘"

echo "$DOCKER_RESULTS" > ${AGENTIC_TMP}/docker-results.txt
echo "docker_exit=$DOCKER_EXIT" >> "$GITHUB_OUTPUT"
