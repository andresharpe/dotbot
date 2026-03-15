# Phase 11: Enterprise Extension Registries

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Concept
Organizations need proprietary workflows, stacks, tools, skills, agents, and hooks customized to their environments, systems, and internal tooling. An **Extension Registry** is a git-compatible repository with a known directory structure that dotbot can discover, cache, and consume. Enterprise content is referenced via a **namespace prefix** (e.g., `myorg:onboard-new-service`) to avoid collisions with built-in names.

Git repos are the source of truth. The Mothership optionally acts as a discovery layer — pointing Outposts and Drones to approved registries for the org — but is not required.

## Enterprise extension repo structure

```
dotbot-extensions/                    # Any git-compatible repo
  registry.yaml                       # Registry metadata
  stacks/
    internal-api/
      profile.yaml                    # type: stack
      defaults/settings.default.json
      hooks/verify/...
      systems/mcp/tools/...
      prompts/skills/...
    data-platform/
      profile.yaml
      ...
  workflows/
    onboard-new-service/
      workflow.yaml                   # Phase pipeline definition
      prompts/workflows/...           # Workflow prompt files
      systems/mcp/tools/...           # Workflow-specific tools
    compliance-audit/
      workflow.yaml
      ...
  tools/                              # Standalone MCP tools (no stack/workflow)
    jira-sync/
      metadata.yaml
      script.ps1
    internal-deploy/
      metadata.yaml
      script.ps1
  skills/                             # Standalone skills
    our-coding-standards/
      ...
  agents/                             # Custom AI personas
    security-reviewer/
      ...
  hooks/                              # Org-wide hooks
    verify/
      04-compliance-check.ps1
  defaults/
    settings.overlay.json             # Org-wide settings overlay
```

## Registry metadata (`registry.yaml`)

```yaml
name: myorg
display_name: "Acme Corp Dotbot Extensions"
description: "Internal workflows, stacks, and tools for Acme engineering"
version: "1.2.0"
min_dotbot_version: "4.0.0"
maintainers:
  - platform-team@acme.com
content:
  stacks: [internal-api, data-platform]
  workflows: [onboard-new-service, compliance-audit]
  tools: [jira-sync, internal-deploy]
  skills: [our-coding-standards]
  agents: [security-reviewer]
```

## CLI commands

```bash
# Registry management
dotbot registry add myorg https://dev.azure.com/org/dotbot-extensions
dotbot registry add myorg https://dev.azure.com/org/dotbot-extensions --branch release/v2
dotbot registry list
dotbot registry update [name]          # Fetch latest from remote
dotbot registry remove myorg

# Using enterprise content (namespace prefix)
dotbot init --profile myorg:internal-api
dotbot init --profile dotnet,myorg:internal-api    # Combine built-in + enterprise stacks
dotbot run myorg:onboard-new-service
dotbot run myorg:compliance-audit

# Discovery
dotbot workflows                       # Lists built-in AND enterprise workflows
dotbot stacks                          # Lists built-in AND enterprise stacks
```

## Local cache

- Registries are shallow-cloned to `~/dotbot/registries/{name}/`
- Shallow clone for bandwidth efficiency (`--depth 1`)
- Auto-update on `dotbot init` or `dotbot run` (configurable: `auto_update: true|false`)
- Offline mode: use cached version if network unavailable, emit warning
- Cache age threshold: warn if cache is older than N days (configurable)

## Configuration

**Global registry config** (`~/dotbot/registries.json`):
```json
{
  "registries": [
    {
      "name": "myorg",
      "url": "https://dev.azure.com/org/dotbot-extensions",
      "branch": "main",
      "auth": "credential-helper",
      "auto_update": true,
      "cache_max_age_days": 7
    }
  ]
}
```

**Per-project override** (`.bot/.control/settings.json`):
```json
{
  "registries": [
    {
      "name": "myorg",
      "branch": "feature/new-workflow"
    }
  ]
}
```

Per-project overrides merge with global config — useful for testing a registry branch before merging.

## Namespace resolution

When dotbot encounters `myorg:internal-api`:

1. Look up `myorg` in configured registries
2. Ensure local cache exists (clone if not, update if stale)
3. Resolve the content type:
   - `dotbot init --profile myorg:internal-api` → look in `registries/myorg/stacks/internal-api/`
   - `dotbot run myorg:onboard-new-service` → look in `registries/myorg/workflows/onboard-new-service/`
4. Apply using the same overlay/execution mechanisms as built-in content

**Resolution order for name collisions:**
- Namespaced names never collide (different namespace = different content)
- Unqualified names (no prefix) always resolve to built-in content
- Enterprise content MUST use its namespace prefix — no implicit override

## Mothership discovery (optional)

When an Outpost or Drone connects to the Mothership, it can receive a list of approved registries:

```json
GET /api/fleet/registries
{
  "registries": [
    {
      "name": "myorg",
      "url": "https://dev.azure.com/org/dotbot-extensions",
      "branch": "main",
      "required": true,
      "description": "Acme Corp standard extensions"
    }
  ]
}
```

- `required: true` — Outpost/Drone must configure this registry to participate in the fleet
- On first Mothership connection, registries are auto-configured (with user confirmation for Outposts, auto for Drones)
- Mothership can push registry updates (new repos, branch changes) via the existing heartbeat response

## Drone integration

When the Mothership dispatches work to a Drone:

```json
{
  "id": "assign-abc123",
  "workflow": "myorg:onboard-new-service",
  "required_registries": ["myorg"],
  ...
}
```

The Drone Agent:
1. Checks if `myorg` registry is configured and cached
2. If not, fetches registry config from Mothership and clones
3. Resolves `myorg:onboard-new-service` from the cached registry
4. Proceeds with normal workflow execution

## Security considerations

- Git authentication handles access control (SSH keys, PATs, credential helpers)
- Registry content is code — subject to the same review/PR/approval process as any enterprise code
- Optional integrity: `registry.yaml` can include content hashes for tamper detection
- Registries from unknown sources require explicit `dotbot registry add` — no auto-discovery without Mothership trust
- `.env.local` patterns in enterprise repos are gitignored by convention

## RegistryManager.psm1

**Path:** `profiles/default/systems/runtime/modules/RegistryManager.psm1`

Functions:
- `Add-DotBotRegistry -Name <string> -Url <string> -Branch <string>` — add to global config, initial clone
- `Remove-DotBotRegistry -Name <string>` — remove config and cached clone
- `Update-DotBotRegistry -Name <string>` — git fetch + reset to latest
- `Get-DotBotRegistries` — list all configured registries with status
- `Resolve-RegistryContent -Namespace <string> -ContentName <string> -ContentType <stack|workflow|tool|skill|agent>` — find content path in cache
- `Test-RegistryStale -Name <string>` — check if cache exceeds max age
- `Sync-RegistriesFromMothership -MothershipUrl <string>` — fetch approved registry list

## Files

- Create: `profiles/default/systems/runtime/modules/RegistryManager.psm1`
- Modify: `scripts/init-project.ps1` — resolve `namespace:stack` references during init
- Modify: `systems/runtime/modules/WorkflowRegistry.psm1` — resolve `namespace:workflow` references
- Modify: `install.ps1` — add `dotbot registry` subcommand
- Modify: `profiles/default/systems/runtime/modules/DroneAgent.psm1` — registry sync before assignment execution
- Server: Add `GET /api/fleet/registries` endpoint to `FleetController`
- Create: `~/dotbot/registries.json` schema and default
- Add to init: `~/dotbot/registries/` directory

## Events

- `registry.added`, `registry.updated`, `registry.removed` emitted via bus
- `registry.stale` warning event when cache exceeds max age
