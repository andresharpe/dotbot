<#
.SYNOPSIS
Dotbot.Events root module — event-bus sinks.

The actual surface lives under Private/*.psm1 (Discovery today; Dispatch and
the background Consumer land in later steps). This root file exists so the psd1
has a RootModule to point at; it deliberately exports nothing of its own. The
plugin contract and shipped sinks live on disk under
<runtime>/Plugins/Events/Sinks/* and are picked up at dispatch time.
#>

# Intentionally empty: nested modules carry the surface.
