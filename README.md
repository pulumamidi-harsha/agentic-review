# AI CI Prompts — Universal PR Review Pipeline

Zero-config, fully AI-driven CI that works for **any** repository. No hardcoded commands, no stack-specific logic. The AI reads your repo and figures out everything itself.

## How It Works (2-Pass AI Architecture)

```
PR opened → GitHub Actions triggers
  ↓
Gather repo context (file tree + ALL config/build files + diff)
  ↓
━━━ AI PASS 1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
AI reads package.json scripts, Makefile targets, pyproject.toml
tools, existing CI workflows — determines what commands to run
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ↓
Pipeline executes those commands dynamically (no hardcoding)
  ↓
━━━ AI PASS 2 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
AI reviews the code diff + check results → provides feedback
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ↓
Posts detailed review as PR comment
```

**Key principle:** The AI derives commands from what's IN the repo (package.json `scripts`, Makefile targets, pyproject.toml `[tool.*]`, etc.) — it never guesses or hardcodes.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  THIS REPO (agentic-review)                          │
│                                                     │
│  prompts/                                           │
│  ├── detect-and-command.md  ← Pass 1: read repo,   │
│  │                             determine commands   │
│  ├── review-results.md      ← Pass 2: review code  │
│  │                             + check results      │
│  └── security-scan.md       ← Security-focused      │
│                                                     │
│  .github/workflows/                                 │
│  └── ai-review.yml          ← Reusable workflow     │
│                                                     │
│  examples/                                          │
│  └── caller-workflow.yml     ← Copy to your repo    │
└─────────────────────────────────────────────────────┘
```

## Quick Start (2 minutes)

### 1. Add secrets to your repo (or org-level)

| Secret | Value |
|--------|-------|
| `AI_API_KEY` | Your MGA / OpenAI / Azure OpenAI API key |
| `AI_API_ENDPOINT` | API endpoint (e.g., `https://mga.bayer.com/v1/chat/completions`) |

### 2. Copy the caller workflow to your repo

```bash
mkdir -p .github/workflows
cp examples/caller-workflow.yml your-repo/.github/workflows/pr-check.yml
```

Or just create `.github/workflows/pr-check.yml`:

```yaml
name: PR Check
on:
  pull_request:
    branches: [main, dev]
jobs:
  ai-review:
    uses: bayer-int/agentic-review/.github/workflows/ai-review.yml@main
    with:
      review_type: full    # or: security
    secrets:
      AI_API_KEY: ${{ secrets.AI_API_KEY }}
      AI_API_ENDPOINT: ${{ secrets.AI_API_ENDPOINT }}
```

### 3. Open a PR — done!

The pipeline will:
1. Detect your stack (package.json? Python? Terraform?)
2. Run appropriate lint/test/security checks
3. Send code + results to the AI
4. Post a detailed review comment on your PR

## How It Works

```
PR opened → GitHub Actions triggers
  ↓
Checkout repo + prompts
  ↓
Detect stack (package.json → Node.js, requirements.txt → Python, etc.)
  ↓
Run standard checks (eslint, tsc, pytest, terraform validate, etc.)
  ↓
Gather context: file tree + diff + config files + check results
  ↓
Send to LLM with review prompt
  ↓
Post AI review as PR comment (issues, suggestions, verdict)
```

## Customizing Prompts

Edit files in `prompts/` to customize what the AI checks for. Changes apply to ALL repos using this pipeline — no per-repo updates needed.

## Supported — Everything (AI figures it out)

The AI reads your repo's config files and determines what to run. Examples of what it picks up:

| What AI Reads | Commands It Derives |
|---------------|---------------------|
| `package.json` → `scripts.lint` | `npm run lint` |
| `package.json` → `scripts.test` | `npm run test -- --ci` |
| `Makefile` → `lint:` target | `make lint` |
| `pyproject.toml` → `[tool.ruff]` | `ruff check .` |
| `pyproject.toml` → `[tool.pytest]` | `pytest` |
| `tox.ini` | `tox` |
| `.github/workflows/ci.yml` | Replicates existing CI checks |
| `Dockerfile` + no hadolint config | `hadolint Dockerfile` |
| `go.mod` + `golangci-lint` in deps | `golangci-lint run` |
| `turbo.json` / `nx.json` | Monorepo-aware commands |

No hardcoded stack detection. No `if python then ruff`. The AI reads and decides.

## LLM Compatibility

Works with any OpenAI-compatible chat completions API:
- **MGA (MyGenAssist)** — Bayer internal
- **Azure OpenAI**
- **OpenAI API**
- **Any OpenAI-compatible proxy**

Just set `AI_API_ENDPOINT` to your provider's `/v1/chat/completions` URL.
