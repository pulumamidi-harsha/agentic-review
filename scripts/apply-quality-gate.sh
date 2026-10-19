#!/usr/bin/env bash
# Evaluate normalized findings against config/quality-gate.yml.
# Phase 1: mode=advisory → always exit 0; write gate-result.json + markdown summary.
set -euo pipefail
source "$(dirname "$0")/common.sh"

PIPELINE_DIR="${PIPELINE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
GATE_FILE="${PIPELINE_DIR}/config/quality-gate.yml"
FINDINGS_IN="${AGENTIC_TMP}/semgrep-findings.json"
BUNDLE_OUT="${AGENTIC_TMP}/findings.json"
GATE_OUT="${AGENTIC_TMP}/gate-result.json"
GATE_MD="${AGENTIC_TMP}/quality-gate.md"

mkdir -p "$AGENTIC_TMP"
[[ -f "$FINDINGS_IN" ]] || echo '[]' > "$FINDINGS_IN"

GATE_MODE="advisory"
if [[ -f "$GATE_FILE" ]]; then
  GATE_MODE=$(grep -E '^mode:' "$GATE_FILE" | head -1 | awk '{print $2}' | tr -d '"' || echo advisory)
fi
GATE_MODE="${GATE_MODE:-advisory}"

NEW_LINES=0
if git rev-parse --verify "origin/${GITHUB_BASE_REF:-main}" >/dev/null 2>&1; then
  NEW_LINES=$(git diff --numstat "origin/${GITHUB_BASE_REF:-main}...HEAD" 2>/dev/null \
    | awk '{ add+=$1 } END { print add+0 }' || echo 0)
fi

REPO="${GITHUB_REPOSITORY:-unknown/unknown}"
SHA="${GITHUB_EVENT_PULL_REQUEST_HEAD_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
PR_NUM="${GITHUB_EVENT_PULL_REQUEST_NUMBER:-}"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [[ -n "$PR_NUM" ]]; then
  jq -n \
    --arg ver "1.0.0" --arg at "$NOW" --arg repo "$REPO" --arg sha "$SHA" --argjson pr "$PR_NUM" \
    --slurpfile findings "$FINDINGS_IN" \
    '{schema_version:$ver,generated_at:$at,repository:$repo,head_sha:$sha,pr_number:$pr,findings:$findings[0]}' \
    > "$BUNDLE_OUT"
else
  jq -n \
    --arg ver "1.0.0" --arg at "$NOW" --arg repo "$REPO" --arg sha "$SHA" \
    --slurpfile findings "$FINDINGS_IN" \
    '{schema_version:$ver,generated_at:$at,repository:$repo,head_sha:$sha,pr_number:null,findings:$findings[0]}' \
    > "$BUNDLE_OUT"
fi

python3 - "$BUNDLE_OUT" "$GATE_OUT" "$GATE_MD" "$GATE_MODE" "$NEW_LINES" <<'PY'
import json, sys
bundle_path, gate_out, gate_md, mode, new_lines = sys.argv[1:6]
new_lines = int(new_lines or 0)

with open(bundle_path) as f:
    bundle = json.load(f)
findings = bundle.get("findings") or []

errors_in_diff = [f for f in findings if f.get("in_pr_diff") and f.get("severity") == "error"]
secrets_in_diff = [f for f in findings if f.get("category") == "secret" and f.get("in_pr_diff")]
warnings_in_diff = [f for f in findings if f.get("in_pr_diff") and f.get("severity") == "warning"]

reasons_fail = []
reasons_warn = []
if secrets_in_diff:
    reasons_fail.append(f"{len(secrets_in_diff)} new secret finding(s) in PR diff")
non_secret_errors = [f for f in errors_in_diff if f.get("category") != "secret"]
if non_secret_errors:
    reasons_fail.append(f"{len(non_secret_errors)} error-severity finding(s) in PR diff")
if warnings_in_diff:
    reasons_warn.append(f"{len(warnings_in_diff)} warning finding(s) in PR diff")

status = "fail" if reasons_fail else ("warn" if reasons_warn else "pass")
result = {
    "mode": mode,
    "status": status,
    "blocking": False,
    "new_lines": new_lines,
    "counts": {
        "findings_total": len(findings),
        "in_pr_diff": sum(1 for f in findings if f.get("in_pr_diff")),
        "errors_in_diff": len(errors_in_diff),
        "warnings_in_diff": len(warnings_in_diff),
        "secrets_in_diff": len(secrets_in_diff),
    },
    "fail_reasons": reasons_fail,
    "warn_reasons": reasons_warn,
    "note": "Advisory mode: GitHub check always passes. Sonar remains shadow-only.",
}
with open(gate_out, "w") as f:
    json.dump(result, f, indent=2)

emoji = {"pass": "✅", "warn": "⚠️", "fail": "❌"}.get(status, "ℹ️")
lines = [
    f"### {emoji} Quality gate (advisory)",
    "",
    f"**Status:** `{status}` · **Mode:** `{mode}` (does not block merge)",
    "",
    "| Metric | Count |",
    "|--------|------:|",
    f"| Findings (all) | {result['counts']['findings_total']} |",
    f"| In PR diff | {result['counts']['in_pr_diff']} |",
    f"| Errors in diff | {result['counts']['errors_in_diff']} |",
    f"| Warnings in diff | {result['counts']['warnings_in_diff']} |",
    f"| Secrets in diff | {result['counts']['secrets_in_diff']} |",
    "",
]
if reasons_fail:
    lines.append("**Would fail (when hard_fail enabled):**")
    lines.extend([f"- {r}" for r in reasons_fail])
    lines.append("")
if reasons_warn:
    lines.append("**Warnings:**")
    lines.extend([f"- {r}" for r in reasons_warn])
    lines.append("")

top = sorted(findings, key=lambda f: (not f.get("in_pr_diff"), f.get("severity") != "error"))[:15]
if top:
    lines += ["| Sev | Engine | File | Message |", "|:---:|--------|------|---------|"]
    for f in top:
        sev = f.get("severity", "info")
        loc = f.get("path") or "—"
        if f.get("start_line"):
            loc = f"{loc}:{f['start_line']}"
        msg = (f.get("message") or "").replace("|", "\\|").replace("\n", " ")[:120]
        badge = "🔴" if sev == "error" else ("🟡" if sev == "warning" else "ℹ️")
        diff = " · PR" if f.get("in_pr_diff") else ""
        lines.append(f"| {badge} | `{f.get('engine')}` | `{loc}`{diff} | {msg} |")
    lines.append("")

lines.append("_Hub gate (`config/quality-gate.yml` + Semgrep). SonarQube, if present, is shadow-only._")
with open(gate_md, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"  Gate status={status} mode={mode} (advisory → never blocking)")
PY

write_github_output "gate_status" "$(jq -r '.status' "$GATE_OUT")"
write_github_output "gate_mode" "$(jq -r '.mode' "$GATE_OUT")"
exit 0
