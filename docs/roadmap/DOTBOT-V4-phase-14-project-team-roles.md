# Phase 14: Project Team & Roles

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Concept

Project team members and their roles become first-class dotbot entities, stored in the workspace and queryable via MCP tools. This replaces the flat `recipients` list in settings with a structured team registry that drives Q&A routing, decision stakeholder assignment, review requests, and notification targeting.

## Team member record

Stored at `.bot/workspace/team/{member-id}.json`:

```json
{
  "id": "tm-a1b2c3d4",
  "name": "André Sharpe",
  "email": "andre@org.com",
  "aliases": {
    "github": "andresharpe",
    "azure_devops": "andre@org.com",
    "jira": "andre.sharpe",
    "slack": "U12345ABC",
    "discord": "andre#1234"
  },
  "roles": ["lead", "architect"],
  "domains": ["backend", "infrastructure", "database"],
  "channels": {
    "primary": "teams",
    "fallback": ["email"],
    "preferences": {
      "business_hours_only": true,
      "batch_notifications": false
    }
  },
  "availability": {
    "status": "active",
    "out_of_office_until": null,
    "delegate": null
  },
  "added_at": "2026-03-14T10:00:00Z",
  "added_by": "system"
}
```

## Role definitions

Roles are defined in a registry at `.bot/workspace/team/roles.json`:

```json
{
  "roles": [
    {
      "id": "lead",
      "name": "Project Lead",
      "description": "Overall project ownership and final sign-off authority",
      "permissions": ["approve-decisions", "approve-questionnaires", "manage-team"],
      "auto_include_in": ["decision.high_impact", "questionnaire.*"]
    },
    {
      "id": "architect",
      "name": "Architect",
      "description": "Technical architecture decisions and design review",
      "permissions": ["approve-decisions"],
      "auto_include_in": ["decision.architecture", "decision.technical"]
    },
    {
      "id": "developer",
      "name": "Developer",
      "description": "Implementation and code review",
      "permissions": [],
      "auto_include_in": []
    },
    {
      "id": "reviewer",
      "name": "Reviewer",
      "description": "Code and design review only",
      "permissions": ["review"],
      "auto_include_in": ["review.*"]
    },
    {
      "id": "stakeholder",
      "name": "Stakeholder",
      "description": "Business stakeholder — receives updates, provides input on business decisions",
      "permissions": ["approve-decisions"],
      "auto_include_in": ["decision.business", "questionnaire.kickstart"]
    },
    {
      "id": "qa",
      "name": "QA Engineer",
      "description": "Test strategy and quality assurance",
      "permissions": ["review"],
      "auto_include_in": ["review.test-plan"]
    }
  ]
}
```

## How team drives other systems

### Q&A routing (Phase 13 integration)

Instead of a flat `recipients` list, questions can target **roles** or **domains**:

```powershell
# MCP tool: task-mark-needs-input
Invoke-TaskMarkNeedsInput -TaskId $id -Question @{
    question = "Should we use PostgreSQL or SQL Server?"
    target = @{
        roles = @("architect", "lead")       # Send to all architects and leads
        domains = @("database")              # Also send to database domain experts
        specific = @("andre@org.com")        # Plus specific individuals
    }
}
```

The outpost resolves targets to actual team members:
```powershell
# Resolve-QuestionRecipients in MothershipClient.psm1
$architects = Get-TeamMembers -Role "architect"
$dbExperts = Get-TeamMembers -Domain "database"
$recipients = ($architects + $dbExperts + $specific) | Select-Object -Unique
```

Each resolved member's channel preferences are used for delivery — no more single `channel` setting for all recipients.

### Decision stakeholders (Phase 5 integration)

When creating decisions, stakeholders are resolved from the team registry:

```json
{
  "id": "dec-abc123",
  "stakeholders": {
    "by_role": ["architect", "lead"],
    "by_domain": ["backend"],
    "specific": ["andre@org.com"],
    "resolved": ["tm-a1b2c3d4", "tm-e5f6g7h8"]
  }
}
```

Decisions with `auto_include_in` matching role rules automatically include the right people — no manual stakeholder assignment needed for standard decision types.

### Review requests

Team roles enable targeted review routing:
```powershell
# Request architecture review from architects
Send-ReviewRequest -Type "architecture" -Links @(
    @{ title = "PR #42"; url = "https://..."; type = "pull-request" }
) -TargetRoles @("architect", "reviewer")
```

### Availability and delegation

When a team member is out of office:
- Questions route to their `delegate` if specified
- If no delegate, questions route to other members with the same role
- Dashboard shows availability status

## MCP tools

- `team-add -Name <string> -Email <string> -Roles <array> -Domains <array>` — add team member
- `team-remove -MemberId <string>` — remove team member
- `team-update -MemberId <string> -Updates <hashtable>` — update member details
- `team-list [-Role <string>] [-Domain <string>]` — list team members, filter by role/domain
- `team-get -MemberId <string>` — get member details
- `team-set-availability -MemberId <string> -Status <string> [-OutOfOfficeUntil <date>] [-Delegate <string>]`
- `role-list` — list defined roles and their permissions
- `role-create -Id <string> -Name <string> -Description <string> -Permissions <array>`

## Web UI

**"Team" tab** in the dashboard:
- Team member list with roles, domains, availability status
- Add/edit/remove members
- Role management
- Channel preference configuration per member
- Availability calendar view

**API module:** `systems/ui/modules/TeamAPI.psm1`

## Prompt integration

Team context is available to analysis and execution prompts:

```markdown
<!-- In 98-analyse-task.md -->
## Project Team Context
Review the project team registry to understand:
- Who are the architects and domain experts relevant to this task?
- Are there decisions that need specific stakeholder sign-off?
- Route any questions to the appropriate roles, not generic recipients
```

## Mothership sync

Team registries sync to the Mothership for:
- **Cross-project team visibility** — see who is assigned across all outposts
- **Org-wide role resolution** — `lead` in project A might also be `stakeholder` in project B
- **Centralized availability** — OOO status visible fleet-wide

```json
POST /api/fleet/{instance_id}/team
{
  "members": [ ... ],
  "roles": [ ... ]
}
```

## Settings

```json
"team": {
  "sync_to_mothership": true,
  "auto_resolve_from_git": true,
  "default_channel": "teams"
}
```

When `auto_resolve_from_git` is true, `dotbot init` scans git log to suggest initial team members based on commit authors.

## Events

- `team.member_added`, `team.member_removed`, `team.member_updated`
- `team.availability_changed`
- `team.role_created`, `team.role_updated`

## Files

- Create: `profiles/default/systems/mcp/tools/team-{add,remove,update,list,get,set-availability}/` (6 tools)
- Create: `profiles/default/systems/mcp/tools/role-{list,create}/` (2 tools)
- Create: `profiles/default/systems/ui/modules/TeamAPI.psm1`
- Modify: `profiles/default/systems/mcp/modules/NotificationClient.psm1` / `MothershipClient.psm1` — role-based recipient resolution
- Modify: `profiles/default/systems/mcp/tools/task-mark-needs-input/` — add `target` with role/domain routing
- Modify: Decision tools — auto-resolve stakeholders from team registry
- Modify: `profiles/default/defaults/settings.default.json` — add `team` section
- Modify: Prompt files — inject team context
- Add to init: `workspace/team/`, `workspace/team/roles.json`
- Server: Add team sync endpoint to `FleetController`
