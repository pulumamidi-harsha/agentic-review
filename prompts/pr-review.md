# PR Review Prompt — Architecture Reference

> **NOTE:** This file documents the 2-pass review architecture used by the pipeline.
> Runtime prompts live in `scripts/prompts/pass1-system.txt` and `scripts/prompts/pass2-system.txt`.
> See `detect-and-command.md` and `review-results.md` for expanded documentation.

## 2-Pass Architecture

### Pass 1: Stack Detection & Command Generation (`detect-and-command.md`)

**Input:** Repository file tree + all configuration files + custom instructions (if any)

**Output:** JSON with detected stack, setup commands, check commands, runtime requirements

**Key behaviors:**
- Reads package.json scripts, Makefile targets, pyproject.toml tools, go.mod, etc.
- Supports monorepos (detects multiple stacks in subdirectories)
- Handles IaC (Terraform, Helm, Kubernetes, Ansible)
- Respects custom instructions with priority over auto-detection
- Never invents commands the repo doesn't support

### Pass 2: Code Review & Verdict (`review-results.md`)

**Input:** PR diff + CI check results + Docker/Trivy results + Security scans + SonarQube + Dependency audit

**Output:** JSON with summary, verdict, issues, positives, suggestions, repo_health

**Key behaviors:**
- Reviews ONLY files changed in this PR (pre-existing issues go to repo_health)
- Verdict: approve / needs_work / reject
- Integrates SonarQube Quality Gate status into verdict
- Does NOT hallucinate issues — must cite exact file:line
- Separates PR issues from repository health issues

## Verdict → PR Review Status Mapping

| AI Verdict | GitHub Review Event | Effect on PR |
|-----------|-------------------|--------------|
| `approve` | APPROVE | Green checkmark |
| `needs_work` | REQUEST_CHANGES | Blocks merge (dismissible) |
| `reject` | REQUEST_CHANGES | Blocks merge (dismissible) |

Previous bot reviews are auto-dismissed before submitting a new one.

## Custom Instructions Flow

```
Owner writes plain English in .agentic-review.yml or workflow input
       │
       ▼
Security filtering (reject suppression, credentials, verdict manipulation)
       │
       ▼
Validated payload injected into Pass 1 prompt with priority rules
       │
       ▼
AI interprets and translates to commands (MATCH / OWNER ADDED / OWNER OVERRIDE)
       │
       ▼
Pass 2 receives payload context for review awareness
```
