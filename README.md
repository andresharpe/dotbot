# dotbot

## Your system for spec-driven agentic development on Windows.

**dotbot** transforms AI coding agents into productive developers with structured workflows that capture your standards, your stack, and the unique details of your codebase. Inspired by [agent-os](https://github.com/buildermethods/agent-os) and GitHub's spec-kit, dotbot brings spec-driven development to Windows with PowerShell-native tooling.

Use it with:

✅ Warp, Claude Code, Cursor, or any other AI coding tool  
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

Default settings are stored in `~\dotbot\config.yml`. You can edit this file to change your global defaults.

---

## Features

### Spec-Driven Development

dotbot enables a structured approach to AI-assisted development:

1. **Plan** - Define your product vision and roadmap
2. **Specify** - Write detailed specifications for features
3. **Implement** - Break specs into tasks and implement them
4. **Verify** - Validate implementations against specs

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

### Workflows

Pre-defined workflows guide AI agents through complex tasks:

- `workflows/planning/` - Product planning workflows
- `workflows/specification/` - Spec creation workflows  
- `workflows/implementation/` - Implementation workflows

---

## PowerShell Native

Unlike agent-os which uses bash scripts, dotbot is built natively for Windows with PowerShell:

- Full Windows path support (including UNC paths)
- PowerShell cmdlets and idioms
- Windows-friendly file operations
- Compatible with Windows Terminal, PowerShell 7+, and Warp

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
