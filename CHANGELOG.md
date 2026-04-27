# Changelog

All notable changes to dotbot are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- The kickstart vocabulary rename is locked in across the codebase. CSS classes, JS function names, modal IDs, the `kickstart_*` keys on `/api/info` (now `workflow_*`), the `Get-KickstartStatus` PowerShell function (now `Get-WorkflowStatus`), workflow YAML commit-message templates (`chore(kickstart):` → `chore(workflow):`), and the `dotbot-kickstart` generator string in `task-groups.json` and `roadmap-overview.md` front matter (now `dotbot-task-runner`) all use the new names.
- User-visible: the project-launch button label changed from `KICKSTART PROJECT` to `LAUNCH PROJECT`. The `Kickstart` button text in the preflight modal changed to `Launch`. The Jira interview phase title changed from `Kickstart Interview (Multi-Repo)` to `Project Interview (Multi-Repo)`. New commit messages use `chore(workflow):` instead of `chore(kickstart):`.

### Removed
- The `kickstart-via-jira`, `kickstart-via-pr`, `kickstart-via-repo`, and `kickstart-from-scratch` workflow aliases in `dotbot init -Workflow`. Use the canonical `start-from-jira`, `start-from-pr`, `start-from-repo`, and `start-from-prompt` names.

### CI
- The `tests/Test-NoKickstartReferences.ps1` warning gate is now `tests/Test-NoLegacyVocabulary.ps1`, a hard Layer 1 fail. Any `kickstart` reference outside `ideas/` and the gate file itself fails the build.
