# PRD-03: Worktree rewrite

## Problem Statement

As a developer running workflows, I want a worktree to exist when (and only when) I have isolated work that needs to coexist with other work on the same repo. Today every prompt task gets its own worktree, the framework auto-merges via patch-replay onto main when a task completes, and the worktree machinery junctions seven shared directories from main — all of which couples me to a specific integration model and makes the worktree code hard to reason about.

## Solution

One worktree per WorkflowRun (when isolated). Workflows-of-one (standalone tasks) follow the same model. No junctions: the worktree is a pure git checkout, and the runtime resolves shared paths from the WorkflowRun record. No auto-merge: on completion the worktree directory is removed but the branch stays. The user merges manually via standard git. On cancellation the framework captures any uncommitted work as a final `wip:` commit so nothing is silently lost.

## User Stories

1. As a developer starting an isolated workflow, I want a fresh worktree at a predictable path that mirrors the run record's name, so that I can `cd` into it to inspect work in progress.
2. As a developer with several concurrent isolated runs, I want each to have its own worktree directory, so that they don't collide on the working tree.
3. As a developer inspecting a worktree, I want it to be a pure git checkout (no junctions, no symlinks to main), so that what I see is what's actually on the branch.
4. As a developer, I want the worktree path to mirror the on-disk run directory name (date prefix + slug + 4-char ID), so that the worktree and the run record are visually linked.
5. As a developer, I want the branch to be named `workflow/<slug>-<4charID>` (or `task/<slug>-<4charID>` for standalone), so that PR titles and `git branch` listings stay clean.
6. As a developer whose run completes successfully, I want the worktree directory removed automatically, so that completed runs don't pile up under `../worktrees/`.
7. As a developer whose run completes successfully, I want the branch to remain, so that I can decide when and how to integrate (squash-merge, push, PR, or discard).
8. As a developer who wants to integrate, I want to use standard git commands (`git merge --squash`, `git push`, `gh pr create`), so that integration matches my team's normal workflow.
9. As a developer cancelling a run, I want any uncommitted work captured as a final commit on the branch, so that nothing the agent did is silently lost.
10. As a developer cancelling a run, I want the worktree directory removed afterwards, so that the cleanup is symmetric with success.
11. As a developer whose run failed, I want the branch to stay around for forensics, so that I can inspect `git log` to understand what was attempted.
12. As a developer accumulating many old branches, I want a `prune-branches` command, so that I can clean up branches older than a threshold.
13. As a developer running `prune-branches --dry-run`, I want to see what would be deleted before anything happens, so that I can verify the selection.
14. As a developer with a no-git directory, I want the runtime to refuse an isolated run with a clear error, so that I'm told to either `git init` or flip the workflow to non-isolated.
15. As a developer with parallel tasks within a workflow, I want them to share the run's worktree, so that the runtime doesn't have to merge their commits across sibling worktrees.

## Implementation Decisions

A worktree exists if and only if the parent WorkflowRun has `isolated: true`. The runtime owns its lifecycle and tracks the path on the WorkflowRun record (`worktree_path`, `branch_name`).

Naming:
- Worktree directory: `<repo-parent>/worktrees/<repo-leaf>/<YYYY-MM-DD>-<slug>-<4charID>/`. Mirrors the on-disk run directory under `workspace/tasks/workflow-runs/`.
- Branch: `workflow/<slug>-<4charID>` for workflow runs, `task/<slug>-<4charID>` for standalone tasks.

Branched always from the project's main integration branch (resolved via the same logic v4 uses for `Resolve-MainBranch`).

`Dotbot.Worktree` is rewritten to a smaller surface:
- Create a per-run worktree.
- Read the worktree path from the WorkflowRun record.
- Tear down: success path = remove worktree directory. Cancel/fail path = stage and commit any uncommitted work as a single `wip:` commit, then remove the directory. Branch is always preserved.
- Prune branches matching `workflow/*` or `task/*` older than a threshold, skipping the currently checked-out branch.

No junction setup. No `worktree-map.json`. No patch-replay logic. No HITL escalation for rebase conflicts (the runtime never auto-merges, so there's no conflict path to escalate).

Within an isolated run, parallel tasks share the worktree directory. Tasks are responsible for not colliding on overlapping paths; the `depends_on` graph is the mechanism to serialise when needed. Each task's commits are made directly to the workflow branch from inside the shared worktree.

Cancellation flow:
1. Mark WorkflowRun as `cancelled` (or `failed`).
2. Signal child processes to terminate; wait a short grace period (default 30s).
3. In the worktree: `git add -A`; if changes exist, `git commit -m "wip: <reason> at <iso-timestamp>"`.
4. Remove the worktree directory via `git worktree remove --force`.
5. Persist the run's completed_at; the `worktree_path` on the record is preserved for historical reference even though the directory no longer exists.

`dotbot prune-branches` accepts `--older-than <duration>` (default `30d`), `--match <workflow|task|all>` (default `all`), and `--dry-run`. Lists candidates; prompts for confirmation unless `--dry-run`; never deletes the currently checked-out branch on any worktree; reports each branch's last-commit date and merged status.

Git-ready precondition (the actual check fires here, not in PRD-02): `.git/` exists AND `git rev-list --count HEAD > 0`. On failure the worktree create call returns the standard refusal message.

## Testing Decisions

A good test for this module operates against a temporary git repo and asserts on the on-disk and git state afterwards. Tests should not poke at internal helpers; they should drive the public surface (create-worktree, complete-worktree, prune-branches) and inspect what's left on disk.

Modules to be tested:
- **Dotbot.Worktree** (path/branch derivation) — pure function tests: given a run record, what path and branch name result. No git needed.
- **Dotbot.Worktree** (lifecycle) — integration tests against a tmp git repo: create per-run worktree; verify path, branch, no junctions; complete with success; verify dir removed and branch present; complete with cancel after dirtying the worktree; verify wip commit present and dir removed.
- **Dotbot.Worktree** (parallel runs) — start two isolated runs at the same time; verify each has its own worktree path; both branches exist independently.
- **Dotbot.Worktree** (prune-branches selection) — pure selection logic given a list of branches and a threshold; assert which would be deleted.
- **Dotbot.Worktree** (git-ready refusal) — tmp non-git directory; attempt isolated worktree creation; assert the specific refusal error.

Prior art: today's `tests/Test-Worktree*.ps1` (if present on v4) is the pattern, but most of those tests assert on junction state — those assertions are now invalid. The new tests are simpler because the new worktree is simpler. Use `New-Item -ItemType Directory -Path "$env:TEMP/dotbot-test-..."` + `git init` + `git commit --allow-empty -m initial` to seed the tmp repo.

## Out of Scope

- Worktree creation/cleanup timing within the WorkflowRun lifecycle: hooks in PRD-06 trigger create on `enter-in-progress` (idempotent) and removal on terminal transitions.
- The `isolated` flag itself: defined in PRD-02.
- Migration of existing per-task worktrees from v4: not supported (greenfield rewrite per PRD-02's `Further Notes`). Stale worktrees left behind are cleaned up by `dotbot prune-branches` plus a manual `git worktree prune`.
- Pushing branches to remote: framework never pushes. Users push manually.

## Further Notes

- `Dotbot.Worktree` should shrink substantially (current v4 file is 57 KB; target is well under half that). The reduction comes from removing junction setup, patch-replay logic, conflict classification, and per-task worktree-map bookkeeping.
- The default cancellation grace period (30s) is hard-coded for now. Make it a setting later if a slow workflow needs more.
- Open question for implementor: should `prune-branches` consider remote tracking refs (don't delete a branch with an `origin/` counterpart)? Proposal: yes — skip branches that have a remote ref unless `--force`.
