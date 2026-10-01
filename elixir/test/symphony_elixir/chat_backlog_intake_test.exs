defmodule SymphonyElixir.Chat.BacklogIntakeTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Chat.Store

  defmodule IntakeRuntime do
    def run(opts, emit, tool) do
      result = tool.("symphony_propose_action", %{})
      send(opts.test_pid, {:tool_result, result})
      if opts.text == "repeat", do: send(opts.test_pid, {:tool_result, tool.("symphony_propose_action", %{})})
      emit.({:delta, "Requested task recorded."})
      {:ok, %{status: :completed}}
    end
  end

  defmodule IntakeTools do
    def specs, do: []

    def call("symphony_propose_action", _, context) do
      if context.auth[:delay_tool] do
        send(context.auth.test_pid, {:tool_prepared, self()})
        receive do: (:deliver -> :ok)
      end

      {:ok, %{"proposal" => context.auth.proposal, "widgets" => [%{"type" => "proposal"}]}}
    end

    def call(_, _, _), do: {:ok, %{}}

    def confirm(proposal, context) do
      send(context.auth.test_pid, {:confirmed, proposal})
      send(context.auth.test_pid, {:pre_write_guard, context.before_write.()})
      send(context.auth.test_pid, {:pre_write_callback, context.before_write})

      case context.auth[:action_result] do
        :unknown -> {:error, :write_outcome_unknown}
        :failed -> {:error, :revision_conflict}
        _ -> {:ok, %{"summary" => "Task created"}}
      end
    end
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "backlog-intake-#{System.unique_integer([:positive])}")
    {:ok, access} = Agent.start_link(fn -> true end)
    settings = %{enabled: true, state_path: root, timeout_ms: 3_000, max_concurrent: 2, test_pid: self()}

    opts = [
      name: nil,
      settings: Map.put(settings, :auto_create_backlog, context[:automatic] != false),
      projects: fn -> [%{"id" => "github:test/one", "label" => "One"}] end,
      authorize: fn auth -> auth[:allowed] == true and Agent.get(access, & &1) end,
      runtime: IntakeRuntime,
      tools: IntakeTools
    ]

    server = start_supervised!({Store, opts})
    proposal = %{"action" => "create_task", "args" => %{"title" => "Requested task", "body" => ""}, "project_id" => "github:test/one", "tracker_fingerprint" => "scope"}
    auth = %{allowed: true, tracker_fingerprint: "scope", test_pid: self(), proposal: proposal}
    on_exit(fn -> File.rm_rf(root) end)
    %{server: server, opts: opts, root: root, access: access, auth: auth, project: "github:test/one"}
  end

  test "human project intake persists and creates once without another form", c do
    chat = conversation(c, nil)
    send_prompt(c, chat)
    assert_receive {:confirmed, proposal}, 2_000
    assert proposal["action"] == "create_task"
    assert_receive {:tool_result, %{"proposal" => %{"status" => "completed"}, "summary" => "Task created"}}, 2_000
    assert_receive {:pre_write_guard, :ok}
    settled = settle(c, chat)
    assert_receive {:pre_write_callback, guard}
    assert {:error, :stale_turn} = guard.()
    assert [saved] = settled["proposals"]
    assert saved["status"] == "completed"
    assert Enum.any?(List.last(settled["messages"])["tool_receipts"], &(&1["tool"] == "symphony_create_backlog"))
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", "request", c.auth, c.server)
    refute_receive {:confirmed, _}
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert restored["proposals"] == settled["proposals"]
  end

  test "duplicate create calls in one turn reuse the completed proposal", c do
    chat = conversation(c, nil)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "repeat", "request", c.auth, c.server)
    assert_receive {:confirmed, _}, 2_000
    settled = settle(c, chat)
    assert length(settled["proposals"]) == 1
    refute_receive {:confirmed, _}
  end

  @tag automatic: false
  test "disabled policy retains exact inline confirmation", c do
    chat = conversation(c, nil)
    send_prompt(c, chat)
    settled = settle(c, chat)
    assert [proposal] = settled["proposals"]
    assert proposal["status"] == "pending"
    refute_receive {:confirmed, _}
  end

  test "task agent cannot use project intake authority", c do
    chat = conversation(c, c.project <> ":1")
    send_prompt(c, chat)
    settled = settle(c, chat)
    assert hd(settled["proposals"])["status"] == "pending"
    refute_receive {:confirmed, _}
  end

  test "agent evidence and reports never gain human intake authority", c do
    for origin <- ["agent_evidence", "agent_message"] do
      chat = conversation(c, nil)
      auth = Map.put(c.auth, :delay_tool, true)
      client = "request-#{origin}"
      assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", client, auth, c.server)
      assert_receive {:tool_prepared, runtime}, 2_000
      :sys.replace_state(c.server, fn state -> put_in(state, [:jobs, chat["id"], :entry, "origin"], origin) end)
      send(runtime, :deliver)
      settled = settle(c, chat)
      assert List.last(settled["proposals"])["status"] == "pending"
      refute_receive {:confirmed, _}
    end
  end

  test "revoked authorization and stopped turns cannot create", c do
    chat = conversation(c, nil)
    auth = Map.put(c.auth, :delay_tool, true)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", "request", auth, c.server)
    assert_receive {:tool_prepared, runtime}, 2_000
    Agent.update(c.access, fn _ -> false end)
    send(runtime, :deliver)
    refute_receive {:confirmed, _}, 150
    Agent.update(c.access, fn _ -> true end)
    assert {:ok, _} = Store.stop(c.project, chat["id"], c.auth, c.server)
    assert {:error, :stale_turn} = GenServer.call(c.server, {:start_backlog_creation, chat["id"], "stale", "missing"})
  end

  for {outcome, status} <- [{:unknown, "unknown"}, {:failed, "failed"}] do
    test "#{outcome} task outcome is retained rather than blindly retried", c do
      chat = conversation(c, nil)
      send_prompt(%{c | auth: Map.put(c.auth, :action_result, unquote(outcome))}, chat)
      assert_receive {:confirmed, _}, 2_000
      settled = settle(c, chat)
      assert hd(settled["proposals"])["status"] == unquote(status)
      refute_receive {:confirmed, _}
      stop_supervised!(Store)
      server = start_supervised!({Store, c.opts})
      assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
      assert hd(restored["proposals"])["status"] == unquote(status)
    end
  end

  defp conversation(c, task) do
    assert {:ok, chat} = Store.ensure_conversation(c.project, task, c.auth, c.server)
    chat
  end

  defp send_prompt(c, chat), do: assert({:ok, _} = Store.send_message(c.project, chat["id"], "proposal", "request", c.auth, c.server))

  defp settle(c, chat, remaining \\ 200) do
    assert {:ok, current} = Store.get(c.project, chat["id"], c.auth, c.server)
    if current["status"] == "idle", do: current, else: wait_again(c, chat, remaining)
  end

  defp wait_again(c, chat, remaining) do
    assert remaining > 0
    Process.sleep(10)
    settle(c, chat, remaining - 1)
  end
end
