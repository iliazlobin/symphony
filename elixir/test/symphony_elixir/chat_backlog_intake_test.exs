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

      if context.auth[:delay_confirm] do
        send(context.auth.test_pid, {:creation_prepared, self()})
        receive do: (:complete_creation -> :ok)
      end

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

  test "creation cannot start if its durable intent cannot be saved", c do
    chat = conversation(c, nil)
    auth = Map.put(c.auth, :delay_tool, true)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", "request", auth, c.server)
    assert_receive {:tool_prepared, _runtime}, 2_000
    run = :sys.get_state(c.server).jobs[chat["id"]].run
    outcome = GenServer.call(c.server, {:tool_result, chat["id"], run, %{tool: "symphony_propose_action", arguments: %{}}, %{"proposal" => c.auth.proposal, "widgets" => [%{"type" => "proposal"}]}})
    block_record(c, chat)
    assert {:error, :chat_storage_unavailable} = GenServer.call(c.server, {:start_backlog_creation, chat["id"], run, outcome["proposal"]["id"]})
    refute_receive {:confirmed, _}
  end

  test "a committed write with a storage failure stays uncertain for reconciliation", c do
    chat = conversation(c, nil)
    auth = Map.put(c.auth, :delay_confirm, true)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", "request", auth, c.server)
    assert_receive {:confirmed, _}, 2_000
    assert_receive {:creation_prepared, runtime}, 2_000
    disk = block_record(c, chat)
    assert hd(Jason.decode!(disk)["proposals"])["status"] == "executing"
    send(runtime, :complete_creation)
    state = await_fault(c.server)
    refute_receive {:confirmed, _}
    assert state.chats[chat["id"]]["proposals"] |> hd() |> Map.fetch!("status") == "unknown"
  end

  test "an expired turn cannot claim a finished creation", c do
    assert %{"error" => error} = GenServer.call(c.server, {:finish_backlog_creation, "missing", "stale", "proposal", {:ok, %{}}})
    assert error =~ "unknown"
  end

  test "later human turns must reconcile an unknown creation before any new creation", c do
    chat = conversation(c, nil)
    send_prompt(%{c | auth: Map.put(c.auth, :action_result, :unknown)}, chat)
    assert_receive {:confirmed, _}, 2_000
    first = settle(c, chat)
    assert_receive {:tool_result, %{"proposal" => %{"status" => "unknown"}}}, 2_000

    for {title, client} <- [{"Requested task", "same-request"}, {"A different task", "new-request"}] do
      proposal = put_in(c.auth.proposal, ["args", "title"], title)
      auth = Map.put(c.auth, :proposal, proposal)
      assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", client, auth, c.server)
      current = settle(c, chat)
      assert current["proposals"] == first["proposals"]
      assert_receive {:tool_result, %{"proposal" => %{"status" => "unknown"}, "error" => error}}, 2_000
      assert error =~ "Check the outcome"
      refute_receive {:confirmed, _}
    end
  end

  for mode <- [:stopped, :crashed] do
    test "#{mode} creation becomes reconcilable without a service restart", c do
      chat = conversation(c, nil)
      auth = Map.put(c.auth, :delay_confirm, true)
      assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", "request", auth, c.server)
      assert_receive {:confirmed, _}, 2_000
      assert_receive {:creation_prepared, runtime}, 2_000
      if unquote(mode) == :stopped, do: assert({:ok, _} = Store.stop(c.project, chat["id"], c.auth, c.server))
      Process.exit(runtime, :kill)
      settled = await_settled(c, chat)
      assert settled["status"] == if(unquote(mode) == :stopped, do: "interrupted", else: "error")
      assert [proposal] = settled["proposals"]
      assert proposal["status"] == "unknown"
      assert proposal["error"] =~ "Check the outcome"
      assert hd(Jason.decode!(File.read!(Path.join(c.root, chat["id"] <> ".json")))["proposals"])["status"] == "unknown"
      refute_receive {:confirmed, _}
    end
  end

  defp await_settled(c, chat, remaining \\ 200) do
    assert {:ok, current} = Store.get(c.project, chat["id"], c.auth, c.server)

    if current["status"] != "running" do
      current
    else
      assert remaining > 0
      Process.sleep(10)
      await_settled(c, chat, remaining - 1)
    end
  end

  defp await_fault(server, remaining \\ 200) do
    state = :sys.get_state(server)

    if state.fault do
      state
    else
      assert remaining > 0
      Process.sleep(10)
      await_fault(server, remaining - 1)
    end
  end

  defp block_record(c, chat) do
    path = Path.join(c.root, chat["id"] <> ".json")
    bytes = File.read!(path)
    File.rm!(path)
    File.mkdir!(path)
    bytes
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
