#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

agentic_log ""
agentic_log "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
agentic_log "┃          STAGE 1: Repository Context Gathering        ┃"
agentic_log "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"

# fetch base for diff (best-effort)
git fetch origin "${GITHUB_BASE_REF}" --depth=50 2>/dev/null || true

# file tree — two-step to avoid SIGPIPE under pipefail (find | head closes pipe early)
find . -type f \
  -not -path './.git/*' \
  -not -path './node_modules/*' \
  -not -path './dist/*' \
  -not -path './build/*' \
  -not -path './.next/*' \
  -not -path './__pycache__/*' \
  -not -path './.venv/*' \
  -not -path './vendor/*' \
  -not -path './target/*' \
  -not -path './.gradle/*' \
  2>/dev/null | sort -u > "${AGENTIC_TMP}/file-tree-all.txt" || true
head -n 500 "${AGENTIC_TMP}/file-tree-all.txt" > "${AGENTIC_TMP}/file-tree.txt" 2>/dev/null || echo "" > "${AGENTIC_TMP}/file-tree.txt"

git diff "origin/${GITHUB_BASE_REF}...HEAD" -- . \
  ':!package-lock.json' ':!yarn.lock' ':!pnpm-lock.yaml' ':!*.lock' ':!go.sum' ':!Cargo.lock' \
  > "${AGENTIC_TMP}/pr-diff.txt" 2>/dev/null || true

truncate_pr_diff

DIFF_LINES=$(wc -l < "${AGENTIC_TMP}/pr-diff.txt" 2>/dev/null | tr -d ' ' || echo "0")
DIFF_LINES=${DIFF_LINES:-0}
CHANGED_FILES=$(grep -c "^diff --git" "${AGENTIC_TMP}/pr-diff.txt" 2>/dev/null || echo "0")
CHANGED_FILES=${CHANGED_FILES:-0}
agentic_log "  PR diff: ${DIFF_LINES} lines across ${CHANGED_FILES} files"

CONFIG_CONTENT=""
CONFIG_COUNT=0
find . -maxdepth 3 \( \
  -name "package.json" -o -name "tsconfig.json" -o -name "pnpm-workspace.yaml" \
  -o -name "pyproject.toml" -o -name "requirements*.txt" -o -name "setup.py" \
  -o -name "go.mod" -o -name "Cargo.toml" -o -name "Cargo.lock" \
  -o -name "pom.xml" -o -name "build.gradle" -o -name "build.gradle.kts" \
  -o -name "Gemfile" -o -name "Rakefile" -o -name ".rubocop.yml" \
  -o -name "mix.exs" -o -name "composer.json" -o -name "phpstan.neon" \
  -o -name "*.csproj" -o -name "*.sln" \
  -o -name "Makefile" -o -name "Dockerfile" \
  -o -name "eslint.config*" -o -name ".eslintrc*" \
  -o -name "vitest.config*" -o -name "jest.config*" -o -name "pytest.ini" \
  -o -name "nx.json" -o -name "turbo.json" \
  -o -name ".npmrc" -o -name ".yarnrc.yml" \
  -o -name "*.tf" -o -name "Chart.yaml" \
  \) -not -path './.git/*' -not -path './node_modules/*' -not -path './vendor/*' \
  2>/dev/null | sort -u > "${AGENTIC_TMP}/config-paths.txt" || true

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ ! -f "$f" ]] && continue
  if [[ $(wc -c < "$f" 2>/dev/null | tr -d ' ') -lt 50000 ]]; then
    CONFIG_CONTENT+=$'\n=== FILE: '"$f"$' ===\n'
    CONFIG_CONTENT+="$(cat "$f" 2>/dev/null || echo "")"$'\n'
    CONFIG_COUNT=$((CONFIG_COUNT + 1))
  fi
done < <(head -n 25 "${AGENTIC_TMP}/config-paths.txt" 2>/dev/null)

echo "$CONFIG_CONTENT" > "${AGENTIC_TMP}/config-files.txt"
agentic_log "  Config files loaded: ${CONFIG_COUNT}"

PR_SIZE="normal"
if [[ "${DIFF_LINES}" -gt 5000 ]]; then
  PR_SIZE="very_large"
elif [[ "${DIFF_LINES}" -gt 2000 ]]; then
  PR_SIZE="large"
fi

write_github_output "diff_lines" "$DIFF_LINES"
write_github_output "changed_files" "$CHANGED_FILES"
write_github_output "pr_size" "$PR_SIZE"

HAS_DOCKERFILE="false"
if find . -maxdepth 3 \( -name "Dockerfile" -o -name "Dockerfile.*" -o -name "*.Dockerfile" \) \
  -not -path './.git/*' -print -quit 2>/dev/null | grep -q .; then
  HAS_DOCKERFILE="true"
fi
write_github_output "has_dockerfile" "$HAS_DOCKERFILE"

if [[ "$PR_SIZE" == "very_large" ]]; then
  agentic_log "  ⚠ PR is very large (${DIFF_LINES} lines)."
fi
