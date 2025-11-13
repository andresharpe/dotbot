# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Repository Overview

**dotbot** is a PowerShell-based tool that transforms AI coding agents into productive developers through structured workflows. It combines spec-driven development with cross-platform tooling, optimized for Warp AI and other AI coding assistants.

### Core Concept
dotbot provides repeatable, predictable, and auditable AI-driven development by:
- Guiding agents through structured workflows (Plan → Shape → Specify → Tasks → Implement → Verify)
- Enforcing coding standards and conventions
- Creating an audit trail through specs, task lists, and verification reports
- Supporting cross-functional teams (Product, Architects, Developers, QA)

## Commands

### Development & Testing

**Run PowerShell scripts:**
```powershell
pwsh <script-name>.ps1
```

**Test the init script (base installation):**
```powershell
pwsh init.ps1
```

**Test project installation in a test directory:**
```powershell
cd <test-project-directory>
dotbot init --dry-run
```

**Validate file references in profile content:**
```powershell
pwsh scripts/validate-references.ps1
```

### Installation Commands

**Global installation (from repository):**
```powershell
cd ~/dotbot
pwsh init.ps1
```

**Project initialization:**
```powershell
dotbot init [options]
```

**Status checking:**
```powershell
dotbot status
```

**Update operations:**
```powershell
dotbot update              # Update global installation
dotbot update-project      # Update project installation
```

### Key PowerShell Modules

- `scripts/Common-Functions.psm1` - Shared utility functions (file operations, config parsing)
- `scripts/Platform-Functions.psm1` - Cross-platform compatibility functions
- `bin/dotbot.ps1` - Main CLI entry point

## Architecture

### High-Level Structure

```
dotbot/
├── bin/                    # CLI entry point (dotbot.ps1)
├── scripts/                # PowerShell installation and utility scripts
├── profiles/               # Reusable profiles (default profile contains all content)
│   └── default/
│       ├── agents/         # AI agent personas (8 specialized agents)
│       ├── commands/       # Warp slash command templates (7 commands)
│       ├── standards/      # Coding standards organized by domain
│       └── workflows/      # Step-by-step implementation workflows
├── docs/                   # Documentation for interaction patterns and templates
├── config.yml              # Default configuration
└── init.ps1               # Smart initialization script
```

### Profile Architecture

Profiles are the core organizational unit in dotbot. The `default` profile contains:

**Agents (8 specialized personas):**
- `implementer.md` - Code implementation specialist
- `spec-writer.md` - Technical specification author
- `implementation-verifier.md` - End-to-end verification
- `product-planner.md` - Product vision and roadmap creator
- `spec-initializer.md` - Spec structure initialization
- `spec-shaper.md` - Requirements research and scoping
- `spec-verifier.md` - Specification validation
- `tasks-list-creator.md` - Task breakdown and planning

**Standards (organized by domain):**
- `global/` - Language-agnostic standards (coding-style, error-handling, conventions, etc.)
- `backend/` - Server-side standards (API, migrations, models, queries)
- `frontend/` - UI standards (accessibility, components, CSS, responsive)
- `testing/` - Test writing approach and strategy

**Workflows (organized by phase):**
- `planning/` - Product vision, mission, roadmap, tech stack
- `specification/` - Initialize, research, write, verify specs
- `implementation/` - Create tasks, implement, verify
- `implementation/verification/` - Task verification, testing, reporting

**Commands (Warp integration):**
- Templates for Warp slash commands that trigger workflows
- Support template variables for dynamic content
- Can be installed to `.warp/commands/dotbot/` or standalone `.bot/commands/`

### Installation Flow

1. **Base Installation** (`init.ps1` → `scripts/base-install.ps1`)
   - Copies dotbot to `~/dotbot`
   - Adds `dotbot` command to PATH (Windows registry or shell profile)
   - Creates global configuration

2. **Project Installation** (`dotbot init` → `scripts/project-install.ps1`)
   - Creates `.bot/` directory structure
   - Copies agents, standards, and workflows from selected profile
   - Optionally installs Warp commands to `.warp/commands/dotbot/`
   - Optionally adds standards as Warp rules to `WARP.md`
   - Creates `.dotbot-state.json` to track installation

### Configuration System

**Global config** (`~/dotbot/config.yml`):
- Default profile selection
- Standards handling preference (as Warp rules vs. separate files)
- Base installation tracking

**Project state** (`.bot/.dotbot-state.json`):
- Installed version tracking
- Profile used
- Installation options chosen

**Template variables** (used in commands/workflows):
- `{{IF warp_commands}}` - Conditional content for Warp integration
- `{{IF standards_as_warp_rules}}` - Conditional standards handling
- `{{workflows/path/to/workflow}}` - Workflow references
- See `docs/TEMPLATE-VARIABLES.md` for full documentation

### Interaction Pattern

The interaction pattern (documented in `docs/INTERACTION-GUIDELINES.md`) defines how agents should interact with users:

**Core principles:**
1. List all questions upfront before starting
2. Present options in consistent format (A, B, C, D with descriptions)
3. Use simple commands: `go A`, `skip`, `back`, `exit`, `summary`, `help`
4. Order options by recommendation (best first)
5. **Dynamic option refinement** - If user provides context instead of selecting, acknowledge and refine options
6. Show progress indicators (Question 2 of 5)
7. Acknowledge and echo back choices
8. Provide exit options
9. Handle unexpected input gracefully
10. Offer quick defaults for power users
11. Summary before proceeding

**Critical rule:** Never ignore user context. If user provides guidance or corrections, refine the options based on their input and re-present them.

## Development Practices

### PowerShell Coding Standards

When contributing PowerShell code:
- Use approved verbs: `Get-`, `Set-`, `New-`, `Remove-`, `Test-`, `Invoke-`
- Follow PascalCase for function names
- Use `[CmdletBinding()]` for advanced functions
- Include parameter validation with `[Parameter()]` attributes
- Support `-WhatIf` and `-Confirm` for destructive operations
- Handle errors with `$ErrorActionPreference = "Stop"`
- Use `Write-Host` with `-ForegroundColor` for user-facing output
- Test cross-platform compatibility (Windows, macOS, Linux)

### File Operations

Use the helper functions from `Common-Functions.psm1`:
- `Copy-FileWithLogging` - Copy files with logging and dry-run support
- `Get-ConfigValue` - Parse YAML config files
- `Write-StepHeader` - Consistent step formatting
- `Write-Success`, `Write-Warning`, `Write-Error` - Formatted messages

### Cross-Platform Considerations

**PATH handling:**
- Windows: Uses registry (`HKCU:\Environment`) with `;` separator
- macOS/Linux: Uses shell profiles with `:` separator

**PowerShell version:**
- Requires PowerShell 7+ on all platforms
- Check with `Test-PowerShellVersion` from Platform-Functions.psm1

**File permissions:**
- macOS/Linux: Set executable permissions on `bin/dotbot.ps1`
- Windows: No special permissions needed

### Profile Creation

To create a new profile:
1. Create directory under `profiles/[profile-name]/`
2. Add subdirectories: `agents/`, `commands/`, `standards/`, `workflows/`
3. Populate with markdown files following existing patterns
4. Update `config.yml` to reference the new profile
5. Organize standards by domain (global, backend, frontend, testing)
6. Organize workflows by phase (planning, specification, implementation)

### Testing

Before submitting changes:
1. Test with `-DryRun` flag for installation scripts
2. Verify file copying works correctly on your platform
3. Test configuration loading from `config.yml`
4. Ensure cross-platform compatibility (test on Windows if possible)
5. Validate file references: `pwsh scripts/validate-references.ps1`
6. Test template variable substitution

### Documentation

- Update `README.md` for user-facing features
- Update `CHANGELOG.md` following Keep a Changelog format
- Add inline comments for complex logic in PowerShell
- Document interaction patterns in workflow files
- Update `config.yml` defaults when adding options

## Key Files to Understand

### Core Scripts
- `bin/dotbot.ps1` - Main CLI router, handles command dispatch
- `init.ps1` - Smart initialization that detects context (repo vs. project)
- `scripts/base-install.ps1` - Global installation logic
- `scripts/project-install.ps1` - Project-level installation with profile support
- `scripts/Common-Functions.psm1` - Shared utilities
- `scripts/Platform-Functions.psm1` - Platform detection and compatibility

### Documentation
- `docs/INTERACTION-GUIDELINES.md` - Complete interaction pattern specification
- `docs/TEMPLATE-VARIABLES.md` - Template variable system documentation
- `CONTRIBUTING.md` - Contribution guidelines and structure

### Profile Content
- `profiles/default/agents/implementer.md` - Reference implementation of agent persona
- `profiles/default/workflows/implementation/implement-tasks.md` - Reference workflow
- `profiles/default/standards/global/workflow-interaction.md` - Concise interaction standard

## Common Development Patterns

### Adding a New Workflow

1. Create markdown file in appropriate `profiles/[profile]/workflows/[phase]/` directory
2. Include agent reference: `**Agent:** @.bot/agents/[agent-name].md`
3. Include interaction standard reference for user-facing workflows
4. Structure: Prerequisites → Steps → Output
5. Add to profile's command if it should be exposed to users

### Adding a New Agent

1. Create markdown file in `profiles/[profile]/agents/`
2. Define role and responsibilities
3. Reference relevant standards files
4. Reference relevant workflow files
5. Include interaction principles if agent interacts with users
6. Add code review checklist if applicable

### Adding a New Standard

1. Create markdown file in appropriate `profiles/[profile]/standards/[domain]/` directory
2. Use clear principle-based structure
3. Provide examples where helpful
4. Keep it concise - agents should be able to parse quickly
5. Reference from relevant agent files

### Updating Configuration Behavior

1. Add configuration key to `config.yml` with default value
2. Document the configuration in comments
3. Update `project-install.ps1` to respect the configuration
4. Add command-line flag support if appropriate
5. Update README.md with new option
6. Consider backward compatibility

## Spec-Driven Development Flow

The intended workflow for users of dotbot:

1. **Plan** - Define product vision, mission, roadmap (`gather-product-info`, `create-product-mission`, etc.)
2. **Shape** - Research and scope features (`research-spec`)
3. **Specify** - Write detailed technical specifications (`write-spec`)
4. **Tasks** - Break specs into implementable tasks (`create-tasks-list`)
5. **Implement** - Execute tasks with verification steps (`implement-tasks`)
6. **Verify** - Validate requirements are met (`verify-implementation`)

Each phase has corresponding:
- Workflows (step-by-step process)
- Agents (specialized persona)
- Standards (quality guidelines)
- Commands (Warp slash command to trigger)

## Windows-Specific Notes

- dotbot is primarily developed on Windows with cross-platform support
- Uses Windows registry for PATH manipulation: `HKCU:\Environment\Path`
- PowerShell 5.1+ supported but 7+ recommended
- Path separators in code should use `Join-Path` for cross-platform compatibility
- Test with both PowerShell 5.1 (Windows PowerShell) and 7+ (PowerShell Core)

## Warp Integration

dotbot is designed specifically for Warp's Agent Mode:

**Slash Commands:**
- Commands install to `.warp/commands/dotbot/`
- Accessible via Ctrl-Shift-R in Warp
- Named pattern: `dotbot-[number]-[action-name]`

**Project Rules:**
- Standards can be added to `WARP.md` automatically
- Controlled by `standards_as_warp_rules` config option
- Provides automatic agent guidance without file references

**Agent Mode Optimization:**
- Structured workflows guide agents step-by-step
- Clear interaction patterns reduce ambiguity
- Template variables enable context-aware behavior
- Standards enforce consistency across sessions
