#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

if ! should_run_security_scans; then
  echo "  Security scans skipped (skip_security or review_type)"
  echo "" > "${AGENTIC_TMP}/security-results.txt"
  write_github_output "security_exit" "0"
  exit 0
fi

set +e

echo ""
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃          SECURITY & FILE HYGIENE SCANS                ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""

SECURITY_RESULTS=""
SECURITY_EXIT=0

# ─────────────────────────────────────────────────────────
# SCAN 1: Gitleaks — Detect hardcoded secrets in code
# ─────────────────────────────────────────────────────────
echo "┌─────────────────────────────────────────────────────┐"
echo "│  SCAN 1: Gitleaks — Secret Detection                 │"
echo "└─────────────────────────────────────────────────────┘"

# Install gitleaks
GITLEAKS_VERSION="8.18.4"
curl -sSfL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
  | tar -xz -C /usr/local/bin gitleaks 2>/dev/null || {
  echo "  ⚠ Failed to install gitleaks — skipping"
  SECURITY_RESULTS+="### Gitleaks (Secret Detection) -- SKIPPED (install failed)"$'\n\n'
  GITLEAKS_INSTALLED=false
}
GITLEAKS_INSTALLED=${GITLEAKS_INSTALLED:-true}

if [[ "$GITLEAKS_INSTALLED" == "true" ]]; then
  # Create a config to reduce false positives (GitHub Actions refs, test fixtures, etc.)
  cat > ${AGENTIC_TMP}/.gitleaks.toml << 'GITLEAKS_CFG'
[allowlist]
  description = "Allowlist for CI pipeline - reduces false positives"
  paths = [
    '''\.github/workflows/.*\.yml$''',
    '''\.github/workflows/.*\.yaml$''',
    '''\.gitleaks\.toml$''',
    '''go\.sum$''',
    '''package-lock\.json$''',
    '''pnpm-lock\.yaml$''',
    '''yarn\.lock$''',
    '''poetry\.lock$'''
  ]
  regexTarget = "match"
  regexes = [
    '''\$\{\{\s*secrets\..*\}\}''',
    '''REDACTED''',
    '''placeholder'''
  ]
GITLEAKS_CFG

  echo "  Scanning PR commit range for secrets (origin/${GITHUB_BASE_REF}...HEAD)..."

  git fetch origin "${GITHUB_BASE_REF}" --depth=50 2>/dev/null || true
  GITLEAKS_OUTPUT=$(gitleaks detect \
    --log-opts="origin/${GITHUB_BASE_REF}...HEAD" \
    --no-banner \
    --redact \
    --config "${AGENTIC_TMP}/.gitleaks.toml" \
    2>&1) || true
  GITLEAKS_EXIT=$?
  if [[ $GITLEAKS_EXIT -ne 0 ]] && ! echo "$GITLEAKS_OUTPUT" | grep -q "Finding:"; then
    GITLEAKS_EXIT=0
  fi

  if [[ $GITLEAKS_EXIT -ne 0 ]]; then
    # Count actual findings (filter noise)
    FINDING_COUNT=$(echo "$GITLEAKS_OUTPUT" | grep -c "Finding:" 2>/dev/null || echo "0")

    if [[ "$FINDING_COUNT" -gt 0 ]]; then
      SECURITY_EXIT=1
      echo "  ❌ ${FINDING_COUNT} potential secret(s) detected — Review required!"
      echo "$GITLEAKS_OUTPUT"
      SECURITY_RESULTS+="### Gitleaks (Secret Detection) -- ❌ ${FINDING_COUNT} potential secret(s) found"$'\n'
      SECURITY_RESULTS+='```'$'\n'
      SECURITY_RESULTS+="${GITLEAKS_OUTPUT:0:3000}"$'\n'
      SECURITY_RESULTS+='```'$'\n'
      SECURITY_RESULTS+="Note: Review these findings. Some may be false positives (test fixtures, example configs). Add a \`.gitleaks.toml\` to your repo to customize."$'\n\n'
    else
      echo "  ✅ No actionable secrets found (some patterns excluded by config)"
      SECURITY_RESULTS+="### Gitleaks (Secret Detection) -- ✅ PASSED (no actionable findings)"$'\n\n'
    fi
  else
    echo "  ✅ No hardcoded secrets found"
    SECURITY_RESULTS+="### Gitleaks (Secret Detection) -- ✅ PASSED"$'\n\n'
  fi
fi

echo ""

# ─────────────────────────────────────────────────────────
# SCAN 2: Sensitive File Detection
# ─────────────────────────────────────────────────────────
echo "┌─────────────────────────────────────────────────────┐"
echo "│  SCAN 2: Sensitive File Detection                     │"
echo "└─────────────────────────────────────────────────────┘"

echo "  Checking for sensitive files added in this PR..."
SENSITIVE_FILES=""
SENSITIVE_PATTERNS=(
  ".env" ".env.local" ".env.production"
  "*.pem" "*.key" "*.p12" "*.pfx" "*.jks"
  "id_rsa" "id_ed25519" "*.keystore"
  "credentials.json" "service-account.json" "service-account*.json"
  "secrets.yml" "secrets.yaml" ".htpasswd"
)

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  base=$(basename "$f")
  case "$base" in
    .env|.env.local|.env.production|credentials.json|secrets.yml|secrets.yaml|.htpasswd|shadow)
      SENSITIVE_FILES+="$f"$'\n' ;;
    *.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|id_rsa|id_ed25519)
      SENSITIVE_FILES+="$f"$'\n' ;;
    service-account*.json)
      SENSITIVE_FILES+="$f"$'\n' ;;
  esac
done < <(pr_added_files)

if [[ -n "$SENSITIVE_FILES" ]]; then
  SECURITY_EXIT=1
  echo "  ❌ Sensitive files found:"
  echo "$SENSITIVE_FILES" | sed 's/^/    /'
  SECURITY_RESULTS+="### Sensitive File Detection -- ❌ FOUND"$'\n'
  SECURITY_RESULTS+='```'$'\n'
  SECURITY_RESULTS+="$SENSITIVE_FILES"$'\n'
  SECURITY_RESULTS+='```'$'\n'
  SECURITY_RESULTS+="These files may contain secrets and should be in .gitignore."$'\n\n'
else
  echo "  ✅ No sensitive files found"
  SECURITY_RESULTS+="### Sensitive File Detection -- ✅ PASSED"$'\n\n'
fi

echo ""

# ─────────────────────────────────────────────────────────
# SCAN 3: End-of-File Newline Check (skipped in quick review_type)
# ─────────────────────────────────────────────────────────
if should_run_heavy_hygiene; then
echo "┌─────────────────────────────────────────────────────┐"
echo "│  SCAN 3: End-of-File (EOF) Newline Check             │"
echo "└─────────────────────────────────────────────────────┘"

echo "  Checking source files for missing trailing newline..."
EOF_ISSUES=""
EOF_COUNT=0

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  # Only check text/source files, skip binaries
  if file "$file" 2>/dev/null | grep -q "text"; then
    if [[ -s "$file" ]] && [[ $(tail -c 1 "$file" | wc -l) -eq 0 ]]; then
      EOF_ISSUES+="  $file"$'\n'
      EOF_COUNT=$((EOF_COUNT + 1))
    fi
  fi
done < <(find . -type f \
  \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
  -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.rb" \
  -o -name "*.java" -o -name "*.kt" -o -name "*.scala" \
  -o -name "*.ex" -o -name "*.exs" -o -name "*.php" \
  -o -name "*.css" -o -name "*.scss" -o -name "*.html" \
  -o -name "*.yml" -o -name "*.yaml" -o -name "*.json" \
  -o -name "*.toml" -o -name "*.cfg" -o -name "*.ini" \
  -o -name "*.md" -o -name "*.tf" -o -name "*.sh" \
  -o -name "Dockerfile" -o -name "Makefile" \) \
  -not -path './.git/*' \
  -not -path './node_modules/*' \
  -not -path './dist/*' \
  -not -path './.venv/*' \
  -not -path './vendor/*' \
  -not -path './build/*' \
  2>/dev/null | head -200)

if [[ $EOF_COUNT -gt 0 ]]; then
  echo "  ⚠ ${EOF_COUNT} files missing trailing newline:"
  echo "$EOF_ISSUES" | head -20
  [[ $EOF_COUNT -gt 20 ]] && echo "  ... and $((EOF_COUNT - 20)) more"
  SECURITY_RESULTS+="### EOF Newline Check -- ⚠ ${EOF_COUNT} files missing newline"$'\n'
  SECURITY_RESULTS+='```'$'\n'
  SECURITY_RESULTS+="${EOF_ISSUES:0:2000}"$'\n'
  SECURITY_RESULTS+='```'$'\n\n'
else
  echo "  ✅ All source files have proper trailing newline"
  SECURITY_RESULTS+="### EOF Newline Check -- ✅ PASSED"$'\n\n'
fi

echo ""
else
  SECURITY_RESULTS+="### EOF Newline Check -- ℹ Skipped (quick review)"$'\n\n'
fi

# ─────────────────────────────────────────────────────────
# SCAN 4: Large File Detection (skipped in quick review_type)
# ─────────────────────────────────────────────────────────
if should_run_heavy_hygiene; then
echo "┌─────────────────────────────────────────────────────┐"
echo "│  SCAN 4: Large File Detection (>5MB)                 │"
echo "└─────────────────────────────────────────────────────┘"

echo "  Scanning for files larger than 5MB..."
LARGE_FILES=$(find . -type f -size +5M \
  -not -path './.git/*' \
  -not -path './node_modules/*' \
  -not -path './.venv/*' \
  -not -path './vendor/*' \
  2>/dev/null | while read -r f; do
    SIZE=$(du -h "$f" 2>/dev/null | cut -f1)
    echo "  ${SIZE}  ${f}"
  done)

if [[ -n "$LARGE_FILES" ]]; then
  echo "  ⚠ Large files found:"
  echo "$LARGE_FILES"
  SECURITY_RESULTS+="### Large File Detection (>5MB) -- ⚠ FOUND"$'\n'
  SECURITY_RESULTS+='```'$'\n'
  SECURITY_RESULTS+="$LARGE_FILES"$'\n'
  SECURITY_RESULTS+='```'$'\n'
  SECURITY_RESULTS+="Consider using Git LFS for large files."$'\n\n'
else
  echo "  ✅ No files exceeding 5MB"
  SECURITY_RESULTS+="### Large File Detection (>5MB) -- ✅ PASSED"$'\n\n'
fi

echo ""
else
  SECURITY_RESULTS+="### Large File Detection (>5MB) -- ℹ Skipped (quick review)"$'\n\n'
fi

# ─────────────────────────────────────────────────────────
# SCAN 5: TODO/FIXME/HACK Detection in Changed Files
# ─────────────────────────────────────────────────────────
echo "┌─────────────────────────────────────────────────────┐"
echo "│  SCAN 5: TODO/FIXME/HACK in PR Changes               │"
echo "└─────────────────────────────────────────────────────┘"

echo "  Checking PR diff for TODO/FIXME/HACK markers..."
MARKERS=$(grep -n "TODO\|FIXME\|HACK\|XXX\|WORKAROUND" ${AGENTIC_TMP}/pr-diff.txt 2>/dev/null | grep "^+" | head -20)

if [[ -n "$MARKERS" ]]; then
  MARKER_COUNT=$(echo "$MARKERS" | wc -l)
  echo "  ⚠ Found ${MARKER_COUNT} TODO/FIXME markers in changes:"
  echo "$MARKERS" | sed 's/^/    /'
  SECURITY_RESULTS+="### TODO/FIXME/HACK Detection -- ⚠ ${MARKER_COUNT} markers found"$'\n'
  SECURITY_RESULTS+='```'$'\n'
  SECURITY_RESULTS+="${MARKERS:0:2000}"$'\n'
  SECURITY_RESULTS+='```'$'\n\n'
else
  echo "  ✅ No TODO/FIXME/HACK markers in changes"
  SECURITY_RESULTS+="### TODO/FIXME/HACK Detection -- ✅ CLEAN"$'\n\n'
fi

echo ""

# ─────────────────────────────────────────────────────────
# SCAN 6: License File Check
# ─────────────────────────────────────────────────────────
echo "┌─────────────────────────────────────────────────────┐"
echo "│  SCAN 6: License File Check                          │"
echo "└─────────────────────────────────────────────────────┘"

LICENSE_FILE=$(find . -maxdepth 1 \( -iname "LICENSE" -o -iname "LICENSE.*" -o -iname "LICENCE" -o -iname "COPYING" \) 2>/dev/null | head -1)
if [[ -n "$LICENSE_FILE" ]]; then
  echo "  ✅ License file found: ${LICENSE_FILE}"
  SECURITY_RESULTS+="### License File -- ✅ Present (${LICENSE_FILE})"$'\n\n'
else
  echo "  ⚠ No license file found in repo root"
  SECURITY_RESULTS+="### License File -- ⚠ Missing"$'\n'
  SECURITY_RESULTS+="Consider adding a LICENSE file to the repository root."$'\n\n'
fi

echo ""

# ─────────────────────────────────────────────────────────
# SCAN 7: YAML/JSON/XML Syntax Validation
# ─────────────────────────────────────────────────────────
echo "┌─────────────────────────────────────────────────────┐"
echo "│  SCAN 7: YAML/JSON/XML Syntax Validation             │"
echo "└─────────────────────────────────────────────────────┘"

SYNTAX_ERRORS=""
SYNTAX_COUNT=0

# Get list of changed files from the PR diff
CHANGED_FILES=$(grep "^diff --git" ${AGENTIC_TMP}/pr-diff.txt 2>/dev/null | sed 's|diff --git a/||;s| b/.*||' || true)

# Validate YAML files
YAML_FILES=$(echo "$CHANGED_FILES" | grep -E '\.(yml|yaml)$' || true)
if [[ -n "$YAML_FILES" ]]; then
  echo "  Checking YAML files..."
  while IFS= read -r yf; do
    [[ -z "$yf" ]] && continue
    [[ ! -f "$yf" ]] && continue
    ERR=$(python3 -c "
import yaml, sys
try:
    with open('$yf') as f:
        yaml.safe_load(f)
except yaml.YAMLError as e:
    print(str(e)[:200])
    sys.exit(1)
" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "    ❌ $yf — INVALID YAML"
      SYNTAX_ERRORS+="- \`$yf\` — INVALID YAML: ${ERR}"$'\n'
      SYNTAX_COUNT=$((SYNTAX_COUNT + 1))
      SECURITY_EXIT=1
    else
      echo "    ✅ $yf — valid"
    fi
  done <<< "$YAML_FILES"
fi

# Validate JSON files
JSON_FILES=$(echo "$CHANGED_FILES" | grep -E '\.json$' || true)
if [[ -n "$JSON_FILES" ]]; then
  echo "  Checking JSON files..."
  while IFS= read -r jf; do
    [[ -z "$jf" ]] && continue
    [[ ! -f "$jf" ]] && continue
    ERR=$(python3 -c "
import json, sys
try:
    with open('$jf') as f:
        json.load(f)
except (json.JSONDecodeError, ValueError) as e:
    print(str(e)[:200])
    sys.exit(1)
" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "    ❌ $jf — INVALID JSON"
      SYNTAX_ERRORS+="- \`$jf\` — INVALID JSON: ${ERR}"$'\n'
      SYNTAX_COUNT=$((SYNTAX_COUNT + 1))
      SECURITY_EXIT=1
    else
      echo "    ✅ $jf — valid"
    fi
  done <<< "$JSON_FILES"
fi

# Validate XML files
XML_FILES=$(echo "$CHANGED_FILES" | grep -E '\.(xml|pom|csproj|props|targets)$' || true)
if [[ -n "$XML_FILES" ]]; then
  echo "  Checking XML files..."
  while IFS= read -r xf; do
    [[ -z "$xf" ]] && continue
    [[ ! -f "$xf" ]] && continue
    ERR=$(python3 -c "
import xml.etree.ElementTree as ET, sys
try:
    ET.parse('$xf')
except ET.ParseError as e:
    print(str(e)[:200])
    sys.exit(1)
" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "    ❌ $xf — INVALID XML"
      SYNTAX_ERRORS+="- \`$xf\` — INVALID XML: ${ERR}"$'\n'
      SYNTAX_COUNT=$((SYNTAX_COUNT + 1))
      SECURITY_EXIT=1
    else
      echo "    ✅ $xf — valid"
    fi
  done <<< "$XML_FILES"
fi

# GitHub Actions workflow validation (check for common issues)
GHA_FILES=$(echo "$CHANGED_FILES" | grep -E '^\.github/workflows/.*\.(yml|yaml)$' || true)
if [[ -n "$GHA_FILES" ]]; then
  echo "  Checking GitHub Actions workflows for common issues..."
  while IFS= read -r gf; do
    [[ -z "$gf" ]] && continue
    [[ ! -f "$gf" ]] && continue
    GHA_ISSUES=""
    # Check: must have 'on' trigger
    if ! grep -q "^on:" "$gf" && ! grep -q "^'on':" "$gf" && ! grep -q '^"on":' "$gf"; then
      GHA_ISSUES+="missing 'on' trigger; "
    fi
    # Check: must have 'jobs' section
    if ! grep -q "^jobs:" "$gf"; then
      GHA_ISSUES+="missing 'jobs' section; "
    fi
    # Check: uses references should have version pinning
    UNPINNED=$(grep -n "uses:" "$gf" | grep -v "@" | grep -v "#" || true)
    if [[ -n "$UNPINNED" ]]; then
      GHA_ISSUES+="unpinned action references (missing @version); "
    fi
    if [[ -n "$GHA_ISSUES" ]]; then
      echo "    ⚠️  $gf — ${GHA_ISSUES}"
      SYNTAX_ERRORS+="- \`$gf\` — GHA issues: ${GHA_ISSUES}"$'\n'
      SYNTAX_COUNT=$((SYNTAX_COUNT + 1))
    else
      echo "    ✅ $gf — valid workflow structure"
    fi
  done <<< "$GHA_FILES"
fi

if [[ $SYNTAX_COUNT -gt 0 ]]; then
  echo ""
  echo "  ⚠ Found ${SYNTAX_COUNT} syntax/validation issues"
  SECURITY_RESULTS+="### YAML/JSON/XML Validation -- ⚠ ${SYNTAX_COUNT} issues found"$'\n'
  SECURITY_RESULTS+="${SYNTAX_ERRORS}"$'\n'
elif [[ -n "$YAML_FILES" || -n "$JSON_FILES" || -n "$XML_FILES" || -n "$GHA_FILES" ]]; then
  echo "  ✅ All checked files have valid syntax"
  SECURITY_RESULTS+="### YAML/JSON/XML Validation -- ✅ All valid"$'\n\n'
else
  echo "  ℹ No YAML/JSON/XML files changed in this PR"
  SECURITY_RESULTS+="### YAML/JSON/XML Validation -- ℹ No files to check"$'\n\n'
fi

echo ""
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃          SECURITY SCANS COMPLETE                      ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"

echo "$SECURITY_RESULTS" > "${AGENTIC_TMP}/security-results.txt"
"$(dirname "$0")/extra-scans.sh" || true
write_github_output "security_exit" "$SECURITY_EXIT"
