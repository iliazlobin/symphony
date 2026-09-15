defmodule SymphonyElixir.Chat.StoreTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Chat.{Persistence, Store}

  defmodule TestRuntime do
    @spec run(map(), function(), function()) :: term()
    def run(opts, emit, tool) do
      send(opts.test_pid, {:runtime, self(), opts.thread_id, opts.text})
      emit.({:thread, opts.thread_id || "native-#{System.unique_integer([:positive])}"})
      emit.({:status, "Reading project"})
      emit.({:usage, %{"totalTokens" => 10}})

      case opts.text do
        "wait" ->
          emit.({:delta, "Partial response"})

          receive do
            :interrupt -> {:ok, %{status: :interrupted}}
            :finish -> {:ok, %{status: :completed}}
          end

        "proposal" ->
          result = tool.("propose_action", %{})
          send(opts.test_pid, {:tool_result, result})
          emit.({:delta, "Review this action."})
          {:ok, %{status: :completed}}

        "unauthorized tool" ->
          receive do
            :continue -> :ok
          end

          send(opts.test_pid, {:tool_result, tool.("project_status", %{})})
          {:ok, %{status: :completed}}

        "tool error" ->
          send(opts.test_pid, {:tool_result, tool.("invalid", %{})})
          {:ok, %{status: :completed}}

        "crash" ->
          exit(:runtime_failure)

        "error" ->
          {:error, :model_unavailable}

        "auth" ->
          {:error, :auth_required}

        _ ->
          emit.({:delta, "Hello "})
          emit.({:delta, "from the project."})
          {:ok, %{status: :completed}}
      end
    end
  end

  defmodule TestTools do
    @spec specs() :: list()
    def specs, do: []
    @spec call(String.t(), map(), map()) :: term()
    def call("invalid", _, _), do: {:error, :invalid_tool}

    def call("propose_action", _, ctx) do
      proposal = %{"action" => "feedback", "args" => %{"body" => "Please check this"}, "project_id" => ctx.project_id, "tracker_fingerprint" => ctx.tracker_fingerprint}
      {:ok, %{"proposal" => proposal, "widgets" => [%{"type" => "proposal"}], "references" => [%{"label" => "Task", "url" => "https://github.com/test/project/issues/1"}]}}
    end

    def call(_, _, _), do: {:ok, %{"summary" => "No active tasks", "widgets" => []}}
    @spec confirm(map(), map()) :: term()
    def confirm(proposal, ctx) do
      send(ctx.auth.test_pid, {:confirmed, proposal})

      case ctx.auth[:action_result] do
        :wait ->
          receive do
            :finish -> {:ok, %{"summary" => "Feedback saved"}}
          end

        :unknown ->
          {:error, :write_outcome_unknown}

        :failed ->
          {:error, :revision_conflict}

        _ ->
          {:ok, %{"summary" => "Feedback saved", "url" => "https://github.com/test/project/issues/1"}}
      end
    end

    @spec reconcile(map(), map()) :: term()
    def reconcile(proposal, ctx) do
      send(ctx.auth.test_pid, {:reconciled, proposal})
      {:ok, %{"summary" => "Existing feedback found"}}
    end
  end

  setup do
    {:ok, tmp} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "symphony-chat-store-#{System.unique_integer([:positive])}")
    settings = %{enabled: true, state_path: root, codex_home: root <> "/runtime", executable: "/test/codex", timeout_ms: 3_000, max_concurrent: 2, test_pid: self()}
    project_reader = fn -> [%{"id" => "github:test/one", "label" => "One"}, %{"id" => "github:test/two", "label" => "Two"}] end
    {:ok, access} = Agent.start_link(fn -> true end)
    authorize = fn auth -> is_map(auth) and auth[:allowed] == true and Agent.get(access, & &1) end
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    opts = [name: name, settings: settings, projects: project_reader, authorize: authorize, runtime: TestRuntime, tools: TestTools]
    server = start_supervised!({Store, opts})
    auth = %{allowed: true, tracker_fingerprint: "scope", test_pid: self()}
    on_exit(fn -> File.rm_rf(root) end)
    %{server: server, opts: opts, root: root, auth: auth, access: access, project: "github:test/one"}
  end

  test "project lookup, history and immutable ownership reject foreign selections", c do
    assert {:ok, [_, _]} = Store.projects(c.auth, c.server)
    assert {:error, :unauthorized} = Store.projects(%{}, c.server)
    assert {:error, :project_not_found} = Store.create("github:unknown/repo", "Chat", c.auth, c.server)
    assert {:error, :invalid_chat} = Store.create(c.project, " ", c.auth, c.server)
    chat = create(c)
    assert {:ok, []} = Store.list("github:test/two", c.auth, c.server)
    assert {:error, :chat_not_found} = Store.get("github:test/two", chat["id"], c.auth, c.server)
    assert {:error, :chat_not_found} = Store.get(c.project, chat["id"], %{c.auth | tracker_fingerprint: "new-scope"}, c.server)
    assert {:ok, []} = Store.list(c.project, %{c.auth | tracker_fingerprint: "new-scope"}, c.server)
    assert {:error, :unauthorized} = Store.get(c.project, chat["id"], %{}, c.server)
    assert {:error, :invalid_title} = Store.rename(c.project, chat["id"], "", c.auth, c.server)
    assert {:ok, renamed} = Store.rename(c.project, chat["id"], "A plan", c.auth, c.server)
    assert renamed["title"] == "A plan"
    refute Map.has_key?(renamed, "codex_thread_id")
    assert {:ok, [^renamed]} = Store.list(c.project, c.auth, c.server)
    assert {:ok, %{"archived" => true}} = Store.archive(c.project, chat["id"], c.auth, c.server)
    assert {:ok, []} = Store.list(c.project, c.auth, c.server)
    assert {:error, :chat_busy} = Store.send_message(c.project, chat["id"], "x", "x", c.auth, c.server)
  end

  test "streamed deltas survive restart, resume native thread, and reject duplicate submissions", c do
    chat = create(c)
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat:" <> chat["id"])
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "Hello", "client-1", c.auth, c.server)
    assert_receive {:runtime, _, nil, "Hello"}
    assert_receive {:chat_updated, _}
    finished = wait_chat(c, chat, &(&1["status"] == "idle"))
    assert List.last(finished["messages"])["text"] == "Hello from the project."
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "Hello", "client-1", c.auth, c.server)
    refute_receive {:runtime, _, _, _}
    assert {:error, :invalid_message} = Store.send_message(c.project, chat["id"], "", "client-2", c.auth, c.server)
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert restored["messages"] == finished["messages"]
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "Again", "client-2", c.auth, server)
    assert_receive {:runtime, _, native, "Again"}
    assert is_binary(native)
    wait_chat(%{c | server: server}, chat, &(&1["status"] == "idle"))
  end

  test "Stop cancels only chat execution and interrupted service restarts retain history", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "client", c.auth, c.server)
    assert_receive {:runtime, pid, _, "wait"}
    wait_chat(c, chat, &(get_in(&1, ["messages", Access.at(-1), "text"]) == "Partial response"))
    assert {:error, :chat_busy} = Store.archive(c.project, chat["id"], c.auth, c.server)
    assert {:error, :chat_busy} = Store.send_message(c.project, chat["id"], "Again", "next", c.auth, c.server)
    assert {:ok, _} = Store.stop(c.project, chat["id"], c.auth, c.server)
    wait_chat(c, chat, &(&1["status"] == "interrupted"))
    refute Process.alive?(pid)
    assert {:ok, _} = Store.stop(c.project, chat["id"], c.auth, c.server)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "next", c.auth, c.server)
    assert_receive {:runtime, running, _, "wait"}
    stop_supervised!(Store)
    refute Process.alive?(running)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert restored["status"] == "interrupted"
  end

  test "bounded concurrency, runtime failures and stale events never start extra work", c do
    first = create(c)
    second = create(c)
    third = create(c)
    for chat <- [first, second], do: assert({:ok, _} = Store.send_message(c.project, chat["id"], "wait", chat["id"], c.auth, c.server))
    assert {:error, :chat_capacity} = Store.send_message(c.project, third["id"], "Hello", "three", c.auth, c.server)
    assert {:ok, _} = Store.stop(c.project, first["id"], c.auth, c.server)
    wait_chat(c, first, &(&1["status"] == "interrupted"))

    for text <- ["error", "auth", "crash", "tool error"] do
      assert {:ok, _} = Store.send_message(c.project, first["id"], text, text, c.auth, c.server)
      wait_chat(c, first, &(&1["status"] != "running"))
    end

    GenServer.cast(c.server, {:delta, first["id"], "stale", "must not appear"})
    send(c.server, {:job_done, first["id"], "stale", {:ok, %{status: :completed}}})
    send(c.server, {:stop_deadline, first["id"], self()})
    send(c.server, :unrecognized)
    {:ok, result} = Store.get(c.project, first["id"], c.auth, c.server)
    refute inspect(result) =~ "must not appear"
    assert {:error, :stale_turn} = GenServer.call(c.server, {:runtime_event, first["id"], "stale", {:thread, "wrong"}})
    assert %{"error" => _} = GenServer.call(c.server, {:tool_result, first["id"], "stale", %{}})
  end

  test "proposals require a user decision, execute once, and retain receipts", c do
    {chat, proposal} = propose(c)
    refute_receive {:confirmed, _}
    assert {:error, :proposal_not_found} = Store.decide(c.project, chat["id"], "missing", "confirm", c.auth, c.server)
    assert {:error, :invalid_decision} = Store.decide(c.project, chat["id"], proposal["id"], "yes maybe", c.auth, c.server)
    assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "confirm", c.auth, c.server)
    assert_receive {:confirmed, payload}
    refute Map.has_key?(payload, "status")
    assert payload["id"] == proposal["id"]
    complete = wait_chat(c, chat, &(hd(&1["proposals"])["status"] == "completed"))
    assert List.last(complete["messages"])["text"] == "Feedback saved"
    assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "confirm", c.auth, c.server)
    refute_receive {:confirmed, _}
  end

  test "cancelled proposals never execute and uncertain writes reconcile without repeating", c do
    {chat, proposal} = propose(c)
    assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "cancel", c.auth, c.server)
    refute_receive {:confirmed, _}
    {next, pending} = propose(c)
    assert {:ok, _} = Store.decide(c.project, next["id"], pending["id"], "confirm", Map.put(c.auth, :action_result, :unknown), c.server)
    wait_chat(c, next, &(hd(&1["proposals"])["status"] == "unknown"))
    assert_receive {:confirmed, _}
    assert {:ok, _} = Store.decide(c.project, next["id"], pending["id"], "reconcile", c.auth, c.server)
    assert_receive {:reconciled, _}
    refute_receive {:confirmed, _}
    wait_chat(c, next, &(hd(&1["proposals"])["status"] == "completed"))
  end

  test "restart during a write requires reconciliation; stale authorization blocks tools", c do
    {chat, proposal} = propose(c)
    assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "confirm", Map.put(c.auth, :action_result, :wait), c.server)
    assert_receive {:confirmed, _}
    assert {:error, :chat_busy} = Store.decide(c.project, chat["id"], proposal["id"], "cancel", c.auth, c.server)
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, result} = Store.get(c.project, chat["id"], c.auth, server)
    assert hd(result["proposals"])["status"] == "unknown"
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "unauthorized tool", "auth-test", c.auth, server)
    assert_receive {:runtime, _, _, "proposal"}
    assert_receive {:runtime, running, _, "unauthorized tool"}
    Agent.update(c.access, fn _ -> false end)
    send(running, :continue)
    assert_receive {:tool_result, %{"error" => _}}
    assert {:error, :unauthorized} = Store.list(c.project, c.auth, server)
  end

  test "storage faults stop active response and preserve last durable record", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "wait", c.auth, c.server)
    assert_receive {:runtime, running, _, _}
    wait_chat(c, chat, &(get_in(&1, ["messages", Access.at(-1), "text"]) == "Partial response"))
    path = Path.join(c.root, chat["id"] <> ".json")
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, :chat_storage_unavailable} = Store.rename(c.project, chat["id"], "Rename", c.auth, c.server)
    refute Process.alive?(running)
    assert {:error, :chat_storage_unavailable} = Store.create(c.project, "Another", c.auth, c.server)
  end

  test "disabled chat and conflicting storage owners fail closed", c do
    disabled = start_supervised!({Store, name: nil, settings: %{enabled: false}, projects: fn -> [] end, authorize: fn _ -> true end}, id: :disabled)
    assert {:ok, []} = Store.projects(%{}, disabled)
    assert {:error, :chat_storage_locked} = Persistence.open(c.root)
    assert {:error, _} = Store.projects(%{}, :not_running)
  end

  defp create(c) do
    {:ok, chat} = Store.create(c.project, "New chat", c.auth, c.server)
    chat
  end

  defp propose(c) do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", "proposal", c.auth, c.server)
    final = wait_chat(c, chat, &(&1["status"] == "idle"))
    {final, hd(final["proposals"])}
  end

  defp wait_chat(c, chat, predicate, attempts \\ 100) do
    {:ok, current} = Store.get(c.project, chat["id"], c.auth, c.server)

    if predicate.(current) do
      current
    else
      assert attempts > 0, "chat state did not settle: #{inspect(current)}"
      Process.sleep(10)
      wait_chat(c, chat, predicate, attempts - 1)
    end
  end
end
