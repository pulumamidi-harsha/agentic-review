# Agentic Review — AI-Powered Universal PR Review Pipeline

A **centralized, reusable** GitHub Actions workflow that provides intelligent code review for **any repository**, regardless of tech stack. It uses AI (LLM) to dynamically detect your project's technology, run the appropriate quality checks, and post a detailed review comment on every pull request.

> **One workflow. Any language. Zero configuration per repo.**

---

## What This Does

When a pull request is opened against any repository that calls this workflow, it automatically:

1. **Scans** your repository structure and configuration files
2. **Identifies** the tech stack using AI (not regex, not file-extension matching — actual AI reasoning)
3. **Determines** the correct commands to install dependencies, lint, type-check, and test
4. **Executes** those commands in CI
5. **Reviews** your code changes alongside the check results using AI
6. **Posts** a structured, actionable review comment directly on the PR

The entire process is **informational** — it never blocks merging. Your existing CI gates remain untouched.

---

## How It Works — Step by Step

### Pipeline Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│  PR Opened / Updated                                                  │
└──────────────┬───────────────────────────────────────────────────────┘
               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  STAGE 1: Gather Repository Context                                   │
│                                                                      │
│  • Builds a file tree (excludes node_modules, .venv, dist, etc.)     │
│  • Generates the PR diff (excludes lock files)                       │
│  • Reads ALL config files: package.json, pyproject.toml, Makefile,   │
│    go.mod, Cargo.toml, tsconfig.json, Dockerfile, eslint configs,    │
│    vitest/jest configs, pom.xml, build.gradle, .npmrc, etc.          │
└──────────────┬───────────────────────────────────────────────────────┘
               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  STAGE 2: AI Pass 1 — Stack Detection & Command Generation           │
│                                                                      │
│  The file tree + config file contents are sent to the LLM.           │
│  The AI reads them and returns a structured JSON response:            │
│                                                                      │
│  {                                                                   │
│    "stack": { "language": "python", "framework": "fastapi",          │
│               "package_manager": "pip" },                            │
│    "setup_commands": [                                                │
│      { "cmd": "pip install -r requirements.txt", "purpose": "..." }  │
│    ],                                                                │
│    "check_commands": [                                                │
│      { "cmd": "ruff check .", "purpose": "Linting" },                │
│      { "cmd": "mypy app/", "purpose": "Type checking" },             │
│      { "cmd": "pytest --tb=short", "purpose": "Unit tests" }         │
│    ],                                                                │
│    "runtime_requirements": { "python_version": "3.11" }              │
│  }                                                                   │
│                                                                      │
│  KEY: The AI ONLY derives commands from what exists in the repo.      │
│  It reads Makefile targets, package.json scripts, pyproject.toml     │
│  tool sections — it never invents commands the repo doesn't support. │
└──────────────┬───────────────────────────────────────────────────────┘
               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  STAGE 3: Runtime Setup (Conditional)                                 │
│                                                                      │
│  Based on the AI's response, the pipeline conditionally sets up:      │
│                                                                      │
│  • Node.js (+ pnpm/yarn/npm auto-detected from packageManager field)│
│  • Python (version from pyproject.toml or AI recommendation)         │
│  • Go (version from go.mod)                                          │
│  • Private registry auth (Artifactory) — only if credentials exist   │
│                                                                      │
│  If the stack is Python → Node.js steps are completely skipped.       │
│  If the stack is Go → both Node.js and Python steps are skipped.     │
└──────────────┬───────────────────────────────────────────────────────┘
               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  STAGE 4: Execute AI-Determined Checks                                │
│                                                                      │
│  1. Runs setup_commands (dependency installation)                     │
│     → Failures here are non-fatal (noted as warnings)                │
│                                                                      │
│  2. Runs each check_command sequentially:                             │
│     → Captures stdout/stderr and exit code                           │
│     → Records PASSED/FAILED status per check                         │
│     → Continues even if one check fails                              │
│                                                                      │
│  Example output for a Python repo:                                    │
│     ✅ ruff check . — PASSED                                         │
│     ✅ mypy app/ — PASSED                                            │
│     ❌ pytest --tb=short — FAILED (exit 1)                           │
└──────────────┬───────────────────────────────────────────────────────┘
               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  STAGE 4.5: Docker Build & Trivy Security Scan (Auto-Detected)        │
│                                                                      │
│  If the repo contains a Dockerfile:                                   │
│                                                                      │
│  1. Auto-detects ALL Dockerfiles (Dockerfile, Dockerfile.*, *.Dockerfile)│
│  2. Detects required build ARGs and provides placeholder values       │
│  3. Runs `docker build` to verify the image builds successfully       │
│  4. If build passes → runs Trivy vulnerability scanner                │
│     → Scans for HIGH and CRITICAL CVEs in the built image            │
│     → Reports vulnerabilities with CVE IDs and affected packages     │
│  5. Results are included in the AI review for context                 │
│                                                                      │
│  If NO Dockerfile exists → this stage is completely skipped.          │
│  If build fails → reports the error, skips Trivy scan.                │
│  If Trivy finds issues → they appear in the AI review as security    │
│  concerns with specific CVE details.                                  │
└──────────────┬───────────────────────────────────────────────────────┘
               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  STAGE 5: AI Pass 2 — Code Review                                     │
│                                                                      │
│  Sends to the LLM:                                                    │
│    • The PR diff (code changes)                                       │
│    • The check results (what passed, what failed, output)            │
│    • Docker build & Trivy scan results (if applicable)               │
│    • Config files (for context)                                       │
│                                                                      │
│  The AI reviews for:                                                  │
│    1. Code quality & best practices                                   │
│    2. Security vulnerabilities (OWASP Top 10)                         │
│    3. Breaking changes or regressions                                 │
│    4. Test coverage gaps                                              │
│    5. Performance concerns                                            │
│    6. Whether CI failures are from THIS PR or pre-existing            │
│                                                                      │
│  Returns a structured verdict: approve / request_changes / comment    │
└──────────────┬───────────────────────────────────────────────────────┘
               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  STAGE 6: Post Review to PR                                           │
│                                                                      │
│  Posts a formatted comment including:                                  │
│    • Detected stack (e.g., "Python / FastAPI / pip")                  │
│    • Check results summary (3 passed, 1 failed)                      │
│    • Issues found (with severity, file, line, suggestion)            │
│    • Positives (what was done well)                                   │
│    • Suggestions (non-blocking improvements)                         │
│    • Full check output (collapsible)                                 │
│    • Commands the AI decided to run (collapsible)                    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## How AI Identifies Your Stack

The AI does **not** use simple file-extension matching or regex patterns. It receives the full content of your configuration files and reasons about them:

| What the AI Reads | What It Understands |
|-------------------|---------------------|
| `package.json` → `scripts` section | Which npm/pnpm/yarn commands are available (`lint`, `test`, `build`, `typecheck`) |
| `package.json` → `packageManager` field | Exact package manager and version (e.g., `pnpm@9.1.0`) |
| `pyproject.toml` → `[tool.ruff]` | Ruff is configured → run `ruff check .` |
| `pyproject.toml` → `[tool.mypy]` | MyPy is configured → run `mypy` with the right paths |
| `pyproject.toml` → `[tool.pytest.ini_options]` | Pytest is configured → run `pytest` |
| `Makefile` → target names | Available make targets (`make lint`, `make test`, `make format-check`) |
| `requirements.txt` / `requirements-dev.txt` | Python dependencies to install |
| `go.mod` → module path + Go version | Go project → run `go vet`, `go test`, check for `golangci-lint` |
| `Cargo.toml` | Rust project → run `cargo check`, `cargo test`, `cargo clippy` |
| `tsconfig.json` | TypeScript configured → type checking available |
| `.eslintrc.*` / `eslint.config.*` | ESLint configured → linting available |
| `Dockerfile` | Container build context (but does NOT run docker builds) |
| `.npmrc` | Private registry configuration (scoped packages) |

**The AI never guesses.** If your repo has no test framework configured, it won't try to run tests. If your Makefile has a `lint` target, it will use `make lint` instead of calling the linter directly.

---

## Quick Start

### 1. Add Secrets to Your Repository

Go to **Settings → Secrets and variables → Actions** and add:

| Secret | Required | Description |
|--------|----------|-------------|
| `AI_API_KEY` | Yes | API key for the LLM service |
| `AI_API_ENDPOINT` | Yes | Chat completions endpoint URL |
| `ARTIFACTORY_USERNAME` | No | For private npm packages (Node.js repos only) |
| `ARTIFACTORY_AUTH_TOKEN` | No | For private npm packages (Node.js repos only) |

### 2. Add the Caller Workflow to Your Repository

Create `.github/workflows/ai-review.yml` in your repo:

```yaml
name: AI PR Review

on:
  pull_request:
    branches: [main, dev]

jobs:
  ai-review:
    uses: pulumamidi-harsha/agentic-review/.github/workflows/ai-review.yml@main
    secrets:
      AI_API_KEY: ${{ secrets.AI_API_KEY }}
      AI_API_ENDPOINT: ${{ secrets.AI_API_ENDPOINT }}
      ORG_PAT: ${{ secrets.ORG_REPOS_INTERNAL_READ_ONLY }}
      ARTIFACTORY_USERNAME: ${{ secrets.ARTIFACTORY_USERNAME }}
      ARTIFACTORY_AUTH_TOKEN: ${{ secrets.ARTIFACTORY_AUTH_TOKEN }}
```

That's it. **5 lines of YAML.** All logic lives in this centralized repo.

### 3. Open a PR

The pipeline triggers automatically. Within ~2 minutes you'll see a review comment on your PR.

---

## What the PR Comment Looks Like

```
┌────────────────────────────────────────────────────────────────────┐
│  🤖 AI Code Review — ✅ APPROVE                                     │
│                                                                    │
│  > This PR adds input validation to the API endpoints.             │
│                                                                    │
│  | Stack              | Checks          | Confidence |             │
│  |--------------------|-----------------|------------|             │
│  | Python / FastAPI / pip | ✅ 3 passed, 0 failed | 92%       |   │
│                                                                    │
│  ### CI Analysis                                                   │
│  All linting, type checking, and tests pass cleanly.               │
│                                                                    │
│  ### What's Good                                                   │
│  - Input validation using Pydantic models                          │
│  - Comprehensive test coverage for edge cases                      │
│                                                                    │
│  ### Suggestions                                                   │
│  - Consider adding rate limiting to the new endpoint               │
│                                                                    │
│  📋 Commands AI decided to run (expandable)                        │
│  📊 Full Check Output (expandable)                                 │
└────────────────────────────────────────────────────────────────────┘
```

---

## Supported Stacks

This workflow works for **any** tech stack. The AI adapts to whatever it finds in your repo:

| Stack | How It's Detected | Typical Commands Generated |
|-------|-------------------|---------------------------|
| **Node.js / TypeScript** | `package.json`, `tsconfig.json` | `pnpm install`, `pnpm run lint`, `pnpm run typecheck`, `pnpm run test` |
| **Python** | `pyproject.toml`, `requirements.txt`, `Makefile` | `pip install -r requirements.txt`, `ruff check .`, `mypy app/`, `pytest` |
| **Go** | `go.mod` | `go mod download`, `go vet ./...`, `go test ./...`, `golangci-lint run` |
| **Rust** | `Cargo.toml` | `cargo check`, `cargo clippy`, `cargo test` |
| **Java / Kotlin** | `pom.xml`, `build.gradle` | `mvn verify`, `gradle check` |
| **Monorepos** | `nx.json`, `turbo.json`, `pnpm-workspace.yaml` | Monorepo-aware commands |

---

## Docker Build & Trivy Security Scan

If your repository contains a **Dockerfile**, the pipeline automatically:

### 1. Detects Dockerfiles
Searches for any file matching `Dockerfile`, `Dockerfile.*`, or `*.Dockerfile` up to 3 directories deep.

### 2. Handles Build Arguments
If the Dockerfile uses `ARG` without defaults (required at build time), the pipeline:
- Detects them via `grep`
- Provides placeholder values so the build can proceed
- This verifies the Dockerfile syntax and layer structure even without real values

### 3. Runs `docker build`
```
docker build -t agentic-review-scan:<hash> -f ./Dockerfile --build-arg ENV=placeholder .
```
- If the build **fails** → reports the exact error output
- If the build **passes** → proceeds to security scan

### 4. Runs Trivy Vulnerability Scan
```
trivy image --severity HIGH,CRITICAL --no-progress --exit-code 1 <image>
```
- Scans the built image for known CVEs (HIGH and CRITICAL only)
- Reports affected packages, CVE IDs, and fixed versions
- Results are passed to the AI reviewer for analysis

### 5. AI Reviews the Results
The Docker build output and Trivy findings are sent to AI Pass 2. The AI:
- Identifies which vulnerabilities are from base images vs your code
- Suggests version bumps or alternative base images
- Flags if a Dockerfile change in the PR introduced new vulnerabilities

### When Does This Run?

| Scenario | Behavior |
|----------|----------|
| Repo has no Dockerfile | Entire Docker stage is skipped |
| Dockerfile exists, build fails | Reports error, skips Trivy |
| Build passes, Trivy finds nothing | Reports clean scan |
| Build passes, Trivy finds CVEs | Reports vulnerabilities in PR comment |
| Multiple Dockerfiles | Builds and scans each one |

---

## Design Principles

| Principle | Implementation |
|-----------|----------------|
| **Zero config per repo** | Add the 5-line caller workflow and secrets — done |
| **AI-driven, not rule-driven** | No `if language == "python"` logic anywhere. The LLM reasons about your repo. |
| **Centralized updates** | Fix a bug or improve prompts here → all repos benefit immediately |
| **Informational only** | Never blocks merging. Separate CI handles gating. |
| **Graceful degradation** | If AI fails, secrets are missing, or checks error — the workflow still completes without breaking |
| **Stack agnostic** | Works for Node.js, Python, Go, Rust, Java, or anything else |
| **Secure** | Secrets are passed via `workflow_call` secrets — never logged or exposed |

---

## Resilience & Error Handling

The workflow is designed to **never fail catastrophically**:

- If `AI_API_KEY` or `AI_API_ENDPOINT` is not configured → posts a clear error message, does not crash
- If the AI API is unreachable → falls back gracefully, still posts what it can
- If dependency installation fails → notes the warning, continues with checks
- If individual checks fail → captures output, continues to next check
- If Artifactory credentials are missing → skips private registry setup (Python/Go repos don't need it)
- All AI steps use `continue-on-error: true` — no single failure cascades

---

## LLM Compatibility

Works with any OpenAI-compatible chat completions API:

| Provider | Endpoint Example |
|----------|-----------------|
| **MGA (MyGenAssist)** — Bayer internal | `https://chat.int.bayer.com/api/v2/chat/completions` |
| **Azure OpenAI** | `https://{resource}.openai.azure.com/openai/deployments/{model}/chat/completions` |
| **OpenAI API** | `https://api.openai.com/v1/chat/completions` |
| **Any compatible proxy** | Your custom endpoint |

Set `AI_API_ENDPOINT` to your provider's URL. The model used is `gpt-4.1`.

---

## Repository Structure

```
agentic-review/
├── .github/
│   └── workflows/
│       └── ai-review.yml       ← The reusable workflow (all logic lives here)
├── README.md                   ← This file
└── examples/
    └── caller-workflow.yml     ← Copy this to your repo
```

---

## FAQ

**Q: Does this replace my existing CI?**  
No. This is purely informational. It adds a review comment but never blocks merging or interferes with your existing pipelines.

**Q: How long does it take?**  
Typically 1–3 minutes depending on repository size and how many checks the AI decides to run.

**Q: What if the AI gets it wrong?**  
The AI only runs commands it finds in your config files. If it picks something incorrect, the check will fail and the AI will note that in its review. Nothing is destructive.

**Q: Do I need different workflows for different languages?**  
No. The same 5-line caller workflow works for Python, Node.js, Go, Rust, Java — anything. The AI figures it out.

**Q: What about private packages / registries?**  
For Node.js repos using Bayer Artifactory, pass `ARTIFACTORY_USERNAME` and `ARTIFACTORY_AUTH_TOKEN` secrets. For Python repos using standard pip, no extra config is needed.

**Q: Can I use this across the org?**  
Yes. Set `AI_API_KEY` and `AI_API_ENDPOINT` as organization-level secrets, and every repo only needs the caller workflow file.
