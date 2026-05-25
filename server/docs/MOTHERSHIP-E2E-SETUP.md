# Mothership E2E Test Setup (Playwright + Azurite)

How to run the Mothership web UI end-to-end tests locally. Tests cover the magic-link respond flow for all six question types: `singleChoice`, `multiChoice`, `approval`, `documentReview`, `freeText`, `priorityRanking`.

---

## Prerequisites

| Tool | Minimum version | Check |
|------|----------------|-------|
| .NET SDK | 9.0 | `dotnet --version` |
| Node.js + npm | 18+ | `node --version` |
| Azurite | any | `azurite --version` |
| Azure CLI | any recent | `az --version` |
| PowerShell | 7+ | `pwsh --version` |

Install Azurite if missing:

```powershell
npm install -g azurite
```

---

## One-time setup

### 1. Create Azurite data directory

```powershell
New-Item -ItemType Directory -Force C:\azurite
```

### 2. Seed blob containers

Azurite does not create containers automatically. Do this once (idempotent — safe to re-run):

```powershell
# Terminal 1 — start Azurite
azurite --skipApiVersionCheck --location C:\azurite

# Terminal 2 — seed containers
az storage container create --name answers                 --connection-string "UseDevelopmentStorage=true"
az storage container create --name conversation-references --connection-string "UseDevelopmentStorage=true"
```

---

## Running the tests

Every test session requires three terminals.

### Terminal 1 — Azurite

```powershell
azurite --skipApiVersionCheck --location C:\azurite
```

### Terminal 2 — DotbotServer (test mode)

```powershell
$env:BlobStorage__ConnectionString = "UseDevelopmentStorage=true"
cd server/src/Dotbot.Server
dotnet run --launch-profile http-test
```

Wait for:
```
[INF] DOTBOT_TEST_MODE is enabled - /api/test/* endpoints are live.
[INF] Now listening on: http://localhost:5048
```

### Terminal 3 — Playwright tests

```powershell
$env:DOTBOT_SERVER_URL = "http://localhost:5048"
$env:DOTBOT_API_KEY    = "mF/rHJQE/MQ3W0hIaKUL6GxsBxTsZpHvSRmDhIf3Udw="
pwsh tests/Test-E2E-Mothership-QA.ps1
```

---

## What the tests do

For each question type the script:

1. `POST /api/templates` — creates a template
2. Generates an `instanceId` (no real delivery — avoids SMTP/Teams dependency)
3. `POST /api/test/magic-link` — mints a JWT for `playwright-test@test.local`
4. Playwright navigates to the magic-link URL and asserts:
   - Question title is visible
   - Correct UI elements rendered per type (radio buttons, approve/reject, textarea, drag-and-drop list, etc.)
   - Submit redirects to confirmation page
5. `POST /api/test/responses` — injects a response directly (supports `selectedKey`, `freeText`, and `rankedItems`)
6. `GET /api/instances/.../responses` — asserts payload persisted correctly

---

## Viewing the HTML report

If any test fails:

```powershell
cd tests/e2e
npx playwright show-report
```

Traces and screenshots are saved under `tests/e2e/test-results/`.

---

## Watching tests run in the browser

Pass `-Headed` to the test runner — no config file changes needed:

```powershell
pwsh tests/Test-E2E-Mothership-QA.ps1 -Headed
```

This sets `PLAYWRIGHT_HEADED=1`, which `playwright.config.ts` reads to disable headless mode. CI never sets this variable, so it always runs headless.

---

## BlobStorage connection string

The server requires either `BlobStorage:AccountUri` or `BlobStorage:ConnectionString`. For local dev with Azurite, set the connection string via environment variable before starting the server:

```powershell
$env:BlobStorage__ConnectionString = "UseDevelopmentStorage=true"
```

Or add it to a local `appsettings.Development.json` (not checked in):

```json
"BlobStorage": {
  "ConnectionString": "UseDevelopmentStorage=true"
}
```

Do not use a full `127.0.0.1` Azurite connection string — the Azure CLI does not honour IP-based Azurite endpoints when a real Azure account is logged in.
