defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Spawns Claude Code CLI as a subprocess and parses stream-json events.

  Design choices:
  - Process-group isolation via `setsid` to prevent orphan processes.
  - Prompt delivered via temp file + stdin redirection (avoids ENAMETOOLONG).
  - Session resume via `--resume` for multi-turn continuations.
  - Dual timeout: absolute turn deadline + stall detection that resets per event.
  - Cache-aware usage tracking for accurate cost reporting.
  """

  require Logger
  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576

  # --- Public API ---

  @spec run_turn(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(workspace, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    worker_host = Keyword.get(opts, :worker_host)
    session_id = Keyword.get(opts, :session_id)
    claude_settings = Config.claude_settings()

    cli_args = build_cli_args(claude_settings, session_id: session_id)

    case start_port(workspace, cli_args, prompt, worker_host) do
      {:ok, port, os_pid} ->
        try do
          collect_events(port, on_message, port_metadata(port, os_pid, worker_host), issue, claude_settings)
        after
          stop_port(port, os_pid)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec parse_event(String.t()) ::
          {:session_started, map()}
          | {:assistant_message, map()}
          | {:turn_completed, map()}
          | {:turn_failed, map()}
          | {:rate_limit, map()}
          | {:api_retry, map()}
          | :ignore
  def parse_event(json_line) do
    case Jason.decode(json_line) do
      {:ok, %{"type" => "system", "subtype" => "init"} = event} ->
        {:session_started, %{session_id: event["session_id"], model: event["model"]}}

      {:ok, %{"type" => "assistant", "message" => message} = event} ->
        {:assistant_message, %{session_id: event["session_id"], usage: message["usage"]}}

      {:ok, %{"type" => "result", "is_error" => false} = event} ->
        {:turn_completed,
         %{
           session_id: event["session_id"],
           result: event["result"],
           duration_ms: event["duration_ms"],
           num_turns: event["num_turns"],
           total_cost_usd: event["total_cost_usd"],
           usage: event["usage"]
         }}

      {:ok, %{"type" => "result", "is_error" => true} = event} ->
        {:turn_failed, %{session_id: event["session_id"], reason: event["result"]}}

      {:ok, %{"type" => "rate_limit_event", "rate_limit_info" => info}} ->
        {:rate_limit,
         %{
           status: info["status"],
           resets_at: info["resetsAt"],
           requests_remaining: info["requestsRemaining"],
           tokens_remaining: info["tokensRemaining"]
         }}

      {:ok, %{"type" => "system", "subtype" => "api_retry"} = event} ->
        {:api_retry,
         %{
           attempt: event["attempt"],
           max_retries: event["max_retries"],
           retry_delay_ms: event["retry_delay_ms"],
           error_status: event["error_status"],
           error: event["error"]
         }}

      {:ok, %{"type" => "system"}} ->
        :ignore

      {:ok, _} ->
        :ignore

      {:error, _} ->
        :ignore
    end
  end

  @spec build_cli_args(map(), keyword()) :: [String.t()]
  def build_cli_args(claude_settings, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)

    args = [
      "--print",
      "--verbose",
      "--output-format",
      "stream-json",
      "--permission-mode",
      claude_settings.permission_mode || "bypassPermissions",
      "--model",
      claude_settings.model
    ]

    args = maybe_append(args, "--fallback-model", claude_settings[:fallback_model])
    args = maybe_append(args, "--max-budget-usd", claude_settings[:max_budget_usd])
    args = maybe_append(args, "--max-turns", claude_settings[:max_turns])
    args = maybe_append_list(args, "--allowedTools", claude_settings[:allowed_tools])
    args = maybe_append_list(args, "--disallowedTools", claude_settings[:disallowed_tools])

    args =
      case claude_settings[:system_prompt] do
        nil -> args ++ ["--append-system-prompt", tracker_api_supplement()]
        prompt -> args ++ ["--append-system-prompt", prompt <> "\n" <> tracker_api_supplement()]
      end

    # Resume existing session for multi-turn continuations.
    # Sessions are persisted by default so --resume works on subsequent turns.
    if session_id do
      args ++ ["--resume", session_id]
    else
      args
    end
  end

  # --- Private: event collection ---

  defp collect_events(port, on_message, metadata, issue, claude_settings) do
    deadline = System.monotonic_time(:millisecond) + (claude_settings.turn_timeout_ms || 3_600_000)
    stall_ms = claude_settings.stall_timeout_ms || 300_000

    collect_loop(port, on_message, metadata, issue, nil, "", deadline, stall_ms)
  end

  defp collect_loop(port, on_message, metadata, issue, last_result, buffer, deadline, stall_ms) do
    remaining = min(deadline - System.monotonic_time(:millisecond), stall_ms)

    receive do
      {^port, {:data, {:eol, line}}} ->
        full_line = buffer <> to_string(line)

        last_result =
          case parse_event(full_line) do
            {:turn_completed, payload} ->
              emit(on_message, :turn_completed, payload, metadata)
              {:ok, payload}

            {:turn_failed, payload} ->
              emit(on_message, :turn_failed, payload, metadata)
              {:error, payload}

            {event, payload} ->
              emit(on_message, event, payload, metadata)
              last_result

            :ignore ->
              last_result
          end

        collect_loop(port, on_message, metadata, issue, last_result, "", deadline, stall_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        collect_loop(port, on_message, metadata, issue, last_result, buffer <> to_string(chunk), deadline, stall_ms)

      {^port, {:exit_status, 0}} ->
        last_result || {:error, :no_result_event}

      {^port, {:exit_status, status}} ->
        Logger.warning("Claude Code exited with status #{status} for #{issue_context(issue)}")
        last_result || {:error, {:exit_status, status}}
    after
      max(remaining, 0) ->
        timeout_kind = if deadline - System.monotonic_time(:millisecond) <= 0, do: :turn_timeout, else: :stall_timeout
        Logger.warning("Claude Code #{timeout_kind} for #{issue_context(issue)}")
        last_result || {:error, timeout_kind}
    end
  end

  # --- Private: subprocess management ---

  defp start_port(workspace, cli_args, prompt, nil) do
    prompt_file = write_prompt_file!(prompt)
    setsid_path = System.find_executable("setsid")
    shell_cmd = build_shell_command(cli_args, prompt_file)

    {executable, exec_args} =
      if setsid_path do
        {setsid_path, ["bash", "-lc", shell_cmd]}
      else
        bash_path = System.find_executable("bash") || "/bin/bash"
        {bash_path, ["-lc", shell_cmd]}
      end

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :stderr_to_stdout, args: exec_args, cd: workspace, line: @port_line_bytes]
      )

    {:ok, port, extract_os_pid(port)}
  rescue
    e -> {:error, e}
  end

  defp start_port(_workspace, _cli_args, _prompt, _worker_host) do
    {:error, :remote_claude_not_supported}
  end

  defp write_prompt_file!(prompt) do
    path = Path.join(System.tmp_dir!(), "symphony_prompt_#{:erlang.unique_integer([:positive])}")
    File.write!(path, prompt)
    path
  end

  defp build_shell_command(cli_args, prompt_file) do
    escaped = Enum.map(cli_args, &shell_escape/1)
    file = shell_escape(prompt_file)
    Enum.join(["claude" | escaped], " ") <> " - < #{file}; rm -f #{file}"
  end

  defp shell_escape(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  defp extract_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp stop_port(port, os_pid) when is_port(port) do
    if os_pid, do: System.cmd("kill", ["--", "-#{os_pid}"], stderr_to_stdout: true)
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp stop_port(_port, _os_pid), do: :ok

  # --- Private: message emission and usage ---

  defp emit(on_message, event, payload, metadata) do
    on_message.(%{
      event: event,
      timestamp: DateTime.utc_now(),
      payload: payload,
      raw: inspect(payload),
      codex_app_server_pid: metadata[:pid],
      usage: normalize_usage(payload)
    })
  end

  defp normalize_usage(%{usage: %{} = usage}) do
    cache_creation = usage["cache_creation_input_tokens"] || 0
    cache_read = usage["cache_read_input_tokens"] || 0
    base_input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    %{
      "input_tokens" => base_input + cache_creation + cache_read,
      "output_tokens" => output,
      "total_tokens" => base_input + cache_creation + cache_read + output,
      "cache_creation_input_tokens" => cache_creation,
      "cache_read_input_tokens" => cache_read
    }
  end

  defp normalize_usage(_), do: nil

  defp default_on_message(message), do: Logger.debug("Claude event: #{inspect(message.event)}")

  # --- Private: tracker API supplement ---

  defp tracker_api_supplement do
    case Config.settings!().tracker.kind do
      "github_project" -> github_api_supplement()
      _ -> linear_api_supplement()
    end
  end

  defp github_api_supplement do
    tracker = Config.settings!().tracker

    """
    ## GitHub API access

    Use the `gh` CLI or `curl` via Bash to interact with GitHub.
    The `GITHUB_TOKEN` environment variable is set in your shell.

    ### Create a comment on the issue

    ```bash
    gh issue comment <number> -R #{tracker.repository || "<owner/repo>"} --body "Your comment"
    ```

    ### Move the issue on the project board

    The issue is tracked on a GitHub Projects V2 board. To change the status column,
    use the GitHub GraphQL API. You must look up the project item ID and status field
    option ID first.

    Step 1 — find the project item ID and status options:

    ```bash
    gh api graphql -f query='
      query {
        user(login: "#{tracker.project_owner}") {
          projectV2(number: #{tracker.project_number}) {
            id
            field(name: "Status") {
              ... on ProjectV2SingleSelectField {
                id
                options { id name }
              }
            }
            items(first: 100) {
              nodes {
                id
                content { ... on Issue { number } }
              }
            }
          }
        }
      }'
    ```

    Step 2 — update the status (replace the IDs from step 1):

    ```bash
    gh api graphql -f query='
      mutation {
        updateProjectV2ItemFieldValue(input: {
          projectId: "<PROJECT_ID>",
          itemId: "<ITEM_ID>",
          fieldId: "<STATUS_FIELD_ID>",
          value: { singleSelectOptionId: "<OPTION_ID>" }
        }) { projectV2Item { id } }
      }'
    ```
    """
  end

  defp linear_api_supplement do
    """
    ## Linear API access

    You do NOT have a `linear_graphql` tool. Instead, use `curl` via Bash to call the Linear GraphQL API.
    The `LINEAR_API_KEY` environment variable is set in your shell.

    Example — execute a GraphQL query:

    ```bash
    curl -s -X POST https://api.linear.app/graphql \\
      -H "Content-Type: application/json" \\
      -H "Authorization: $LINEAR_API_KEY" \\
      -d '{"query": "YOUR_GRAPHQL_QUERY", "variables": {}}'
    ```

    Use this for all Linear operations: fetching issues, updating state, creating/editing comments, attaching PRs.
    Refer to `.codex/skills/linear/SKILL.md` in your workspace for GraphQL query examples.
    """
  end

  # --- Private: helpers ---

  defp port_metadata(port, os_pid, worker_host) do
    %{pid: inspect(port), os_pid: os_pid, worker_host: worker_host}
  end

  defp maybe_append(args, _flag, nil), do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_append_list(args, _flag, nil), do: args
  defp maybe_append_list(args, _flag, []), do: args
  defp maybe_append_list(args, flag, values), do: args ++ [flag, Enum.join(values, ",")]

  defp issue_context(%{id: id, identifier: ident}) when is_binary(id), do: "issue_id=#{id} issue_identifier=#{ident}"
  defp issue_context(_), do: "unknown_issue"
end
