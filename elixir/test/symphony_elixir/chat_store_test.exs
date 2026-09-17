defmodule SymphonyElixir.Chat.StoreTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Chat.{Artifacts, Persistence, Store, ViewContext}

  defmodule TestRuntime do
    @spec run(map(), function(), function()) :: term()
    def run(opts, emit, tool) do
      send(opts.test_pid, {:runtime, self(), opts.thread_id, opts.text})
      before_events(opts.text)
      emit.({:thread, opts.thread_id || "native-#{System.unique_integer([:positive])}"})
      emit.({:status, "Reading project"})
      emit.({:usage, %{"totalTokens" => 10}})
      send(opts.test_pid, {:phase_ready, self(), opts.text})

      respond(opts.text, opts, emit, tool)
    end

    defp before_events("delay thread") do
      receive do
        :continue -> :ok
      end
    end

    defp before_events(_), do: :ok

    defp respond("delayed delta", _opts, emit, _tool) do
      receive do
        :continue -> :ok
      end

      emit.({:delta, "Buffered response"})

      receive do
        :finish -> {:ok, %{status: :completed}}
      end
    end

    defp respond("delay finish", _opts, _emit, _tool) do
      receive do
        :continue -> {:ok, %{status: :completed}}
      end
    end

    defp respond("ignore stop", opts, _emit, _tool) do
      receive do
        :interrupt -> send(opts.test_pid, :interrupt_received)
      end

      receive do
        :finish -> {:ok, %{status: :completed}}
      end
    end

    defp respond("view", opts, _emit, tool) do
      send(opts.test_pid, {:view_runtime, opts.view_context, opts.instructions})
      send(opts.test_pid, {:view_tool, tool.("symphony_view_context", %{})})
      {:ok, %{status: :completed}}
    end

    defp respond("status", opts, emit, tool) do
      emit.({:future_event, %{}})
      send(opts.test_pid, {:tool_result, tool.("symphony_project_status", %{})})
      emit.({:delta, "Current status is available in the card."})
      {:ok, %{status: :completed}}
    end

    defp respond("artifacts", opts, _emit, tool) do
      send(opts.test_pid, {:tool_result, tool.("artifacts", %{})})
      {:ok, %{status: :completed}}
    end

    defp respond("malformed tool", opts, _emit, tool) do
      send(opts.test_pid, {:tool_result, tool.("malformed", %{})})
      {:ok, %{status: :completed}}
    end

    defp respond("wait", _opts, emit, _tool) do
      emit.({:delta, "Partial response"})

      receive do
        :interrupt -> {:ok, %{status: :interrupted}}
        :finish -> {:ok, %{status: :completed}}
      end
    end

    defp respond("proposal", opts, emit, tool) do
      result = tool.("symphony_propose_action", %{})
      send(opts.test_pid, {:tool_result, result})
      emit.({:delta, "Review this action."})
      {:ok, %{status: :completed}}
    end

    defp respond("unauthorized tool", opts, _emit, tool) do
      receive do
        :continue -> :ok
      end

      send(opts.test_pid, {:tool_result, tool.("symphony_project_status", %{})})
      {:ok, %{status: :completed}}
    end

    defp respond("tool error", opts, _emit, tool) do
      send(opts.test_pid, {:tool_result, tool.("invalid", %{})})
      {:ok, %{status: :completed}}
    end

    defp respond("crash", _opts, _emit, _tool), do: exit(:runtime_failure)
    defp respond("error", _opts, _emit, _tool), do: {:error, :model_unavailable}
    defp respond("auth", _opts, _emit, _tool), do: {:error, :authentication_required}

    defp respond(_, _opts, emit, _tool) do
      emit.({:delta, "Hello "})
      emit.({:delta, "from the project."})
      {:ok, %{status: :completed}}
    end
  end

  defmodule TestTools do
    @spec specs() :: list()
    def specs, do: []
    @spec call(String.t(), map(), map()) :: term()
    def call("invalid", _, _), do: {:error, :invalid_tool}
    def call("malformed", _, _), do: :unavailable

    def call("symphony_view_context", _, ctx), do: {:ok, %{"snapshot" => ctx.view_context}}

    def call("artifacts", _, ctx) do
      task = %{
        "id" => ctx.project_id <> ":1",
        "issue_id" => "1",
        "project" => ctx.project_id,
        "title" => "Saved issue",
        "tracker_state" => "open",
        "checked_at" => "2026-09-16T12:00:00Z",
        "pull_requests" => [%{"number" => 10, "url" => "https://github.com/test/one/pull/10", "title" => "Saved PR", "state" => "open"}]
      }

      {:ok, %{"widgets" => [%{"type" => "task", "task" => task}]}}
    end

    def call("symphony_propose_action", _, ctx) do
      if ctx.auth[:delay_tool] do
        send(ctx.auth.test_pid, {:tool_prepared, self()})

        receive do
          :deliver -> :ok
        end
      end

      proposal = %{"action" => "feedback", "args" => %{"body" => "Please check this"}, "project_id" => ctx.project_id, "tracker_fingerprint" => ctx.tracker_fingerprint}
      {:ok, %{"proposal" => proposal, "widgets" => [%{"type" => "proposal"}], "references" => [%{"label" => "Task", "url" => "https://github.com/test/project/issues/1"}]}}
    end

    def call(_, _, _) do
      {:ok,
       %{
         "summary" => "No active tasks",
         "widgets" => [
           %{"type" => "status", "title" => "Current work", "url" => "/?project=github%3Atest%2Fone"}
         ]
       }}
    end

    @spec confirm(map(), map()) :: term()
    def confirm(proposal, ctx) do
      send(ctx.auth.test_pid, {:confirmed, proposal})
      send(ctx.auth.test_pid, {:action_started, self(), proposal["id"]})

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

      case ctx.auth[:reconcile_result] do
        :unavailable -> {:error, :github_unavailable}
        :unauthorized -> {:error, :unauthorized}
        :native_unavailable -> {:error, :native_receipt_required}
        _ -> {:ok, %{"summary" => "Existing feedback found"}}
      end
    end
  end

  setup do
    {:ok, tmp} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "symphony-chat-store-#{System.unique_integer([:positive])}")

    settings = %{
      enabled: true,
      state_path: root,
      codex_home: root <> "/runtime",
      executable: "/test/codex",
      timeout_ms: 3_000,
      max_concurrent: 2,
      test_pid: self()
    }

    project_reader = fn -> [%{"id" => "github:test/one", "label" => "One"}, %{"id" => "github:test/two", "label" => "Two"}] end
    {:ok, access} = Agent.start_link(fn -> true end)
    authorize = fn auth -> is_map(auth) and auth[:allowed] == true and Agent.get(access, & &1) end
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")

    opts = [
      name: name,
      settings: settings,
      projects: project_reader,
      authorize: authorize,
      runtime: TestRuntime,
      tools: TestTools
    ]

    server = start_supervised!({Store, opts})
    auth = %{allowed: true, tracker_fingerprint: "scope", test_pid: self()}
    on_exit(fn -> File.rm_rf(root) end)
    %{server: server, opts: opts, root: root, auth: auth, access: access, project: "github:test/one"}
  end

  test "health exposes only captured configuration and storage state to an authorized caller", c do
    create(c)
    before = :sys.get_state(c.server)
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
    assert :sys.get_state(c.server) == before
    assert {:error, :unauthorized} = Store.health(%{})
    assert {:error, :unauthorized} = Store.health(%{}, c.server)
    Agent.update(c.access, fn _ -> false end)
    assert {:error, :unauthorized} = Store.health(c.auth, c.server)
    refute_receive {:runtime, _, _, _}
  end

  test "health reports disabled configuration without treating it as ready or probing a runtime", c do
    opts = c.opts |> Keyword.put(:name, nil) |> Keyword.put(:settings, %{enabled: false})
    disabled = start_supervised!({Store, opts}, id: :disabled_health)
    assert Store.health(c.auth, disabled) == {:ok, %{enabled: false, healthy: false}}
    assert {:error, :unauthorized} = Store.health(%{}, disabled)
    refute_receive {:runtime, _, _, _}
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
    assert {:ok, [%{"id" => id, "title" => "A plan", "display_status" => "new"}]} = Store.list(c.project, c.auth, c.server)
    assert id == renamed["id"]
    assert {:ok, %{"archived" => true}} = Store.archive(c.project, chat["id"], c.auth, c.server)
    assert {:ok, []} = Store.list(c.project, c.auth, c.server)
    assert {:error, :chat_busy} = Store.send_message(c.project, chat["id"], "x", "x", c.auth, c.server)
  end

  test "thread summaries are scoped, bounded, and derive default titles without changing saved conversations", c do
    assert {:ok, chat} = Store.create(c.project, "New conversation", c.auth, c.server)
    assert {:ok, [%{"display_status" => "new", "snippet" => "", "message_count" => 0}]} = Store.list(c.project, c.auth, c.server)
    text = "  A useful question\n" <> String.duplicate("about this project ", 30)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], text, "summary", c.auth, c.server)
    finished = wait_chat(c, chat, &(&1["status"] == "idle"))
    assert {:ok, [summary]} = Store.list(c.project, c.auth, c.server)
    assert Map.keys(summary) |> Enum.sort() == Enum.sort(~w(id project_id title snippet updated_at status display_status archived message_count pinned))
    assert summary["title"] == text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 80)
    assert summary["snippet"] == "Hello from the project."
    assert summary["display_status"] == "idle"
    assert summary["message_count"] == 2
    assert finished["title"] == "New conversation"
    assert {:ok, []} = Store.list("github:test/two", c.auth, c.server)
    assert {:ok, []} = Store.list(c.project, %{c.auth | tracker_fingerprint: "other"}, c.server)
    assert {:error, :unauthorized} = Store.list(c.project, %{}, c.server)
  end

  test "project invalidation follows nonselected conversation lifecycle without streaming content or token churn", c do
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat_project:" <> c.project)
    project = c.project
    selected = create(c)
    assert_receive {:chat_list_updated, ^project}
    assert {:ok, chat} = Store.create(c.project, "New chat", c.auth, c.server)
    assert_receive {:chat_list_updated, ^project}
    assert {:ok, _} = Store.create("github:test/two", "Other project", c.auth, c.server)
    refute_receive {:chat_list_updated, _}

    assert {:ok, _} = Store.send_message(c.project, chat["id"], "delayed delta", "turn", c.auth, c.server)
    assert_receive {:chat_list_updated, ^project}
    assert_receive {:runtime, runtime, _, "delayed delta"}
    assert_receive {:phase_ready, ^runtime, "delayed delta"}
    assert {:ok, summaries} = Store.list(c.project, c.auth, c.server)
    assert Enum.find(summaries, &(&1["id"] == selected["id"]))["display_status"] == "new"
    assert Enum.find(summaries, &(&1["id"] == chat["id"]))["display_status"] == "running"
    send(runtime, :continue)
    wait_chat(c, chat, &(List.last(&1["messages"])["text"] == "Buffered response"))
    run = :sys.get_state(c.server).jobs[chat["id"]].run
    assert :ok = GenServer.call(c.server, {:runtime_event, chat["id"], run, {:status, "New activity"}})
    refute_receive {:chat_list_updated, _}
    assert {:ok, summaries} = Store.list(c.project, c.auth, c.server)
    assert Enum.find(summaries, &(&1["id"] == chat["id"]))["snippet"] == "delayed delta"

    send(runtime, :finish)
    wait_chat(c, chat, &(&1["status"] == "idle"))
    assert_receive {:chat_list_updated, ^project}
    assert {:ok, summaries} = Store.list(c.project, c.auth, c.server)
    assert Enum.find(summaries, &(&1["id"] == chat["id"]))["display_status"] == "idle"
    assert {:ok, _} = Store.archive(c.project, chat["id"], c.auth, c.server)
    assert_receive {:chat_list_updated, ^project}
    assert {:ok, [%{"id" => selected_id}]} = Store.list(c.project, c.auth, c.server)
    assert selected_id == selected["id"]
  end

  test "thread action states distinguish confirmation, execution, uncertain outcomes and stale failures", c do
    {chat, proposal} = propose(c)
    assert thread_summary(c, chat)["display_status"] == "awaiting_confirmation"
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat_project:" <> c.project)
    project = c.project
    auth = Map.put(c.auth, :action_result, :wait)
    assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "confirm", auth, c.server)
    assert_receive {:chat_list_updated, ^project}
    assert_receive {:action_started, action, _}
    assert thread_summary(c, chat)["display_status"] == "action"
    send(action, :finish)
    wait_chat(c, chat, &(hd(&1["proposals"])["status"] == "completed"))
    assert_receive {:chat_list_updated, ^project}
    assert thread_summary(c, chat)["display_status"] == "idle"

    {failed, failed_proposal} = propose(c)
    failed_auth = Map.put(c.auth, :action_result, :failed)
    assert {:ok, _} = Store.decide(c.project, failed["id"], failed_proposal["id"], "confirm", failed_auth, c.server)
    wait_chat(c, failed, &(hd(&1["proposals"])["status"] == "failed"))
    assert thread_summary(c, failed)["display_status"] == "error"
    assert {:ok, _} = Store.send_message(c.project, failed["id"], "Hello", "after-failure", c.auth, c.server)
    wait_chat(c, failed, &(&1["status"] == "idle"))
    assert thread_summary(c, failed)["display_status"] == "idle"

    {uncertain, uncertain_proposal} = propose(c)
    unknown_auth = Map.put(c.auth, :action_result, :unknown)
    assert {:ok, _} = Store.decide(c.project, uncertain["id"], uncertain_proposal["id"], "confirm", unknown_auth, c.server)
    wait_chat(c, uncertain, &(hd(&1["proposals"])["status"] == "unknown"))
    assert thread_summary(c, uncertain)["display_status"] == "needs_reconciliation"
  end

  test "errors, interruptions and recovery invalidate thread summaries without losing conversations", c do
    chat = create(c)
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat_project:" <> c.project)
    project = c.project
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "error", "error", c.auth, c.server)
    assert_receive {:chat_list_updated, ^project}
    wait_chat(c, chat, &(&1["status"] == "error"))
    assert_receive {:chat_list_updated, ^project}
    assert thread_summary(c, chat)["display_status"] == "error"

    assert {:ok, _} = Store.send_message(c.project, chat["id"], "delay finish", "held", c.auth, c.server)
    assert_receive {:chat_list_updated, ^project}
    assert_receive {:phase_ready, _, "delay finish"}
    assert thread_summary(c, chat)["display_status"] == "running"
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert_receive {:chat_list_updated, ^project}
    assert thread_summary(%{c | server: server}, chat)["display_status"] == "interrupted"
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert length(restored["messages"]) == 4
  end

  test "a storage fault stops action execution and shows reconciliation instead of a running action", c do
    {chat, proposal} = propose(c)
    assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "confirm", Map.put(c.auth, :action_result, :wait), c.server)
    assert_receive {:action_started, action, _}
    monitor = Process.monitor(action)
    assert thread_summary(c, chat)["display_status"] == "action"
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat_project:" <> c.project)
    project = c.project
    block_record(c, chat)
    assert {:error, :chat_storage_unavailable} = Store.rename(c.project, chat["id"], "Attempted rename", c.auth, c.server)
    assert_receive {:DOWN, ^monitor, :process, ^action, :shutdown}
    assert_receive {:chat_list_updated, ^project}
    assert thread_summary(c, chat)["display_status"] == "needs_reconciliation"
  end

  test "most recent action outcome follows decision order rather than proposal creation order", c do
    {chat, earlier} = propose(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", "second-proposal", c.auth, c.server)
    updated = wait_chat(c, chat, &(&1["status"] == "idle"))
    later = List.last(updated["proposals"])
    assert {:ok, _} = Store.decide(c.project, chat["id"], later["id"], "cancel", c.auth, c.server)
    assert {:ok, _} = Store.decide(c.project, chat["id"], earlier["id"], "confirm", Map.put(c.auth, :action_result, :failed), c.server)
    wait_chat(c, chat, &(hd(&1["proposals"])["status"] == "failed"))
    assert thread_summary(c, chat)["display_status"] == "error"

    :sys.replace_state(c.server, fn state ->
      update_in(state, [:chats, chat["id"], "proposals"], fn proposals ->
        Enum.map(proposals, &(&1 |> Map.put("created_at", "legacy-unknown") |> Map.delete("updated_at")))
      end)
    end)

    # Legacy records without observation times still open; they cannot prove a current failure.
    assert thread_summary(c, chat)["display_status"] == "idle"
  end

  test "identical update timestamps have stable thread ordering", c do
    first = create(c)
    second = create(c)

    :sys.replace_state(c.server, fn state ->
      Map.update!(state, :chats, &Map.new(&1, fn {id, chat} -> {id, Map.put(chat, "updated_at", "2026-09-16T00:00:00Z")} end))
    end)

    assert {:ok, summaries} = Store.list(c.project, c.auth, c.server)
    assert Enum.map(summaries, & &1["id"]) == Enum.sort([first["id"], second["id"]], :desc)
    assert {:ok, ^summaries} = Store.list(c.project, c.auth, c.server)
  end

  test "pins and same-group manual order persist atomically without rewriting conversations", c do
    [first, second, third] = Enum.map(1..3, fn _ -> create(c) end)
    originals = Map.new([first, second, third], &{&1["id"], File.read!(Path.join(c.root, &1["id"] <> ".json"))})
    assert {:ok, _} = Store.pin(c.project, first["id"], true, c.auth, c.server)
    assert {:ok, _} = Store.pin(c.project, second["id"], true, c.auth, c.server)
    assert {:ok, moved} = Store.move(c.project, second["id"], first["id"], true, c.auth, c.server)
    assert Enum.map(moved, &{&1["id"], &1["pinned"]}) == [{second["id"], true}, {first["id"], true}, {third["id"], false}]
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat_project:" <> c.project)
    assert {:ok, ^moved} = Store.move(c.project, second["id"], first["id"], true, c.auth, c.server)
    assert {:ok, ^moved} = Store.pin(c.project, first["id"], true, c.auth, c.server)
    refute_receive {:chat_list_updated, _}
    assert {:ok, _} = Store.pin(c.project, second["id"], false, c.auth, c.server)
    assert_receive {:chat_list_updated, _}
    assert {:ok, ordered} = Store.move(c.project, second["id"], third["id"], false, c.auth, c.server)
    assert Enum.map(ordered, & &1["id"]) == Enum.map([first, second, third], & &1["id"])
    assert {:ok, appended} = Store.move(c.project, second["id"], nil, false, c.auth, c.server)
    assert Enum.map(appended, & &1["id"]) == Enum.map([first, third, second], & &1["id"])
    assert Enum.all?(originals, fn {id, bytes} -> File.read!(Path.join(c.root, id <> ".json")) == bytes end)
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, ^appended} = Store.list(c.project, c.auth, server)
    assert {:ok, new} = Store.create(c.project, "Arrival", c.auth, server)
    assert {:ok, with_new} = Store.list(c.project, c.auth, server)
    assert Enum.map(with_new, & &1["id"]) == Enum.map([first, third, second, new], & &1["id"])
  end

  test "history commands reject invalid, archived, foreign and cross-group rows without changing state", c do
    [first, second] = Enum.map(1..2, fn _ -> create(c) end)
    assert {:ok, foreign} = Store.create("github:test/two", "Other", c.auth, c.server)
    assert {:ok, _} = Store.pin(c.project, first["id"], true, c.auth, c.server)

    foreign_scope = %{c.auth | tracker_fingerprint: "other"}

    for operation <- [:pin, :move] do
      group = if operation == :move, do: [true], else: []
      value = if operation == :pin, do: true, else: nil
      arguments = [c.project, first["id"], value] ++ group
      foreign_arguments = [c.project, foreign["id"], value] ++ group
      assert {:error, :unauthorized} = apply(Store, operation, arguments ++ [%{}, c.server])
      assert {:error, :chat_not_found} = apply(Store, operation, foreign_arguments ++ [c.auth, c.server])
      assert {:error, :chat_not_found} = apply(Store, operation, arguments ++ [foreign_scope, c.server])
    end

    assert {:error, :invalid_pin} = Store.pin(c.project, first["id"], "true", c.auth, c.server)

    for anchor <- [first["id"], "bad", %{}, second["id"]] do
      assert {:error, :invalid_chat_order} = Store.move(c.project, first["id"], anchor, true, c.auth, c.server)
    end

    for anchor <- [foreign["id"], String.duplicate("f", 32)] do
      assert {:error, :chat_not_found} = Store.move(c.project, first["id"], anchor, true, c.auth, c.server)
    end

    assert {:ok, _} = Store.archive(c.project, second["id"], c.auth, c.server)
    assert {:error, :chat_not_found} = Store.pin(c.project, second["id"], true, c.auth, c.server)
    assert {:error, :chat_not_found} = Store.move(c.project, first["id"], second["id"], true, c.auth, c.server)
    assert {:ok, [%{"pinned" => true}]} = Store.list(c.project, c.auth, c.server)
    assert {:ok, [%{"pinned" => false}]} = Store.list("github:test/two", c.auth, c.server)
    other_auth = %{c.auth | tracker_fingerprint: "new-project-version"}
    assert {:ok, versioned} = Store.create(c.project, "New scope", other_auth, c.server)
    assert {:ok, [%{"pinned" => true}]} = Store.pin(c.project, versioned["id"], true, other_auth, c.server)
    assert {:ok, [%{"id" => original_id, "pinned" => true}]} = Store.list(c.project, c.auth, c.server)
    assert original_id == first["id"]
  end

  test "concurrent history commands serialize while retaining all pins and streaming never resets order", c do
    [first, second, third] = Enum.map(1..3, fn _ -> create(c) end)
    jobs = for chat <- [first, second], do: Task.async(fn -> Store.pin(c.project, chat["id"], true, c.auth, c.server) end)
    assert Enum.all?(Task.await_many(jobs), &match?({:ok, _}, &1))
    moves = for chat <- [first, second], do: Task.async(fn -> Store.move(c.project, chat["id"], nil, true, c.auth, c.server) end)
    move_results = Task.await_many(moves)
    assert {:ok, final_move} = Store.list(c.project, c.auth, c.server)
    assert {:ok, final_move} in move_results
    assert Enum.sort(Enum.map(final_move, & &1["id"])) == Enum.sort(Enum.map([first, second, third], & &1["id"]))
    assert {:ok, ordered} = Store.move(c.project, first["id"], second["id"], true, c.auth, c.server)
    assert Enum.map(ordered, &{&1["id"], &1["pinned"]}) == [{first["id"], true}, {second["id"], true}, {third["id"], false}]
    assert {:ok, _} = Store.send_message(c.project, second["id"], "wait", "during-order", c.auth, c.server)
    wait_chat(c, second, &(List.last(&1["messages"])["text"] == "Partial response"))
    assert {:ok, streaming} = Store.list(c.project, c.auth, c.server)
    assert Enum.map(streaming, & &1["id"]) == Enum.map(ordered, & &1["id"])
  end

  test "unwritable or corrupt preference state never resets pins or removes the selected conversation", c do
    chat = create(c)
    assert {:ok, pinned} = Store.pin(c.project, chat["id"], true, c.auth, c.server)
    path = Path.join(c.root, "presentation.json")
    original = File.read!(path)
    File.rm!(path)
    File.mkdir!(path)
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat_project:" <> c.project)
    assert {:error, :chat_preferences_unavailable} = Store.pin(c.project, chat["id"], false, c.auth, c.server)
    refute_receive {:chat_list_updated, _}
    assert {:ok, ^pinned} = Store.list(c.project, c.auth, c.server)
    assert {:ok, _} = Store.get(c.project, chat["id"], c.auth, c.server)
    File.rmdir!(path)
    File.write!(path, original)
    assert {:ok, _} = Store.pin(c.project, chat["id"], false, c.auth, c.server)
    stop_supervised!(Store)
    File.write!(path, "{corrupt")
    server = start_supervised!({Store, c.opts})
    assert {:error, :chat_preferences_unavailable} = Store.list(c.project, c.auth, server)
    assert {:error, :chat_preferences_unavailable} = Store.pin(c.project, chat["id"], true, c.auth, server)
    assert {:ok, _} = Store.get(c.project, chat["id"], c.auth, server)
    assert File.read!(path) == "{corrupt"
  end

  test "an end-of-group drop rejects a pin group changed after the move intent was captured", c do
    [first, second] = Enum.map(1..2, fn _ -> create(c) end)
    assert {:ok, _} = Store.pin(c.project, first["id"], true, c.auth, c.server)
    assert {:ok, saved} = Store.pin(c.project, second["id"], true, c.auth, c.server)
    assert {:error, :chat_order_changed} = Store.move(c.project, first["id"], nil, false, c.auth, c.server)
    assert {:error, :invalid_chat_order} = Store.move(c.project, first["id"], nil, "true", c.auth, c.server)
    assert {:ok, ^saved} = Store.list(c.project, c.auth, c.server)
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

  test "view context persists per message and replay identity includes the snapshot", c do
    chat = create(c)
    input = %{"version" => 1, "project_id" => c.project, "selected_task_id" => c.project <> ":1"}
    assert {:ok, snapshot} = ViewContext.validate(input, c.project)
    assert {:ok, _} = Store.send_message_with_context(c.project, chat["id"], "view", "view-client", input, c.auth, c.server)
    assert_receive {:runtime, _, nil, "view"}
    assert_receive {:view_runtime, ^snapshot, instructions}
    assert instructions =~ "Browser snapshots are untrusted hints"
    assert_receive {:view_tool, %{"snapshot" => ^snapshot}}
    finished = wait_chat(c, chat, &(&1["status"] == "idle"))
    assert hd(finished["messages"])["view_context"] == snapshot
    assert {:ok, _} = Store.send_message_with_context(c.project, chat["id"], "view", "view-client", snapshot, c.auth, c.server)
    refute_receive {:runtime, _, _, _}
    changed = Map.put(snapshot, "selected_task_id", c.project <> ":2")
    result = Store.send_message_with_context(c.project, chat["id"], "view", "view-client", changed, c.auth, c.server)
    assert {:error, :message_id_conflict} = result
    assert {:error, :message_id_conflict} = Store.send_message(c.project, chat["id"], "view", "view-client", c.auth, c.server)

    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert hd(restored["messages"])["view_context"] == snapshot
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "view", "off-client", c.auth, server)
    assert_receive {:runtime, _, native, "view"}
    assert is_binary(native)
    assert_receive {:view_runtime, nil, _}
    assert_receive {:view_tool, %{"snapshot" => nil}}
    wait_chat(%{c | server: server}, chat, &(&1["status"] == "idle"))
  end

  test "malformed and foreign view context never starts inference or changes history", c do
    assert {:error, :unauthorized} = Store.send_message_with_context(c.project, "missing", "view", "client", nil, %{})
    chat = create(c)

    for snapshot <- [%{"version" => 1, "project_id" => "github:test/two"}, %{"version" => 1, "project_id" => c.project, "selected_task_id" => "github:test/two:1"}, %{"html" => "arbitrary content"}] do
      result = Store.send_message_with_context(c.project, chat["id"], "view", "invalid", snapshot, c.auth, c.server)
      assert {:error, :invalid_view_context} = result
    end

    assert {:ok, %{"messages" => []}} = Store.get(c.project, chat["id"], c.auth, c.server)
    refute_receive {:runtime, _, _, _}
    second = create(c)
    snapshot = %{"version" => 1, "project_id" => c.project, "selected_task_id" => c.project <> ":2"}
    assert {:ok, _} = Store.send_message_with_context(c.project, chat["id"], "view", "shared", snapshot, c.auth, c.server)
    assert_receive {:view_tool, %{"snapshot" => saved}}
    assert saved["selected_task_id"] == c.project <> ":2"
    wait_chat(c, chat, &(&1["status"] == "idle"))
    assert {:ok, _} = Store.send_message(c.project, second["id"], "view", "separate", c.auth, c.server)
    assert_receive {:view_tool, %{"snapshot" => nil}}
    wait_chat(c, second, &(&1["status"] == "idle"))
  end

  test "durable tool artifacts reopen after a real store restart without a migration or another provider read", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "artifacts", "artifacts-request", c.auth, c.server)
    assert_receive {:runtime, _, _, "artifacts"}
    wait_chat(c, chat, &(&1["status"] == "idle"))
    assert_receive {:tool_result, %{"widgets" => [_]}}
    assert {:ok, before_restart} = Store.get(c.project, chat["id"], c.auth, c.server)
    assert Enum.all?(before_restart["messages"], &match?({:ok, _, _}, DateTime.from_iso8601(&1["created_at"])))
    entries = Artifacts.entries(before_restart)
    assert Enum.map(entries, & &1["kind"]) == ["pull_request", "issue"]
    assert Enum.all?(entries, &(&1["checked_at"] == "2026-09-16T12:00:00Z"))

    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert restored["messages"] == before_restart["messages"]
    assert Artifacts.entries(restored) == entries
    refute_receive {:runtime, _, _, _}
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
    wait_chat(c, chat, &(List.last(&1["messages"])["text"] == "Partial response"))
    stop_supervised!(Store)
    refute Process.alive?(running)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert restored["status"] == "interrupted"
    assert List.last(restored["messages"])["status"] == "interrupted"
    assert List.last(restored["messages"])["text"] == "Partial response"
  end

  test "bounded concurrency, runtime failures and stale events never start extra work", c do
    first = create(c)
    second = create(c)
    third = create(c)

    for chat <- [first, second] do
      assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", chat["id"], c.auth, c.server)
    end

    assert {:error, :chat_capacity} = Store.send_message(c.project, third["id"], "Hello", "three", c.auth, c.server)
    assert {:ok, _} = Store.stop(c.project, first["id"], c.auth, c.server)
    wait_chat(c, first, &(&1["status"] == "interrupted"))

    for text <- ["error", "auth", "crash", "tool error", "malformed tool"] do
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
    assert {:ok, pending_at, _} = DateTime.from_iso8601(proposal["updated_at"])
    refute_receive {:confirmed, _}
    assert {:error, :proposal_not_found} = Store.decide(c.project, chat["id"], "missing", "confirm", c.auth, c.server)
    assert {:error, :invalid_decision} = Store.decide(c.project, chat["id"], proposal["id"], "yes maybe", c.auth, c.server)
    assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "confirm", c.auth, c.server)
    assert_receive {:confirmed, payload}
    refute Map.has_key?(payload, "status")
    refute Map.has_key?(payload, "updated_at")
    assert payload["id"] == proposal["id"]
    complete = wait_chat(c, chat, &(hd(&1["proposals"])["status"] == "completed"))
    assert {:ok, completed_at, _} = DateTime.from_iso8601(hd(complete["proposals"])["updated_at"])
    assert DateTime.compare(completed_at, pending_at) in [:eq, :gt]
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
    assert_receive {:reconciled, payload}
    refute Map.has_key?(payload, "updated_at")
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
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "wait", c.auth, c.server)
    assert_receive {:runtime, running, _, _}
    wait_chat(c, chat, &(get_in(&1, ["messages", Access.at(-1), "text"]) == "Partial response"))
    path = Path.join(c.root, chat["id"] <> ".json")
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, :chat_storage_unavailable} = Store.rename(c.project, chat["id"], "Rename", c.auth, c.server)
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: false}}
    refute Process.alive?(running)
    assert {:error, :chat_storage_unavailable} = Store.create(c.project, "Another", c.auth, c.server)
  end

  test "disabled chat and conflicting storage owners fail closed", c do
    opts = [name: nil, settings: %{enabled: false}, projects: fn -> [] end, authorize: fn _ -> true end]
    disabled = start_supervised!({Store, opts}, id: :disabled)
    assert {:ok, []} = Store.projects(%{}, disabled)
    assert {:error, :chat_storage_locked} = Persistence.open(c.root)
    assert {:error, _} = Store.projects(%{}, :not_running)
  end

  test "a reused submission id with different content is rejected and stays rejected after restart", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "Original request", "same-id", c.auth, c.server)
    assert_receive {:runtime, _, nil, "Original request"}
    original = wait_chat(c, chat, &(&1["status"] == "idle"))
    assert {:error, :message_id_conflict} = Store.send_message(c.project, chat["id"], "Different request", "same-id", c.auth, c.server)
    refute_receive {:runtime, _, _, _}
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:error, :message_id_conflict} = Store.send_message(c.project, chat["id"], "Different request", "same-id", c.auth, server)
    assert {:ok, replay} = Store.send_message(c.project, chat["id"], " Original request ", "same-id", c.auth, server)
    assert replay["messages"] == original["messages"]
    refute_receive {:runtime, _, _, _}
  end

  test "reconcile cannot substitute for confirming a pending action", c do
    {chat, proposal} = propose(c)
    assert {:error, :invalid_decision} = Store.decide(c.project, chat["id"], proposal["id"], "reconcile", c.auth, c.server)
    refute_receive {:confirmed, _}
    refute_receive {:reconciled, _}
    assert {:ok, saved} = Store.get(c.project, chat["id"], c.auth, c.server)
    assert hd(saved["proposals"])["status"] == "pending"
  end

  test "failed read-only reconciliation preserves unknown outcomes across retries and restart", c do
    {chat, proposal} = propose(c)
    assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "confirm", Map.put(c.auth, :action_result, :unknown), c.server)
    assert_receive {:confirmed, _}
    wait_chat(c, chat, &(hd(&1["proposals"])["status"] == "unknown"))

    for error <- [:unavailable, :unauthorized, :native_unavailable] do
      auth = Map.put(c.auth, :reconcile_result, error)
      assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "reconcile", auth, c.server)
      assert_receive {:reconciled, _}
      wait_chat(c, chat, &(hd(&1["proposals"])["status"] == "unknown"))
      refute_receive {:confirmed, _}
    end

    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert hd(restored["proposals"])["status"] == "unknown"
    assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "reconcile", c.auth, server)
    assert_receive {:reconciled, _}
    wait_chat(%{c | server: server}, chat, &(hd(&1["proposals"])["status"] == "completed"))
    refute_receive {:confirmed, _}
  end

  test "action execution shares the job capacity limit and frees capacity on completion", c do
    [{first, first_proposal}, {second, second_proposal}, {third, third_proposal}] = Enum.map(1..3, fn _ -> propose(c) end)
    blocked_auth = Map.put(c.auth, :action_result, :wait)

    for {chat, proposal} <- [{first, first_proposal}, {second, second_proposal}] do
      assert {:ok, _} = Store.decide(c.project, chat["id"], proposal["id"], "confirm", blocked_auth, c.server)
    end

    first_id = first_proposal["id"]
    second_id = second_proposal["id"]
    assert_receive {:action_started, first_pid, ^first_id}
    assert_receive {:action_started, second_pid, ^second_id}
    assert {:error, :chat_capacity} = Store.decide(c.project, third["id"], third_proposal["id"], "confirm", c.auth, c.server)
    assert {:error, :chat_capacity} = Store.send_message(c.project, third["id"], "Status", "capacity-test", c.auth, c.server)
    assert {:ok, pending} = Store.get(c.project, third["id"], c.auth, c.server)
    assert hd(pending["proposals"])["status"] == "pending"
    send(first_pid, :finish)
    wait_chat(c, first, &(hd(&1["proposals"])["status"] == "completed"))
    assert {:ok, _} = Store.decide(c.project, third["id"], third_proposal["id"], "confirm", c.auth, c.server)
    wait_chat(c, third, &(hd(&1["proposals"])["status"] == "completed"))
    send(second_pid, :finish)
    wait_chat(c, second, &(hd(&1["proposals"])["status"] == "completed"))
  end

  test "authorization is rechecked for every conversation mutation", c do
    {chat, proposal} = propose(c)
    Agent.update(c.access, fn _ -> false end)
    assert {:error, :unauthorized} = Store.rename(c.project, chat["id"], "Changed", c.auth, c.server)
    assert {:error, :unauthorized} = Store.archive(c.project, chat["id"], c.auth, c.server)
    assert {:error, :unauthorized} = Store.send_message(c.project, chat["id"], "New", "denied", c.auth, c.server)
    assert {:error, :unauthorized} = Store.stop(c.project, chat["id"], c.auth, c.server)
    assert {:error, :unauthorized} = Store.decide(c.project, chat["id"], proposal["id"], "confirm", c.auth, c.server)
    refute_receive {:confirmed, _}
    Agent.update(c.access, fn _ -> true end)
    assert {:ok, saved} = Store.get(c.project, chat["id"], c.auth, c.server)
    assert saved["messages"] == chat["messages"]
    assert hd(saved["proposals"])["status"] == "pending"
  end

  test "a status tool produces visible widgets and context references without an action", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "status", "read-status", c.auth, c.server)
    saved = wait_chat(c, chat, &(&1["status"] == "idle"))
    assert saved["proposals"] == []
    assert [%{"type" => "status", "title" => "Current work"}] = List.last(saved["messages"])["widgets"]

    assert [%{"label" => "Current work", "url" => "/?project=github%3Atest%2Fone", "checked_at" => time}] =
             Enum.filter(saved["context"], &(&1["label"] == "Current work"))

    assert {:ok, _, _} = DateTime.from_iso8601(time)
  end

  test "a rejected action stays failed and pending proposals survive a service restart", c do
    {pending_chat, pending} = propose(c)
    {failed_chat, failed} = propose(c)
    auth = Map.put(c.auth, :action_result, :failed)
    assert {:ok, _} = Store.decide(c.project, failed_chat["id"], failed["id"], "confirm", auth, c.server)
    saved = wait_chat(c, failed_chat, &(hd(&1["proposals"])["status"] == "failed"))
    assert is_binary(hd(saved["proposals"])["error"])
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, pending_saved} = Store.get(c.project, pending_chat["id"], c.auth, server)
    assert hd(pending_saved["proposals"])["id"] == pending["id"]
    assert hd(pending_saved["proposals"])["status"] == "pending"
    assert {:ok, failed_saved} = Store.get(c.project, failed_chat["id"], c.auth, server)
    assert hd(failed_saved["proposals"])["status"] == "failed"
  end

  test "Stop enforces its deadline when a runtime ignores interruption", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "ignore stop", "stubborn", c.auth, c.server)
    assert_receive {:runtime, pid, _, "ignore stop"}
    monitor = Process.monitor(pid)
    assert {:ok, _} = Store.stop(c.project, chat["id"], c.auth, c.server)
    assert_receive :interrupt_received
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 7_000
    saved = wait_chat(c, chat, &(&1["status"] == "interrupted"))
    assert List.last(saved["messages"])["status"] == "interrupted"
  end

  test "failure to save a turn or approval prevents its execution", c do
    chat = create(c)
    block_record(c, chat)
    assert {:error, :chat_storage_unavailable} = Store.send_message(c.project, chat["id"], "New", "not-started", c.auth, c.server)
    refute_receive {:runtime, _, _, _}
  end

  test "failure to save an approved proposal does not execute the action", c do
    {chat, proposal} = propose(c)
    block_record(c, chat)
    assert {:error, :chat_storage_unavailable} = Store.decide(c.project, chat["id"], proposal["id"], "confirm", c.auth, c.server)
    refute_receive {:confirmed, _}
  end

  for phase <- ["delay thread", "delayed delta", "delay finish"] do
    test "storage failure during #{phase} stops the response", c do
      chat = create(c)
      phase = unquote(phase)
      assert {:ok, _} = Store.send_message(c.project, chat["id"], phase, phase, c.auth, c.server)
      assert_receive {:runtime, pid, _, ^phase}
      if phase != "delay thread", do: assert_receive({:phase_ready, ^pid, ^phase})
      block_record(c, chat)
      send(pid, :continue)
      saved = wait_chat(c, chat, &(&1["status"] == "error"))
      assert saved["error"] =~ "storage"
    end
  end

  test "failure to save a tool proposal cannot leave an approved action", c do
    chat = create(c)
    auth = Map.put(c.auth, :delay_tool, true)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", "delayed-proposal", auth, c.server)
    assert_receive {:tool_prepared, pid}
    block_record(c, chat)
    send(pid, :deliver)
    saved = wait_chat(c, chat, &(&1["status"] == "error"))
    assert saved["proposals"] == []
    refute_receive {:confirmed, _}
  end

  test "losing the OS ownership lock stops active work and rejects new writes", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "lock-loss", c.auth, c.server)
    assert_receive {:runtime, pid, _, "wait"}
    wait_chat(c, chat, &(List.last(&1["messages"])["text"] == "Partial response"))
    # Kill the actual lock helper to exercise loss of OS ownership, not a synthetic store event.
    lock = :sys.get_state(c.server).persistence.lock
    {:os_pid, os_pid} = Port.info(lock, :os_pid)
    assert {_, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    wait_chat(c, chat, &(&1["status"] == "error"))
    refute Process.alive?(pid)
    assert {:error, :chat_storage_unavailable} = Store.create(c.project, "Blocked", c.auth, c.server)
  end

  test "unavailable storage remains explicit while configured project discovery still works", c do
    path = Path.join(c.root, "unavailable")
    File.write!(path, "retained")
    settings = Keyword.fetch!(c.opts, :settings) |> Map.put(:state_path, path)
    options = c.opts |> Keyword.put(:name, nil) |> Keyword.put(:settings, settings)
    unavailable = start_supervised!({Store, options}, id: :unavailable_storage)
    assert Store.health(c.auth, unavailable) == {:ok, %{enabled: true, healthy: false}}
    assert {:error, :chat_storage_unavailable} = Store.create(c.project, "Blocked", c.auth, unavailable)
    assert File.read!(path) == "retained"

    previous_workflow = SymphonyElixir.Workflow.workflow_file_path()
    workflow = Path.join(c.root, "WORKFLOW.md")

    config = %{
      tracker: %{
        kind: "github",
        provider: %{repo: "example/discovery", token: "fixture-only-token"},
        active_states: ["open"],
        terminal_states: ["closed"]
      }
    }

    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    SymphonyElixir.Workflow.set_workflow_file_path(workflow)

    try do
      :ok = SymphonyElixir.WorkflowStore.force_reload()
      default_options = [name: nil, settings: %{enabled: false}, authorize: fn _ -> true end]
      defaults = start_supervised!({Store, default_options}, id: :configured_projects)
      assert {:ok, [%{"id" => "github:example/discovery"}]} = Store.projects(%{}, defaults)
    after
      SymphonyElixir.Workflow.set_workflow_file_path(previous_workflow)
      SymphonyElixir.WorkflowStore.force_reload()
    end
  end

  defp block_record(c, chat) do
    path = Path.join(c.root, chat["id"] <> ".json")
    File.rm!(path)
    File.mkdir!(path)
  end

  defp create(c) do
    {:ok, chat} = Store.create(c.project, "New chat", c.auth, c.server)
    chat
  end

  defp thread_summary(c, chat) do
    assert {:ok, summaries} = Store.list(c.project, c.auth, c.server)
    Enum.find(summaries, &(&1["id"] == chat["id"]))
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
