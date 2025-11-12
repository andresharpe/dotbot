# Cross-Platform Changes - dotbot

## Overview

dotbot has been thoroughly updated to support Windows, macOS, and Linux platforms with PowerShell 7+ as the cross-platform scripting engine.

## What Changed

### 1. New Platform Functions Module (`scripts/Platform-Functions.psm1`)

A comprehensive new module providing:

- **OS Detection**: Automatic platform identification (Windows, macOS, Linux)
- **PowerShell Version Check**: Validates PowerShell 6+ on Unix, 5.1+ on Windows
- **Cross-Platform PATH Management**: 
  - Windows: Registry-based User PATH updates
  - macOS/Linux: Shell profile updates (.bashrc, .zshrc, .bash_profile, .profile)
- **Path Separators**: Automatic `;` (Windows) vs `:` (Unix) handling
- **Executable Permissions**: Sets +x on Unix systems automatically
- **Home Directory**: Uses cross-platform `$HOME` variable

### 2. Updated Core Scripts

All scripts now use cross-platform functions:

#### `init.ps1`
- Added PowerShell version check on startup
- Changed `$env:USERPROFILE` → `$HOME`
- Imports Platform-Functions for version validation

#### `bin/dotbot.ps1`
- Changed `$env:USERPROFILE` → `$HOME`
- Inherits platform functions via Common-Functions

#### `scripts/base-install.ps1`
- Replaced Windows-specific PATH code with `Add-ToPath` function
- Sets executable permissions on Unix
- Platform-aware post-install instructions
- PowerShell version check
- Changed `$env:USERPROFILE` → `$HOME`

#### `scripts/uninstall.ps1`
- Replaced Windows-specific PATH removal with `Remove-FromPath` function
- Changed `$env:USERPROFILE` → `$HOME`

#### `scripts/project-install.ps1`
- Changed `$env:USERPROFILE` → `$HOME`

#### `scripts/update.ps1`
- Changed `$env:USERPROFILE` → `$HOME`

#### `scripts/upgrade-project.ps1`
- Changed `$env:USERPROFILE` → `$HOME`

#### `scripts/Common-Functions.psm1`
- Imports Platform-Functions.psm1 automatically
- All functions now have access to platform detection

### 3. Line Ending Normalization

Created `.gitattributes` to ensure consistent line endings:
- All text files use LF (Unix-style) line endings
- PowerShell scripts (.ps1, .psm1) use LF
- Markdown, YAML, JSON use LF
- Binary files marked appropriately

### 4. Documentation Updates

#### `README.md`
- Added **Prerequisites** section with PowerShell 7+ installation instructions
- Updated badges to show cross-platform support
- Changed installation instructions to work on all platforms
- Added **Platform-Specific Notes** section with details for Windows/macOS/Linux
- Updated command examples to use `pwsh` (cross-platform)
- Changed "Windows-native" to "cross-platform" throughout
- Updated paths from backslash to forward slash where appropriate

## Key Technical Details

### Platform Detection

```powershell
# PowerShell 6+ has built-in $IsWindows, $IsLinux, $IsMacOS
# PowerShell 5.x (Windows only) needs manual detection
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $script:IsWindows = $true
    $script:IsLinux = $false
    $script:IsMacOS = $false
} else {
    $script:IsWindows = $IsWindows
    $script:IsLinux = $IsLinux
    $script:IsMacOS = $IsMacOS
}
```

### PATH Management

**Windows:**
- Uses `[Environment]::SetEnvironmentVariable("Path", $newPath, "User")`
- Updates registry key for persistent PATH
- Changes take effect after terminal restart

**macOS/Linux:**
- Writes to shell profiles: `~/.bashrc`, `~/.zshrc`, `~/.bash_profile`, `~/.profile`
- Adds block with comment marker for easy removal
- Changes take effect after `source ~/.bashrc` or terminal restart

### Home Directory

Changed from Windows-specific `$env:USERPROFILE` to cross-platform `$HOME`:
- Windows: `$HOME` = `C:\Users\username`
- macOS: `$HOME` = `/Users/username`
- Linux: `$HOME` = `/home/username`

## Version Requirements

- **Windows**: PowerShell 5.1+ (7+ strongly recommended)
- **macOS**: PowerShell 7+ (required)
- **Linux**: PowerShell 7+ (required)

The installer will check and warn/fail if requirements aren't met.

## Testing Checklist

- [ ] Windows 10/11 with PowerShell 5.1
- [ ] Windows 10/11 with PowerShell 7+
- [ ] macOS with PowerShell 7+ (via Homebrew)
- [ ] Ubuntu/Debian with PowerShell 7+
- [ ] Fedora/RHEL with PowerShell 7+
- [ ] PATH updates work correctly on each platform
- [ ] Uninstall removes PATH entries on each platform
- [ ] Executable permissions set on Unix
- [ ] Line endings are LF after clone on Windows
- [ ] All commands work on all platforms

## Migration Notes

### For Existing Users

No action required for existing installations. The changes are backward compatible:
- Windows users will continue to work exactly as before
- `$HOME` and `$env:USERPROFILE` are equivalent on Windows
- Existing PATH entries remain unchanged

### For New Installations

- macOS/Linux users can now install dotbot
- All platforms use the same installation commands
- Documentation now covers all platforms

## Breaking Changes

None. All changes are additive and maintain backward compatibility with existing Windows installations.

## Files Added

- `scripts/Platform-Functions.psm1` - New cross-platform helper module
- `.gitattributes` - Line ending configuration
- `CROSS-PLATFORM-CHANGES.md` - This document

## Files Modified

- `README.md` - Updated for cross-platform support
- `init.ps1` - PowerShell version check, $HOME
- `bin/dotbot.ps1` - $HOME
- `scripts/base-install.ps1` - Cross-platform PATH, $HOME
- `scripts/project-install.ps1` - $HOME
- `scripts/uninstall.ps1` - Cross-platform PATH removal, $HOME
- `scripts/update.ps1` - $HOME
- `scripts/upgrade-project.ps1` - $HOME
- `scripts/Common-Functions.psm1` - Import Platform-Functions

## Future Enhancements

Potential areas for future improvement:
- Add platform-specific profiles (e.g., macOS-specific workflows)
- Test with other shells (fish, zsh with frameworks)
- Consider adding shell completion for bash/zsh
- Add Windows Terminal settings integration
- Add iTerm2/Alacritty configuration examples

## Acknowledgments

This cross-platform update maintains compatibility with the original Windows-focused design while extending support to Unix-like operating systems. The core workflow and user experience remain consistent across all platforms.
