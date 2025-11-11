# Contributing to dotbot

Thank you for your interest in contributing to dotbot! This document provides guidelines and information for contributors.

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Create a feature branch: `git checkout -b feature/your-feature-name`
4. Make your changes
5. Test your changes
6. Commit with clear messages
7. Push to your fork
8. Open a pull request

## Project Structure

```
dotbot/
├── profiles/          # Reusable profiles with standards, workflows, commands
│   └── default/       # The default profile
│       ├── agents/    # AI agent templates
│       ├── commands/  # Command templates
│       ├── standards/ # Coding standards and best practices
│       └── workflows/ # Step-by-step workflows
├── scripts/           # PowerShell installation scripts
│   ├── base-install.ps1          # Base installation
│   ├── project-install.ps1       # Project installation
│   └── Common-Functions.psm1     # Shared functions
├── config.yml         # Default configuration
├── README.md          # Documentation
└── CHANGELOG.md       # Version history
```

## Creating Profiles

You can create custom profiles for different tech stacks or teams:

1. Create a new directory under `profiles/`
2. Add the same structure as `profiles/default/`
3. Customize standards, workflows, commands, and agents
4. Update `config.yml` to reference your new profile

## Adding Standards

Standards go in `profiles/[profile]/standards/`:

- `global/` - Language-agnostic standards
- `frontend/` - Frontend-specific standards
- `backend/` - Backend-specific standards  
- `testing/` - Testing standards

Format:
```markdown
## [Standard Name]

- **Principle 1**: Description
- **Principle 2**: Description
```

## Adding Workflows

Workflows go in `profiles/[profile]/workflows/`:

- `planning/` - Product planning workflows
- `specification/` - Spec creation workflows
- `implementation/` - Implementation workflows

Format:
```markdown
# [Workflow Name] Workflow

## Prerequisites
[What you need before starting]

## Steps
1. [Step 1]
2. [Step 2]

## Output
[What you'll have when done]
```

## Adding Commands

Commands go in `profiles/[profile]/commands/`

Format:
```markdown
# [Command Name] Command

## Description
[What this command does]

## When to Use
[Scenarios for using this command]

## Inputs
[What information is needed]

## Standards
[Which standards this follows]

## Workflow
[Which workflow this follows]

## Output
[What the command produces]
```

## Adding Agents

Agents go in `profiles/[profile]/agents/`

Format:
```markdown
# [Agent Name] Agent

You are a [role]. Your responsibilities are...

## Your Responsibilities
1. [Responsibility 1]
2. [Responsibility 2]

## Standards to Follow
- `path/to/standard.md`

## Workflow to Follow
- `path/to/workflow.md`
```

## PowerShell Coding Standards

When contributing PowerShell code:

- Use approved verbs (Get, Set, New, Remove, etc.)
- Follow PascalCase for function names
- Use `[CmdletBinding()]` for advanced functions
- Include parameter validation
- Support `-WhatIf` and `-Confirm` for destructive operations
- Add comment-based help
- Handle errors with `$ErrorActionPreference`
- Use verbose and debug output appropriately

## Testing

Before submitting a PR:

1. Test installation scripts with `-DryRun`
2. Verify file copying works correctly
3. Test configuration loading
4. Ensure Windows paths work (including UNC paths)
5. Test with PowerShell 7+

## Documentation

- Update README.md if adding user-facing features
- Update CHANGELOG.md following Keep a Changelog format
- Add inline comments for complex logic
- Update config.yml if adding configuration options

## Commit Messages

Use clear, descriptive commit messages:

```
Add user authentication workflow

- Add workflow for OAuth implementation
- Include security best practices
- Add examples for common providers
```

## Pull Request Process

1. Ensure your PR description explains what and why
2. Reference any related issues
3. Include testing notes
4. Update documentation
5. Keep PRs focused (one feature/fix per PR)

## Questions?

Open an issue for:
- Bug reports
- Feature requests
- Questions about contributing
- General discussions

## Code of Conduct

Be respectful, constructive, and collaborative. We're all here to build better tools together.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
