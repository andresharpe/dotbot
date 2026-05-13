<#
.SYNOPSIS
Rate-limit message parser shared by all adapters.

.DESCRIPTION
Get-RateLimitResetTime takes a free-form rate-limit message (e.g. "You've hit
your limit · resets 10pm (Europe/Berlin)") and returns a hashtable with the
parsed reset time plus a recommended wait window. Adapters detect rate-limit
events in their own streams and feed the raw message text here.

Adapter-agnostic — relies only on regex + timezone math.
#>

function Get-RateLimitResetTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    # Pattern: "resets 10pm (Europe/Berlin)" or "resets 10:30pm (Europe/Berlin)"
    if ($Message -match "resets?\s+(\d{1,2}):?(\d{2})?\s*(am|pm)\s*\(([^)]+)\)") {
        $hour = [int]$matches[1]
        $minute = if ($matches[2]) { [int]$matches[2] } else { 0 }
        $ampm = $matches[3].ToLowerInvariant()
        $timezone = $matches[4]

        if ($ampm -eq "pm" -and $hour -ne 12) {
            $hour += 12
        } elseif ($ampm -eq "am" -and $hour -eq 12) {
            $hour = 0
        }

        $tzMap = @{
            "Europe/Berlin"        = "Central European Standard Time"
            "Europe/London"        = "GMT Standard Time"
            "America/New_York"     = "Eastern Standard Time"
            "America/Los_Angeles"  = "Pacific Standard Time"
            "UTC"                  = "UTC"
        }

        $dotnetTz = $tzMap[$timezone]
        if (-not $dotnetTz) {
            $dotnetTz = [TimeZoneInfo]::Local.Id
        }

        try {
            $tz = [TimeZoneInfo]::FindSystemTimeZoneById($dotnetTz)
            $now = [DateTimeOffset]::Now
            $nowInTz = [TimeZoneInfo]::ConvertTime($now, $tz)

            $resetInTz = [DateTime]::new($nowInTz.Year, $nowInTz.Month, $nowInTz.Day, $hour, $minute, 0)

            if ($resetInTz -lt $nowInTz.DateTime) {
                $resetInTz = $resetInTz.AddDays(1)
            }

            $resetOffset = [DateTimeOffset]::new($resetInTz, $tz.GetUtcOffset($resetInTz))
            $resetLocal = $resetOffset.ToLocalTime()

            $waitSeconds = [int]($resetLocal - [DateTimeOffset]::Now).TotalSeconds + 60

            if ($waitSeconds -lt 0) {
                $waitSeconds = 60
            }

            return @{
                reset_time = $resetLocal.DateTime
                wait_seconds = $waitSeconds
                timezone = $timezone
                original_message = $Message
            }
        } catch {
            return @{
                reset_time = (Get-Date).AddMinutes(15)
                wait_seconds = 900
                timezone = $timezone
                original_message = $Message
                parse_error = $_.Exception.Message
            }
        }
    }

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
