# Agentic AppSec

Four repositories that check code for Bayer teams: open-source scanners, with an AI explanation of what to fix.

- [agentic-review](https://github.com/bayer-int/agentic-review) (this repo)
- [agentic-quality-gate](https://github.com/bayer-int/agentic-quality-gate)
- [agentic-verdict](https://github.com/bayer-int/agentic-verdict)
- [agentic-dast](https://github.com/bayer-int/agentic-dast)

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
| 2 | Prepare context and AI Pass 1 | Collects the repo evidence and asks the AI to name the stack and the commands. The sections under this table say how | `agentic-prepare` |
| 3 | Quality checks and dependency audit | Installs the toolchain from step 2 and runs the planned commands. When a setup command fails, the model suggests a repair and the step retries. Then it audits dependencies. A `quick` review skips that audit. Coverage reports are collected for the quality gate | `agentic-checks`, `agentic-coverage` |
| 4 | Security and hygiene scans | On the files this pull request changed: Gitleaks, sensitive-file names, missing newline at end of file, files over 5 MB, TODO or FIXME, a license file, YAML / JSON / XML syntax, then actionlint, hadolint, tfsec, tflint, Checkov, and ShellCheck where those files exist | `agentic-scans` |

`review_type` chooses how much of this runs. `full` is the default. `security` runs the scans and the dependency audit, and skips lint, test, and build. `quick` skips the dependency audit.

<details>
<summary><b>How it detects the stack</b></summary>

Step 2 collects evidence from the repo and the model reads it.

| Evidence | Where it comes from |
|:---------|:--------------------|
| File tree | Every file in the repo, so a monorepo is visible, not just the root |
| Manifests and tool config | Up to three directories deep: `package.json`, `tsconfig`, `pyproject.toml`, `requirements.txt`, `go.mod`, `Cargo.toml`, `pom.xml`, `build.gradle`, `Gemfile`, `mix.exs`, `composer.json`, `*.csproj`, `Makefile`, `Dockerfile`, ESLint, Jest, Vitest, pytest, `*.tf`, `Chart.yaml` |
| Versions and package manager | `.nvmrc`, `engines`, `.python-version`, `go.mod`, and lockfiles: `pnpm-lock.yaml` means pnpm, `yarn.lock` means yarn, `package-lock.json` means npm |
| How the team installs it | README, CONTRIBUTING, DEVELOPMENT, INSTALL |
| This pull request | The list of changed files, so Terraform checks stay on the stacks the PR actually touches |
| Owner notes | [`.agentic-review.yml`](examples/.agentic-review.yml). These win when they disagree with the guess. Instructions that skip a check, force an approval, or contain a real token are rejected |

The model copies the version, the package manager, and the commands from those files. It picks a default only when the stack is clear and no version file exists: Node 20, Python 3.11.

</details>

### Stacks it supports

Node.js, TypeScript, Python, Go, Rust, Java, Kotlin, Ruby, Elixir, PHP, C# / .NET, Scala, Swift, Terraform, Helm, CloudFormation, Ansible, and Kubernetes manifests.

A repo can hold more than one. A web app, an API, and Terraform in the same repository are each planned in their own directory.

### How it chooses the commands

In this order:

1. **A command the repo already has.** A `package.json` script, a Makefile target, or the install steps written in the README. Those are copied as they are.
2. **A tool configured on disk, with no script.** ESLint config becomes `eslint`, Ruff in `pyproject.toml` becomes `ruff check`, a Terraform deploy root becomes `terraform validate` on the environments this pull request changes.
3. **A lockfile and no install script.** The normal install for that manager: `pnpm install`, `npm ci`, `pip install`.

Every command runs in the directory it belongs to. The checks it plans are format, lint, typecheck, unit tests, build, and IaC validate. End-to-end tests that need a browser, a database, or a running app, plus deploys and image builds, stay out of this job. A pull request that only edits GitHub workflows skips lint and test; actionlint still runs in step 4.

If a setup command fails, the model proposes a repair and the step retries.

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

DAST is a separate workflow. It scans a running non-prod URL on a schedule or by hand. [Know more →](https://github.com/bayer-int/agentic-dast#readme)

