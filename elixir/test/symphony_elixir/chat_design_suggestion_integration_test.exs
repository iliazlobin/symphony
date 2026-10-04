defmodule SymphonyElixir.ChatDesignSuggestionIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Chat.{Provider, Store, Tools, ViewContext}
  alias SymphonyElixirWeb.TaskBoard

  @project "github:example/design"

  defmodule Board do
    def load(_owner, _timeout), do: Application.fetch_env!(:symphony_elixir, :design_suggestion_board)
  end

  defmodule Owner do
    use GenServer
    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)
    @impl true
    def init(observer), do: {:ok, observer}
    @impl true
    def handle_call(command, _from, observer) do
      send(observer, {:unexpected_native_command, command})
      {:reply, {:error, :design_read_only}, observer}
    end
  end

  setup do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.dirname(Workflow.workflow_file_path()))
    control_path = Path.join(root, "control.json")

    config = %{
      tracker: %{
        kind: "github",
        provider: %{repo: "example/design", token: "fixture-only"},
        required_labels: ["ready"],
        active_states: ["open"],
        terminal_states: ["closed"]
      },
      control: %{enabled: true, state_path: control_path, initial_mode: "paused"},
      observability: %{dashboard_enabled: false}
    }

    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nFixture")
    assert :ok = WorkflowStore.force_reload()
    token = String.duplicate("design-test", 4)
    previous_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)

    keys = [:chat_board_module, :chat_github_request, :design_suggestion_board]
    previous = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    board = TaskBoard.project([], %{}, %{"enabled" => true, "revision" => 3, "mode" => "paused", "issues" => %{}}, Config.settings!())
    Application.put_env(:symphony_elixir, :chat_board_module, Board)
    Application.put_env(:symphony_elixir, :design_suggestion_board, board)
    Application.put_env(:symphony_elixir, :chat_github_request, fn _, _, _, _, _ -> flunk("Design feedback must not call GitHub") end)

    marker = %{"fingerprint" => :crypto.mac(:hmac, :sha256, token, "symphony-browser-operator-v1") |> Base.url_encode64(padding: false), "issued_at" => System.system_time(:second)}
    auth = %{marker: marker, host: "localhost", peer_ip: {127, 0, 0, 1}, tracker_fingerprint: Orchestrator.tracker_fingerprint()}
    owner = start_supervised!({Owner, self()})
    {:ok, view} = ViewContext.validate(%{"version" => 1, "project_id" => @project, "mode" => "design"}, @project)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> if is_nil(value), do: Application.delete_env(:symphony_elixir, key), else: Application.put_env(:symphony_elixir, key, value) end)
      restore_env("SYMPHONY_CONTROL_TOKEN", previous_token)
    end)

    %{root: root, auth: auth, owner: owner, view: view, control_path: control_path, board: board}
  end

  test "real OpenRouter tool loop persists reviewed canvas feedback without changing tasks or goals", ctx do
    observer = self()
    suggestion = suggestion()

    request = fn options ->
      payload = Jason.decode!(options[:body])

      case List.last(payload["messages"])["role"] do
        "user" ->
          names = Enum.map(payload["tools"], &get_in(&1, ["function", "name"]))
          send(observer, {:provider_catalog, names})
          http(tool_call("design-call", "symphony_propose_design", suggestion), "tool_calls")

        "tool" ->
          receipt = payload["messages"] |> List.last() |> Map.fetch!("content") |> Jason.decode!()
          send(observer, {:provider_design_receipt, receipt})
          http(%{"role" => "assistant", "content" => "Review the proposed Event entity and relationship, then Apply if it fits."})
      end
    end

    {server, opts} = start_store(ctx, request)
    assert {:ok, chat} = Store.ensure_conversation(@project, nil, ctx.auth, server)

    assert {:ok, _} =
             Store.send_message_with_context(@project, chat["id"], "Review this canvas snapshot: document_id=design-fixture, revision=7, section=data", "design-review", ctx.view, ctx.auth, server)

    assert_receive {:provider_catalog, names}
    assert "symphony_propose_design" in names
    refute Enum.any?(names, &(&1 in ~w(symphony_propose_action symphony_set_goal symphony_delegate symphony_report)))
    assert_receive {:provider_design_receipt, %{"widgets" => [%{"type" => "design_suggestion", "suggestion" => ^suggestion}]}}, 1_000
    saved = await_status(server, ctx, chat, "idle")
    response = List.last(saved["messages"])
    assert response["text"] =~ "then Apply"
    assert response["widgets"] == [%{"type" => "design_suggestion", "suggestion" => suggestion}]
    design_receipts = Enum.filter(response["tool_receipts"], &(&1["tool"] == "symphony_propose_design"))
    assert [%{"tool" => "symphony_propose_design", "arguments" => ^suggestion}] = Enum.map(design_receipts, &Map.take(&1, ["tool", "arguments"]))
    assert response["view_context"] == ctx.view
    assert saved["proposals"] == []
    assert saved["agent_goal"] == chat["agent_goal"]
    assert Application.fetch_env!(:symphony_elixir, :design_suggestion_board) == ctx.board
    refute File.exists?(ctx.control_path)
    refute_receive {:unexpected_native_command, _}

    stop_supervised!(Store)
    restored_server = start_supervised!({Store, opts})
    assert {:ok, restored} = Store.get(@project, chat["id"], ctx.auth, restored_server)
    assert restored["messages"] == saved["messages"]
    assert restored["proposals"] == []
  end

  test "a model cannot use Design feedback to write tasks or change an agent goal", ctx do
    request = fn options ->
      payload = Jason.decode!(options[:body])

      if List.last(payload["messages"])["role"] == "user" do
        http(tool_call("design-call", "symphony_propose_design", suggestion()), "tool_calls")
      else
        http(tool_call("write-call", "symphony_propose_action", %{"action" => "create_task", "title" => "Unauthorized task"}), "tool_calls")
      end
    end

    {server, _opts} = start_store(ctx, request)
    assert {:ok, chat} = Store.ensure_conversation(@project, nil, ctx.auth, server)
    assert {:ok, _} = Store.send_message_with_context(@project, chat["id"], "Review a design; never start work.", "design-guard", ctx.view, ctx.auth, server)
    saved = await_status(server, ctx, chat, "error")
    assert saved["error"] =~ "could not finish"
    assert [%{"type" => "design_suggestion"}] = Enum.map(List.last(saved["messages"])["widgets"], &Map.take(&1, ["type"]))
    assert saved["proposals"] == []
    assert saved["agent_goal"] == chat["agent_goal"]
    refute File.exists?(ctx.control_path)
    refute_receive {:unexpected_native_command, _}
  end

  defp start_store(ctx, request) do
    settings = %{enabled: true, provider: "openrouter", model: "test/model", api_key: "fixture-key", state_path: Path.join(ctx.root, "chat"), timeout_ms: 3_000, max_concurrent: 1, request: request}
    opts = [name: nil, settings: settings, runtime: Provider, tools: Tools, orchestrator: ctx.owner]
    {start_supervised!({Store, opts}), opts}
  end

  defp suggestion do
    %{
      "version" => 1,
      "project" => @project,
      "section" => "data",
      "base_document" => "design-fixture",
      "base_revision" => 7,
      "changes" => [
        %{"op" => "add_node", "node" => %{"id" => "n-event", "kind" => "entity", "title" => "Event", "text" => "id: key\ntitle: text\nAssumption: source IDs are stable."}},
        %{"op" => "add_edge", "edge" => %{"id" => "e-source", "from" => "n-source", "to" => "n-event", "label" => "one to many"}}
      ]
    }
  end

  defp tool_call(id, name, args),
    do: %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}]}

  defp http(message, reason \\ "stop"), do: {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"choices" => [%{"message" => message, "finish_reason" => reason}]})}}

  defp await_status(server, ctx, chat, status, remaining \\ 200)
  defp await_status(_server, _ctx, _chat, _status, 0), do: flunk("provider turn did not settle")

  defp await_status(server, ctx, chat, status, remaining) do
    assert {:ok, current} = Store.get(@project, chat["id"], ctx.auth, server)

    if current["status"] == status do
      current
    else
      Process.sleep(10)
      await_status(server, ctx, chat, status, remaining - 1)
    end
  end
end
