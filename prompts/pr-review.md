# Universal PR Review Prompt (Legacy — kept for reference)

> **NOTE:** This prompt is no longer used directly by the pipeline.
> The pipeline now uses a 2-pass approach:
> - `detect-and-command.md` — AI reads the repo and decides what to run
> - `review-results.md` — AI reviews the code and results
>
> This file is kept for reference only.

3. **Review the code changes** for:
   - Security vulnerabilities (OWASP Top 10)
   - Performance issues
   - Error handling gaps
   - Breaking changes
   - Test coverage
   - Documentation accuracy
   - Code style consistency

4. **Output Format** — Return a structured JSON response:

```json
{
  "stack": {
    "language": "TypeScript",
    "framework": "React",
    "package_manager": "npm",
    "test_framework": "vitest",
    "linter": "eslint"
  },
  "commands_to_run": [
    {"cmd": "npm ci", "purpose": "Install dependencies"},
    {"cmd": "npx eslint . --max-warnings=0", "purpose": "Lint check"},
    {"cmd": "npx tsc --noEmit", "purpose": "Type check"},
    {"cmd": "npm test -- --ci", "purpose": "Run tests"}
  ],
  "review": {
    "summary": "Brief overall assessment",
    "issues": [
      {
        "severity": "critical|high|medium|low|info",
        "file": "src/components/Auth.tsx",
        "line": 42,
        "title": "Hardcoded secret in source",
        "description": "API key is hardcoded...",
        "suggestion": "Use environment variable..."
      }
    ],
    "security": [],
    "performance": [],
    "approvals": ["List of things done well"]
  },
  "verdict": "approve|request_changes|comment",
  "confidence": 0.92
}
```

## Context You Will Receive

- Repository file tree
- Changed files (diff)
- Full content of key config files (package.json, tsconfig.json, etc.)
- PR title and description
