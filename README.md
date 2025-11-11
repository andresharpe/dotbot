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

# Configure Warp commands
~\dotbot\scripts\project-install.ps1 -WarpCommands $true -StandardsAsWarpRules $true

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

**Standards (15 files)**:
- Global: `coding-style.md`, `commenting.md`, `conventions.md`, `error-handling.md`, `tech-stack.md`, `validation.md`
- Backend: `api.md`, `migrations.md`, `models.md`, `queries.md`
- Frontend: `accessibility.md`, `components.md`, `css.md`, `responsive.md`
- Testing: `test-writing.md`

**Workflows (15 files)**:
- Planning: `gather-product-info.md`, `create-product-mission.md`, `create-product-roadmap.md`, `create-product-tech-stack.md`
- Specification: `initialize-spec.md`, `research-spec.md`, `verify-spec.md`, `write-spec.md`
- Implementation: `create-tasks-list.md`, `implement-tasks.md`, `verify-implementation.md`
- Implementation Verification: `verify-tasks.md`, `update-roadmap.md`, `run-all-tests.md`, `create-verification-report.md`

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
