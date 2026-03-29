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
  max_turns: 20
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

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the issue is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
{% endif %}

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

## Default posture

- Start by determining the issue's current status, then follow the matching flow for that status.
- Open the progress comment and bring it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Keep issue metadata current (state, progress comment checklist).
- Treat the single persistent progress comment as the source of truth for all progress and handoff notes. Do not post separate summary comments.
- Treat any `Validation`, `Test Plan`, or `Testing` section in the issue description as non-negotiable acceptance input: mirror it in the progress comment and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered, file a separate GitHub issue instead of expanding current scope.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.

## Related skills

- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.

## Step 0: Determine current issue state and route

1. Read the current issue state.
2. Route to the matching flow:
   - `Ready` — immediately move to `In progress`, ensure the progress comment exists (create if missing), then start the execution flow.
     - If a PR is already attached, start by reviewing all open PR comments before new implementation work.
   - `In progress` — continue execution from the current progress comment state.
   - `In review` — do not code or change issue content; wait and poll for human decision.
   - `Done` — terminal state; do nothing and shut down.
3. Check whether a PR already exists for the current branch and whether it is closed or merged.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run. Create a fresh branch from `origin/main` and restart execution.
4. For `Ready` issues, do startup sequencing in this exact order:
   - Move issue to `In progress`.
   - Find or create the progress comment.
   - Only then begin analysis, planning, and implementation.

## Step 1: Start/continue execution

1. Find or create a single persistent progress comment for the issue:
   - Search existing comments for a marker header: `## Agent Progress`.
   - If found, reuse that comment; do not create a new one.
   - If not found, create one and use it for all updates.
   - Persist the comment ID and only write progress updates to that ID.
2. Immediately reconcile the progress comment before new edits:
   - Check off items that are already done.
   - Expand the plan so it is comprehensive for the current scope.
   - Ensure `Acceptance Criteria` and `Validation` are current.
3. Write or update a hierarchical plan in the progress comment.
4. Add explicit acceptance criteria and TODOs in checklist form in the same comment.
   - If the issue description includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the `Acceptance Criteria` and `Validation` sections as required checkboxes.
5. Before implementing, capture a concrete reproduction signal and record it in the comment's `Notes` section when applicable.
6. Run the `pull` skill to sync with latest `origin/main` before any code edits.

## PR feedback sweep protocol (required)

When an issue has an attached PR, run this protocol before moving to `In review`:

1. Identify the PR number from issue links or comments.
2. Gather feedback from all channels:
   - Top-level PR comments: `gh pr view --comments`
   - Inline review comments: `gh api repos/<owner>/<repo>/pulls/<pr>/comments`
   - Review summaries: `gh pr view --json reviews`
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the progress comment checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or auth/permissions that cannot be resolved in-session.

- GitHub auth is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then fork-and-PR flow).
- Do not move to `In review` for GitHub access/auth issues until all fallback strategies have been attempted and documented.
- If a required tool is missing or required auth is unavailable after exhausting fallbacks, move the issue to `In review` with a short blocker brief in the progress comment that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.

## Step 2: Execution phase

1. Determine current repo state (`branch`, `git status`, `HEAD`) and verify the sync with `origin/main` is recorded in the progress comment before implementation continues.
2. Load the existing progress comment and treat it as the active execution checklist.
   - Edit it whenever reality changes (scope, risks, validation approach, discovered tasks).
3. Implement against the hierarchical TODOs and keep the comment current:
   - Check off completed items immediately.
   - Add newly discovered items in the appropriate section.
   - Update the comment after each meaningful milestone (reproduction complete, code change landed, validation run, review feedback addressed).
4. Run validation/tests required for the scope.
   - Mandatory gate: execute all issue-provided `Validation`/`Test Plan`/`Testing` requirements when present.
   - Prefer targeted proof that directly demonstrates the behavior you changed.
   - Revert every temporary proof edit before committing.
   - Document validation steps and outcomes in the progress comment.
5. Re-check all acceptance criteria and close any gaps.
6. Before every `git push`, run the required validation for your scope and confirm it passes; if it fails, fix and rerun until green.
7. When creating a PR, follow the "Pull requests" section below.
8. Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
9. Update the progress comment with final checklist status and validation notes.
   - Mark completed plan/acceptance/validation items as checked.
   - Add final handoff notes (commit + validation summary).
   - Do not post any additional completion summary comment.
10. Before moving to `In review`, run the full PR feedback sweep protocol.
    - Confirm PR checks are passing after the latest changes.
    - Confirm every required validation item is explicitly marked complete.
    - Repeat the check-address-verify loop until no outstanding comments remain.
11. Only then move issue to `In review`.

## Step 3: Human review handling

1. When the issue is in `In review`, do not code or change issue content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If the issue is sent back to `In progress`, read all new feedback comments, then follow the execution flow to address them.

## Completion bar before `In review`

- Progress comment checklist is fully complete and accurately reflects completed work.
- Acceptance criteria and all required issue-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state. Create a new branch from `origin/main` and restart.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent progress comment (`## Agent Progress`) per issue.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate GitHub issue rather than expanding current scope.
- Do not move to `In review` unless the `Completion bar` is satisfied.
- If state is terminal (`Done`), do nothing and shut down.

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

### Acceptance Criteria
- [ ] ...

### Validation
- [ ] ...

### Notes
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

### Acceptance Criteria
- [ ] ...

### Validation
- [ ] targeted tests: \`<command>\`

### Notes
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
