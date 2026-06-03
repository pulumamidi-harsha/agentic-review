# Pass 1 user message structure (built by ai-pass1.sh)

Sections sent to the model:
- PR context: size class, diff line count, review_type, separate pipeline jobs
- Repository file tree (truncated)
- Configuration file contents (truncated)
- Optional: repository owner custom instructions (high priority)

The model must output valid JSON per pass1-system.txt. All runnable commands (setup, check, dependency_audit) are chosen by the model from repo config — bash scripts only execute and format results.
