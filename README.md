# Agentic AppSec

Four repositories that check code for Bayer teams: open-source scanners, with an AI explanation of what to fix.

## The problem

> Agentify Q&A gates for DAST and SAST checks and be part of the Agentic SDLC — contributing to an exit from SonarQube and Burp Suite. Target state: agentified SAST analysis and DAST covering bugs, vulnerabilities, code smells, coverage gaps, and duplication.

## How it works

![How Agentic AppSec works](docs/overview.png)

`run-qg` on your machine and the pull-request checks use the same engines and the same rules. DAST is separate: it scans a running non-production app and never blocks a merge.

| Today | Here |
|:------|:-----|
| SonarQube | Semgrep, jscpd, Lizard and coverage in [agentic-quality-gate](#2-agentic-quality-gate), with the written review from [agentic-verdict](#3-agentic-verdict) |
| Burp Suite | OWASP ZAP and Nuclei in [agentic-dast](#4-agentic-dast), summarized by AI |

Advisory first. A team turns on failing the build after the signal is trusted. Pin every workflow to a full commit SHA before production use.

---

## 1. agentic-review

This repo is the first job on a pull request, and that job is four steps. The review comment is posted later by [agentic-verdict](#3-agentic-verdict). Semgrep, duplication, and complexity run in [agentic-quality-gate](#2-agentic-quality-gate).

![What agentic-review does](docs/review.png)

Steps 3 and 4 start together, as soon as step 2 has planned the commands.

| Step | Job | What it does | What it saves |
|:----:|:----|:-------------|:--------------|
| 1 | Check skip label | Stops the whole job when the pull request has `skip-ai-review` or `no-review` | — |
| 2 | Prepare context and AI Pass 1 | Reads [`.agentic-review.yml`](examples/.agentic-review.yml) if the app has one, rejects instructions that try to skip checks or force a verdict, reads the pull request diff, then the AI detects the stack and writes the lint, test, build, and audit commands. Stacks it detects: Node, Python, Go, Java, .NET, Ruby, PHP, Elixir, Terraform | `agentic-prepare` |
| 3 | Quality checks and dependency audit | Installs the toolchain from step 2 and runs the planned commands. When a setup command fails, the model suggests a repair and the step retries. Then it audits dependencies. A `quick` review skips that audit. Coverage reports are collected for the quality gate | `agentic-checks`, `agentic-coverage` |
| 4 | Security and hygiene scans | On the files this pull request changed: Gitleaks, sensitive-file names, missing newline at end of file, files over 5 MB, TODO or FIXME, a license file, YAML / JSON / XML syntax, then actionlint, hadolint, tfsec, tflint, Checkov, and ShellCheck where those files exist | `agentic-scans` |

`review_type` chooses how much of this runs. `full` is the default. `security` runs the scans and the dependency audit, and skips lint, test, and build. `quick` skips the dependency audit.

## Use this in your repository

An application repo calls the hubs with one workflow file. The workflow runs three jobs, in this order:

```text
agentic-review  →  agentic-quality-gate  →  agentic-verdict
```

### 1. Add the secrets

In the application repo: Settings → Secrets and variables → Actions.

| Secret | Required | Why |
|:-------|:--------:|:----|
| `AI_API_KEY` | yes | AI Pass 1, and the repair when a setup command fails |
| `AI_API_ENDPOINT` | yes | Same |
| `ORG_PAT` | when the hubs are private | The job clones the hub scripts with this token |
| `ARTIFACTORY_USERNAME` | when the app installs private packages | npm and pip login |
| `ARTIFACTORY_AUTH_TOKEN` | same | Same |

### 2. Add the workflow

Create `.github/workflows/agentic-pr.yml` in the application repo. The ready-made file is [`examples/caller-orchestrated.yml`](examples/caller-orchestrated.yml). That copy still names the pilot mirror and `@main`. Point it at `bayer-int` and pin each `uses:` and `pipeline_ref` to a full commit SHA before you rely on it.

```yaml
name: Agentic PR Pipeline

on:
  pull_request:
    branches: [main]          # change this if the default branch is not main

permissions:
  contents: read
  pull-requests: write
  issues: write

jobs:
  ai-phase1:
    uses: bayer-int/agentic-review/.github/workflows/ai-review-phase1.yml@<full-sha>
    with:
      pipeline_repository: bayer-int/agentic-review
      pipeline_ref: <full-sha>
      review_type: full       # full | security | quick
    secrets:
      AI_API_KEY: ${{ secrets.AI_API_KEY }}
      AI_API_ENDPOINT: ${{ secrets.AI_API_ENDPOINT }}
      ORG_PAT: ${{ secrets.ORG_PAT }}

  quality-gate:
    needs: ai-phase1
    if: always() && needs.ai-phase1.result == 'success'
    uses: bayer-int/agentic-quality-gate/.github/workflows/quality-gate.yml@<full-sha>
    with:
      pipeline_repository: bayer-int/agentic-quality-gate
      pipeline_ref: <full-sha>
      coverage_artifact: agentic-coverage
    secrets:
      ORG_PAT: ${{ secrets.ORG_PAT }}

  ai-verdict:
    needs: [ai-phase1, quality-gate]
    if: always() && needs.ai-phase1.result == 'success'
    uses: bayer-int/agentic-verdict/.github/workflows/ai-verdict.yml@<full-sha>
    with:
      pipeline_repository: bayer-int/agentic-verdict
      pipeline_ref: <full-sha>
      pr_size: ${{ needs.ai-phase1.outputs.pr_size }}
      diff_lines: ${{ needs.ai-phase1.outputs.diff_lines }}
      changed_files: ${{ needs.ai-phase1.outputs.changed_files }}
      pr_scope: ${{ needs.ai-phase1.outputs.pr_scope }}
      checks_passed: ${{ needs.ai-phase1.outputs.checks_passed }}
      checks_failed: ${{ needs.ai-phase1.outputs.checks_failed }}
      checks_exit: ${{ needs.ai-phase1.outputs.checks_exit }}
      setup_failed: ${{ needs.ai-phase1.outputs.setup_failed }}
      security_exit: ${{ needs.ai-phase1.outputs.security_exit }}
      quality_gate_artifact: agentic-metrics
    secrets:
      AI_API_KEY: ${{ secrets.AI_API_KEY }}
      AI_API_ENDPOINT: ${{ secrets.AI_API_ENDPOINT }}
      ORG_PAT: ${{ secrets.ORG_PAT }}
```

### 3. Tell it about the repo, if the defaults are wrong

Optional. Put [`.agentic-review.yml`](examples/.agentic-review.yml) in the application repo root.

```yaml
skip_docker: false
skip_security: false
skip_checks: false
max_diff_lines: 15000
custom_instructions: |
  We use pnpm. Run lint and tests from the repo root.
  The e2e folder has its own package.json.
```

Write the notes in plain language. The job refuses instructions that say to skip a check, always approve, or that contain a real token.

### 4. Open a pull request

On the pull request you get the four steps from the table above, then the quality-gate check, then one comment titled **AI Code Review** with an approve or a request for changes and a label.

To skip this repo on one pull request, add the label `skip-ai-review` or `no-review`. `skip-quality-gate` and `skip-ai-verdict` skip the other two jobs on their own.

DAST is not part of this workflow. It scans a running non-prod URL on a schedule or by hand. [Know more →](https://github.com/bayer-int/agentic-dast#readme)

## 2. agentic-quality-gate

Sonar-style checks on the change: security hotspots, secrets, duplication, complexity, and coverage. No AI in this repo.

| Where | What you get |
|:------|:-------------|
| Terminal, `run-qg` | The report, with no pull request needed |
| IDE chat, "run quality gate" | The same checks, then an explanation |
| `git push` | The same checks in a pre-push hook |
| Pull request | The same checks, plus line comments. Coverage runs here when `lcov` exists |

[Know more →](https://github.com/bayer-int/agentic-quality-gate#readme)

## 3. agentic-verdict

Last step of the pull request. It reads the results of agentic-review and agentic-quality-gate and posts one **AI Code Review**: a comment, an approve or a request for changes, and a label. It runs no scanners of its own.

[Know more →](https://github.com/bayer-int/agentic-verdict#readme)

## 4. agentic-dast

Scans a running non-production app with OWASP ZAP and Nuclei, then files one GitHub Issue: a short AI summary, with the detail folded underneath. It runs in GitHub Actions only. It does not run on a laptop, it does not scan production, and it does not block a merge.

| Profile | What it does |
|:--------|:-------------|
| `baseline` | Passive ZAP plus Nuclei. Suits a nightly run |
| `deep` | Full ZAP scan plus a wider Nuclei set |
| `api` | Same as `deep` today |

[Know more →](https://github.com/bayer-int/agentic-dast#readme)
