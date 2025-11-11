# dotbot

## Your system for spec-driven agentic development on Windows.

**dotbot** transforms AI coding agents into productive developers with structured workflows that capture your standards, your stack, and the unique details of your codebase. Inspired by [agent-os](https://github.com/buildermethods/agent-os) and GitHub's spec-kit, dotbot brings spec-driven development to Windows with PowerShell-native tooling.

Use it with:

✅ **Warp AI** - Primary AI coding environment  
✅ New products or established codebases  
✅ Big features, small fixes, or anything in between  
✅ Any language or framework

---

## Installation

### Base Installation

Clone dotbot to your home directory:

```powershell
cd ~
git clone <your-repo-url> dotbot
cd dotbot
.\scripts\base-install.ps1
```

This installs dotbot to `~\dotbot` and makes it available globally.

---

## Usage

### Install dotbot into a project

Navigate to your project directory and run:

```powershell
~\dotbot\scripts\project-install.ps1
```

This will:
- Install spec-driven workflows into your project
- Set up AI agent commands and configurations
- Configure standards for your codebase

### Configuration Options

You can customize the installation with command-line flags:

```powershell
# Use a specific profile
~\dotbot\scripts\project-install.ps1 -Profile rails

# Configure Claude Code commands
~\dotbot\scripts\project-install.ps1 -ClaudeCodeCommands $true -UseClaudeCodeSubagents $true

# Install dotbot commands for other AI tools
~\dotbot\scripts\project-install.ps1 -DotbotCommands $true

# Dry run to see what would be installed
~\dotbot\scripts\project-install.ps1 -DryRun
```

### Default Configuration

Default settings are stored in `~\dotbot\config.yml`. In projects, dotbot installs to `.bot/`. You can edit config.yml to change your global defaults.

---

## Features

### Spec-Driven Development

dotbot enables a structured approach to AI-assisted development:

1. **Plan** - Define your product vision, mission, and roadmap
2. **Shape** - Interactively explore and scope features
3. **Specify** - Write detailed technical specifications
4. **Task Breakdown** - Break specs into implementable tasks
5. **Orchestrate** - Coordinate implementation across task groups
6. **Implement** - Execute tasks with quality verification
7. **Verify** - Validate implementations against specs

### Profiles

Organize your workflows, standards, and commands into reusable profiles:

- `profiles/default/` - The default profile with general-purpose workflows
- Custom profiles - Create your own for specific stacks or teams

### Standards

Define coding standards that AI agents should follow:

- `standards/global/` - Language-agnostic standards
- `standards/frontend/` - Frontend-specific standards
- `standards/backend/` - Backend-specific standards
- `standards/testing/` - Testing standards

### Commands

Powerful slash commands for Warp Agent:

- `/plan-product` - Create product mission, roadmap, and tech stack
- `/shape-spec` - Interactively explore and scope features
- `/write-spec` - Write detailed technical specifications
- `/create-tasks` - Break specs into implementable tasks
- `/orchestrate-tasks` - Coordinate implementation across task groups
- `/implement-tasks` - Execute tasks with verification steps
- `/improve-rules` - Optimize WARP.md project rules for clarity

### Workflows

Pre-defined workflows guide AI agents through complex tasks:

- `workflows/planning/` - Product planning workflows (mission, roadmap)
- `workflows/specification/` - Spec creation workflows  
- `workflows/implementation/` - Implementation and verification workflows

---

## Warp-Native & PowerShell

dotbot is built specifically for Warp AI on Windows:

- **Warp Integration**: Commands install to `.warp/commands/` for slash command support
- **Project Rules**: Standards can be added to `WARP.md` for automatic agent guidance
- **PowerShell Native**: Full Windows path support, PowerShell cmdlets, Windows-friendly operations
- **Agent Mode Optimized**: Designed for Warp's agentic development environment

---

## Contributing

dotbot is under active development. Contributions welcome!

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Related Projects

- [agent-os](https://github.com/buildermethods/agent-os) - The bash-based inspiration for dotbot
- [spec-kit](https://github.com) - GitHub's spec-driven development toolkit
