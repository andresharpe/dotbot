<!-- dotbot:framework-protection -->
## dotbot framework files (READ-ONLY)

NEVER modify files under `.bot/` except `.bot/workspace/`.

Framework files under `.bot/core/`, `.bot/hooks/`, `.bot/recipes/`, and `.bot/settings/*.default.json` are managed by dotbot. Direct edits are rejected by a pre-commit hook and detected by verification hooks. To update framework files, run `dotbot init --force`.
<!-- /dotbot:framework-protection -->
