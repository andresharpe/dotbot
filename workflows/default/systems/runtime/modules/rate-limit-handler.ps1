function Get-RateLimitResetTime {
    <#
    .SYNOPSIS
    Parses a rate limit message and extracts the reset time
    
    .PARAMETER Message
    The rate limit message to parse (e.g., "You've hit your limit · resets 10pm (Europe/Berlin)")
    
    .OUTPUTS
    Hashtable with parsed info or $null if not a rate limit message
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    
    # Pattern: "resets 10pm (Europe/Berlin)" or "resets 10:30pm (Europe/Berlin)"
    if ($Message -match "resets?\s+(\d{1,2}):?(\d{2})?\s*(am|pm)\s*\(([^)]+)\)") {
        $hour = [int]$matches[1]
        $minute = if ($matches[2]) { [int]$matches[2] } else { 0 }
        $ampm = $matches[3].ToLower()
        $timezone = $matches[4]
        
        # Convert to 24-hour format
        if ($ampm -eq "pm" -and $hour -ne 12) {
            $hour += 12
        } elseif ($ampm -eq "am" -and $hour -eq 12) {
            $hour = 0
        }
        
        # Try to map timezone to .NET timezone
        $tzMap = @{
            "Europe/Berlin" = "Central European Standard Time"
            "Europe/London" = "GMT Standard Time"
            "America/New_York" = "Eastern Standard Time"
            "America/Los_Angeles" = "Pacific Standard Time"
            "UTC" = "UTC"
        }
        
        $dotnetTz = $tzMap[$timezone]
        if (-not $dotnetTz) {
            # Fallback: assume local timezone
            $dotnetTz = [TimeZoneInfo]::Local.Id
        }
        
        try {
            $tz = [TimeZoneInfo]::FindSystemTimeZoneById($dotnetTz)
            $now = [DateTimeOffset]::Now
            $nowInTz = [TimeZoneInfo]::ConvertTime($now, $tz)
            
            # Build reset time in the target timezone for today
            $resetInTz = [DateTime]::new($nowInTz.Year, $nowInTz.Month, $nowInTz.Day, $hour, $minute, 0)
            
            # If reset time is in the past, it's for tomorrow
            if ($resetInTz -lt $nowInTz.DateTime) {
                $resetInTz = $resetInTz.AddDays(1)
            }
            
            # Convert back to local time
            $resetOffset = [DateTimeOffset]::new($resetInTz, $tz.GetUtcOffset($resetInTz))
            $resetLocal = $resetOffset.ToLocalTime()
            
            # Calculate wait seconds + 1 minute buffer
            $waitSeconds = [int]($resetLocal - [DateTimeOffset]::Now).TotalSeconds + 60
            
            if ($waitSeconds -lt 0) {
                $waitSeconds = 60  # Minimum 1 minute wait
            }
            
            return @{
                reset_time = $resetLocal.DateTime
                wait_seconds = $waitSeconds
                timezone = $timezone
                original_message = $Message
            }
        } catch {
            # If timezone conversion fails, wait 15 minutes as fallback
            return @{
                reset_time = (Get-Date).AddMinutes(15)
                wait_seconds = 900
                timezone = $timezone
                original_message = $Message
                parse_error = $_.Exception.Message
            }
        }
    }
    
    # Check for simpler "hit your limit" patterns without specific time
    if ($Message -match "hit your limit|rate.?limit|too many requests|quota exceeded") {
        return @{
            reset_time = (Get-Date).AddMinutes(15)
            wait_seconds = 900
            timezone = "unknown"
            original_message = $Message
            fallback = $true
        }
    }
    
    return $null
}

function Wait-ForRateLimitReset {
    <#
    .SYNOPSIS
    Waits until the rate limit resets with countdown display

    .PARAMETER RateLimitInfo
    The rate limit info from Get-RateLimitResetTime

    .PARAMETER ControlDir
    Directory to check for control signals

    .PARAMETER LoopType
    Optional loop type ('analysis' or 'execution') for loop-specific stop signals.
    If specified, checks for stop-{LoopType}.signal instead of generic stop.signal.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$RateLimitInfo,

        [Parameter(Mandatory = $false)]
        [string]$ControlDir,

        [Parameter(Mandatory = $false)]
        [ValidateSet('analysis', 'execution')]
        [string]$LoopType
    )
    
    # Import theme if not already available
    if (-not $t) {
        Import-Module "$PSScriptRoot\DotBotTheme.psm1" -Force
        $t = Get-DotBotTheme
    }
    
    $waitSeconds = $RateLimitInfo.wait_seconds
    $resetTime = $RateLimitInfo.reset_time
    $resetTimeStr = $resetTime.ToString("HH:mm:ss")
    $tzStr = $RateLimitInfo.timezone
    
    $waitHours = [math]::Floor($waitSeconds / 3600)
    $waitMin = [math]::Ceiling(($waitSeconds % 3600) / 60)
    $waitText = if ($waitHours -gt 0) { "$waitHours hour(s) $waitMin minute(s)" } else { "$waitMin minute(s)" }
    
    # Display rate limit card
    Write-Host ""
    $rateLimitLines = @(
        "$($t.Label)Reset at:$($t.Reset) $($t.Cyan)$resetTimeStr ($tzStr)$($t.Reset)"
        "$($t.Label)Buffer:$($t.Reset)   $($t.Cyan)+1 minute$($t.Reset)"
        ""
        "$($t.Amber)Waiting approximately $waitText...$($t.Reset)"
    )
    Write-Card -Title "RATE LIMIT REACHED" -Width 50 -BorderStyle Rounded -BorderColor Label -TitleColor Label -Lines $rateLimitLines
    Write-Host ""
    
    # Log to activity
    try {
        $controlDirPath = if ($ControlDir) { $ControlDir } else { Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) ".control" }
        $logPath = Join-Path $controlDirPath "activity.jsonl"
        $event = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            type = "rate_limit"
            message = "Rate limit reached. Waiting until $resetTimeStr ($tzStr)"
        } | ConvertTo-Json -Compress
        $maxRetries = 3
        for ($r = 0; $r -lt $maxRetries; $r++) {
            try {
                $fs = [System.IO.FileStream]::new(
                    $logPath,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite
                )
                $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
                $sw.WriteLine($event)
                $sw.Close()
                $fs.Close()
                break
            } catch {
                if ($r -lt ($maxRetries - 1)) {
                    Start-Sleep -Milliseconds (50 * ($r + 1))
                }
            }
        }
    } catch {
        # Silently ignore logging errors
    }
    
    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($waitSeconds)
    
    while ((Get-Date) -lt $endTime) {
        $remaining = $endTime - (Get-Date)
        $remainingHours = [math]::Floor($remaining.TotalHours)
        $remainingMin = $remaining.Minutes
        $remainingSec = $remaining.Seconds
        
        Write-Host "`r$($t.Label)Time remaining:$($t.Reset) $($t.Cyan)$($remainingHours.ToString('00')):$($remainingMin.ToString('00')):$($remainingSec.ToString('00'))$($t.Reset)   " -NoNewline
        
        # Check for stop signal every second
        # Note: launch-process.ps1 uses its own inline rate-limit wait with Test-ProcessStopSignal.
        # This function is retained for any future callers that may need it.
        if ($ControlDir -and $LoopType) {
            $stopSignalFile = "stop-$LoopType.signal"
            if (Test-Path (Join-Path $ControlDir $stopSignalFile)) {
                Write-Host ""
                Write-Status "Stop signal received during rate limit wait" -Type Error
                return "stop"
            }
        }
        
        Start-Sleep -Seconds 1
    }
    
    Write-Host ""
    Write-Status "Rate limit wait complete, resuming..." -Type Success
    Write-Host ""
    
    return "continue"
}
