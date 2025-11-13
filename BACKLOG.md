# dotbot Backlog

This document tracks all planned improvements, features, and enhancements for dotbot.

## 🔥 Recent Accomplishments (Since Jan 2025)

- ✅ **Template Variables System** - Dynamic content generation in workflows/commands
- ✅ **Cross-Platform Support** - Full Windows, macOS, Linux compatibility
- ✅ **.NET Profile** - Vertical slice architecture with comprehensive setup
- ✅ **Enhanced Documentation** - README restructure, WARP.md, architecture docs
- ✅ **Version Automation** - Automatic version bumping workflow
- ✅ **Reference Validation** - Template variable validation system

## 🎯 Progress Summary

**Phase 1** (Foundation): ✅ **100% Complete** (4/4 items)
**Phase 2** (Polish): 🟨 **75% Complete** (3/4 items)
**Phase 3** (Enhancement): 🟨 **33% Complete** (1/3 items)
**Cross-Platform**: ✅ **100% Complete**

### ✅ Completed Features (10 total):
- Global `dotbot` command with full CLI
- Better error messages with actionable suggestions
- Status command showing installation state
- Update commands (`dotbot update`, `dotbot update-project`)
- Visual workflow map displayed after installation
- Uninstall command (`dotbot uninstall`, `dotbot remove-project`)
- Template variable system for dynamic content
- Cross-platform support (Windows, macOS, Linux)
- Multiple profile support (.NET profile added)
- Enhanced documentation (README restructure, WARP.md)

### ⏳ Next Up:
- Interactive installation (Phase 2)
- Smart project detection - `dotbot setup` command (Phase 1 - not implemented)
- Profile management commands (Phase 3)
- `dotbot doctor` health check command

---

## 🔥 P0 - Critical UX (Do First)

These fundamentally improve the user experience and clarify the mental model.

### 1. Global `dotbot` Command ✅ COMPLETED
**Problem**: Users must type `~\dotbot\scripts\base-install.ps1` - not intuitive  
**Solution**: Add `~\dotbot\bin` to PATH during base-install, create wrapper scripts  
**Commands to add**:
- `dotbot install` - Base installation (replaces `base-install.ps1`)
- `dotbot init` - Project installation (replaces `project-install.ps1`)
- `dotbot setup` - Smart detection for existing projects
- `dotbot status` - Show installation state, version, profile
- `dotbot help` - Show all available commands

**Files to create**:
- `bin/dotbot.ps1` - Main CLI entry point
- `bin/dotbot` - Unix-style wrapper (for cross-platform)
- Update `base-install.ps1` to add to PATH

---

### 2. Better Error Messages ✅ COMPLETED
**Problem**: Cryptic errors when dotbot not installed or wrong directory  
**Solution**: Friendly errors with actionable fix suggestions  
**Examples**:
```
❌ dotbot is not installed on this PC
💡 Run: iwr -useb https://dotbot.sh/install | iex

❌ Not in a project directory
💡 Navigate to your project root, then run: dotbot init

❌ This project already has dotbot installed
💡 Use 'dotbot status' to see configuration
```

**Files to update**:
- `scripts/Common-Functions.psm1` - Add `Write-FriendlyError` function
- All scripts - Replace `Write-Error` with friendly versions

---

### 3. Smart Project Detection (`dotbot setup`) ⏳ NOT IMPLEMENTED
**Problem**: Unclear what to do with cloned projects that have `.bot/`  
**Solution**: Auto-detect and guide users  
**Logic**:
1. Check if `~\dotbot` exists → if not, offer to install
2. Check if `.bot/` exists in current dir → if yes, validate and update
3. If neither exists → guide to `dotbot init`

**Status**: Command not implemented. Current `dotbot init` provides error messages but no smart detection.

**Files to create**:
- `scripts/setup.ps1` - New smart setup script
- Update `bin/dotbot.ps1` to include `setup` subcommand

---

### 4. Interactive Installation (`dotbot init --interactive`)
**Problem**: Too many flags to remember, unclear defaults  
**Solution**: Guided setup with smart questions  
**Flow**:
```powershell
dotbot init --interactive

? What's your primary AI tool? (Use arrow keys)
  > Warp AI
    Cursor
    Windsurf
    Other

? Detected Next.js project. Use React profile? (Y/n)

? Install commands as Warp slash commands? (Y/n)

? Add standards to WARP.md as project rules? (Y/n)

✓ Installing with profile: react-nextjs
✓ Created .bot/ directory
✓ Installed 7 commands in .warp/commands/dotbot/
✓ Created WARP.md with 12 standards

🎉 dotbot is ready! Try: /plan-product
```

**Files to create**:
- `scripts/interactive-install.ps1` - Interactive flow
- `scripts/project-detection.ps1` - Auto-detect project type
- Update `project-install.ps1` to support `-Interactive` flag

---

## 🚀 P1 - High Impact

These significantly improve daily workflows.

### 5. Status & Health Check 🟨 PARTIALLY COMPLETED
**Note**: `dotbot status` ✅ implemented. `dotbot doctor` ⏳ command still TODO.
**Commands**:
```powershell
dotbot status
# Shows:
# - dotbot version
# - Active profile
# - Installed features (Warp commands, standards, etc.)
# - Project health (valid config, all files present)

dotbot doctor
# Validates:
# - Base installation intact
# - Project configuration valid
# - Commands accessible
# - Suggests fixes for issues
```

**Files to create**:
- `scripts/status.ps1`
- `scripts/doctor.ps1`

---

### 6. Update Commands ✅ COMPLETED
**Commands**:
```powershell
dotbot update
# Updates base dotbot installation from git/remote

dotbot upgrade-project
# Migrates project to new dotbot version
# Preserves customizations in .bot/
```

**Files to create**:
- `scripts/update.ps1`
- `scripts/upgrade-project.ps1`
- `MIGRATION.md` - Version migration guide

---

### 7. Visual Workflow Map ✅ COMPLETED
**Problem**: Users don't understand the full workflow  
**Solution**: Show visual diagram after installation  
```
┌─────────────────────────────────────────────────────────────┐
│                  dotbot Workflow                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Plan → Shape → Specify → Create Tasks → Implement → Verify │
│   ↓       ↓        ↓           ↓             ↓         ↓    │
│   📋      🔍       📝          ✂️            ⚡        ✅    │
│                                                              │
│  Commands:                                                   │
│  /plan-product     - Define product vision & roadmap        │
│  /shape-spec       - Research and scope features            │
│  /write-spec       - Write detailed specifications          │
│  /create-tasks     - Break specs into tasks                 │
│  /implement-tasks  - Execute with verification              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Files to update**:
- `scripts/project-install.ps1` - Add workflow map to summary
- Create `docs/workflow-map.txt` - ASCII diagram

---

### 8. Profile Management 🟨 PARTIALLY COMPLETED
**Status**: Profiles system exists (default, dotnet), but CLI management not implemented.
**What works**: `dotbot init --profile <name>` to select profile during installation
**What's missing**: Profile discovery, switching, creation commands

**Commands to implement**:
```powershell
dotbot profiles list
# Shows available profiles

dotbot profiles show <name>
# Show what's in a profile

dotbot profiles switch <name>
# Switch project to different profile

dotbot profiles create <name> --from default
# Create custom profile from template
```

**Files to create**:
- `scripts/profile-manager.ps1`
- `docs/PROFILES.md` - Profile documentation

---

### 9. Uninstall & Rollback 🟨 PARTIALLY COMPLETED
**Note**: `dotbot uninstall` and `dotbot remove-project` ✅ implemented. `dotbot rollback` ⏳ command still TODO.
**Commands**:
```powershell
dotbot uninstall --project
# Remove .bot/ from current project (keep config backup)

dotbot uninstall --global
# Remove dotbot from ~\dotbot (keep config.yml)

dotbot rollback
# Undo last project-install operation
```

**Files to create**:
- `scripts/uninstall.ps1`
- `scripts/rollback.ps1`
- Store rollback info in `.bot/.dotbot-state.json`

---

### 10. Project Memory
**Problem**: No state tracking across sessions  
**Solution**: Store context in `.bot/project.yml`  
**Contents**:
```yaml
dotbot_version: 1.2.0
profile: default
installed_at: 2025-01-11T14:43:22Z
last_command: /implement-tasks
workflow_stage: implementing
active_specs:
  - specs/user-auth.md
  - specs/dashboard.md
```

**Files to create**:
- Add state management to `Common-Functions.psm1`
- Update all command scripts to record state

---

## 💡 P2 - Nice to Have

These add polish and convenience.

### 11. Quick Start (`dotbot quickstart`)
One command to go from zero to first spec:
```powershell
dotbot quickstart
# Runs: install → init → /plan-product → /shape-spec
# Creates sample product plan
```

**Files to create**:
- `scripts/quickstart.ps1`

---

### 12. Demo Mode
**Command**:
```powershell
dotbot demo
# Creates temporary demo project
# Walks through full workflow with sample data
# Cleans up after
```

**Files to create**:
- `scripts/demo.ps1`
- `demos/sample-project/` - Demo project template

---

### 13. Template System 🟨 PARTIALLY COMPLETED
**Status**: Template variables system ✅ implemented for workflows/commands. File-based templates ⏳ not yet implemented.
**What works**: `{{IF condition}}`, `{{workflows/path}}`, dynamic content in commands
**What's missing**: Project scaffolding templates, code generation templates

**Commands to implement**:
```powershell
dotbot template list
dotbot template apply api-endpoint
dotbot template create my-feature
```

**Files to create**:
- `templates/` directory
- `scripts/template-manager.ps1`

**Already completed**:
- ✅ Template variable system (see `docs/TEMPLATE-VARIABLES.md`)
- ✅ Template processing in Copy-DotbotFile function
- ✅ Conditional content rendering

---

### 14. Multi-Project Dashboard
**Command**:
```powershell
dotbot projects
# Lists all projects using dotbot
# Shows status, last modified, workflow stage
# Quick navigation
```

**Files to create**:
- `scripts/projects.ps1`
- Store project registry in `~\dotbot\projects.json`

---

### 15. Progress Tracking
**Command**:
```powershell
dotbot progress
# Visual progress bar through roadmap
# Task completion stats
# Time estimates
```

**Files to create**:
- `scripts/progress.ps1`

---

### 16. Shell Integration
Auto-show dotbot status when entering project:
```powershell
# Add to PowerShell profile
# When cd into dotbot project, show:
# 📦 dotbot v1.2.0 | default profile | 3 active specs
```

**Files to create**:
- `shell-integration/powershell-prompt.ps1`
- `docs/SHELL-INTEGRATION.md`

---

## 🔮 P3 - Future/Research

These require more exploration or dependencies.

### 17. Web Installer
**Goal**: One-line install from web  
```powershell
iwr -useb https://dotbot.sh/install.ps1 | iex
```

**Requirements**:
- GitHub Pages or hosting
- Sign install script
- Windows security considerations

---

### 18. Package Manager Distribution
**Goal**: Install via winget/scoop/chocolatey  
```powershell
winget install dotbot
scoop install dotbot
choco install dotbot
```

**Requirements**:
- Package manifests
- Release automation
- Signing

---

### 19. Profile Marketplace
**Goal**: Share and discover community profiles  
**Features**:
- Online profile repository
- `dotbot profiles search rails`
- `dotbot profiles install community/rails-turbo`

**Requirements**:
- Backend service or GitHub-based registry
- Profile validation
- Rating/review system

---

### 20. AI-Powered Suggestions
**Goal**: Analyze codebase and suggest optimizations  
**Features**:
- "Your project uses TypeScript. Enable these 5 standards?"
- Suggest profile based on dependencies
- Auto-generate custom standards

**Requirements**:
- Codebase analysis
- AI integration (OpenAI/local models)
- User consent/privacy

---

### 21. Collaboration Features
**Goal**: Team workflow coordination  
**Features**:
- Export/import workflow state
- Track who's working on what
- Shared spec status

**Requirements**:
- State synchronization
- Optional backend service
- Git integration

---

### 22. Validation & Testing
**Command**:
```powershell
dotbot test
# Runs health checks
# Validates all commands work
# Tests Warp integration
```

**Files to create**:
- `tests/` directory
- Pester test files
- CI/CD integration

---

## 📝 Documentation Improvements

### 23. Better README ✅ PARTIALLY COMPLETED
- ✅ Comprehensive README with TOC
- ✅ Architecture documentation
- ✅ Cross-platform installation guide
- ✅ Profile documentation (.NET example)
- ⏳ Add GIFs/screenshots of workflow
- ⏳ Show before/after comparisons
- ⏳ Quick 2-minute video walkthrough

### 24. User Guides ⏳ PARTIALLY COMPLETED
- ✅ `docs/TEMPLATE-VARIABLES.md` - Template system documentation
- ✅ `docs/INTERACTION-GUIDELINES.md` - Interaction patterns
- ✅ `docs/CROSS-PLATFORM-CHANGES.md` - Cross-platform notes
- ⏳ `docs/GETTING-STARTED.md` - Step-by-step first project
- ⏳ `docs/WORKFLOWS.md` - Deep dive into each workflow
- ⏳ `docs/CUSTOMIZATION.md` - How to customize profiles
- ⏳ `docs/TROUBLESHOOTING.md` - Common issues and fixes

### 25. Examples Repository ⏳ PARTIALLY COMPLETED
- ✅ .NET profile with vertical slice architecture (`profiles/dotnet/`)
- ✅ .NET profile setup guide (`profiles/dotnet/SETUP.md`)
- ⏳ Sample projects for different stacks
- ⏳ Real-world spec examples
- ⏳ Recorded workflow sessions

---

## 🏗️ Technical Debt

### 26. Testing Infrastructure
- Add Pester tests for all scripts
- Mock file operations for testing
- CI/CD pipeline

### 27. Error Handling
- Consistent error handling across scripts
- Rollback on failure
- Better logging

### 28. Performance
- Cache profile files
- Parallel file operations
- Progress indicators for long operations

### 29. Cross-Platform ✅ COMPLETED
- ✅ Full PowerShell 7+ support on Windows, macOS, Linux
- ✅ Cross-platform PATH management
- ✅ Shell profile integration (.bashrc, .zshrc, .bash_profile)
- ✅ Platform-specific path separators and conventions
- ✅ Documented in README and CROSS-PLATFORM-CHANGES.md

---

## Implementation Priority

**Phase 1 - Foundation** 🟨 75% COMPLETED:
1. ✅ Global `dotbot` command (#1)
2. ✅ Better error messages (#2)
3. ⏳ Smart project detection (#3) - NOT IMPLEMENTED
4. ✅ Status command (#5)

**Phase 2 - Polish** 🟨 75% COMPLETED:
5. ⏳ Interactive installation (#4) - NOT IMPLEMENTED
6. ✅ Visual workflow map (#7)
7. ✅ Update commands (#6)
8. ✅ Uninstall (#9)

**Phase 3 - Enhancement** 🟨 33% COMPLETED:
9. ⏳ Profile management commands (#8) - Profiles exist but no CLI management
10. ⏳ Project memory (#10) - Partial (.dotbot-state.json exists but limited)
11. ✅ Documentation improvements (#23-25) - README restructured, WARP.md added

**Cross-Platform Support** ✅ COMPLETED:
12. ✅ Windows, macOS, Linux support (#29)
13. ✅ Shell integration
14. ✅ PATH management

**Phase 4 - Advanced (Month 2+)**:
12. Template system (#13)
13. Multi-project dashboard (#14)
14. Shell integration (#16)
15. Testing infrastructure (#26)

**Phase 5 - Future (TBD)**:
16. Web installer (#17)
17. Package managers (#18)
18. Profile marketplace (#19)
19. AI features (#20)
