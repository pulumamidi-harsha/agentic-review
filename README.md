# Agentic Review

**AI PR review hub** — Pass 1/2, sandbox checks, security/Docker scans, AI verdict comment.

> **Fully isolated from Sonar replacement.**  
> Quality gate / Semgrep / complexity / duplication lives only in  
> [`agentic-quality-gate`](https://github.com/pulumamidi-harsha/agentic-quality-gate).  
> Use **two separate caller workflows** in consumer repos — never one shared job.

## Two hubs

| Folder / repo | Job | Responsibility |
|---------------|-----|----------------|
| **agentic-review** (this) | `AI PR Review` | AI review only |
| **agentic-quality-gate** | `PR Quality Gate` | Sonar replacement only |

## Caller (AI only)

```yaml
name: AI PR Review
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
  pull-requests: write
  issues: write
jobs:
  ai-review:
    uses: pulumamidi-harsha/agentic-review/.github/workflows/ai-review.yml@<FULL_SHA>
    with:
      pipeline_repository: pulumamidi-harsha/agentic-review
      pipeline_ref: <FULL_SHA>
    secrets:
      AI_API_KEY: ${{ secrets.AI_API_KEY }}
      AI_API_ENDPOINT: ${{ secrets.AI_API_ENDPOINT }}
      ORG_PAT: ${{ secrets.ORG_PAT }}
```

For Sonar replacement, add a **second** workflow that calls `agentic-quality-gate` (see that repo’s README).

## What this hub does

1. Reads repo + PR diff  
2. AI Pass 1 plans lint/test commands  
3. Runs checks / Gitleaks / Docker·Trivy (etc.) in parallel  
4. AI Pass 2 verdict on **changed files**  
5. Posts **🤖 AI Code Review** comment + labels  

**No Semgrep quality-gate package here.**
