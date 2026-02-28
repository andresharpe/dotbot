# Validation Task 6: UI Provider Selector & Dynamic Models

## Scope
Validate the web UI provider selector, dynamic model loading, and the /api/providers endpoint.

## Files to Review
- `profiles/default/systems/ui/modules/SettingsAPI.psm1` (Get-ProviderList, Set-ActiveProvider)
- `profiles/default/systems/ui/server.ps1` (/api/providers route)
- `profiles/default/systems/ui/static/modules/controls.js` (provider selector, dynamic models)
- `profiles/default/systems/ui/static/index.html` (provider section)

## Checks

### API: GET /api/providers
- [ ] Returns `providers` array with all three providers
- [ ] Each provider has `name`, `display_name`, `installed` (bool)
- [ ] `installed` correctly reflects whether CLI is on PATH
- [ ] Returns `active` field matching current settings
- [ ] Returns `models` array for the active provider
- [ ] Each model has `id`, `name`, `badge` (nullable), `description`

### API: POST /api/providers
- [ ] Accepts `{ "provider": "codex" }` and updates settings
- [ ] Returns updated provider list (same shape as GET)
- [ ] Rejects unknown provider names with 400 error
- [ ] Rejects missing provider field with 400 error
- [ ] Persists change to `settings.default.json`

### SettingsAPI.psm1
- [ ] `Get-ProviderList` reads all JSON files from `defaults/providers/`
- [ ] `Get-ProviderList` checks CLI installation with `Get-Command`
- [ ] `Set-ActiveProvider` validates provider exists before saving
- [ ] `Set-ActiveProvider` updates `provider` field in settings JSON
- [ ] Both functions exported in `Export-ModuleMember`

### server.ps1
- [ ] `/api/providers` route handles GET and POST
- [ ] Correct content type set
- [ ] Error handling wraps POST body parsing

### controls.js
- [ ] `ANALYSIS_MODEL_OPTIONS` and `EXECUTION_MODEL_OPTIONS` are now `let` (not `const`)
- [ ] `loadProviderData()` fetches from `/api/providers`
- [ ] Models populated from API response, not hardcoded
- [ ] Fallback to Claude defaults if API fails
- [ ] `initProviderSelector()` renders provider grid
- [ ] Active provider highlighted, non-installed providers show "Not installed" badge
- [ ] Clicking a provider POSTs to `/api/providers`, re-renders models
- [ ] `initSettingsToggles()` calls `loadProviderData()`

### index.html
- [ ] "Provider" nav item added between "Theme" and "Analysis Phase"
- [ ] Provider settings section has `id="settings-provider"`
- [ ] Provider grid container has `id="provider-grid"`
- [ ] "Claude model" text changed to "Model" in both analysis and execution sections

## How to Test
```bash
# Start the web UI
pwsh .bot/go.ps1

# Test API directly
curl http://localhost:8686/api/providers
curl -X POST -H "Content-Type: application/json" -d '{"provider":"codex"}' http://localhost:8686/api/providers

# Then open browser to http://localhost:8686
# Navigate to Settings > Provider tab
# Verify provider cards render
# Click a different provider
# Check Analysis/Execution model grids update
```
