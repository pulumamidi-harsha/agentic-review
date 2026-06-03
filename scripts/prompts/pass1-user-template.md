# Pass 1 user message structure (built by ai-pass1.sh)

Sections sent to the model:
- Repository file tree (truncated)
- Configuration file contents (truncated)
- Optional: repository owner custom instructions (high priority)
- PR metadata: size class, diff line count (when available)

The model must output commands with cd ${WORKDIR} prefixes only.
