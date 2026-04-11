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
