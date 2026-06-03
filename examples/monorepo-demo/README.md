# Monorepo AI Review Demo

Minimal **Node.js + Python + Terraform** monorepo for testing [agentic-review](https://github.com/pulumamidi-harsha/agentic-review).

```
monorepo-demo/
├── apps/web/          ← Node.js / TypeScript (Vite)
├── services/api/      ← Python / FastAPI
├── infra/             ← Terraform (AWS)
└── .github/workflows/ ← AI PR Review caller
```

## Push to GitHub (one-time)

```bash
# From this folder (or copy files to a new repo root)
gh repo create monorepo-ai-review-demo --public --source=. --remote=origin --push
# Or: create empty repo on GitHub, then:
git init && git add . && git commit -m "init monorepo demo for ai-review"
git remote add origin git@github.com:YOUR_USER/monorepo-ai-review-demo.git
git push -u origin main
```

Add secrets on the repo (or org): `AI_API_KEY`, `AI_API_ENDPOINT`, `ORG_PAT`.

## Trigger a review

```bash
git checkout -b test/ai-review
echo "// ai-review test" >> apps/web/src/index.ts
git add . && git commit -m "test: trigger ai-review on monorepo"
git push -u origin test/ai-review
gh pr create --title "Test AI review (monorepo)" --body "Validates Node + Python + IaC detection"
```

## What to verify in the PR comment

| Signal | Expected |
|--------|----------|
| Pass 1 `stacks` | 3 entries: `apps/web`, `services/api`, `infra` |
| Check commands | `cd apps/web …`, Python lint/test in `services/api`, `terraform validate` in `infra` |
| Check summary | Multiple planned/run checks (not 0) |
| Repo health | CI coverage matrix per stack |

## Local Pass 1 dry run (optional)

```bash
export AGENTIC_TMP=/tmp/agentic-review REVIEW_TYPE=full
export GITHUB_BASE_REF=main AI_API_KEY=... AI_API_ENDPOINT=...
mkdir -p "$AGENTIC_TMP"
bash ../../scripts/gather-context.sh   # run from repo root after clone
bash ../../scripts/ai-pass1.sh
jq '{stacks, check_commands: [.check_commands[] | {cmd, purpose}]}' "$AGENTIC_TMP/ai-commands.json"
```

## Layout notes

- **Root** uses pnpm workspaces for `apps/*` only (Python and Terraform are sibling trees — typical monorepo pattern).
- Checks are lightweight (`tsc`, `ruff`, `pytest`, `terraform validate`) so CI finishes quickly.
- Change files in **one** stack first (e.g. only `apps/web`) to test scoped verdict behavior.
