# Dotbot Multi-Channel Notification PoC

Sends multi-choice questions to stakeholders over Teams, Email, Jira, or Slack and stores answers in Azure Blob Storage. Built with the M365 Agents SDK (C# / .NET 9) and deployed to Azure App Service.

## Architecture

The server exposes `POST /api/notify` and delivers to any enabled channels. Teams routes answers back through the Bot Service via `/api/messages`; Email, Jira, and Slack include a magic-link URL that points recipients to the `/respond` Razor Page. Either way, the answer is persisted to Azure Blob Storage.

### Email / Jira / Slack delivery flow (magic link)

```
[PowerShell / dotbot] ──POST──▶ [App Service /api/notify]
                                          │
                                  Per-channel payload (all include magic-link URL):
                                    • Email — Microsoft Graph sendMail (HTML)
                                    • Jira  — REST comment on issue
                                    • Slack — chat.postMessage (Block Kit)
                                          │
[Recipient] ◀──────────────────────────────┘
    │ clicks magic link
    ▼
[/respond Razor Page] ──▶ Stores answer to Azure Blob Storage
```

### Teams delivery flow

```
[PowerShell / dotbot] ──POST──▶ [App Service /api/notify]
                                          │
                                  Sends Adaptive Card
                                          │
[Teams User] ◀──Card──────────────────────┘
    │ clicks choice
    ▼
[Teams] ──▶ [Bot Service] ──▶ [App Service /api/messages]
                                          │
                                  Stores answer to Azure Blob Storage
                                  Sends confirmation card
```

## Prerequisites

**Local development** (run the server against Azurite, no real Azure resources):

- .NET 9 SDK
- Azure CLI (`az`) - used by `Seed-AzuriteContainers.ps1` to create the local blob containers
- Docker or Podman - runs the Azurite blob storage emulator

**Production deploy** (everything above, plus):

- Terraform >= 1.6
- Azure subscription (APPS_EU_TEST)
- Permission to create Entra ID app registrations and Bot Service resources

## Setup

### 1. Provision Infrastructure

```powershell
cd terraform

# Create terraform.tfvars with required variables (see terraform.tfvars.example for full list)
@"
subscription_id = "<YOUR_AZURE_SUBSCRIPTION_ID>"
api_key         = "<YOUR_API_KEY>"
"@ | Set-Content terraform.tfvars

terraform init
terraform plan
terraform apply
```

If using an existing Entra ID app instead of letting Terraform create one, also set `create_azuread_app = false`, `microsoft_app_id`, and `microsoft_app_password` in your tfvars.

This creates: Resource Group, Entra ID App, App Service Plan, App Service, Bot Service + Teams channel.

### 2. Configure Local Development

Create `src/Dotbot.Server/appsettings.Development.json` (gitignored). For local Azurite development, you can do this without running Terraform; use placeholder `MicrosoftApp*` values if you only need local dashboard testing. For production-style Bot Service testing, use the values from `terraform apply`. Start from `appsettings.Example.json` (Serilog + minimal `Auth` block) and add the keys below — these are required at startup and the server will throw `InvalidOperationException` without them:

- `MicrosoftAppTenantId`, `MicrosoftAppId`, `MicrosoftAppPassword` — top-level keys read by the Agents SDK (`Program.cs` / Bot Service auth)
- `BlobStorage:AccountUri` **or** `BlobStorage:ConnectionString` - one is required (`Program.cs:92`). For local dev, set `ConnectionString` to the Azurite emulator (see step 3); production uses `AccountUri` with managed identity.
- `ApiSecurity:ApiKey` — shared secret for the `X-Api-Key` header (`ApiKeyMiddleware.cs`)
- `TokenValidation:{Audiences,TenantId}` + `Connections:ServiceConnection:Settings:{ClientId,ClientSecret,TenantId}` — mirror the structure in the committed `appsettings.json` (use `{{MicrosoftAppId}}`-style tokens there, or paste the real values into `appsettings.Development.json`)
- `DeliveryChannels:{Email,Jira,Slack}` — only needed if you enable that channel; schema lives in `Models/DeliveryChannelSettings.cs`
- `Auth:SeedAdministrators` — see the admin-seed callout below; **must include `"dev@localhost"` for local login to work**.

> **Local admin seed (required for dashboard login).**
> In `Development`, the `DevelopmentAuthMiddleware` injects `dev@localhost` as the current user. The server's `AdministratorService` checks that email against the `Auth:SeedAdministrators` list, which is persisted to the `answers/dev/config/administrators.json` blob on first startup. If `dev@localhost` is not in that list, every dashboard request fails with `Access denied: dev@localhost is not an administrator`.
>
> In `appsettings.Development.json`:
>
> ```json
> "Auth": {
>   "SeedAdministrators": [ "dev@localhost" ]
> }
> ```
>
> The blob is only seeded when absent. If you change the list after the blob has been written, delete the blob and restart the server so the seed re-runs:
>
> ```powershell
> az storage blob delete `
>   --container-name answers `
>   --name dev/config/administrators.json `
>   --connection-string "UseDevelopmentStorage=true" `
>   --auth-mode key
> ```

Get the bot credentials from Terraform:

```powershell
terraform output -raw azuread_app_id
terraform output -raw azuread_app_password
```

User-secrets (`dotnet user-secrets set "ApiSecurity:ApiKey" "…"`) work too and keep secrets off disk.

### 3. Start Azurite (local blob storage)

Local dev uses [Azurite](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azurite), the official Microsoft emulator for Azure Blob / Queue / Table storage. The server reads from two blob containers on startup (`answers`, `conversation-references`) and does not call `CreateIfNotExists`, so a fresh Azurite returns `404 ContainerNotFound` until the containers are seeded once.

Default Azurite ports: `10000` (blob), `10001` (queue), `10002` (table). Use the short emulator connection string in `appsettings.Development.json`:

```json
"BlobStorage": {
  "AccountUri": "",
  "ConnectionString": "UseDevelopmentStorage=true",
  "Backend": "AzureBlob",
  "MaxAttachmentSizeMb": 15
}
```

`UseDevelopmentStorage=true` is the standard Azurite shortcut understood by both the .NET `BlobServiceClient` and `az storage`. Avoid the long `DefaultEndpointsProtocol=http;...;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;...` form - the trailing `/devstoreaccount1` path in `BlobEndpoint` makes some SDK versions compute a different canonical resource than Azurite expects, producing `AuthorizationFailure` (403) that surfaces as the misleading "request may be blocked by network rules" message from Azure CLI.

**Run Azurite in a container.** Pick the runtime you have installed.

The published ports below are explicitly bound to `127.0.0.1` so the emulator (which serves unauthenticated traffic with a well-known key) is not exposed to the LAN. `--skipApiVersionCheck` is included so Azurite accepts newer `x-ms-version` headers from current Azure SDKs / Azure CLI - without it, requests fail with `The API version YYYY-MM-DD is not supported by Azurite` whenever the SDK is newer than the Azurite image.

Docker:

```powershell
docker run -d --name azurite `
  -p 127.0.0.1:10000:10000 -p 127.0.0.1:10001:10001 -p 127.0.0.1:10002:10002 `
  -v azurite-data:/data `
  mcr.microsoft.com/azure-storage/azurite `
  azurite --blobHost 0.0.0.0 --queueHost 0.0.0.0 --tableHost 0.0.0.0 --location /data --skipApiVersionCheck
```

Podman:

```powershell
podman run -d --name azurite `
  -p 127.0.0.1:10000:10000 -p 127.0.0.1:10001:10001 -p 127.0.0.1:10002:10002 `
  -v azurite-data:/data `
  mcr.microsoft.com/azure-storage/azurite `
  azurite --blobHost 0.0.0.0 --queueHost 0.0.0.0 --tableHost 0.0.0.0 --location /data --skipApiVersionCheck
```

The named volume (`azurite-data`) keeps blobs across container restarts. Subsequent runs: `docker start azurite` / `podman start azurite`.

**Seed the containers.** Run once per fresh Azurite data volume:

```powershell
.\scripts\Seed-AzuriteContainers.ps1
```

`Seed-AzuriteContainers.ps1` reads `BlobStorage:ConnectionString` from `appsettings.Development.json`, pings the blob endpoint, and creates both `answers` and `conversation-references` containers via `az storage container create` (idempotent - safe to re-run).

### 4. Run Locally

```powershell
dotnet run --project src/Dotbot.Server
```

Use [dev tunnels](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/) or ngrok to expose `http://localhost:5048` to the internet, then update the Bot Service messaging endpoint.

### 5. Deploy to Azure

```powershell
.\scripts\Deploy.ps1
```

### 6. Test

- Open Teams → chat with "Dotbot" → send any message → receive question card → pick answer
- Proactive: `.\Send-DotbotQuestion.ps1 -User <aad-id-or-email> -Question "Pick one" -Options @(@{ key='A'; label='Option A' }, @{ key='B'; label='Option B' })` (see `SampleQuestions.json` for full payloads)

## Project Structure

```
server/
├── src/Dotbot.Server/        # C# bot application
│   ├── DotbotAgent.cs          # Core bot logic
│   ├── Services/               # Card builder, response storage, convo refs
│   └── Models/                 # QuestionOption, StoredResponse, Envelope/ (SPEC-029 wire)
├── terraform/                  # Azure infrastructure
├── teams-app/                  # Teams app icons (color.png, outline.png)
├── scripts/                    # Deploy, icon generation
└── Send-DotbotQuestion.ps1     # Proactive messaging trigger
```

## Answer Format

Each answer is persisted as a minimal, **flat** `ResponseRecordV2` JSON blob in Azure
Blob Storage (container `answers`). The question and recipients are NOT duplicated on
the response blob, and the storage record is deliberately decoupled from the SPEC-029
wire DTOs - answer/responder fields sit at the top level, and wire-only concerns
(`status`, `agreesWithFirst`) are never persisted:

```json
{
  "responseId": "00000000-0000-0000-0000-000000000001",
  "instanceId": "00000000-0000-0000-0000-000000000002",
  "questionId": "00000000-0000-0000-0000-000000000003",
  "projectId": "dotbot",
  "submittedAt": "2026-04-16T19:30:00Z",
  "answeredVia": "mothership",
  "selectedKey": "A",
  "selectedOptionTitle": "PostgreSQL",
  "responderEmail": "andre@example.com",
  "responderAadObjectId": "abc-123"
}
```

On read, `GET /api/instances/{projectId}/{questionId}/{questionInstanceId}/responses`
assembles each blob into the full SPEC-029 envelope
(`{ envelope, question, answer, responder }`) via `EnvelopeAssembler` - mapping the flat
fields into the nested `answer`/`responder` sections, adding `answer.status`, and
deriving `envelope.agreesWithFirst` per record for dual-surface conflict detection.
