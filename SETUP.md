# Setup Guide

Reference for the dotbot triage workflow infrastructure. Initial setup was completed on 2026-04-10.

## GitHub Project

[Dotbot v4 Roadmap](https://github.com/users/andresharpe/projects/2)

### Status field

Single-select **Status** with these stages (in order):

1. Inbox - new issue or PR, not yet looked at
2. Triage - being reviewed by the steering group
3. Spec/Design - needs a PRD or design before it is buildable
4. Ready - triaged and ready for a contributor to pick up
5. In Progress - actively being worked on
6. In Review - PR open and under review
7. Done - merged and shipped

### Custom fields

- **PRD link** (text) - URL to the product requirements document
- **Design link** (text) - URL to Figma/design artifact
- **Size** (single-select) - XS, S, M, L, XL

### Built-in project workflows (enabled)

- **Auto-add to project** - any new issue or PR in `andresharpe/dotbot` (filter: `is:issue,pr is:open`)
- **Item added to project** -> Status = Inbox
- **Item closed** -> Status = Done
- **Pull request merged** -> Status = Done
- **Pull request linked to issue** -> Status = In Review

### Saved views (to be created as needed)

- **Triage queue** - filter: label = needs-triage
- **Up for grabs** - filter: Status = Ready, sort by Size
- **In flight** - filter: Status in (In Progress, In Review)

## Repo settings

### Branch protection on `main`

- Require a pull request before merging
- Require 1 approval, dismiss stale reviews
- Require status check: `PR link check / check`

### General

- Automatically delete head branches: enabled

## Discord webhooks

Four webhooks are provisioned on the dotbot Discord server and stored as GitHub Actions secrets:

| GitHub secret | Discord channel | Webhook name | Fires on |
|---|---|---|---|
| `DISCORD_DEVOPS_WEBHOOK` | #devops | GitHub - New Issues | New issue opened |
| `DISCORD_ADVISORY_WEBHOOK` | #advisory-steering | GitHub - Triage & Stale | Triage nudge (weekday cron), weekly stale digest |
| `DISCORD_CONTRIBUTORS_WEBHOOK` | #contributors | GitHub - Ready for Pickup | Issue labelled `ready` |
| `DISCORD_PR_WEBHOOK` | #pull-requests | GitHub - PR Activity | PR opened, ready for review, merged, closed |

### Re-provisioning webhooks

If a webhook URL is rotated or lost, re-run the provisioning script (local tooling, gitignored):

```bash
cd ideas/team/discord-setup
npm install
npm run webhooks
```

Requires `DISCORD_BOT_TOKEN` env var (KeePassXC: `APIs/discord/dotbot-bot`). The script is idempotent - it reuses existing webhooks by name. Copy the printed URLs into the matching GitHub Actions secrets.

## GitHub Actions workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `notify-new-issue.yml` | `issues.opened` | Posts embed to #devops |
| `triage-nudge.yml` | Weekday cron 07:00 UTC + manual | Queries `needs-triage` issues idle 2+ days, posts to #advisory-steering |
| `notify-ready.yml` | `issues.labeled` (ready) | Posts to #ap-contributors with size/tags |
| `notify-pr.yml` | `pull_request` (opened, ready, closed) | Posts to #pull-requests |
| `pr-link-check.yml` | `pull_request_target` (opened, edited, sync) | Fails if no `Closes/Fixes/Resolves #N`; override with `no-issue` label |
| `stale.yml` | Monday cron 07:00 UTC + manual | Marks stale issues, posts weekly digest to #advisory-steering |
| `sync-labels.yml` | Push to main (labels.yml changed) + manual | Syncs `.github/labels.yml` to repo labels |

## Labels

Managed in `.github/labels.yml` and synced via the `sync-labels` workflow. Categories:

- **Status** (blue) - needs-triage, ready, in-progress, blocked, help-wanted, good-first-issue
- **Type** (purple) - type:feature, type:bug, type:question, type:chore, type:docs
- **Size** (grey) - size:xs, size:s, size:m, size:l, size:xl
- **Resolution** (red/brown) - wontfix, duplicate, needs-info, stale, stale-triage
- **Workflow** (yellow) - no-issue, pinned
