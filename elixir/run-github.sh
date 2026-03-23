#!/usr/bin/env bash
#
# Run Symphony with Claude Code and a GitHub Projects V2 kanban board.
#
# Usage:
#   ./run-github.sh                          # uses WORKFLOW.github.md in this directory
#   ./run-github.sh /path/to/WORKFLOW.md     # uses a custom workflow file
#   ./run-github.sh --logs                   # tail the log file (run in a second terminal)
#
# Prerequisites:
#   - mise (https://mise.jdx.dev/) with Elixir/Erlang installed
#   - gh CLI authenticated with `project` scope:
#       gh auth refresh -s read:project -s project
#   - claude CLI installed and authenticated
#
# Environment variables (optional):
#   GITHUB_TOKEN              GitHub personal access token (falls back to `gh auth token`)
#   CLAUDE_CODE_OAUTH_TOKEN   Claude subscription token (from `claude setup-token`)
#   ANTHROPIC_API_KEY         Anthropic API key (alternative to OAuth token)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="$SCRIPT_DIR/log"

# --- Handle --logs flag (tail mode) -----------------------------------------

if [[ "${1:-}" == "--logs" ]]; then
  latest_log=$(ls -t "$LOG_DIR"/symphony.log.* 2>/dev/null | grep -v '\.idx$\|\.siz$' | head -1)
  if [[ -z "$latest_log" ]]; then
    echo "No log files found in $LOG_DIR" >&2
    echo "Start Symphony first, then run: ./run-github.sh --logs" >&2
    exit 1
  fi
  echo "Tailing $latest_log (Ctrl+C to stop)"
  echo "---"
  tail -f "$latest_log"
  exit 0
fi

# --- Resolve workflow file ---------------------------------------------------

WORKFLOW_FILE="${1:-WORKFLOW.github.md}"
if [[ ! "$WORKFLOW_FILE" = /* ]]; then
  WORKFLOW_FILE="$SCRIPT_DIR/$WORKFLOW_FILE"
fi

if [[ ! -f "$WORKFLOW_FILE" ]]; then
  echo "Error: Workflow file not found: $WORKFLOW_FILE" >&2
  echo "Create one from WORKFLOW.github.md or pass a path as the first argument." >&2
  exit 1
fi

# --- Resolve GitHub token ----------------------------------------------------

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  if command -v gh &>/dev/null; then
    GITHUB_TOKEN="$(gh auth token 2>/dev/null)" || true
  fi
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Error: GITHUB_TOKEN is not set and could not be resolved from gh CLI." >&2
  echo "Run: gh auth login   or   export GITHUB_TOKEN=ghp_..." >&2
  exit 1
fi

export GITHUB_TOKEN

# --- Preflight checks --------------------------------------------------------

if ! command -v mise &>/dev/null; then
  echo "Error: mise not found. Install from https://mise.jdx.dev/" >&2
  exit 1
fi

if ! command -v claude &>/dev/null; then
  echo "Warning: claude CLI not found in PATH. Claude agent runs will fail." >&2
fi

# --- Build if needed ---------------------------------------------------------

if [[ ! -d "_build" ]]; then
  echo "First run: installing dependencies and building..."
  mise exec -- mix setup
fi

# --- Start Symphony ----------------------------------------------------------

echo "Starting Symphony with workflow: $WORKFLOW_FILE"
echo "GitHub token: ${GITHUB_TOKEN:0:4}****"
echo "Logs: $LOG_DIR/symphony.log.*"
echo ""
echo "To follow logs in another terminal:"
echo "  ./run-github.sh --logs"
echo ""

exec mise exec -- mix run --no-start -e "
  Application.put_env(:symphony_elixir, :workflow_file_path, Path.expand(\"$WORKFLOW_FILE\"))
  {:ok, _} = Application.ensure_all_started(:symphony_elixir)
  Process.sleep(:infinity)
"
