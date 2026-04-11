# Contributing to dotbot

Thanks for your interest in contributing. This guide explains how we work so you can jump in quickly.

## 1. File an issue

Every piece of work starts as a GitHub issue. Use the templates:

- **Feature request** - new capability or improvement
- **Bug report** - something broken or unexpected
- **Question** - when you need a paper trail (for quick questions, try Discord first)

[Open a new issue](https://github.com/andresharpe/dotbot/issues/new/choose)

## 2. Triage

A senior group (the advisory-steering crew) reviews new issues on a Tue/Fri cadence. They decide whether to close, ask for more info, send to spec/design, or mark as ready. You don't need to do anything here - just wait for your issue to move through the board.

## 3. Find work

Two ways to find something to work on:

- **Project board** - filter by Status = `Ready`, sort by size. [View the board](https://github.com/users/andresharpe/projects/2)
- **Discord** - watch `#contributors` for notifications when items move to Ready.

Look for `good-first-issue` and `help-wanted` labels if you're new.

## 4. Claim it

1. Self-assign the issue on GitHub.
2. Move the card to **In Progress** on the project board.
3. That's it - you own it now.

## 5. Submit a PR

### Branch naming

Use the pattern `type/short-description`:

```
feature/webhook-notifications
bugfix/null-ref-on-startup
chore/update-deps
docs/triage-playbook
```

### Commits

Write clear, imperative commit messages. Keep commits focused - one logical change per commit.

### Linking issues

Every PR must reference the issue it closes. Add one of these to the PR body:

```
Closes #42
Fixes #42
Resolves #42
```

PRs without a linked issue will fail the `pr-link-check` CI step. For trivial changes, ask a maintainer to add the `no-issue` label.

### The PR template

The template will prompt you for: linked issue, summary, screenshots (for UI changes), testing notes, and a checklist. Fill it out - it helps reviewers move fast.

### Review

Someone from the team will review your PR. Address feedback, push updates, and once approved it gets merged. The project card moves to **Done** automatically.

## 6. After merge

Your PR closes the linked issue. The card moves to Done. The change ships in the next release. That's the full cycle.

## Discord channels

We coordinate on the dotbot Discord server. Here's the channel map:

- `#general` - questions, chat, general discussion
- `#contributors` - work up for grabs, claim threads
- `#pull-requests` - PR activity notifications
- `#devops` - issue firehose, CI/CD discussion
- `#architecture`, `#ui-design`, `#documentation` - deeper discussion by area
- `#advisory-steering`, `#roadmap`, `#decisions-adrs` - governance (read-mostly for contributors)

## Code of conduct

Be respectful, be direct, and assume good intent. We're building something together.
