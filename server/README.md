# Dotbot Teams Bot PoC

A Teams bot that sends multi-choice questions to users via 1:1 chat and stores answers as JSON. Built with the M365 Agents SDK (C# / .NET 9) and deployed to Azure App Service.

## Architecture

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
                                  Stores answer JSON
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

After `terraform apply`, update `src/Dotbot.Server/appsettings.Development.json` with the output values:

```powershell
# Get the app credentials
terraform output -raw azuread_app_id
terraform output -raw azuread_app_password
```

### 3. Run Locally

```powershell
dotnet run --project src/Dotbot.Server
```

Use [dev tunnels](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/) or ngrok to expose `https://localhost:5001` to the internet, then update the Bot Service messaging endpoint.

### 4. Deploy to Azure

```powershell
.\scripts\Deploy.ps1
```

### 5. Test

- Open Teams → chat with "Dotbot" → send any message → receive question card → pick answer
- Proactive: `.\Send-DotbotQuestion.ps1 -BotUrl <url> -UserObjectId <id> -Question "Pick one" -Choices @("A","B","C")`

## Project Structure

```
DotbotServer/
├── src/Dotbot.Server/        # C# bot application
│   ├── DotbotAgent.cs          # Core bot logic
│   ├── Services/               # Card builder, response storage, convo refs
│   └── Models/                 # QuestionOption, ResponseRecordV2
├── terraform/                  # Azure infrastructure
├── teams-app/                  # Teams manifest + icons
├── scripts/                    # Deploy, icon generation
├── Send-DotbotQuestion.ps1     # Proactive messaging trigger
└── answers/                    # Stored answers (JSON)
```

## Answer Format

```json
{
  "questionId": "q-20260216-001",
  "question": "Which database should we use?",
  "choices": ["PostgreSQL", "SQLite", "CosmosDB"],
  "selectedChoice": "PostgreSQL",
  "selectedIndex": 0,
  "userId": "abc-123",
  "userName": "Andre",
  "timestamp": "2026-02-16T19:30:00Z"
}
```
