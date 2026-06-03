#!/usr/bin/env bash
# Discover Terraform / IaC layout: deploy roots, modules, PR-affected validation targets.
# Writes ${AGENTIC_TMP}/iac-inventory.json and ${AGENTIC_TMP}/iac-context.txt
set -euo pipefail
source "$(dirname "$0")/common.sh"

OUT_JSON="${AGENTIC_TMP}/iac-inventory.json"
OUT_TXT="${AGENTIC_TMP}/iac-context.txt"

# ── helpers ──────────────────────────────────────────────────────────────────

normalize_dir() {
  local d="$1"
  d="${d#./}"
  d="${d%/}"
  echo "$d"
}

has_tf_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  find "$dir" -maxdepth 1 -name '*.tf' -print -quit 2>/dev/null | grep -q .
}

find_deploy_root_for() {
  local relpath="$1"
  local dir
  dir=$(dirname "$relpath")
  while [[ "$dir" != "." && "$dir" != "/" && -n "$dir" ]]; do
    if [[ -f "${dir}/backend.tf" || -f "${dir}/terragrunt.hcl" ]]; then
      normalize_dir "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

stack_from_path() {
  local p="$1"
  # Prefer *-platform or known top-level stack folders
  local top
  top=$(echo "$p" | cut -d/ -f1)
  echo "$top"
}

env_from_deploy_root() {
  local root="$1"
  if [[ "$root" =~ /environments/([^/]+)/?$ ]] || [[ "$root" =~ /environments/([^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$root" =~ /(dev|staging|prod|stage|uat|sandbox)/?$ ]] || [[ "$root" =~ /(dev|staging|prod|stage|uat|sandbox)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    basename "$root"
  fi
}

# ── scan repo ────────────────────────────────────────────────────────────────

DEPLOY_ROOTS=()
MODULE_DIRS=()
COMPOSITOR_DIRS=()
STACK_SET=()

while IFS= read -r bf; do
  [[ -z "$bf" ]] && continue
  root=$(normalize_dir "$(dirname "$bf")")
  DEPLOY_ROOTS+=("$root")
  STACK_SET+=("$(stack_from_path "$root")")
done < <(find . -name 'backend.tf' -not -path './.git/*' 2>/dev/null | sort -u)

while IFS= read -r tg; do
  [[ -z "$tg" ]] && continue
  root=$(normalize_dir "$(dirname "$tg")")
  if [[ " ${DEPLOY_ROOTS[*]:-} " != *" ${root} "* ]]; then
    DEPLOY_ROOTS+=("$root")
    STACK_SET+=("$(stack_from_path "$root")")
  fi
done < <(find . -name 'terragrunt.hcl' -not -path './.git/*' 2>/dev/null | sort -u)

while IFS= read -r mf; do
  [[ -z "$mf" ]] && continue
  dir=$(normalize_dir "$(dirname "$mf")")
  [[ "$dir" == */modules/* ]] || continue
  if ! has_tf_files "$dir"; then continue; fi
  if [[ " ${MODULE_DIRS[*]:-} " != *" ${dir} "* ]]; then
    MODULE_DIRS+=("$dir")
  fi
done < <(find . -name 'main.tf' -not -path './.git/*' 2>/dev/null | sort -u)

while IFS= read -r inf; do
  [[ -z "$inf" ]] && continue
  dir=$(normalize_dir "$(dirname "$inf")")
  [[ "$dir" == */infrastructure ]] || continue
  if [[ -f "${dir}/backend.tf" ]]; then continue; fi
  if has_tf_files "$dir"; then
    if [[ " ${COMPOSITOR_DIRS[*]:-} " != *" ${dir} "* ]]; then
      COMPOSITOR_DIRS+=("$dir")
    fi
  fi
done < <(find . -path '*/infrastructure/main.tf' -not -path './.git/*' 2>/dev/null | sort -u)

# Unique sorted stacks (top-level dirs with deploy roots or platform pattern)
UNIQUE_STACKS=()
for s in "${STACK_SET[@]}"; do
  [[ -z "$s" ]] && continue
  if [[ " ${UNIQUE_STACKS[*]:-} " != *" ${s} "* ]]; then
    UNIQUE_STACKS+=("$s")
  fi
done
IFS=$'\n' UNIQUE_STACKS=($(printf '%s\n' "${UNIQUE_STACKS[@]:-}" | sort -u)); unset IFS

IS_IAC_REPO="false"
if [[ ${#DEPLOY_ROOTS[@]} -gt 0 || ${#MODULE_DIRS[@]} -gt 0 ]]; then
  IS_IAC_REPO="true"
fi

# terraform.tfvars paths (one per line: dir|file)
TFVARS_LIST=""
while IFS= read -r tv; do
  [[ -z "$tv" ]] && continue
  dir=$(normalize_dir "$(dirname "$tv")")
  TFVARS_LIST+="${dir}|${tv#./}"$'\n'
done < <(find . \( -name 'terraform.tfvars' -o -name '*.auto.tfvars' \) -not -path './.git/*' 2>/dev/null | sort -u)

tfvars_for_root() {
  local root="$1"
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local dir="${line%%|*}"
    local file="${line#*|}"
    if [[ "$dir" == "$root" ]]; then
      echo "$file"
      return 0
    fi
  done <<< "$TFVARS_LIST"
  if [[ -f "${root}/terraform.tfvars" ]]; then
    echo "${root}/terraform.tfvars"
    return 0
  fi
  return 1
}

# Root tooling
TFLINT_CONFIG=""
CHECKOV_CONFIG=""
[[ -f .tflint.hcl ]] && TFLINT_CONFIG=".tflint.hcl"
[[ -f .checkov.yml || -f .checkov.yaml ]] && CHECKOV_CONFIG=".checkov.yml"

TF_VERSION_HINT=""
if [[ -f .terraform-version ]]; then
  TF_VERSION_HINT=$(tr -d '[:space:]' < .terraform-version)
fi
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [[ -f "$wf" ]] || continue
  if grep -qiE 'terraform|tflint|checkov' "$wf" 2>/dev/null; then
    ver=$(grep -E 'TF_VERSION:|terraform_version:' "$wf" 2>/dev/null | head -1 | sed -E 's/.*["'\'']([0-9]+\.[0-9]+\.[0-9]+)["'\''].*/\1/' || true)
    [[ -n "$ver" ]] && TF_VERSION_HINT="$ver" && break
  fi
done

# CI workflow hints (first terraform-related workflow, truncated)
CI_WORKFLOW=""
CI_VALIDATE_ROOTS=()
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [[ -f "$wf" ]] || continue
  if grep -qiE 'terraform validate|terraform fmt|tflint|checkov' "$wf" 2>/dev/null; then
    CI_WORKFLOW="${wf#./}"
    # Extract working-directory patterns like stack/environments/prod
    while IFS= read -r wd; do
      wd=$(echo "$wd" | sed -E 's/^\$\{\{.*\}\}\///;s/^\.//;s/"//g;s/'\''//g')
      [[ -n "$wd" && -d "$wd" ]] && CI_VALIDATE_ROOTS+=("$(normalize_dir "$wd")")
    done < <(grep -E 'working-directory:|--chdir=' "$wf" 2>/dev/null | sed -E 's/.*working-directory:[[:space:]]*//;s/.*--chdir=//' || true)
    break
  fi
done

# ── PR-affected targets ──────────────────────────────────────────────────────

CHANGED=""
[[ -f "${AGENTIC_TMP}/pr-changed-files.txt" ]] && CHANGED=$(cat "${AGENTIC_TMP}/pr-changed-files.txt" 2>/dev/null || true)

PR_AFFECTED_ROOTS=()
PR_AFFECTED_STACKS=()
PR_CHANGED_IAC=()

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  f="${f#./}"
  if echo "$f" | grep -qiE '\.(tf|tfvars|hcl)$|/modules/|/infrastructure/|/environments/'; then
    PR_CHANGED_IAC+=("$f")
  fi
  root=""
  if root=$(find_deploy_root_for "$f" 2>/dev/null); then
    if [[ " ${PR_AFFECTED_ROOTS[*]:-} " != *" ${root} "* ]]; then
      PR_AFFECTED_ROOTS+=("$root")
    fi
  fi
  stack=$(stack_from_path "$f")
  if echo "$f" | grep -qE '/modules/|/infrastructure/'; then
    # Shared code change → validate all deploy roots under this stack
    for dr in "${DEPLOY_ROOTS[@]}"; do
      [[ "$dr" == "${stack}/"* || "$dr" == "${stack}" ]] || continue
      if [[ " ${PR_AFFECTED_ROOTS[*]:-} " != *" ${dr} "* ]]; then
        PR_AFFECTED_ROOTS+=("$dr")
      fi
    done
    if [[ " ${PR_AFFECTED_STACKS[*]:-} " != *" ${stack} "* ]]; then
      PR_AFFECTED_STACKS+=("$stack")
    fi
  elif [[ -n "$root" ]]; then
    stack=$(stack_from_path "$root")
    if [[ " ${PR_AFFECTED_STACKS[*]:-} " != *" ${stack} "* ]]; then
      PR_AFFECTED_STACKS+=("$stack")
    fi
  fi
done <<< "$CHANGED"

# Root-level IaC config changes → lint/scan all stacks
if echo "$CHANGED" | grep -qE '^\.tflint\.hcl$|^\.checkov\.|^\.github/workflows/.*terraform'; then
  PR_AFFECTED_STACKS=("${UNIQUE_STACKS[@]}")
fi

# If IaC repo but no specific roots from PR, use CI matrix roots or all deploy roots (cap at 6 for safety)
if [[ ${#PR_AFFECTED_ROOTS[@]} -eq 0 && "$IS_IAC_REPO" == "true" && ${#PR_CHANGED_IAC[@]} -gt 0 ]]; then
  if [[ ${#CI_VALIDATE_ROOTS[@]} -gt 0 ]]; then
    PR_AFFECTED_ROOTS=("${CI_VALIDATE_ROOTS[@]}")
  else
    PR_AFFECTED_ROOTS=("${DEPLOY_ROOTS[@]}")
  fi
fi

# Cap validate roots for very large repos (Pass 1 may add more via custom_instructions)
MAX_VALIDATE=12
if [[ ${#PR_AFFECTED_ROOTS[@]} -gt $MAX_VALIDATE ]]; then
  agentic_log "  IaC: capping PR-affected deploy roots from ${#PR_AFFECTED_ROOTS[@]} to ${MAX_VALIDATE}"
  PR_AFFECTED_ROOTS=("${PR_AFFECTED_ROOTS[@]:0:$MAX_VALIDATE}")
fi

# ── build JSON with jq ───────────────────────────────────────────────────────

deploy_json='[]'
for root in "${DEPLOY_ROOTS[@]}"; do
  has_tv="false"
  tv_path=""
  if tv_path=$(tfvars_for_root "$root" 2>/dev/null); then
    has_tv="true"
  fi
  deploy_json=$(echo "$deploy_json" | jq -c \
    --arg path "$root" \
    --arg stack "$(stack_from_path "$root")" \
    --arg env "$(env_from_deploy_root "$root")" \
    --argjson has_tfvars "$has_tv" \
    --arg tfvars "$tv_path" \
    '. + [{path: $path, stack: $stack, environment: $env, has_terraform_tfvars: $has_tfvars, terraform_tfvars: (if $has_tfvars then $tfvars else null end)}]')
done

pr_roots_json='[]'
for root in "${PR_AFFECTED_ROOTS[@]}"; do
  pr_roots_json=$(echo "$pr_roots_json" | jq -c --arg r "$root" '. + [$r]')
done

pr_stacks_json='[]'
for s in "${PR_AFFECTED_STACKS[@]}"; do
  pr_stacks_json=$(echo "$pr_stacks_json" | jq -c --arg s "$s" '. + [$s]')
done

modules_json=$(printf '%s\n' "${MODULE_DIRS[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
compositors_json=$(printf '%s\n' "${COMPOSITOR_DIRS[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
stacks_json=$(printf '%s\n' "${UNIQUE_STACKS[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
changed_iac_json=$(printf '%s\n' "${PR_CHANGED_IAC[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
ci_roots_json=$(printf '%s\n' "${CI_VALIDATE_ROOTS[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))')

jq -n \
  --argjson is_iac "$([[ "$IS_IAC_REPO" == true ]] && echo true || echo false)" \
  --arg tf_version "${TF_VERSION_HINT}" \
  --arg tflint "${TFLINT_CONFIG}" \
  --arg checkov "${CHECKOV_CONFIG}" \
  --arg ci_workflow "${CI_WORKFLOW}" \
  --argjson deploy_roots "$deploy_json" \
  --argjson modules "$modules_json" \
  --argjson compositors "$compositors_json" \
  --argjson platform_stacks "$stacks_json" \
  --argjson pr_affected_deploy_roots "$pr_roots_json" \
  --argjson pr_affected_stacks "$pr_stacks_json" \
  --argjson pr_changed_iac_files "$changed_iac_json" \
  --argjson ci_validate_roots "$ci_roots_json" \
  '{
    is_iac_repo: $is_iac,
    terraform_version_hint: (if $tf_version == "" then null else $tf_version end),
    root_config: {
      tflint: (if $tflint == "" then null else $tflint end),
      checkov: (if $checkov == "" then null else $checkov end)
    },
    ci_hints: {
      workflow: (if $ci_workflow == "" then null else $ci_workflow end),
      validate_roots: $ci_validate_roots
    },
    deploy_roots: $deploy_roots,
    compositor_directories: $compositors,
    module_directories: $modules,
    platform_stacks: $platform_stacks,
    pr_affected: {
      deploy_roots: $pr_affected_deploy_roots,
      stacks_for_lint: $pr_affected_stacks,
      changed_iac_files: $pr_changed_iac_files
    },
    validation_notes: [
      "deploy_root = directory with backend.tf or terragrunt.hcl — run terraform init -backend=false there",
      "when terraform.tfvars exists in a deploy root, pass -var-file=terraform.tfvars to terraform validate/plan",
      "module/ or infrastructure/ changes affect all environment deploy roots in the same platform stack",
      "never run terraform apply or plan against live backends in PR checks"
    ]
  }' > "$OUT_JSON"

# Human-readable summary for Pass 1
{
  echo "IaC repository: ${IS_IAC_REPO}"
  echo "Deploy roots (backend.tf / terragrunt): ${#DEPLOY_ROOTS[@]}"
  echo "Modules: ${#MODULE_DIRS[@]} | Compositors: ${#COMPOSITOR_DIRS[@]}"
  echo "Platform stacks: ${UNIQUE_STACKS[*]:-none}"
  echo "PR-affected deploy roots (${#PR_AFFECTED_ROOTS[@]}): ${PR_AFFECTED_ROOTS[*]:-none}"
  echo "PR-affected stacks for lint/scan: ${PR_AFFECTED_STACKS[*]:-none}"
  if [[ -n "$TF_VERSION_HINT" ]]; then echo "Terraform version hint: ${TF_VERSION_HINT}"; fi
  if [[ -n "$CI_WORKFLOW" ]]; then echo "CI workflow reference: ${CI_WORKFLOW}"; fi
  echo ""
  echo "Deploy root details:"
  echo "$deploy_json" | jq -r '.[] | "  - \(.path) [stack=\(.stack) env=\(.environment)] tfvars=\(.has_terraform_tfvars)"'
} > "$OUT_TXT"

agentic_log "  IaC inventory: ${#DEPLOY_ROOTS[@]} deploy roots, ${#PR_AFFECTED_ROOTS[@]} PR-affected"
