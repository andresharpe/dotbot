# Phase 10: Drone Agent

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Concept
A **Drone** is a headless dotbot worker that polls the Mothership for work, clones repos, executes tasks, and reports results. Drones reuse the existing Runtime, MCP Server, and ProviderCLI — the only new code is the supervisor agent and its lifecycle management.

## Drone Agent script
**Path:** `scripts/drone-agent.ps1`

The Drone Agent is a long-running PowerShell script that:
```powershell
# drone-agent.ps1 — Headless autonomous worker
param(
    [string]$ConfigPath = "./drone-config.yaml"  # Drone configuration
)

# 1. Load config (providers, capabilities, mothership URL)
# 2. Register with Mothership (POST /api/fleet/register with instance_type=drone)
# 3. Enter main loop:
#    a. Poll Mothership for work (GET /api/fleet/work-queue/poll)
#    b. If assignment received:
#       - Clone repo to workspace_dir
#       - Run dotbot init with required stacks
#       - Launch process (analysis, execution, or workflow)
#       - Stream events to Mothership via event bus
#       - On completion: push commits, create PR, report results
#       - Cleanup workspace
#    c. If no work: heartbeat + sleep(poll_interval)
# 4. On shutdown: deregister, cleanup active workspaces
```

## DroneAgent.psm1
**Path:** `profiles/default/systems/runtime/modules/DroneAgent.psm1`

Functions:
- `Initialize-Drone -Config <hashtable>` — load config, validate providers
- `Register-Drone -MothershipUrl <string> -ApiKey <string> -Capabilities <hashtable>` — register with mothership
- `Get-DroneAssignment -MothershipUrl <string> -DroneId <string>` — poll work queue
- `Invoke-DroneAssignment -Assignment <hashtable>` — clone, init, execute, report
- `Send-DroneHeartbeat -MothershipUrl <string> -DroneId <string> -Status <hashtable>` — periodic heartbeat
- `Complete-DroneAssignment -AssignmentId <string> -Result <hashtable>` — report completion
- `Remove-DroneWorkspace -WorkspacePath <string>` — cleanup after assignment

## Drone configuration format
**Path:** `defaults/drone-config.example.yaml`

```yaml
name: "drone-prod-01"
mothership:
  url: "https://mothership.example.com"
  api_key: "..."
  poll_interval_seconds: 10
  heartbeat_interval_seconds: 30
providers:
  - name: claude
    env_key: ANTHROPIC_API_KEY
    models: [opus, sonnet]
    default_model: opus
  - name: codex
    env_key: OPENAI_API_KEY
    models: [gpt-5.2-codex]
  - name: gemini
    env_key: GEMINI_API_KEY
    models: [gemini-2.5-pro]
capabilities:
  max_concurrent: 3
  stacks: [dotnet, dotnet-blazor, dotnet-ef]
workspace_dir: /var/dotbot/workspaces
cleanup_on_complete: true
git:
  credential_helper: "store"
  user_name: "dotbot-drone"
  user_email: "drone@dotbot.dev"
logging:
  level: Info
  forward_to_mothership: true
```

## Provider selection
When the Mothership dispatches work to a Drone:
- Assignment specifies `preferred_provider` and `preferred_model`
- Drone matches against its configured providers
- If preferred not available, falls back to any available provider
- The existing `ProviderCLI.psm1` handles the actual invocation — Drone just sets the provider config

## Credential management
- Provider API keys: environment variables (set per-drone, not per-assignment)
- Repo credentials: `credentials_ref` in assignment maps to a credential store on the Drone
- Mothership API key: in drone-config.yaml (or environment variable)
- Secrets never transit through the Mothership work queue

## Steering for Drones
- Outposts have developer "whisper" steering via JSONL files
- Drones get **Mothership commands** instead:
  - `POST /api/fleet/{drone_id}/command` with `{type: "stop|pause|resume|reassign"}`
  - Drone Agent polls for commands alongside heartbeat
  - Maps to the same internal stop-signal mechanism (`Test-ProcessStopSignal`)

## Docker support
**Path:** `docker/Dockerfile.drone`

```dockerfile
FROM mcr.microsoft.com/powershell:7.5-ubuntu-24.04
RUN apt-get update && apt-get install -y git
# Install provider CLIs (claude, codex, gemini)
COPY . /opt/dotbot
RUN pwsh /opt/dotbot/install.ps1
ENTRYPOINT ["pwsh", "/opt/dotbot/scripts/drone-agent.ps1"]
```

**Docker Compose for drone fleet:**
```yaml
services:
  drone-1:
    build: { context: ., dockerfile: docker/Dockerfile.drone }
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
    volumes:
      - ./drone-config-1.yaml:/config/drone-config.yaml
      - drone-workspaces-1:/var/dotbot/workspaces
    command: ["-ConfigPath", "/config/drone-config.yaml"]
```

## Events
- `drone.registered` — Drone connects to Mothership
- `drone.assigned` — Drone receives work assignment
- `drone.working` — Drone starts task execution
- `drone.completed` — Drone finishes assignment successfully
- `drone.failed` — Drone assignment failed
- `drone.idle` — Drone has no work (heartbeat)

## Files
- Create: `scripts/drone-agent.ps1` — main entry point
- Create: `profiles/default/systems/runtime/modules/DroneAgent.psm1` — Drone lifecycle functions
- Create: `defaults/drone-config.example.yaml` — example configuration
- Create: `docker/Dockerfile.drone` — containerized Drone
- Create: `docker/docker-compose.drone.yaml` — multi-drone deployment
- Server: Extend `FleetController` with work queue endpoints
- Server: Create `WorkQueueService.cs`, `DroneSchedulerService.cs`
