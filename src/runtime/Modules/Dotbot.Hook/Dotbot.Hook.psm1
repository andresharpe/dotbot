<#
.SYNOPSIS
Dotbot.Hook root module — transition hooks.

The actual surface lives under internal/Discovery.psm1 and internal/Dispatch.psm1. This
root file exists so the psd1 has a RootModule to point at; it deliberately
exports nothing of its own. The plugin contract and shipped hooks live on
disk under <project>/.bot/src/runtime/hooks/transitions/* (or the framework
copy under the dotbot install root) and are picked up at dispatch time.
#>

# Intentionally empty: nested modules carry the surface.
