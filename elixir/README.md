# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls a tracker (Linear or GitHub Projects V2) for candidate work
2. Creates a workspace per issue
3. Launches an agent (Claude Code or Codex) inside the workspace
4. Sends a workflow prompt to the agent
5. Keeps the agent working on the issue until the work is done

Supports two agent backends:
- **Claude Code** (default) — spawns the `claude` CLI with streaming JSON events
- **Codex** — uses the Codex App Server protocol

Supports two issue trackers:
- **Linear** — polls a Linear project for issues
- **GitHub Projects V2** — polls a GitHub kanban board for issues

Issues are routed to agents by label (`claude` or `codex` labels), with a configurable default.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Using GitHub Projects V2 with Claude Code

Symphony can use a GitHub Projects V2 kanban board instead of Linear, with Claude Code as the agent.
Issues are tracked by their kanban column (the "Status" field), not by GitHub's open/closed state.

### Quick start

```bash
cd symphony/elixir
mise trust && mise install
mise exec -- mix setup

# Ensure gh CLI has project scopes
gh auth refresh -s read:project -s project

# Run with the included script
./run-github.sh
```

The script auto-detects your GitHub token from `gh auth token`, validates prerequisites, and starts
Symphony with `WORKFLOW.github.md`.

### Setup

1. **Create a GitHub Projects V2 board** at `https://github.com/users/<you>/projects` (or org-level).
   Add columns matching your workflow states (e.g., `Ready`, `In progress`, `In review`, `Done`).

2. **Install the `claude` CLI** and authenticate it.

   Claude Code supports two authentication methods:

   - **Interactive login** (local machine with a browser):

     ```bash
     claude auth login
     ```

     This stores credentials in the system keychain. Spawned agents inherit them automatically.

   - **Long-lived token** (servers, CI, headless environments):

     ```bash
     claude setup-token
     ```

     This generates a token tied to your Claude subscription (Max/Pro). Export it as an
     environment variable before starting Symphony:

     ```bash
     export CLAUDE_CODE_OAUTH_TOKEN="your-token-here"
     ```

     The spawned `claude` processes will pick it up automatically. This is the recommended
     approach for unattended deployments where no browser is available.

   Alternatively, you can use an Anthropic API key (pay-per-use, no subscription required):

   ```bash
   export ANTHROPIC_API_KEY="sk-ant-..."
   ```

3. **Grant `gh` CLI project access:**

   ```bash
   gh auth refresh -s read:project -s project
   ```

4. **Create `WORKFLOW.github.md`** (or edit the included one):

   ```md
   ---
   tracker:
     kind: github_project
     project_owner: your-username       # GitHub user or org that owns the project
     project_number: 1                  # project number from the URL
     repository: your-username/your-repo # optional — filter to issues from one repo
     status_field_name: Status          # name of the single-select kanban field
     active_states:
       - Ready
       - In progress
     terminal_states:
       - Done
       - In review
   polling:
     interval_ms: 5000
   workspace:
     root: ~/code/symphony-workspaces
   hooks:
     after_create: |
       git clone --depth 1 https://github.com/your-username/your-repo .
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
   ---

   You are working on GitHub issue {{ issue.identifier }}.
   ...
   ```

5. **Enable the web dashboard** (optional) by adding `server.port` to the WORKFLOW config:

   ```yaml
   server:
     port: 8080
   ```

6. **Run Symphony:**

   ```bash
   # Option A: use the helper script (auto-detects GITHUB_TOKEN)
   ./run-github.sh

   # Option B: run manually
   GITHUB_TOKEN=$(gh auth token) mise exec -- mix run --no-start -e '
     Application.put_env(:symphony_elixir, :workflow_file_path, Path.expand("WORKFLOW.github.md"))
     {:ok, _} = Application.ensure_all_started(:symphony_elixir)
     Process.sleep(:infinity)
   '
   ```

   To follow logs in a second terminal: `./run-github.sh --logs`

7. **Move an issue to "Ready"** on your kanban board. Symphony will pick it up, create a workspace,
   run the Claude agent, and move it to "In review" when finished.

### Issue lifecycle

The expected kanban columns and their roles:

| Column | Who moves here | Meaning |
|--------|---------------|---------|
| **Ready** | Human | Issue is queued for the agent |
| **In progress** | Agent | Agent is actively working |
| **In review** | Agent | Agent is finished, awaiting human review |
| **Done** | Human | Human accepted the result |

- The agent picks up issues in **Ready** or **In progress** (active states).
- When done, the agent moves the issue to **In review** and stops.
- A human reviews and either moves to **Done** (accepted) or back to **In progress** (rework needed).
- If moved back to **In progress**, the agent picks it up again and reads review comments for feedback.

### GitHub tracker configuration reference

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `tracker.kind` | yes | — | Must be `github_project` |
| `tracker.project_owner` | yes | — | GitHub username or org owning the project |
| `tracker.project_number` | yes | — | Project number (from the project URL) |
| `tracker.repository` | no | all repos | Filter to issues from a specific `owner/repo` |
| `tracker.status_field_name` | no | `Status` | Name of the single-select kanban column field |
| `tracker.api_key` | no | `GITHUB_TOKEN` or `GH_TOKEN` env | GitHub personal access token |
| `tracker.active_states` | no | `["Todo", "In Progress"]` | Column names that trigger agent dispatch |
| `tracker.terminal_states` | no | `["Closed", "Cancelled", ...]` | Column names that stop agents |
| `tracker.assignee` | no | all | Filter to issues assigned to a user (`me` or a login) |

### Claude Code agent configuration reference

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `claude.model` | no | `claude-sonnet-4-6` | Claude model to use |
| `claude.fallback_model` | no | — | Fallback model when primary is overloaded |
| `claude.max_budget_usd` | no | — | Cost cap per agent turn |
| `claude.max_turns` | no | — | Max internal turns per CLI invocation |
| `claude.permission_mode` | no | `bypassPermissions` | Permission mode for the CLI |
| `claude.allowed_tools` | no | all | List of tools to allow |
| `claude.disallowed_tools` | no | none | List of tools to block |
| `claude.system_prompt` | no | — | Custom system prompt (appended to defaults) |
| `claude.turn_timeout_ms` | no | `3600000` | Absolute turn deadline (ms) |
| `claude.stall_timeout_ms` | no | `300000` | Kill agent if no events for this long (ms) |

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
