defmodule SymphonyElixir.Claude.AppServerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.AppServer

  @default_settings %{
    model: "claude-sonnet-4-6",
    fallback_model: nil,
    max_budget_usd: nil,
    max_turns: nil,
    permission_mode: "bypassPermissions",
    allowed_tools: nil,
    disallowed_tools: nil,
    system_prompt: nil,
    turn_timeout_ms: 3_600_000,
    stall_timeout_ms: 300_000
  }

  describe "parse_event/1" do
    test "parses system init event" do
      json =
        Jason.encode!(%{
          "type" => "system",
          "subtype" => "init",
          "session_id" => "abc-123",
          "model" => "claude-sonnet-4-6",
          "tools" => ["Read", "Write"]
        })

      assert {:session_started, %{session_id: "abc-123", model: "claude-sonnet-4-6"}} =
               AppServer.parse_event(json)
    end

    test "parses assistant event with usage" do
      json =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "id" => "msg_1",
            "model" => "claude-sonnet-4-6",
            "content" => [%{"type" => "text", "text" => "hello"}],
            "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
          },
          "session_id" => "abc-123"
        })

      assert {:assistant_message,
              %{
                session_id: "abc-123",
                usage: %{"input_tokens" => 100, "output_tokens" => 50}
              }} = AppServer.parse_event(json)
    end

    test "parses successful result event" do
      json =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "duration_ms" => 5000,
          "num_turns" => 3,
          "result" => "done",
          "stop_reason" => "end_turn",
          "total_cost_usd" => 0.42,
          "session_id" => "abc-123",
          "usage" => %{"input_tokens" => 1000, "output_tokens" => 500}
        })

      assert {:turn_completed,
              %{
                session_id: "abc-123",
                result: "done",
                duration_ms: 5000,
                num_turns: 3,
                total_cost_usd: 0.42,
                usage: %{"input_tokens" => 1000, "output_tokens" => 500}
              }} = AppServer.parse_event(json)
    end

    test "parses error result event" do
      json =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "is_error" => true,
          "result" => "something failed",
          "session_id" => "abc-123",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 10}
        })

      assert {:turn_failed, %{session_id: "abc-123", reason: "something failed"}} =
               AppServer.parse_event(json)
    end

    test "parses rate limit event with extended fields" do
      json =
        Jason.encode!(%{
          "type" => "rate_limit_event",
          "rate_limit_info" => %{
            "status" => "allowed",
            "resetsAt" => 1_774_134_000,
            "requestsRemaining" => 42,
            "tokensRemaining" => 100_000
          },
          "session_id" => "abc-123"
        })

      assert {:rate_limit,
              %{
                status: "allowed",
                resets_at: 1_774_134_000,
                requests_remaining: 42,
                tokens_remaining: 100_000
              }} = AppServer.parse_event(json)
    end

    test "parses rate limit event with minimal fields" do
      json =
        Jason.encode!(%{
          "type" => "rate_limit_event",
          "rate_limit_info" => %{"status" => "allowed", "resetsAt" => 1_774_134_000},
          "session_id" => "abc-123"
        })

      assert {:rate_limit,
              %{
                status: "allowed",
                resets_at: 1_774_134_000,
                requests_remaining: nil,
                tokens_remaining: nil
              }} = AppServer.parse_event(json)
    end

    test "parses api_retry event" do
      json =
        Jason.encode!(%{
          "type" => "system",
          "subtype" => "api_retry",
          "attempt" => 1,
          "max_retries" => 3,
          "retry_delay_ms" => 1000,
          "error_status" => 429,
          "error" => "rate_limit"
        })

      assert {:api_retry,
              %{
                attempt: 1,
                max_retries: 3,
                retry_delay_ms: 1000,
                error_status: 429,
                error: "rate_limit"
              }} = AppServer.parse_event(json)
    end

    test "ignores system hook events" do
      json =
        Jason.encode!(%{
          "type" => "system",
          "subtype" => "hook_started",
          "hook_name" => "test"
        })

      assert :ignore = AppServer.parse_event(json)
    end

    test "ignores system hook_response events" do
      json =
        Jason.encode!(%{
          "type" => "system",
          "subtype" => "hook_response",
          "hook_name" => "test"
        })

      assert :ignore = AppServer.parse_event(json)
    end

    test "handles invalid JSON gracefully" do
      assert :ignore = AppServer.parse_event("not json at all")
    end

    test "handles empty string" do
      assert :ignore = AppServer.parse_event("")
    end
  end

  describe "build_cli_args/2" do
    test "builds default args" do
      args = AppServer.build_cli_args(@default_settings)

      assert "--print" in args
      assert "--verbose" in args
      assert "--output-format" in args
      assert "stream-json" in args
      assert "--model" in args
      assert "claude-sonnet-4-6" in args
      assert "--permission-mode" in args
      assert "bypassPermissions" in args
      assert "--append-system-prompt" in args
      refute "--dangerously-skip-permissions" in args
      refute "--max-budget-usd" in args
      refute "--max-turns" in args
      refute "--fallback-model" in args
    end

    test "includes max-budget-usd when set" do
      settings = %{@default_settings | max_budget_usd: 5.0}
      args = AppServer.build_cli_args(settings)

      assert "--max-budget-usd" in args
      assert "5.0" in args
    end

    test "includes max-turns when set" do
      settings = %{@default_settings | max_turns: 10}
      args = AppServer.build_cli_args(settings)

      assert "--max-turns" in args
      assert "10" in args
    end

    test "includes fallback-model when set" do
      settings = %{@default_settings | fallback_model: "claude-haiku-4-5"}
      args = AppServer.build_cli_args(settings)

      assert "--fallback-model" in args
      assert "claude-haiku-4-5" in args
    end

    test "uses specified model" do
      settings = %{@default_settings | model: "claude-opus-4-6"}
      args = AppServer.build_cli_args(settings)

      assert "claude-opus-4-6" in args
    end

    test "includes allowed tools when set" do
      settings = %{@default_settings | allowed_tools: ["Read", "Edit", "Bash"]}
      args = AppServer.build_cli_args(settings)

      assert "--allowedTools" in args
      assert "Read,Edit,Bash" in args
    end

    test "includes disallowed tools when set" do
      settings = %{@default_settings | disallowed_tools: ["WebFetch"]}
      args = AppServer.build_cli_args(settings)

      assert "--disallowedTools" in args
      assert "WebFetch" in args
    end

    test "appends custom system prompt before linear supplement" do
      settings = %{@default_settings | system_prompt: "You are a careful reviewer."}
      args = AppServer.build_cli_args(settings)

      idx = Enum.find_index(args, &(&1 == "--append-system-prompt"))
      system_value = Enum.at(args, idx + 1)

      assert system_value =~ "You are a careful reviewer."
      assert system_value =~ "Linear API access"
    end

    test "uses --resume when session_id given" do
      args = AppServer.build_cli_args(@default_settings, session_id: "sess-abc-123")

      assert "--resume" in args
      assert "sess-abc-123" in args
    end

    test "omits --resume and --no-session-persistence when no session_id" do
      args = AppServer.build_cli_args(@default_settings)

      refute "--resume" in args
      refute "--no-session-persistence" in args
    end

    test "uses specified permission mode" do
      settings = %{@default_settings | permission_mode: "acceptEdits"}
      args = AppServer.build_cli_args(settings)

      assert "acceptEdits" in args
      refute "bypassPermissions" in args
    end
  end
end
