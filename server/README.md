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

- .NET 9 SDK
- Azure CLI (`az`)
- Terraform >= 1.6
- Azure subscription (APPS_EU_TEST)

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

After `terraform apply`, create `src/Dotbot.Server/appsettings.Development.json` (gitignored). Start from `appsettings.Example.json` (Serilog + minimal `Auth` block) and add the keys below — these are required at startup and the server will throw `InvalidOperationException` without them:

- `MicrosoftAppTenantId`, `MicrosoftAppId`, `MicrosoftAppPassword` — top-level keys read by the Agents SDK (`Program.cs` / Bot Service auth)
- `BlobStorage:AccountUri` **or** `BlobStorage:ConnectionString` — one is required (`Program.cs:92`)
- `ApiSecurity:ApiKey` — shared secret for the `X-Api-Key` header (`ApiKeyMiddleware.cs`)
- `TokenValidation:{Audiences,TenantId}` + `Connections:ServiceConnection:Settings:{ClientId,ClientSecret,TenantId}` — mirror the structure in the committed `appsettings.json` (use `{{MicrosoftAppId}}`-style tokens there, or paste the real values into `appsettings.Development.json`)
- `DeliveryChannels:{Email,Jira,Slack}` — only needed if you enable that channel; schema lives in `Models/DeliveryChannelSettings.cs`

Get the bot credentials from Terraform:

```powershell
terraform output -raw azuread_app_id
terraform output -raw azuread_app_password
```

User-secrets (`dotnet user-secrets set "ApiSecurity:ApiKey" "…"`) work too and keep secrets off disk.

### 3. Run Locally

```powershell
dotnet run --project src/Dotbot.Server
```

Use [dev tunnels](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/) or ngrok to expose `http://localhost:5048` to the internet, then update the Bot Service messaging endpoint.

### 4. Deploy to Azure

```powershell
.\scripts\Deploy.ps1
```

### 5. Test

- Open Teams → chat with "Dotbot" → send any message → receive question card → pick answer
- Proactive: `.\Send-DotbotQuestion.ps1 -User <aad-id-or-email> -Question "Pick one" -Options @(@{ key='A'; label='Option A' }, @{ key='B'; label='Option B' })` (see `SampleQuestions.json` for full payloads)

## Project Structure

```
server/
├── src/Dotbot.Server/        # C# bot application
│   ├── DotbotAgent.cs          # Core bot logic
│   ├── Services/               # Card builder, response storage, convo refs
│   └── Models/                 # QuestionOption, ResponseRecordV2
├── terraform/                  # Azure infrastructure
├── teams-app/                  # Teams app icons (color.png, outline.png)
├── scripts/                    # Deploy, icon generation
└── Send-DotbotQuestion.ps1     # Proactive messaging trigger
```

## Answer Format

Each answer is persisted as a `ResponseRecordV2` JSON blob in Azure Blob Storage (container `answers`):

```json
{
  "responseId": "00000000-0000-0000-0000-000000000001",
  "instanceId": "00000000-0000-0000-0000-000000000002",
  "questionId": "00000000-0000-0000-0000-000000000003",
  "questionVersion": 1,
  "projectId": "dotbot",
  "responderEmail": "andre@example.com",
  "responderAadObjectId": "abc-123",
  "selectedKey": "A",
  "selectedOptionTitle": "PostgreSQL",
  "freeText": null,
  "submittedAt": "2026-04-16T19:30:00Z",
  "status": "submitted"
}
```
