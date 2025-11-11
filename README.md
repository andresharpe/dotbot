# dotbot

## Your system for spec-driven agentic development on Windows.

**dotbot** transforms AI coding agents into productive developers with structured workflows that capture your standards, your stack, and the unique details of your codebase. Inspired by [agent-os](https://github.com/buildermethods/agent-os) and GitHub's spec-kit, dotbot brings spec-driven development to Windows with PowerShell-native tooling.

Use it with:

✅ **Warp AI** - Primary AI coding environment  
✅ New products or established codebases  
✅ Big features, small fixes, or anything in between  
✅ Any language or framework

---

## Quick Start

### 1. Install dotbot globally (one-time setup)

```powershell
cd ~
git clone https://github.com/andresharpe/dotbot.git dotbot
cd dotbot
.\scripts\base-install.ps1
```

**What this does:**
- Installs dotbot to `~\dotbot`
- Adds `dotbot` command to your PATH
- Makes dotbot available globally

**Restart your terminal** after installation.

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

In Warp AI, use the workflow commands:

```
/plan-product       # Define your product vision
/shape-spec         # Research and scope a feature
/write-spec         # Write technical specifications
/create-tasks       # Break specs into tasks
/implement-tasks    # Execute with verification
```

### For Existing Projects (Cloning a dotbot-enabled project)

If you clone a project that already has `.bot/` directory:

```powershell
git clone <project-url>
cd <project>
dotbot setup        # Checks if dotbot is installed and guides you
```

**If dotbot isn't installed yet**, run step 1 above first.

---

## Commands

### Setup & Management

```powershell
dotbot help             # Show all commands
dotbot status           # Check installation status
dotbot init             # Add dotbot to current project
dotbot setup            # Smart setup for existing projects
```

### Updates & Maintenance

```powershell
dotbot update           # Update dotbot to latest version
dotbot upgrade-project  # Upgrade current project
dotbot uninstall -Project   # Remove from project
dotbot uninstall -Global    # Remove dotbot completely
```

### Configuration Options

```powershell
# Use a specific profile
dotbot init -Profile rails

# Configure for other AI tools
dotbot init -WarpCommands $false -DotbotCommands $true

# Dry run to see what would be installed
dotbot init -DryRun
```

### Configuration Files

- **Global config**: `~\dotbot\config.yml` - Default settings for all projects
- **Project state**: `.bot\.dotbot-state.json` - Tracks installed version and configuration
- **Project standards**: `.bot\standards\` - Coding standards for AI agents
- **Project workflows**: `.bot\workflows\` - Step-by-step implementation guides

---

## The dotbot Workflow

dotbot structures AI development into clear phases:

```
Plan → Shape → Specify → Tasks → Implement → Verify
📋     🔍       📝         ✂️       ⚡          ✅
```

1. **Plan** (`/plan-product`) - Define your product vision, mission, and roadmap
2. **Shape** (`/shape-spec`) - Research and scope features before writing specs
3. **Specify** (`/write-spec`) - Write detailed technical specifications
4. **Tasks** (`/create-tasks`) - Break specs into implementable task groups
5. **Implement** (`/implement-tasks`) - Execute tasks with quality verification
6. **Verify** - Validate implementations meet spec requirements

Each phase has dedicated workflows, standards, and AI agent prompts to guide the process.

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

## Troubleshooting

### `dotbot` command not found

**Problem**: After installation, `dotbot` command doesn't work.

**Solution**: 
1. Restart your terminal completely (close and reopen)
2. Or manually add to PATH: `$env:Path += ";$env:USERPROFILE\dotbot\bin"`

### Project already has dotbot installed

**Problem**: Running `dotbot init` shows files already exist.

**Solution**: 
- Use `dotbot setup` to check existing installation
- Use `dotbot status` to see what's installed
- Use `dotbot init -ReInstall` to reinstall

### Upgrading from old version

**Problem**: Project has old dotbot version.

**Solution**:
```powershell
dotbot update                # Update base dotbot
cd your-project
dotbot upgrade-project       # Upgrade project files
```

### Commands not showing in Warp

**Problem**: Slash commands don't appear in Warp.

**Solution**:
1. Check if `.warp/commands/dotbot/` exists in your project
2. Restart Warp to reload commands
3. Ensure you ran `dotbot init` with Warp commands enabled (default)

### Getting help

```powershell
dotbot help              # Show all commands
dotbot status            # Check installation
dotbot setup             # Smart detection and guidance
```

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
