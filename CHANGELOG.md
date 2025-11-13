# Changelog

All notable changes to dotbot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.15] - 2025-11-13

### Changed
- Updated BACKLOG.md for accuracy against actual implementation status

## [1.3.14] - 2025-11-13

### Added
- **Template Variables System**: Dynamic content generation in commands and workflows
  - New `Template-Processor.psm1` module for variable substitution
  - Support for configuration-aware content
  - Documentation in `docs/TEMPLATE-IMPLEMENTATION.md`
  - Comprehensive test suite in `tests/Template-Processor.Tests.ps1`

## [1.3.13] - 2025-11-13

### Changed
- Fixed README.md inaccuracies
  - Removed non-existent rails profile reference
  - Updated workflow count to 17
  - Corrected workflow organization documentation

## [1.3.12] - 2025-11-13

### Added
- **Comprehensive .NET Profile**: Full-stack .NET development support
  - Vertical slice architecture standards
  - Clean architecture and CQRS/MediatR patterns
  - Backend developer, frontend developer, and solution architect agents
  - API development, authentication, Entity Framework, and logging standards
  - Blazor WebAssembly frontend standards
  - Backend and vertical slice implementation workflows
  - Quick start guide and setup documentation

## [1.3.11] - 2025-11-13

### Changed
- Clarified `dotbot-improve-rules` command description

## [1.3.10] - 2025-11-13

### Changed
- Removed 'slash commands' terminology from README.md for clarity

## [1.3.9] - 2025-11-13

### Added
- **WARP.md**: New documentation file for Warp-specific guidance

### Changed
- Restructured README.md for better organization

## [1.3.8] - 2025-11-13

### Changed
- Enhanced README messaging to position dotbot as enterprise alternative to vibe coding

## [1.3.7] - 2025-11-13

### Changed
- Moved CROSS-PLATFORM-CHANGES.md to docs directory for better organization

## [1.3.6] - 2025-11-12

### Added
- **Cross-Platform Support**: Windows, macOS, and Linux compatibility
  - New `Platform-Functions.psm1` module for platform-specific operations
  - Updated all scripts for cross-platform compatibility
  - Cross-platform path handling and command execution
  - Documentation in `docs/CROSS-PLATFORM-CHANGES.md`
  - Git attributes configuration for line ending handling

## [1.3.5] - 2025-11-12

### Changed
- Made README badge update dynamically with version
- Added auto-rebase to version bump workflow

## [1.3.4] - 2025-11-12

### Added
- Automatic version bumping GitHub workflow
- Table of contents in README
- Dynamic version badge

### Changed
- Refined README documentation
- Removed emojis from README for professional appearance
- Switched to patch version bumping strategy

## [1.3.3] - 2025-11-12

### Added
- **Refactored CLI**: Scoped subcommands architecture
  - Cleaner command structure
  - Better command organization
  - Updated `bin/dotbot.ps1` with subcommand support

### Changed
- Updated README to reflect new CLI structure

## [1.3.2] - 2025-11-11

### Added
- README generation workflow (`create-project-readme.md`)
- Audit trail confirmation workflow (`confirm-audit-trail.md`)

### Changed
- Enhanced `plan-product` command with new workflows

## [1.3.1] - 2025-11-11

### Fixed
- Warp workflow shim YAML formatting
- Commands installation path to prevent nested folders
- Git initialization and Warp workflow shim generation
- Code block language markers in README

### Changed
- Warp workflows now execute dotbot commands instead of workflows directly
- Improved Warp workflow shim instructions with detailed guidance
- Updated documentation to use Ctrl-Shift-R workflow instead of slash commands
- Added numbered workflow names (1-6) for better organization

## [1.3.0] - 2025-11-11

### Added
- **Workflow Interaction Guidelines**: Comprehensive interaction standard for consistent user experiences
  - Option-based question format (A, B, C, D) with recommendations
  - Warp-friendly commands ('go A', 'skip', 'back', 'exit')
  - Dynamic option refinement when users provide context
  - Progress indicators and echo confirmations
  - Complete documentation in `docs/INTERACTION-GUIDELINES.md`
  - Concise agent reference in `.bot/standards/global/workflow-interaction.md`
  - Audit trail logging requirements
- **Interview Enhancements**: Open-ended questions, verbose options, and clarifications
  - Documentation in `docs/APPLIED-INTERVIEW-ENHANCEMENTS.md` and `docs/PROPOSED-INTERVIEW-ENHANCEMENTS.md`
- **Blue+Yellow Color Scheme**: Simplified and consistent UI across all scripts
- **Global dotbot Command**: System-wide CLI access
- **Update Commands**: `dotbot update` for base and project updates
- **Uninstall Command**: `dotbot uninstall` for clean removal
- **Visual Workflow Map**: Documentation in `docs/workflow-map.txt`
- **Comprehensive Default Profile**: Enhanced standards, agents, and workflows
  - New agents: implementation-verifier, product-planner, spec-initializer, spec-shaper, spec-verifier, tasks-list-creator
  - Backend standards: api.md, migrations.md, models.md, queries.md
  - Frontend standards: accessibility.md, components.md, css.md, responsive.md
  - Testing standards: test-writing.md
  - Implementation workflows: create-tasks-list.md, verification workflows
  - Planning workflows: gather-product-info.md, create-product-roadmap.md, create-product-tech-stack.md
  - Specification workflows: initialize-spec.md, research-spec.md, verify-spec.md
- **BACKLOG.md**: Prioritized improvement tracking
- **Git Integration**: Automatic git initialization in project installer
- **Warp Workflow Shims**: Automatic workflow shim generation for Warp integration

### Changed
- **Refactored gather-product-info workflow**: Now uses structured option-based questions
- **Updated all 8 agent files**: Added reference to workflow-interaction standard
- **Updated workflows**: Added interaction standard references to research-spec, write-spec, create-tasks-list, and implement-tasks
- Better error messages across all scripts
- Improved init.ps1 to automatically update when already installed
- Updated all scripts to match Blue+Yellow color scheme
- Completely rewrote README.md for new CLI
- Fixed base-install.ps1 to handle installation from target directory
- Removed refreshenv references from installation instructions
- Added temp/ to .gitignore
- Fixed uninstall argument handling

### Fixed
- Reference issues across all commands and workflows
- Agent invocation in workflows
- Syntax error in init.ps1 (missing else keyword)
- Agents directory installation during project init

## [1.2.0] - 2025-11-11

### Changed
- **Warpified**: Optimized for Warp AI coding environment
- Replaced Claude Code integration with Warp integration
- Commands now install to `.warp/commands/` for slash command support
- **Project files install to `.bot/` directory** (cleaner than `dotbot/`)
- Standards can be added to `WARP.md` as project rules
- Renamed `improve-skills` to `improve-rules` for WARP.md optimization
- Simplified `orchestrate-tasks` by removing subagent complexity
- Updated all documentation to reference Warp instead of Claude Code

### Removed
- Claude Code subagent support (focused on single Warp Agent Mode)
- Claude Code Skills integration
- Install-Agents function from installation scripts

### Fixed
- Configuration now uses `warp_commands` and `standards_as_warp_rules`
- Installation paths updated for Warp's directory structure
- Template variables updated for Warp-centric workflow

## [1.1.0] - 2025-11-11

### Added
- **Commands:**
  - `shape-spec` - Interactive feature scoping and exploration
  - `plan-product` - Product mission, roadmap, and tech stack planning
  - `create-tasks` - Break specifications into implementable tasks
  - `implement-tasks` - Structured implementation with verification
  - `orchestrate-tasks` - Coordinate implementation across task groups with subagent delegation
  - `improve-skills` - Optimize Claude Code Skills descriptions

- **Standards:**
  - `tech-stack.md` - Document technical stack choices
  - `conventions.md` - General development conventions
  - `commenting.md` - Code commenting best practices
  - `validation.md` - Input validation standards

- **Agents:**
  - `implementer.md` - Software implementation specialist agent

- **Workflows:**
  - `planning/create-product-mission.md` - Product mission creation
  - `implementation/verify-implementation.md` - Implementation verification checklist

- **Documentation:**
  - `TEMPLATE-VARIABLES.md` - Template variable system documentation
  - Enhanced README with complete feature list
  - Expanded CONTRIBUTING guide

### Features
- Template variable system for configuration-aware commands
- Support for conditional command logic (IF/UNLESS blocks)
- Orchestration system with orchestration.yml
- Subagent delegation support
- Standards compilation and assignment
- Prompt generation for non-subagent workflows

## [1.0.0] - 2025-11-11

### Added
- Initial release of dotbot
- PowerShell-native implementation for Windows
- Base installation script (`base-install.ps1`)
- Project installation script (`project-install.ps1`)
- Common functions PowerShell module
- Default profile with starter templates
- Core standards (coding-style, error-handling)
- Specification workflows
- Implementation workflows
- Spec writer agent template
- Write-spec command template
- Configuration system via `config.yml`
- Support for Claude Code commands and agents
- Support for generic dotbot commands
- MIT License
- Comprehensive README

### Features
- Spec-driven development workflows
- Extensible profile system
- Standards enforcement
- Agent templates for AI coding tools
- Command templates for common tasks
- Windows path support (including UNC paths)
- Dry-run mode for safe testing
- Verbose logging for debugging
- Configurable installation options
