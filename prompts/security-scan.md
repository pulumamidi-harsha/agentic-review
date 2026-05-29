# Security & File Hygiene Scans

These scans run automatically on every PR, independent of the AI review. Results are fed to AI Pass 2 for contextual analysis.

## Scans Executed

### 1. Gitleaks — Secret Detection
- Scans the entire codebase for hardcoded secrets (API keys, tokens, passwords, private keys)
- Uses a custom `.gitleaks.toml` config to reduce false positives (excludes workflow files, lock files)
- Findings are REDACTED in output (safe for PR comments)
- Pre-existing secrets noted in repo_health; new secrets in PR flagged as CRITICAL

### 2. Sensitive File Detection
Scans for files that should never be committed:
- `.env`, `.env.local`, `.env.production`
- `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`
- `id_rsa`, `id_ed25519`
- `credentials.json`, `service-account*.json`
- `secrets.yml`, `.htpasswd`

### 3. End-of-File (EOF) Newline Check
Verifies all source files end with a newline (POSIX standard). Covers:
- All major source extensions (.ts, .py, .go, .rs, .rb, .java, .kt, etc.)
- Config files (.yml, .json, .toml)
- Infrastructure files (.tf, .sh, Dockerfile, Makefile)

### 4. Large File Detection (>5MB)
Flags files larger than 5MB that should use Git LFS.

### 5. TODO/FIXME/HACK Detection
Scans PR diff for code markers (TODO, FIXME, HACK, XXX, WORKAROUND) in new/changed lines. Informational only.

### 6. License File Check
Verifies LICENSE file exists in repository root.

### 7. YAML/JSON/XML Syntax Validation
Validates changed files for syntax correctness:
- **YAML**: Uses Python `yaml.safe_load()`
- **JSON**: Uses Python `json.load()`
- **XML**: Uses Python `xml.etree.ElementTree.parse()`
- **GitHub Actions workflows**: Checks for `on:` trigger, `jobs:` section, pinned action versions

## How Results Are Used

1. Each scan produces PASSED/FAILED with details
2. All results are saved to `/tmp/security-results.txt`
3. Results are sent to AI Pass 2 as context for the code review
4. Results appear in the PR comment under a collapsible "Security & File Hygiene Scans" section
5. Critical findings (leaked secrets, sensitive files) are flagged by AI as high-severity issues
