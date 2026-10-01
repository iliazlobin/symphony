defmodule SymphonyElixir.Chat.OpenRouterStoreTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Chat.{Provider, Store}

  defmodule ReadTools do
    @spec specs() :: list()
    def specs do
      [%{"name" => "symphony_project_status", "description" => "Read project status", "inputSchema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}}]
    end

    @spec call(String.t(), map(), map()) :: term()
    def call("symphony_project_status", %{}, _context) do
      {:ok, %{"summary" => "Execution is paused", "widgets" => [%{"type" => "status", "title" => "Project status", "url" => "/?project=github%3Atest%2Fone"}]}}
    end
  end

  setup %{outcome: outcome} do
    owner = self()
    {:ok, tmp} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "symphony-openrouter-store-#{System.unique_integer([:positive])}")

    request = fn options ->
      messages = Jason.decode!(options[:body])["messages"]

      if length(messages) == 2 do
        http(
          %{
            "role" => "assistant",
            "content" => "I will inspect the project before answering.",
            "reasoning_details" => [%{"type" => "reasoning.encrypted", "data" => "opaque-provider-context"}],
            "tool_calls" => [%{"id" => "status-call", "type" => "function", "function" => %{"name" => "symphony_project_status", "arguments" => "{}"}}]
          },
          "tool_calls"
        )
      else
        send(owner, {:provider_continuation, self(), messages})

        case outcome do
          :completed -> http(%{"role" => "assistant", "content" => "Execution is paused."})
          :failed -> {:ok, %Req.Response{status: 503}}
          :empty -> http(%{"role" => "assistant", "content" => "  "})
          :interrupted -> receive do: (:never -> flunk("cancelled request continued"))
        end
      end
    end

    opts = [
      name: nil,
      settings: %{
        enabled: true,
        provider: "openrouter",
        model: "test/model",
        api_key: "fixture-key",
        state_path: root,
        timeout_ms: 3_000,
        max_concurrent: 1,
        request: request
      },
      projects: fn -> [%{"id" => "github:test/one", "label" => "One"}] end,
      authorize: fn auth -> auth[:allowed] == true end,
      runtime: Provider,
      tools: ReadTools
    ]

    server = start_supervised!({Store, opts})
    on_exit(fn -> File.rm_rf(root) end)
    %{server: server, opts: opts, root: root, auth: %{allowed: true, tracker_fingerprint: "scope"}, project: "github:test/one"}
  end

  for {outcome, status, text} <- [{:completed, "idle", "Execution is paused."}, {:failed, "error", ""}, {:empty, "error", ""}, {:interrupted, "interrupted", ""}] do
    @tag outcome: outcome
    test "terminal-only transcript and host receipts survive #{outcome} after a tool preamble", c do
      assert {:ok, chat} = Store.create(c.project, "Status", c.auth, c.server)
      assert {:ok, _} = Store.send_message(c.project, chat["id"], "What is running?", "terminal-answer", c.auth, c.server)
      assert_receive {:provider_continuation, request_child, [_, _, assistant, receipt]}
      assert assistant["content"] == "I will inspect the project before answering."
      assert assistant["reasoning_details"] == [%{"type" => "reasoning.encrypted", "data" => "opaque-provider-context"}]
      assert receipt["tool_call_id"] == "status-call"
      assert receipt["content"] =~ "Execution is paused"

      if unquote(outcome) == :interrupted do
        assert {:ok, active} = Store.get(c.project, chat["id"], c.auth, c.server)
        assert active["activity"] == "Using symphony_project_status"
        assert List.last(active["messages"])["text"] == ""
        assert {:ok, _} = Store.stop(c.project, chat["id"], c.auth, c.server)
      end

      saved = await_status(c, chat, unquote(status))
      response = List.last(saved["messages"])
      assert response["text"] == unquote(text)
      assert [%{"tool" => "symphony_project_status", "arguments" => %{}, "result" => result}] = response["tool_receipts"]
      assert result =~ "Execution is paused"
      assert length(response["widgets"]) == 1
      assert :sys.get_state(c.server).fault == nil
      refute Process.alive?(request_child)

      disk = File.read!(Path.join(c.root, chat["id"] <> ".json"))
      refute disk =~ "I will inspect"
      refute disk =~ "opaque-provider-context"
      stop_supervised!(Store)
      server = start_supervised!({Store, c.opts})
      assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
      assert restored["messages"] == saved["messages"]
    end
  end

  defp http(message, reason \\ "stop"),
    do: {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"choices" => [%{"message" => message, "finish_reason" => reason}]})}}

  defp await_status(c, chat, status, remaining \\ 200)
  defp await_status(_c, _chat, _status, 0), do: flunk("provider turn did not settle")

  defp await_status(c, chat, status, remaining) do
    assert {:ok, current} = Store.get(c.project, chat["id"], c.auth, c.server)

    if current["status"] == status do
      current
    else
      Process.sleep(10)
      await_status(c, chat, status, remaining - 1)
    end
  end
end
