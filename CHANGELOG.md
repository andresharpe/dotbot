# Changelog

All notable changes to dotbot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
