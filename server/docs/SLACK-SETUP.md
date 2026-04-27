# Slack Proactive Messaging Setup

How Dotbot sends question cards to Slack users via bot DMs — setup, test paths, and common failure modes.

---

## Prerequisites

| Tool | Minimum version | Check |
|------|----------------|-------|
| .NET SDK | 9.0 | `dotnet --version` |
| Azurite | any | `azurite --version` |
| devtunnel | any | `devtunnel --version` |
| Azure CLI | any recent | `az --version` |
| PowerShell | 7+ | `pwsh --version` |
| Slack workspace | — | Admin rights to install a custom app |

Install what's missing:

```powershell
# Azurite (local Azure blob storage emulator)
npm install -g azurite

# devtunnel — download from https://aka.ms/devtunnels/download
devtunnel --version
```

---

## Setup (shared for both test paths)

Do all four steps once. They're required whether you test manually via the CLI (Path A) or via a real dotbot workflow (Path B).

### 1. Start infrastructure (Terminals 1 & 2)

**Terminal 1 — devtunnel** (one-time create, then `host` every session):

```powershell
devtunnel create dotbot-local --allow-anonymous
devtunnel port create dotbot-local -p 5048
devtunnel host dotbot-local
```

Named tunnels keep the same URL across restarts: `https://dotbot-local-XXXXX.euw.devtunnels.ms`. Copy it — you need it for `BaseUrl` in Step 3.

**Terminal 2 — Azurite**:

```powershell
New-Item -ItemType Directory -Force C:\azurite
azurite --location C:\azurite
# Expect: "Azurite Blob service is starting..."
```

Create the two blob containers the server expects (`answers`, `conversation-references`) — Azurite won't auto-create them:

```powershell
az storage container create --name answers                 --connection-string "UseDevelopmentStorage=true"
az storage container create --name conversation-references --connection-string "UseDevelopmentStorage=true"
```

No Azure CLI? Use the `Az.Storage` PowerShell module, or Azure Storage Explorer GUI:

```powershell
# Az.Storage alternative
$ctx = New-AzStorageContext -ConnectionString "UseDevelopmentStorage=true"
New-AzStorageContainer -Name answers                 -Context $ctx
New-AzStorageContainer -Name conversation-references -Context $ctx
```

### 2. Create a Slack app

1. Go to <https://api.slack.com/apps> → **Create New App** → **From scratch**.
2. Name: `dotbot-local` → pick your workspace → **Create App**.
3. Left sidebar → **OAuth & Permissions** → **Bot Token Scopes** → add all four:
   | Scope | Purpose |
   |-------|---------|
   | `chat:write` | Send DMs |
   | `im:write` | Open DM channel |
   | `users:read` | Resolve display name for personalised header |
   | `users:read.email` | Resolve recipient by email (optional) |
4. Scroll up → **Install to Workspace** → **Allow**.
5. Copy the **Bot User OAuth Token** — starts with `xoxb-...`.
6. In Slack, search for **dotbot-local** under **Apps** and open a DM with it. This creates the DM channel so the bot can message you. Without this step delivery fails with `channel_not_found`.
7. Find your Slack User ID: click your name → **Profile** → **···** → **Copy member ID** — looks like `U012AB3CD`.

### 3. Configure `appsettings.Development.json`

ASP.NET Core loads `appsettings.json` first, then overlays `appsettings.{Environment}.json` (local dev defaults to `Development` via `launchSettings.json`), then environment variables. Put secrets (`BotToken`, `JwtSigningKey`) in the `Development` file — it's gitignored by default and never shipped to production. Using plain `appsettings.json` works too, but risks committing tokens.

Create `server/src/Dotbot.Server/appsettings.Development.json`:

```json
{
  "BlobStorage": {
    "ConnectionString": "UseDevelopmentStorage=true"
  },
  "ApiSecurity": {
    "ApiKey": "local-dev-key-12345"
  },
  "BaseUrl": "https://dotbot-local-XXXXX.euw.devtunnels.ms",
  "Auth": {
    "JwtSigningKey": "dev-only-signing-key-do-not-use-in-production-32chars!",
    "SeedAdministrators": [ "dev@localhost" ]
  },
  "TokenValidation": {
    "Enabled": false
  },
  "DeliveryChannels": {
    "Slack": {
      "Enabled": true,
      "BotToken": "xoxb-YOUR-TOKEN-HERE"
    }
  }
}
```

Replace `xoxb-YOUR-TOKEN-HERE` with the token from Step 2.5 and update `BaseUrl` with your devtunnel URL. `BaseUrl` is the origin used in the **Respond Now** button — a wrong URL here means the button 404s.

### 4. Run the server

```powershell
cd server/src/Dotbot.Server
dotnet run
# Expect: "Now listening on: http://localhost:5048"
```

Verify:

```powershell
Invoke-RestMethod "http://localhost:5048/api/health"
# → { status: "healthy", timestamp: "..." }
```

---

## Testing paths

Pick one (or run both). They share the setup above.

### Path A — Manual test via `Send-DotbotQuestion.ps1`

Fastest sanity check: push a single question to your Slack DM from the CLI, without involving a dotbot workflow.

**A.1. Create `server/.env.local`:**

```env
DOTBOT_QNA_API_KEY=local-dev-key-12345
DOTBOT_QNA_ENDPOINT=http://localhost:5048
```

Read by `Send-DotbotQuestion.ps1` so you don't have to pass `-ApiKey` on every call.

**A.2. Send the question:**

```powershell
cd server

.\Send-DotbotQuestion.ps1 `
    -BotUrl "http://localhost:5048" `
    -User "YOUR_SLACK_USER_ID" `
    -Question "Which database should we use?" `
    -Options @(
        @{ key = "A"; label = "PostgreSQL"; rationale = "Mature, open-source, great ecosystem" },
        @{ key = "B"; label = "SQLite";     rationale = "Simple, embedded, zero config" },
        @{ key = "C"; label = "CosmosDB";   rationale = "Azure-native, global distribution" }
    ) `
    -Channel "slack" `
    -ProjectName "My Test Project" `
    -ProjectDescription "Testing the dotbot Q&A channel" `
    -Wait
```

Replace `YOUR_SLACK_USER_ID` with the `U...` ID from Step 2.7.

Expected console output:

```
Publishing template '...'...  Template published.
Creating instance for channel 'slack'... Instance created.
   Sent to: 1 recipient(s)
Waiting for response (timeout: 300s)...
```

A card appears in your Slack DM from `dotbot-local` with the answer options shown in the message. Click **Respond Now** to choose an option; the script returns the choice and exits.

### Path B — Automated test via dotbot workflow

Exercises the real integration: a task parked at `needs-input` triggers `NotificationClient` → server → Slack, then `NotificationPoller` harvests the response back onto the task.

**B.1. Configure Mothership in your dotbot project**

[`NotificationClient.psm1`](../../core/mcp/modules/NotificationClient.psm1) reads the `mothership` section of merged dotbot settings (`Get-MergedSettings` → `settings.default.json` → `~/dotbot/user-settings.json` → `.bot/.control/settings.json`). Keys consumed: `enabled`, `server_url`, `api_key`, `channel`, `recipients`, `project_name`, `project_description`.

**Option 1 — Dashboard UI**: `.bot\go.ps1` → **Settings** → **Mothership**. Set Server URL, API Key, Channel = **Slack**, Recipients (one `U...` ID per line), Project Name/Description. Click **Test Connection** — green means `/api/health` reachable.

> **Known bug [#309](https://github.com/andresharpe/dotbot/issues/309)**: the UI save currently writes to `.bot/settings/settings.default.json` (framework-protected) instead of `.bot/.control/settings.json`. The next workflow run reverts it via `FrameworkIntegrity`, wiping your config. Until fixed, use Option 2 below.

**Option 2 — edit `.bot/.control/settings.json` directly** (gitignored overrides layer; survives `dotbot init --force`):

```json
{
  "mothership": {
    "enabled": true,
    "server_url": "http://localhost:5048",
    "api_key": "local-dev-key-12345",
    "channel": "slack",
    "recipients": [ "U012AB3CD" ],
    "project_name": "My Project",
    "project_description": "Shipping X",
    "sync_tasks": true,
    "sync_questions": true
  }
}
```

Field notes:
- `server_url`: same machine as server → `http://localhost:5048`. Different machine → use the devtunnel URL from Step 1.
- `api_key`: must match `ApiSecurity:ApiKey` in the server's `appsettings.Development.json`.
- `recipients`: Slack-only list. Entries with `@` route to the Email rail instead.

**B.2. Trigger a workflow that hits `needs-input`**

Run any dotbot flow that parks a task (analyser proposing a split, execution hitting a `pending_question`, etc.). The chain: `task-mark-needs-input` → `Send-TaskNotification` → `Send-ServerNotification` → `POST /api/templates` + `POST /api/instances` with `channel="slack"` + `recipients.slackUserIds` → `SlackDeliveryProvider.DeliverAsync` → DM. Response harvested by `NotificationPoller` and written back to the task state.

### Production / deployed server

When the server runs somewhere you can't drop `appsettings.Development.json` (App Service, container, systemd), provide the same values as environment variables (`:` → `__`):

```
DeliveryChannels__Slack__Enabled=true
DeliveryChannels__Slack__BotToken=xoxb-...
BaseUrl=https://<your-server>
ApiSecurity__ApiKey=<strong-secret>
```

Client-side Mothership config is identical; just point `server_url` at the deployed URL.

---

## Configuration Reference

All server settings resolve through `IConfiguration`, so each key has an equivalent environment variable using `__` as the separator.

| Setting | Env var | Notes |
|---------|---------|-------|
| `DeliveryChannels:Slack:Enabled` | `DeliveryChannels__Slack__Enabled` | `true` to register the Slack provider |
| `DeliveryChannels:Slack:BotToken` | `DeliveryChannels__Slack__BotToken` | `xoxb-...` from the Slack app install |
| `BaseUrl` | `BaseUrl` | Public URL used for the **Respond Now** magic link (devtunnel URL in local dev, App Service URL in prod) |

Required Slack bot token scopes: `chat:write`, `im:write`, `users:read`. Optional: `users:read.email` (only needed to resolve recipients by email).

Shape of `SlackChannelSettings` lives in [server/src/Dotbot.Server/Models/DeliveryChannelSettings.cs](../src/Dotbot.Server/Models/DeliveryChannelSettings.cs). The provider is in [server/src/Dotbot.Server/Services/Delivery/SlackDeliveryProvider.cs](../src/Dotbot.Server/Services/Delivery/SlackDeliveryProvider.cs) — it calls `https://slack.com/api/chat.postMessage` with a Bearer bot token and Block Kit payload.

---

## Troubleshooting

Slack's `chat.postMessage` returns HTTP 200 even when the send fails — the real status is in the JSON body's `ok` and `error` fields. The server logs the `error` string and surfaces it as `Slack API error: <code>` in the delivery result.

### `Slack bot token not configured`

→ `DeliveryChannels:Slack:BotToken` is empty or `Enabled=false`. Set the token, make sure `Enabled=true`, restart the server.

### `Slack API error: invalid_auth`

→ Token is wrong, revoked, or you added scopes without reinstalling the app. Go to **OAuth & Permissions** → **Reinstall to Workspace** → copy the new `xoxb-...` → update `appsettings.Development.json` → restart.

### `Slack API error: channel_not_found` / `not_in_channel`

→ No DM channel exists between the bot and the user. Open Slack → **Apps** → search `dotbot-local` → send any message. Retry delivery.

### `Slack API error: missing_scope`

→ Token lacks a required scope. Add it under **Bot Token Scopes**, **Reinstall to Workspace**, swap the token.

### `No Slack user ID for recipient`

→ The recipient payload is missing `slackUserId` / `slackUserIds`. Supply a real Slack user ID (`U012AB3CD`) — not an `@handle`, not an email.

### Delivery reports success but no DM arrives

→ User ID is malformed (must start with `U...`) or the user has blocked / muted the bot. Verify the ID is the **Member ID** from the user's Profile, not the display name.

### Quick probe — call Slack directly

```powershell
$token = "xoxb-YOUR-TOKEN-HERE"
$r = Invoke-RestMethod -Method Post -Uri "https://slack.com/api/chat.postMessage" `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType "application/json" `
    -Body (@{ channel = "U012AB3CD"; text = "ping from dotbot-local" } | ConvertTo-Json)
$r.ok       # True / False
$r.error    # null on success, error code on failure
```

If this fails, the problem is the token or Slack app config — not the Dotbot server.
