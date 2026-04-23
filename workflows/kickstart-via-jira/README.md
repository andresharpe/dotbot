# kickstart-via-jira

Research-driven initiative workflow. Fetches Jira/Confluence context, runs multi-source research across internet, Atlassian, and org repositories, synthesises findings, plans implementation across multiple repos, and produces handoff documents and draft PRs.

## Prerequisites

**CLI tools** (must be on PATH):
- [PowerShell 7+](https://aka.ms/powershell)
- [git](https://git-scm.com/downloads)
- [Azure CLI](https://aka.ms/installazurecliwindows) (`az`)
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code)

**MCP servers** (register before init):
- `atlassian` — required for Jira + Confluence access
- `sourcebot` — required by this workflow's preflight checks in the UI; used for cross-repo code search if your org runs [Sourcebot](https://sourcebot.dev)

## Setup

### 1. Create a project directory

```powershell
mkdir my-initiative
cd my-initiative
git init
```

### 2. Initialise dotbot with this workflow

```powershell
dotbot init -Workflow kickstart-via-jira
```

This creates `.bot/`, scaffolds `.env.local`, registers the dotbot MCP server, and creates a `repos/` directory for cloned repositories.

### 3. Configure environment variables

Edit `.env.local` in the project root:

| Variable | Value | Where to get it |
|----------|-------|----------------|
| `ATLASSIAN_EMAIL` | Your Atlassian login email | Your Atlassian account |
| `ATLASSIAN_API_TOKEN` | API token | [id.atlassian.com](https://id.atlassian.com/manage-profile/security/api-tokens) → Create API token |
| `ATLASSIAN_CLOUD_ID` | Your Jira site URL | Open Jira in browser — copy `https://yourcompany.atlassian.net` |
| `AZURE_DEVOPS_PAT` | Personal Access Token | `https://dev.azure.com/YOUR_ORG/_usersSettings/tokens` — scopes: Code (Read & Write) + Packaging (Read) |
| `AZURE_DEVOPS_ORG_URL` | Org URL | `https://dev.azure.com/YOUR_ORG` |

### 4. Register the Atlassian MCP server

```powershell
claude mcp add --transport http atlassian -s user https://mcp.atlassian.com/v1/mcp
```

In a Claude Code session, run `/mcp` → select `atlassian` → authenticate via OAuth browser flow.

### 5. Register Sourcebot

If your org runs a self-hosted Sourcebot instance:

```powershell
claude mcp add --transport http sourcebot -s user https://YOUR_SOURCEBOT_URL/mcp
```

Alternatively, use the npm package:

```powershell
claude mcp add sourcebot -s user -- npx -y @sourcebot/mcp@latest
```

### 6. Launch the web UI

```powershell
.bot\go.ps1          # opens http://localhost:8686
```

## Running a kickstart

1. Run the workflow from the Overview tab
2. Paste a Jira epic key (e.g. `ABC-1234`) into the prompt field
3. Click **Kickstart**

### Finding a Jira key

Open any epic in Jira. The key is shown top-left of the issue and in the URL:
`https://yourcompany.atlassian.net/browse/ABC-1234` → key is `ABC-1234`

Use a parent epic, not a subtask. The workflow fetches the epic and all its children automatically.

### Clarifying questions

At certain phases, the workflow may pause and show an **◈ Action Required** widget (bottom-right of UI). Answer the questions and the workflow resumes automatically.

## Pipeline phases

| # | Phase | What happens | External writes? |
|---|-------|-------------|-----------------|
| 0 | Fetch Jira Context | Reads Jira issue, child issues, Confluence pages | No |
| 0.5 | Generate Product Documents | Writes `mission.md`, `roadmap-overview.md` locally | No |
| 1a | Plan Internet Research | Creates internet research task | No |
| 1b | Plan Atlassian Research | Creates Atlassian research task | No |
| 1c | Plan Sourcebot Research | Creates Sourcebot research task (skipped if no Sourcebot) | No |
| — | Execute Research | Barrier — sync point between research task creation and deep-dive planning | No |
| 2a | Create Deep-Dive Tasks | Creates one per-repo analysis task per affected repo | No |
| — | Execute Deep Dives | Barrier — sync point between deep-dive task creation and research synthesis | No |
| 3 | Synthesise Research | Merges all research into a summary locally | No |
| 3b | Publish to Jira | Creates child Jira issue, posts research as comments | **Yes** |
| 4 | Research Repositories | Synthesises deep dives into implementation guide locally | No |
| 5 | Refine Dependencies | Writes cross-repo dependency map locally | No |
| 6 | Generate Implementation Plans | Writes per-repo code-level plans locally | No |
| 7 | Create Implementation Tasks | Creates per-repo implementation tasks locally | No |
| — | Execute Implementation | Barrier — sync point between implementation task creation and remediation | No |
| 9 | Remediate Builds | Fixes build/test failures in local cloned repos | No |
| 10 | Draft Handoff & PRs | Pushes branches, creates draft PRs in Azure DevOps | **Yes** |

Phases with **Yes** are visible to your team. All others are local-only — safe to run freely.

## Outputs

Initiative-level outputs land in `.bot/workspace/product/`. Per-repo outputs land inside each cloned repository under `repos/{RepoName}/.bot/workspace/product/`.

| File | Created by |
|------|-----------|
| `briefing/jira-context.md` | Fetch Jira Context |
| `mission.md` | Generate Product Documents |
| `roadmap-overview.md` | Generate Product Documents |
| `research-internet.md` | Internet research task |
| `research-documents.md` | Atlassian research task |
| `research-repos.md` | Sourcebot research task (or seeded from briefing) |
| `research-summary.md` | Synthesise Research |
| `briefing/04_IMPLEMENTATION_RESEARCH.md` | Research Repositories |
| `briefing/05_DEPENDENCY_MAP.md` | Refine Dependencies |
| `repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md` | Generate Implementation Plans |
| `repos/{RepoName}/.bot/workspace/product/{RepoName}_Outcomes.md` | Execute Implementation |
| `repos/{RepoName}/.bot/workspace/product/{RepoName}_Remediation.md` | Remediate Builds |
| `repos/{RepoName}/.bot/workspace/product/{RepoName}-handoff.md` | Draft Handoff & PRs |
