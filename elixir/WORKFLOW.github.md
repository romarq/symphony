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
    git config credential.helper '!gh auth git-credential'
    git config user.name "Symphony Agent"
    git config user.email "symphony@noreply.github.com"
agent:
  default: claude
  max_concurrent_agents: 5
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
4. Post a **progress comment** on the issue (see "Progress comment" section below). Save the comment ID — you will update this same comment throughout your work.
5. Do the work described in the issue thoroughly. Read code, make changes, run tests as needed.
6. Update the progress comment after each significant milestone (e.g. analysis done, changes committed, tests passing, PR opened).
7. If you make code changes, follow the "Pull requests" section below.
8. Finalize the progress comment with a summary of what was done. Include the PR link if one was created.
9. **Only after** the comment is finalized, move the issue to `In review` on the project board. Never move it to `Done`.

Work only in the provided repository copy. Do not touch any other path.

## Progress comment

Post a comment when you start, then **edit that same comment** as you progress. Never post multiple progress comments — always update the original.

To create the initial comment and capture its ID:

```bash
COMMENT_URL=$(gh issue comment <NUMBER> -R <OWNER/REPO> --body "## Agent Progress

**Status:** 🔄 Working

### Plan
- [ ] Analyze the issue
- [ ] Implement changes
- [ ] Verify and test

### Log
- \`$(date +%H:%M)\` — Started working" 2>&1 | grep -o 'https://[^ ]*')

COMMENT_ID=$(echo "$COMMENT_URL" | grep -o '[0-9]*$')
```

To update the comment in-place:

```bash
gh api repos/<OWNER/REPO>/issues/comments/$COMMENT_ID -X PATCH -f body="## Agent Progress

**Status:** 🔄 Working

### Plan
- [x] Analyze the issue
- [ ] Implement changes
- [ ] Verify and test

### Log
- \`14:00\` — Started working
- \`14:05\` — Analysis complete, found 3 issues
- \`14:15\` — Implementing fixes..."
```

When finished, set status to `✅ Done` and check off all items. If blocked, use `🚫 Blocked — <reason>`.

## Pull requests

Before creating a PR, always check if one already exists for this issue:

```bash
# Check for existing PRs from this repo
EXISTING_PR=$(gh pr list -R <OWNER/REPO> --head "<BRANCH_NAME>" --json number --jq '.[0].number' 2>/dev/null)
```

If a PR exists, push to the same branch and it will update automatically. Only create a new PR if none exists.

When creating a PR, always target the same repository (never the upstream parent):

```bash
git checkout -b <BRANCH_NAME>
# ... make changes, commit ...
git push -u origin <BRANCH_NAME>
gh pr create -R <OWNER/REPO> --head <BRANCH_NAME> --base main \
  --title "Short title" --body "Closes #<NUMBER>"
```

### Push permission denied — fork and PR

If `git push` fails with a permission error (e.g. the workspace was cloned from a repo where you don't have write access), fork the repo and open a PR from the fork:

```bash
# Fork the repo under your GitHub account
gh repo fork <OWNER/REPO> --clone=false

# Add the fork as a remote
FORK_OWNER=$(gh api user --jq '.login')
git remote add fork "https://github.com/$FORK_OWNER/<REPO>.git"

# Push to the fork
git push fork <BRANCH_NAME>

# Open a PR from the fork against the upstream repo
gh pr create --repo <OWNER/REPO> --head "$FORK_OWNER:<BRANCH_NAME>" --base main \
  --title "Short title" --body "Closes #<NUMBER>"
```

IMPORTANT:
- Always pass `-R <OWNER/REPO>` to `gh pr create` to ensure it targets the correct repository.
- Always pass `--base main` to ensure it targets the main branch, not an upstream fork.
- Check for existing PRs and branches before creating new ones.
- If push is denied, always fork and open a PR from the fork rather than stopping.
