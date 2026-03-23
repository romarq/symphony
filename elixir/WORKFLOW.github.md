---
tracker:
  kind: github_project
  project_owner: RomarQ
  project_number: 1
  status_field_name: Status
  active_states:
    - Ready
    - In progress
  terminal_states:
    - Done
    - In review
server:
  port: 8080
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/RomarQ/the-forge .
    git config credential.helper '!gh auth git-credential'
    git config user.name "Symphony Agent"
    git config user.email "symphony@noreply.github.com"
agent:
  default: claude
  max_concurrent_agents: 1
  max_turns: 5
  routing:
    claude_label: claude
    codex_label: codex
claude:
  model: claude-sonnet-4-6
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a GitHub issue `{{ issue.identifier }}`

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Issue lifecycle

- **Ready** — the issue is queued for you. Move it to `In progress` before starting work.
- **In progress** — you are actively working. Stay in this state while implementing.
- **In review** — you are finished. Move the issue here when done. A human will review and either accept (move to `Done`) or send it back (move to `In progress`).
- **Done** — accepted by a human. You never move issues to `Done` yourself.

If the issue is already `In progress` when you start (e.g. sent back from review), read any existing comments for feedback and address them before moving back to `In review`.

## Instructions

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets).
3. Move the issue to `In progress` on the project board immediately when you start.
4. Post a **progress comment** on the issue right away (see format below). Update this same comment as you work — it is the primary way the user tracks what you are doing.
5. Do the work described in the issue thoroughly. Read code, make changes, run tests as needed.
6. Update the progress comment after each significant milestone (e.g. analysis done, changes committed, tests passing, PR opened).
7. If you make code changes:
   - Create a branch named after the issue (e.g. `the-forge-4-find-improvements`)
   - Commit your changes with clear messages
   - Push the branch and open a pull request with `gh pr create`
   - Link the PR to the issue by mentioning `Closes #<number>` in the PR body
8. Finalize the progress comment with a summary of what was done and any findings. Include the PR link if one was created.
9. **Only after** the comment is finalized, move the issue to `In review` on the project board. Never move it to `Done`.

IMPORTANT: Always post and update the progress comment throughout your work. It is the primary feedback mechanism for the user watching the issue.

Work only in the provided repository copy. Do not touch any other path.

## Progress comment format

Post this as the first comment when you start, then edit it in-place as you progress. Use `gh issue comment` to create and `gh api` to update.

```md
## Agent Progress

**Status:** 🔄 Working

### Plan
- [ ] Step 1
- [ ] Step 2

### Log
- `HH:MM` — Started working on the issue
- `HH:MM` — ...
```

When finished, update the status line to `✅ Done` and check off completed items. If blocked, use `🚫 Blocked — <reason>`.
