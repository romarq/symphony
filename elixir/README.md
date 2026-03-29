# Symphony Elixir

An Elixir/OTP orchestrator that connects a GitHub Projects V2 kanban board to AI coding agents. Symphony polls your board for issues, spins up isolated workspaces, and runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [Codex](https://github.com/openai/codex) against each one — moving cards across columns as work progresses.

Based on [`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls a GitHub Projects V2 board for issues in active columns (e.g., **Ready**, **In progress**)
2. Creates an isolated workspace per issue
3. Launches an agent (Claude Code or Codex) inside the workspace
4. Sends a workflow prompt — built from your `WORKFLOW.github.md` template — to the agent
5. Monitors the agent until the work is done, then moves the issue forward (e.g., to **In review**)

Issues are routed to agents by label (`claude` or `codex`), with a configurable default. If an issue moves to a terminal state (**Done**, **Closed**, **Cancelled**, or **Duplicate**), Symphony stops the active agent and cleans up the workspace.

## Quick start

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir

# Install Erlang & Elixir via mise
mise trust && mise install

# Fetch deps and build the escript
mise exec -- mix setup
mise exec -- mix build

# Authenticate GitHub with the required scopes
gh auth login
gh auth refresh -s project

# Launch Symphony (auto-detects GITHUB_TOKEN from gh CLI)
./run-github.sh
```

> [!TIP]
> `run-github.sh` validates prerequisites, resolves your GitHub token, and starts Symphony
> with `WORKFLOW.github.md`. Pass a custom path as the first argument:
> `./run-github.sh /path/to/MY_WORKFLOW.md`

## Prerequisites

| Dependency | Purpose | Install |
|---|---|---|
| [mise](https://mise.jdx.dev/) | Manages Erlang 28 + Elixir 1.19 | `curl https://mise.run \| sh` |
| `libssl-dev` | Required for Erlang's `:crypto` module | `apt install libssl-dev` / `brew install openssl` |
| [gh CLI](https://cli.github.com/) | GitHub authentication and API access | `apt install gh` / `brew install gh` |
| [claude CLI](https://docs.anthropic.com/en/docs/claude-code) | Claude Code agent backend | `npm install -g @anthropic-ai/claude-code` |

After installing system dependencies, run:

```bash
mise trust
mise install
mise exec -- elixir --version   # verify Elixir 1.19.x
```

## Setup

### 1. Create a GitHub Projects V2 board

Go to `https://github.com/users/<you>/projects` (or org-level) and create a project. Add columns matching your workflow states:

| Column | Who moves here | Meaning |
|---|---|---|
| **Ready** | Human | Issue is queued for the agent |
| **In progress** | Agent | Agent is actively working |
| **In review** | Agent | Agent finished, awaiting human review |
| **Done** | Human | Human accepted the result |

### 2. Authenticate Claude Code

Claude Code supports two authentication methods:

- **Interactive login** (local machine with a browser):

  ```bash
  claude auth login
  ```

- **Long-lived token** (servers, CI, headless environments):

  ```bash
  claude setup-token
  export CLAUDE_CODE_OAUTH_TOKEN="your-token-here"
  ```

Alternatively, use an Anthropic API key (pay-per-use, no subscription required):

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

### 3. Authenticate the `gh` CLI

```bash
gh auth login
gh auth refresh -s project
```

Required token scopes:

| Scope | Purpose |
|---|---|
| `repo` | Clone repos, push branches, create PRs, post comments |
| `project` | Read/write GitHub Projects V2 board (move columns) |

Verify with `gh auth status` — token scopes should include `repo` and `project`.

### 4. Configure the workflow

Edit `WORKFLOW.github.md` (or create your own). The file uses YAML front matter for configuration, plus a Markdown body used as the agent session prompt.

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

Title: {{ issue.title }}
Body: {{ issue.description }}
```

### 5. Run Symphony

```bash
# Option A: helper script (recommended)
./run-github.sh

# Option B: manual
GITHUB_TOKEN=$(gh auth token) mise exec -- mix run --no-start -e '
  Application.put_env(:symphony_elixir, :workflow_file_path, Path.expand("WORKFLOW.github.md"))
  {:ok, _} = Application.ensure_all_started(:symphony_elixir)
  Process.sleep(:infinity)
'
```

To follow logs in a second terminal:

```bash
./run-github.sh --logs
```

### 6. Start working

Move an issue to **Ready** on your kanban board. Symphony picks it up, creates a workspace, runs the agent, and moves the issue to **In review** when finished.

To request rework, move the issue back to **In progress** — the agent picks it up again and reads review comments for feedback.

## Configuration reference

### CLI flags

```
./bin/symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]
```

| Flag | Default | Description |
|---|---|---|
| `--logs-root` | `./log` | Directory for log files |
| `--port` | disabled | Start the Phoenix web dashboard on this port |
| *(positional)* | `./WORKFLOW.md` | Path to the workflow file |

### GitHub tracker fields

| Field | Required | Default | Description |
|---|---|---|---|
| `tracker.kind` | yes | — | Must be `github_project` |
| `tracker.project_owner` | yes | — | GitHub username or org owning the project |
| `tracker.project_number` | yes | — | Project number (from the project URL) |
| `tracker.repository` | no | all repos | Filter to issues from a specific `owner/repo` |
| `tracker.status_field_name` | no | `Status` | Name of the single-select kanban column field |
| `tracker.api_key` | no | `GITHUB_TOKEN` or `GH_TOKEN` env | GitHub personal access token |
| `tracker.active_states` | no | `["Todo", "In Progress"]` | Column names that trigger agent dispatch |
| `tracker.terminal_states` | no | `["Closed", "Cancelled", ...]` | Column names that stop agents |
| `tracker.assignee` | no | all | Filter to issues assigned to a user (`me` or a login) |

### Claude Code agent fields

| Field | Required | Default | Description |
|---|---|---|---|
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

### Codex agent fields

| Field | Required | Default | Description |
|---|---|---|---|
| `codex.command` | no | `codex app-server` | Shell command to start the Codex app server |
| `codex.approval_policy` | no | `{"reject":{...}}` | Approval policy passed to Codex |
| `codex.thread_sandbox` | no | `workspace-write` | Sandbox level: `read-only`, `workspace-write`, `danger-full-access` |
| `codex.turn_sandbox_policy` | no | workspace-scoped | Sandbox policy map passed through to Codex |

### General agent fields

| Field | Required | Default | Description |
|---|---|---|---|
| `agent.default` | no | `claude` | Default agent backend (`claude` or `codex`) |
| `agent.max_concurrent_agents` | no | `10` | Max parallel agent processes |
| `agent.max_turns` | no | `20` | Max back-to-back turns per agent invocation |
| `agent.routing.claude_label` | no | `claude` | Issue label that routes to Claude Code |
| `agent.routing.codex_label` | no | `codex` | Issue label that routes to Codex |

### Workflow file notes

- If the Markdown body is blank, Symphony uses a default prompt template with the issue identifier, title, and body.
- `hooks.after_create` bootstraps a fresh workspace (e.g., `git clone ... .`).
- Path values expand `~` to the home directory and `$VAR` from the environment.
- If the workflow file is missing or has invalid YAML at startup, Symphony does not boot.
- If a reload fails at runtime, Symphony keeps the last known good config and logs the error.

## Web dashboard

Enable the Phoenix LiveView dashboard by setting a port:

```yaml
server:
  port: 8080
```

Or via CLI: `./bin/symphony --port 8080`

Available endpoints:

| Path | Description |
|---|---|
| `/` | LiveView dashboard with real-time agent status |
| `/api/v1/state` | JSON snapshot of all tracked issues |
| `/api/v1/<issue_identifier>` | JSON detail for a single issue |
| `/api/v1/refresh` | Force a tracker poll |

## Project layout

```
lib/
  symphony_elixir/          # Core application
    claude/app_server.ex    # Claude Code agent backend
    codex/app_server.ex     # Codex agent backend
    github/                 # GitHub Projects V2 tracker
    config.ex               # Runtime configuration from WORKFLOW front matter
    orchestrator.ex         # Main supervision and issue lifecycle
    agent_runner.ex         # Agent process management
    workspace.ex            # Workspace creation and cleanup
    workflow.ex             # WORKFLOW.md parsing
  symphony_elixir_web/      # Phoenix web dashboard
    live/dashboard_live.ex  # LiveView dashboard
    controllers/            # JSON API endpoints
config/                     # Phoenix application config
test/                       # ExUnit tests
priv/static/                # Static assets
```

## Testing

Run the full quality gate (format check, lint, tests with coverage, dialyzer):

```bash
make all
```

Individual targets:

```bash
make test        # unit tests
make lint        # credo --strict + @spec check
make fmt         # format code
make fmt-check   # check formatting without modifying
make coverage    # tests with coverage report
make dialyzer    # static type analysis
```

## Troubleshooting

### `:crypto` module not available

```
** (UndefinedFunctionError) function :crypto.strong_rand_bytes/1 is undefined
   (module :crypto is not available)
```

Erlang was compiled without OpenSSL support. Install the development headers and rebuild:

```bash
# Ubuntu/Debian
sudo apt install libssl-dev

# macOS
brew install openssl

# Then reinstall Erlang
mise uninstall erlang
mise install
```

### `gh auth` missing project scope

```
Error: GraphQL: Resource not accessible by personal access token
```

Refresh your GitHub token with the required scope:

```bash
gh auth refresh -s project
```

### Claude CLI not authenticated

If agents fail immediately, ensure the `claude` CLI is authenticated:

```bash
# Interactive (with browser)
claude auth login

# Headless (token-based)
claude setup-token
export CLAUDE_CODE_OAUTH_TOKEN="your-token"
```

### Workflow file errors at startup

```
** Symphony does not boot
```

The YAML front matter in your workflow file is invalid. Validate it:

```bash
mise exec -- mix run -e 'IO.inspect(YamlElixir.read_from_file!("WORKFLOW.github.md"))'
```

### Agent stalls or times out

Agents have two timeout controls in the workflow config:

- `claude.turn_timeout_ms` (default: 3,600,000ms / 1 hour) — absolute deadline per turn
- `claude.stall_timeout_ms` (default: 300,000ms / 5 minutes) — kills the agent if no events are received

Lower these values if you want faster failure detection. Check logs for details:

```bash
./run-github.sh --logs
```

### Workspace permission errors

Symphony creates workspaces under the configured `workspace.root`. Ensure the directory exists and is writable:

```bash
mkdir -p ~/code/symphony-workspaces
```

### Port already in use

If the web dashboard fails to start, another process may be using the port:

```bash
lsof -i :<port>
# Or choose a different port
./bin/symphony --port 8081
```

## FAQ

### Why Elixir?

Elixir runs on Erlang/BEAM/OTP, which excels at supervising long-running processes. It supports hot code reloading without stopping active agents, which is useful during development.

### How do I set this up for my own codebase?

1. Fork or clone this repo
2. Copy `WORKFLOW.github.md` into your project and customize it
3. Set up a GitHub Projects V2 board with the expected columns
4. Run `./run-github.sh`

See the [Setup](#setup) section for detailed steps.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
