# dotbot

**Repeatable, predictable, and auditable AI-driven development for serious projects.**

![Version](https://img.shields.io/badge/version-1.3.11-blue)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-7%2B-blue)

**dotbot** transforms AI coding agents into productive developers with structured workflows that capture your standards, your stack, and the unique details of your codebase. It combines spec-driven development (inspired by [agent-os](https://github.com/buildermethods/agent-os) and GitHub's spec-kit) with cross-platform PowerShell tooling, optimized for Warp AI.

Use it with:

- **Warp AI** - Primary AI coding environment  
- New products or established codebases  
- Big features, small fixes, or anything in between  
- Any language or framework

## Why dotbot?

### The Problem with "Vibe Coding"

As projects grow, unstructured AI development breaks down:
- **Drift**: Code quality degrades without consistent standards
- **Brittleness**: Changes in one area unexpectedly break others
- **Lost Context**: Tribal knowledge and decisions aren't captured
- **Team Friction**: Different developers get different AI outputs

### The dotbot Solution

dotbot brings engineering discipline to AI-driven development:

**Repeatable** - Structured workflows ensure every feature follows the same proven process  
**Predictable** - Standards and specifications reduce surprises and regressions  
**Auditable** - Specs, task lists, and verification reports create a clear paper trail  
**Team-Ready** - Serves the entire product lifecycle, not just coding  
**Future-Proof** - As AI agents evolve, your standards and workflows remain constant

### Who dotbot Serves

dotbot isn't just for developers. It supports cross-functional teams:

- **Product Leads** - Define vision and roadmaps that translate directly to implementation
- **Solution Architects** - Establish technical standards that AI agents follow automatically
- **Tech Leads** - Review auditable specs and task breakdowns before code is written
- **Business Analysts** - Participate in spec shaping with structured research workflows
- **Developers** - Implement with confidence using verified, spec-driven tasks
- **QA/Testers** - Verify against documented requirements and acceptance criteria

The result: **AI development that scales with your team and project complexity.**

## Table of Contents

- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Commands](#commands)
- [Architecture](#architecture)
- [Cross-Platform Support](#cross-platform-support)
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
- Installs Warp commands in `.warp/commands/dotbot/`
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
Ctrl-Shift-R → dotbot-improve-rules              # [Improve] Refine WARP.md rules for clarity and effectiveness
```

---

## How It Works

### The Spec-Driven Workflow

dotbot guides AI agents through a proven 6-phase development process:

```
1. PLAN      →  Define product vision, mission, and roadmap
2. SHAPE     →  Research and scope features interactively
3. SPECIFY   →  Write detailed technical specifications
4. TASKS     →  Break specs into implementable task groups
5. IMPLEMENT →  Execute tasks with built-in verification
6. VERIFY    →  Validate all requirements are met
```

Each phase uses:
- **Specialized Agents** - AI personas trained for that phase (spec-writer, implementer, verifier, etc.)
- **Structured Workflows** - Step-by-step processes that ensure consistency
- **Quality Standards** - Coding conventions and best practices automatically applied
- **Audit Trail** - Everything documented for team review and future reference

### What Gets Installed

When you run `dotbot init`, you get:

```
your-project/
├── .bot/
│   ├── agents/         # 8 specialized AI personas
│   ├── standards/      # 16 coding standards (global, backend, frontend, testing)
│   └── workflows/      # 15+ step-by-step workflows
├── .warp/
│   └── commands/       # Warp commands (Ctrl-Shift-R)
└── WARP.md             # Project rules (optional)
```

**Profiles:** All content comes from profiles (like `default`). You can create custom profiles for different tech stacks or team practices.

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

## Architecture

### System Overview

```
dotbot/
├── bin/                    # CLI entry point (dotbot.ps1)
├── scripts/                # PowerShell installation & utility scripts
├── profiles/               # Reusable profiles
│   └── default/
│       ├── agents/         # 8 specialized AI personas
│       ├── commands/       # 7 Warp command templates
│       ├── standards/      # 16 coding standards (by domain)
│       └── workflows/      # 15+ step-by-step workflows
├── docs/                   # Interaction patterns & template docs
└── config.yml              # Global configuration
```

### Profile Architecture

Profiles are dotbot's core organizational unit. Each profile contains a complete set of agents, standards, workflows, and commands tailored for specific tech stacks or team practices.

**The `default` profile includes:**

#### 🤖 Agents (8 specialized personas)
AI personas that guide workflow execution:
- `product-planner.md` - Product vision and roadmap creation
- `spec-shaper.md` - Requirements research and feature scoping
- `spec-writer.md` - Technical specification authoring
- `tasks-list-creator.md` - Task breakdown and planning
- `implementer.md` - Code implementation specialist
- `implementation-verifier.md` - End-to-end verification
- `spec-initializer.md` - Spec structure initialization
- `spec-verifier.md` - Specification validation

#### 📋 Standards (16 files, organized by domain)
**Global** - Language-agnostic best practices:
- `coding-style.md`, `commenting.md`, `conventions.md`, `error-handling.md`, `validation.md`, `tech-stack.md`, `workflow-interaction.md`

**Backend** - Server-side development:
- `api.md`, `migrations.md`, `models.md`, `queries.md`

**Frontend** - UI development:
- `accessibility.md`, `components.md`, `css.md`, `responsive.md`

**Testing** - Test strategy:
- `test-writing.md`

**Special: Interaction Standards**
- Structured option-based questions (A, B, C, D format)
- Simple commands: `go A`, `skip`, `back`, `exit`, `summary`, `help`
- **Dynamic option refinement** - agents adapt options based on user context
- Progress indicators and echo confirmations
- See [docs/INTERACTION-GUIDELINES.md](docs/INTERACTION-GUIDELINES.md)

#### 🔄 Workflows (15+ files, organized by phase)
**Planning:**
- `gather-product-info.md`, `create-product-mission.md`, `create-product-roadmap.md`, `create-product-tech-stack.md`

**Specification:**
- `initialize-spec.md`, `research-spec.md`, `verify-spec.md`, `write-spec.md`

**Implementation:**
- `create-tasks-list.md`, `implement-tasks.md`, `verify-implementation.md`

**Verification:**
- `verify-tasks.md`, `update-roadmap.md`, `run-all-tests.md`, `create-verification-report.md`

#### ⚡ Commands (7 Warp commands)
- `plan-product.md` - Create product mission, roadmap, and tech stack
- `shape-spec.md` - Interactively explore and scope features
- `write-spec.md` - Write detailed technical specifications
- `create-tasks.md` - Break specs into implementable tasks
- `orchestrate-tasks.md` - Coordinate implementation across task groups
- `implement-tasks.md` - Execute tasks with verification steps
- `improve-rules.md` - Optimize WARP.md project rules

### How Components Work Together

1. **Workflows** orchestrate the process and reference specific agents
2. **Agents** provide specialized guidance and reference relevant standards
3. **Standards** define quality guardrails that agents enforce
4. **Commands** trigger workflows and make them accessible in Warp

Example flow:
```
User runs: Ctrl-Shift-R → dotbot-3-write-spec
  ↓
Command loads: write-spec.md workflow
  ↓
Workflow invokes: spec-writer.md agent
  ↓
Agent follows: coding-style.md, error-handling.md standards
  ↓
Agent uses: workflow-interaction.md for user questions
  ↓
Result: Consistent, high-quality technical spec
```

### Configuration System

**Global config** (`~/dotbot/config.yml`):
- Default profile selection
- Standards handling (as Warp rules vs. separate files)
- Version tracking

**Project state** (`.bot/.dotbot-state.json`):
- Installed version and profile
- Configuration options chosen

**Template variables** (used in commands/workflows):
- `{{IF warp_commands}}` - Conditional Warp integration
- `{{IF standards_as_warp_rules}}` - Conditional standards handling
- `{{workflows/path/to/workflow}}` - Workflow references
- See [docs/TEMPLATE-VARIABLES.md](docs/TEMPLATE-VARIABLES.md)

### Creating Custom Profiles

Build profiles for specific tech stacks or team practices:

1. Create `profiles/[your-profile]/` with subdirectories: `agents/`, `commands/`, `standards/`, `workflows/`
2. Customize content for your stack (e.g., Rails, Django, React Native)
3. Update `config.yml` to set your profile as default
4. Run `dotbot init --profile your-profile` in projects

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed profile creation guidance

---

## Cross-Platform Support

### PowerShell-Native

dotbot uses PowerShell 7+ for true cross-platform compatibility:

- ✅ **Windows** - PowerShell 5.1+ supported (7+ recommended)
- ✅ **macOS** - Install via `brew install powershell`
- ✅ **Linux** - [Installation guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)

### Warp Integration

Designed specifically for Warp's Agent Mode:

- **Warp Commands** - Install to `.warp/commands/dotbot/` (accessible via Ctrl-Shift-R)
- **Project Rules** - Standards can be added to `WARP.md` for automatic agent guidance
- **Template Variables** - Context-aware commands that adapt to your setup
- **Interaction Patterns** - Optimized for conversational AI workflows

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
