<#
.SYNOPSIS
    Sanitizes absolute file-system paths from text to prevent privacy leaks.

.DESCRIPTION
    Provides Remove-AbsolutePaths which strips OS-specific absolute paths
    (Windows, macOS, Linux) from strings, replacing project-root references
    with '.' and any remaining user-home paths with '<REDACTED>'.

    Used by Write-ActivityLog (at write time) and Get-*ActivityLog helpers
    (at read-back time) to ensure activity logs and task state files never
    contain absolute user paths.
#>

function Remove-AbsolutePaths {
    <#
    .SYNOPSIS
    Removes absolute file-system paths from a text string.

    .PARAMETER Text
    The string to sanitize.

    .PARAMETER ProjectRoot
    Optional project root path. All occurrences (backslash, forward-slash,
    and JSON-escaped variants) are replaced with '.'.

    .OUTPUTS
    The sanitized string.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [string]$ProjectRoot
    )

    if (-not $Text) { return $Text }

    # --- Phase 1: Replace known project root with '.' ---
    if ($ProjectRoot) {
        # JSON-escaped double-backslash variant (e.g. C:\\Users\\<user>\\repos\\project)
        # In -replace, '\\' as regex matches one literal '\'; '\\' as replacement outputs '\\'
        # (backslash is not special in .NET replacement strings, only $ is)
        $doubleEscaped = $ProjectRoot -replace '\\', '\\'
        if ($doubleEscaped -ne $ProjectRoot) {
            $Text = $Text -replace [regex]::Escape($doubleEscaped), '.'
        }

        # Native backslash variant (e.g. C:\Users\<user>\repos\project)
        $Text = $Text -replace [regex]::Escape($ProjectRoot), '.'

        # Forward-slash variant (e.g. /c/Users/<user>/repos/project or C:/Users/<user>/repos/project)
        $forwardSlash = $ProjectRoot -replace '\\', '/'
        if ($forwardSlash -ne $ProjectRoot) {
            $Text = $Text -replace [regex]::Escape($forwardSlash), '.'
        }

        # Git-bash style lowercase drive letter (e.g. /c/Users/... from C:\Users\...)
        if ($ProjectRoot -match '^([A-Za-z]):\\') {
            $driveLetter = $Matches[1].ToLowerInvariant()
            $gitBashPath = '/' + $driveLetter + ($ProjectRoot.Substring(2) -replace '\\', '/')
            $Text = $Text -replace [regex]::Escape($gitBashPath), '.'
        }
    }

    # --- Phase 2: Safety net — redact any remaining user-home paths ---
    # Windows:  C:\Users\<user>  or  C:\\Users\\<user>  or  C:/Users/<user>
    $Text = $Text -replace '[A-Za-z]:[/\\]+Users[/\\]+\w+', '<REDACTED>'

    # Linux:    /home/<user>
    $Text = $Text -replace '/home/\w+', '<REDACTED>'

    # macOS:    /Users/<user>
    $Text = $Text -replace '/Users/\w+', '<REDACTED>'

    return $Text
}

Export-ModuleMember -Function 'Remove-AbsolutePaths'
