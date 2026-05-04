# Canonical exemplar: validate an externally-supplied name against an
# allowlist BEFORE constructing and invoking the corresponding function.
#
# Source: core/mcp/dotbot-mcp.ps1 — Invoke-CallTool dispatches incoming
# `tools/call` requests by name; the registry-lookup gates the dispatch.
#
# Why this pattern is required:
#   The MCP server takes a tool name from a JSON-RPC request and calls
#   the matching `Invoke-<PascalCase>` function. Without the allowlist
#   gate, an attacker who controls the request body could call any
#   function in scope (e.g. `Remove-Item`) by spelling its name as a
#   tool name. The `$tools.ContainsKey($Name)` check makes the dispatch
#   surface enumerable and bounded.
#
# Apply the pattern any time you have:
#   - A name that arrives from outside the process boundary
#   - A code path that constructs a function name / cmdlet name / path
#     from that name
#   - A subsequent invocation (`& $f`, `. $f`, `Invoke-Command` with the
#     name as a parameter, etc.)
#
# The reviewer's PWSH-SEC-NNN dynamic-invocation rule and the project's
# .pwsh-review/standards.md "Tool-name allowlist before dispatch" rule
# both reference this file.

# ---- Bad: external name -> function call without validation ---------------

function Invoke-CallTool-Bad {
    param(
        [string]$Name,
        [hashtable]$Arguments
    )
    # ATTACK: $Name = "Item" makes this call Remove-Item with the supplied args.
    # No validation, no allowlist, the function name is constructed from
    # external input.
    $functionName = 'Remove-' + $Name
    & $functionName @Arguments
}

# ---- Good: registry lookup gates the dispatch -----------------------------

# The discovery pass populates this registry once at server start. After
# that, new entries cannot appear — every dispatch is bounded by what was
# discovered.
$script:tools = [ordered]@{}

function Register-Tool {
    param(
        [Parameter(Mandatory)][string]$Name,        # snake_case (MCP wire name)
        [Parameter(Mandatory)][hashtable]$Schema,
        [Parameter(Mandatory)][string]$FunctionName # Invoke-PascalCase (the actual cmdlet)
    )
    $script:tools[$Name] = @{ schema = $Schema; function = $FunctionName }
}

function Invoke-CallTool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments
    )

    # Allowlist gate. The wire name MUST appear in the registry before we
    # invoke anything. `ContainsKey` is the canonical check (case-sensitive
    # on the JSON-RPC name, which matches the MCP spec).
    if (-not $script:tools.ContainsKey($Name)) {
        throw "Unknown tool: $Name"
    }

    # Pull the resolved function name from the registry, NOT from the
    # request. The registry was populated at start-up by the discovery
    # pass, so $functionName is always one of the known-safe values.
    $functionName = $script:tools[$Name].function
    & $functionName -Arguments $Arguments
}

# ---- Three things to notice -----------------------------------------------
# 1. The $Name -> $functionName mapping lives in the registry, not in a
#    string-concatenation step. Even if the registry were tampered with,
#    a value still has to be present BEFORE dispatch.
# 2. `ContainsKey` is the bounded check. Don't substitute `-contains` on a
#    list — registries grow, lists drift.
# 3. The throw on unknown name is intentional. Returning a "no such tool"
#    JSON-RPC error message is fine; silently ignoring the call is not —
#    silent failures hide attempted abuse.
