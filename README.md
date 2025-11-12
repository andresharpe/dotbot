# dotbot

**Your system for spec-driven agentic development across Windows, macOS, and Linux.**

![Version](https://img.shields.io/badge/version-1.3.4-blue)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-7%2B-blue)

**dotbot** transforms AI coding agents into productive developers with structured workflows that capture your standards, your stack, and the unique details of your codebase. It combines spec-driven development (inspired by [agent-os](https://github.com/buildermethods/agent-os) and GitHub's spec-kit) with cross-platform PowerShell tooling, optimized for Warp AI.

Use it with:

- **Warp AI** - Primary AI coding environment  
- New products or established codebases  
- Big features, small fixes, or anything in between  
- Any language or framework

## Table of Contents

- [Quick Start](#quick-start)
- [Commands](#commands)
- [Features](#features)
- [Warp Integration](#warp-native--powershell)
- [Contributing](#contributing)

---

## Prerequisites

**PowerShell 7+** is required on all platforms:

- **Windows**: Pre-installed on Windows 10/11, or [download here](https://aka.ms/powershell)
- **macOS**: Install via Homebrew: `brew install powershell`
- **Linux**: [Installation instructions](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)

Verify your PowerShell version:
```powershell
$PSVersionTable.PSVersion
```

## Quick Start

### 1. Install dotbot globally (one-time setup)

**All platforms:**
```powershell
cd ~
git clone https://github.com/andresharpe/dotbot
cd dotbot
pwsh init.ps1
```

**What this does:**
- Installs dotbot to `~/dotbot`
- Adds `dotbot` command to your PATH (Windows: User PATH, macOS/Linux: shell profile)
- Makes dotbot available globally

**After installation:**
- **Windows**: Restart your terminal
- **macOS/Linux**: Run `source ~/.bashrc` (or `~/.zshrc`) or restart your terminal

### 2. Add dotbot to your project

```powershell
cd C:\your\project
dotbot init
```

**What this does:**
- Creates `.bot/` directory with workflows, standards, and agents
- Installs Warp slash commands in `.warp/commands/dotbot/`
- Shows you the dotbot workflow diagram

### 3. Start using dotbot

In Warp AI, press **Ctrl-Shift-R** and select dotbot workflows:

**Complete workflow (Plan → Shape → Specify → Tasks → Implement → Verify):**

```
Ctrl-Shift-R → dotbot-1-gather-product-info      # [Plan] Define product vision
Ctrl-Shift-R → dotbot-2-research-spec            # [Shape] Research & scope feature
Ctrl-Shift-R → dotbot-3-write-spec               # [Specify] Write technical spec
Ctrl-Shift-R → dotbot-4-create-tasks-list        # [Tasks] Break into implementable tasks
Ctrl-Shift-R → dotbot-5-implement-tasks          # [Implement] Execute with verification
Ctrl-Shift-R → dotbot-6-verify-implementation    # [Verify] Validate requirements met
```

**Optional/Advanced Commands:**

```
Ctrl-Shift-R → dotbot-orchestrate-tasks          # [Orchestrate] Manage complex multi-group implementations
Ctrl-Shift-R → dotbot-improve-rules              # [Improve] Optimize WARP.md project rules
```

---

## Commands

### Global Commands

```powershell
dotbot install          # Install dotbot globally
dotbot update           # Update global installation
dotbot uninstall        # Remove global installation
```

### Project Commands

```powershell
dotbot init             # Initialize dotbot in current project
dotbot update-project   # Update project to latest version
dotbot remove-project   # Remove dotbot from current project
```

### Info Commands

```powershell
dotbot status           # Show global and project status
dotbot help             # Show all commands
```

### Init Options

```powershell
# Use a specific profile
dotbot init --profile rails

# Configure for other AI tools
dotbot init --no-warp-commands --commands

# Add standards to WARP.md
dotbot init --warp-rules

# Dry run to see what would be installed
dotbot init --dry-run

# Force overwrite existing files
dotbot init --force
```

### Configuration Files

- **Global config**: `~\dotbot\config.yml` - Default settings for all projects
- **Project state**: `.bot\.dotbot-state.json` - Tracks installed version and configuration
- **Project standards**: `.bot\standards\` - Coding standards for AI agents
- **Project workflows**: `.bot\workflows\` - Step-by-step implementation guides
- **Template variables**: See [docs/TEMPLATE-VARIABLES.md](docs/TEMPLATE-VARIABLES.md) for dynamic content in commands and workflows

---

## Features

### Profiles

Organize your workflows, standards, and commands into reusable profiles:

- `profiles/default/` - The default profile with comprehensive workflows, agents, and standards
- Custom profiles - Create your own for specific stacks or teams

#### Default Profile Contents

**Agents (8 total)**:
- `implementer.md` - Software implementation specialist
- `spec-writer.md` - Technical specification writer
- `implementation-verifier.md` - End-to-end implementation verifier
- `product-planner.md` - Product documentation and roadmap creator
- `spec-initializer.md` - Spec folder structure initialization
- `spec-shaper.md` - Requirements research specialist
- `spec-verifier.md` - Specification verification
- `tasks-list-creator.md` - Tasks list planning and creation

**Commands (7 total)**:
- `plan-product.md` - Create product mission, roadmap, and tech stack
- `shape-spec.md` - Interactively explore and scope features
- `write-spec.md` - Write detailed technical specifications
- `create-tasks.md` - Break specs into implementable tasks
- `orchestrate-tasks.md` - Coordinate implementation across task groups
- `implement-tasks.md` - Execute tasks with verification steps
- `improve-rules.md` - Optimize WARP.md project rules

**Standards (16 files)**:
- Global: `coding-style.md`, `commenting.md`, `conventions.md`, `error-handling.md`, `tech-stack.md`, `validation.md`, `workflow-interaction.md`
- Backend: `api.md`, `migrations.md`, `models.md`, `queries.md`
- Frontend: `accessibility.md`, `components.md`, `css.md`, `responsive.md`
- Testing: `test-writing.md`

**Workflows (15 files)**:
- Planning: `gather-product-info.md`, `create-product-mission.md`, `create-product-roadmap.md`, `create-product-tech-stack.md`
- Specification: `initialize-spec.md`, `research-spec.md`, `verify-spec.md`, `write-spec.md`
- Implementation: `create-tasks-list.md`, `implement-tasks.md`, `verify-implementation.md`
- Implementation Verification: `verify-tasks.md`, `update-roadmap.md`, `run-all-tests.md`, `create-verification-report.md`

### Agents

Agent files define specialized AI personas that guide workflow execution. Each workflow automatically invokes the appropriate agent:

**How Agents Work:**
- Agents are automatically loaded when following workflows
- Each workflow specifies which agent to use (e.g., `**Agent:** @.bot/agents/spec-writer.md`)
- Agents provide role-specific guidance and ensure consistency
- Users don't need to manually load agents - workflows handle this automatically

**Agent Responsibilities:**
- `product-planner.md` - Guides product planning and roadmap creation
- `spec-shaper.md` - Researches requirements and scopes features
- `spec-writer.md` - Writes detailed technical specifications
- `tasks-list-creator.md` - Breaks specs into implementable tasks
- `implementer.md` - Implements code following standards
- `implementation-verifier.md` - Verifies implementation quality
- `spec-initializer.md` - Sets up spec folder structures
- `spec-verifier.md` - Validates specifications

### Standards

Define coding standards that AI agents should follow:

**Global Standards** - Language-agnostic best practices:
- Coding style conventions
- Commenting guidelines
- Error handling patterns
- Input validation practices
- Tech stack documentation
- General development conventions

**Backend Standards** - Server-side development:
- API endpoint design and conventions
- Database migration best practices
- Data model design patterns
- Query optimization and safety

**Frontend Standards** - UI development:
- Accessibility requirements
- Component architecture
- CSS methodology
- Responsive design principles

**Testing Standards** - Test writing approach:
- Focused test-driven development
- Minimal test coverage during development (2-8 tests per task group)
- Strategic test gap filling (max 10 additional tests)

**Interaction Standards** - User interaction patterns:
- Structured option-based questions (A, B, C, D format)
- Warp-friendly commands ('go A', 'skip', 'back', 'exit')
- Dynamic option refinement based on user context
- Progress indicators and echo confirmations
- See [docs/INTERACTION-GUIDELINES.md](docs/INTERACTION-GUIDELINES.md) for detailed patterns

---

## Cross-Platform & PowerShell

dotbot works seamlessly across Windows, macOS, and Linux:

- **Warp Integration**: Commands install to `.warp/commands/` for slash command support
- **Project Rules**: Standards can be added to `WARP.md` for automatic agent guidance
- **PowerShell Native**: Cross-platform PowerShell 7+ for consistent experience
- **Agent Mode Optimized**: Designed for Warp's agentic development environment
- **Platform Detection**: Automatically adapts to your operating system

### Platform-Specific Notes

#### Windows
- dotbot automatically adds itself to your User PATH via registry
- Restart terminal after installation for PATH changes to take effect
- Uses Windows-native path separators (`;`)
- PowerShell 5.1+ supported (7+ recommended)

#### macOS
- dotbot adds itself to shell profiles (`~/.bashrc`, `~/.zshrc`, `~/.bash_profile`)
- Run `source ~/.zshrc` (or appropriate profile) or restart terminal after installation
- Uses Unix path separators (`:`)
- PowerShell 7+ required - install via: `brew install powershell`
- Executable permissions set automatically on installation

#### Linux
- dotbot adds itself to shell profiles (`~/.bashrc`, `~/.profile`, etc.)
- Run `source ~/.bashrc` or restart terminal after installation
- Uses Unix path separators (`:`)
- PowerShell 7+ required - [installation guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)
- Executable permissions set automatically on installation

---

## Contributing

dotbot is under active development. Contributions welcome!

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Related Projects

- [agent-os](https://github.com/buildermethods/agent-os) - The bash-based inspiration for dotbot
- [Warp AI](https://www.warp.dev) - The AI-powered terminal for developers

## Repository

**GitHub**: https://github.com/andresharpe/dotbot  
**Issues**: https://github.com/andresharpe/dotbot/issues  
**Discussions**: https://github.com/andresharpe/dotbot/discussions
# Test commit
# Another test
