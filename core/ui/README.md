# .bot Web UI

A minimal, dependency-free PowerShell web server for monitoring and controlling `.bot` autonomous development.

## Features

- **CP/M-inspired terminal aesthetic** with Axiome Design amber accents
- **Real-time monitoring** via auto-polling (3-5 second intervals)
- **Task queue visualization** (TODO/Analysing/Analysed/In-Progress/Done)
- **Process management** - launch, stop, kill, and whisper to tracked processes
- **Localhost-only** - no authentication needed
- **Zero dependencies** - pure PowerShell + vanilla HTML/CSS/JS

## Quick Start

```powershell
# Start the web server
cd .bot
.\go.ps1

# Or start directly
cd .bot\systems\ui
pwsh .\server.ps1
```

The server runs on port 8686 by default. If the port is busy, it auto-selects the next available port (up to 8699).

## Architecture

### Process Registry
All processes are tracked via JSON files in `.bot/.control/processes/`:
- `proc-{id}.json` - Process state (status, PID, heartbeat, etc.)
- `proc-{id}.activity.jsonl` - Activity log stream
- `proc-{id}.whisper.jsonl` - Operator whisper messages
- `proc-{id}.stop` - Stop signal file (presence triggers graceful stop)

### File Structure

```
.bot/
├── systems/
│   ├── ui/
│   │   ├── server.ps1           # PowerShell HTTP server
│   │   ├── modules/             # Server-side API modules
│   │   │   ├── ProcessAPI.psm1  # Process CRUD & lifecycle
│   │   │   ├── ControlAPI.psm1  # Start/stop/reset actions
│   │   │   ├── StateBuilder.psm1# Overview tab state
│   │   │   └── ...
│   │   └── static/              # Frontend (HTML/CSS/JS)
│   └── runtime/
│       └── launch-process.ps1   # Unified process launcher
├── .control/
│   ├── processes/               # Process registry
│   │   ├── proc-a1b2c3.json
│   │   ├── proc-a1b2c3.activity.jsonl
│   │   └── proc-a1b2c3.whisper.jsonl
│   └── activity.jsonl           # Global activity log
└── workspace/
    └── tasks/
        ├── todo/
        ├── analysing/
        ├── analysed/
        ├── in-progress/
        └── done/
```

## API Endpoints

### `GET /api/state`
Returns current .bot state (Overview tab).

### `GET /api/processes`
Returns all tracked processes with status.

### `POST /api/process/launch`
Launch a new process:
```json
{
  "type": "analysis",
  "continue": true,
  "model": "Opus"
}
```

### `POST /api/process/{id}/stop`
Send graceful stop signal to a process.

### `POST /api/process/{id}/kill`
Kill a process immediately (terminates PID).

### `POST /api/process/{id}/whisper`
Send a whisper message to a running process:
```json
{
  "message": "Focus on error handling",
  "priority": "normal"
}
```

### `POST /api/control`
Send control signal (start/stop/pause/resume/reset):
```json
{
  "action": "stop",
  "mode": "both"
}
```

## Process Lifecycle

1. **Launch** - `launch-process.ps1` creates a `proc-{id}.json` with `status: starting`
2. **Running** - Status transitions to `running`, heartbeats update the JSON
3. **Stop** - A `.stop` file is created; the process checks for it between tasks
4. **Completion** - Status becomes `completed`, window auto-closes after 5s countdown
5. **Crash detection** - Dead PIDs are detected within one poll cycle (~3s) and marked as `stopped` with an error

## Design System

Colors inspired by **Axiome Design** system:

- **Background**: `#1a1a1a` (deep, not pure black)
- **Text**: `#e8e8e8` (primary), `#999999` (secondary)
- **Accent**: `#d4a574` (warm amber - from Axiome)
- **Progress**: `#5fb3b3` (cyan)
- **Success**: `#8fbf7f` (green)
- **Danger**: `#d16969` (red)

Typography: Consolas/Courier New monospace

## Customization

### Change Port

```powershell
.\server.ps1 -Port 3000
```

## Troubleshooting

### Server won't start
- The server auto-selects an available port (8686–8699) by default
- To force a specific port: `.\server.ps1 -Port 8080`

### UI shows "No active session"
- Launch a process from the PROCESSES tab
- Or use the Start button on the Overview tab

### Browser shows stale data
- Check browser console for fetch errors
- Verify server is running and accessible (check the port shown in the server window)

## License

Part of the .bot autonomous development system.
