defmodule SymphonyElixir.Chat.StoreTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Chat.{Artifacts, Persistence, PRUpdates, Sessions, Store, ViewContext}

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

    defp respond("report interleaving", opts, emit, tool) do
      receive do
        :deliver_tools ->
          send(opts.test_pid, {:report_tool, tool.("artifacts", %{})})
          emit.({:delta, "Agent response"})
      end

      receive do
        :interrupt -> {:ok, %{status: :interrupted}}
        :finish -> {:ok, %{status: :completed}}
      end
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

    defp respond("provider-error:" <> reason, _opts, _emit, _tool) do
      errors = %{
        "auth" => :openrouter_auth_required,
        "rate" => :openrouter_rate_limited,
        "unavailable" => :openrouter_unavailable,
        "limit" => :openrouter_tool_limit,
        "budget" => :provider_budget_exhausted,
        "unknown" => :protocol_error
      }

      {:error, Map.fetch!(errors, reason)}
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

  defmodule CheckpointRuntime do
    @spec run(map(), function(), function()) :: term()
    def run(opts, emit, _tool) do
      send(opts.test_pid, {:checkpoint, opts.history, opts.model, opts.thread_id})
      emit.({:delta, "Continued from saved context"})
      {:ok, %{status: :completed}}
    end
  end

  defmodule TestTools do
    @spec specs() :: list()
    def specs, do: []
    @spec call(String.t(), map(), map()) :: term()
    def call("invalid", _, _), do: {:error, :invalid_tool}
    def call("malformed", _, _), do: :unavailable

    def call("symphony_view_context", _, ctx), do: {:ok, %{"snapshot" => ctx.view_context, "task_id" => ctx.task_id}}

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
      proposal = ctx.auth[:pr_work_proposal] || proposal
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
      if ctx.auth[:pr_work_proposal], do: send(ctx.auth.test_pid, {:confirmed_scope, ctx.task_id})
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
      if ctx.auth[:pr_work_proposal], do: send(ctx.auth.test_pid, {:reconciled_scope, ctx.task_id})

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
      tools: TestTools,
      session_reader: fn task_id, session, context ->
        if task_id == "github:test/one:11" do
          Sessions.resolve(pr_task(), session, context.tracker_fingerprint)
        else
          {:error, :pr_session_unavailable}
        end
      end
    ]

    server = start_supervised!({Store, opts})
    auth = %{allowed: true, tracker_fingerprint: "scope", test_pid: self()}
    on_exit(fn -> File.rm_rf(root) end)
    %{server: server, opts: opts, root: root, auth: auth, access: access, project: "github:test/one"}
  end

  test "PR chats are canonical, separate from the issue main thread and retain binding across restart", c do
    task = pr_task()
    session = "work:" <> String.duplicate("a", 32)
    children = 1..6 |> Task.async_stream(fn _ -> Store.ensure_pr_conversation(c.project, task.id, session, c.auth, c.server) end) |> Enum.map(fn {:ok, {:ok, chat}} -> chat end)
    assert length(Enum.uniq_by(children, & &1["id"])) == 1
    child = hd(children)
    assert child["conversation_role"] == "pr"
    assert child["session_id"] == session
    assert {:ok, parent} = Store.ensure_conversation(c.project, task.id, c.auth, c.server)
    refute child["id"] == parent["id"]
    assert {:ok, other} = Store.ensure_pr_conversation(c.project, task.id, "pr:22", c.auth, c.server)
    refute other["id"] in [parent["id"], child["id"]]
    assert {:error, :pr_session_unavailable} = Store.ensure_pr_conversation(c.project, task.id, "pr:999", c.auth, c.server)
    assert {:error, :pr_session_unavailable} = Store.ensure_pr_conversation(c.project, "github:test/two:11", session, c.auth, c.server)
    assert {:error, :unauthorized} = Store.ensure_pr_conversation(c.project, task.id, session, %{}, c.server)
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.ensure_pr_conversation(c.project, task.id, session, c.auth, server)
    assert restored["id"] == child["id"]
    assert {:ok, chats} = Store.list(c.project, c.auth, server)
    assert length(chats) == 4
  end

  test "read-only PR polling delivers independent durable reports to main and matching PR chats without model turns", c do
    task = pr_task()
    assert {:ok, child} = Store.ensure_pr_conversation(c.project, task.id, "work:" <> String.duplicate("a", 32), c.auth, c.server)
    assert {:ok, other} = Store.ensure_pr_conversation(c.project, task.id, "pr:22", c.auth, c.server)
    assert {:ok, parent} = Store.ensure_conversation(c.project, task.id, c.auth, c.server)
    board = report_board(task)
    reader = fn -> {:ok, c.project, c.auth.tracker_fingerprint, board} end
    sync = start_supervised!({PRUpdates, name: nil, store: c.server, interval_ms: :manual, reader: reader})
    assert :ok = PRUpdates.sync(sync)
    assert {:ok, main} = Store.get(c.project, parent["id"], c.auth, c.server)
    assert length(main["messages"]) == 3
    assert Enum.any?(main["messages"], &String.contains?(&1["text"], "PR #14"))
    assert Enum.any?(main["messages"], &String.contains?(&1["text"], "PR #22"))
    assert {:ok, selected} = Store.get(c.project, child["id"], c.auth, c.server)
    assert length(selected["messages"]) == 2
    assert Enum.all?(selected["messages"], &(&1["session_id"] == child["session_id"]))
    assert {:ok, second} = Store.get(c.project, other["id"], c.auth, c.server)
    assert length(second["messages"]) == 1
    refute_receive {:runtime, _, _, _}

    assert :ok = PRUpdates.sync(sync)
    assert {:ok, unchanged} = Store.get(c.project, parent["id"], c.auth, c.server)
    assert unchanged["messages"] == main["messages"]
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert :ok = Store.sync_pr_updates(c.project, "scope", board, server)
    assert {:ok, restored} = Store.get(c.project, parent["id"], c.auth, server)
    assert restored["messages"] == main["messages"]
    assert {:ok, _} = Store.send_message(c.project, child["id"], "view", "view-pr", c.auth, server)
    assert_receive {:view_runtime, nil, instructions}
    assert instructions =~ "work session work:"
    assert instructions =~ "Recent PR reports"
    assert instructions =~ "PR #14"
  end

  test "reports preserve streaming assistant ownership through widgets, deltas and cancellation", c do
    task = pr_task()
    assert {:ok, chat} = Store.ensure_conversation(c.project, task.id, c.auth, c.server)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "report interleaving", "stream", c.auth, c.server)
    assert_receive {:runtime, runtime, _, "report interleaving"}
    assert_receive {:phase_ready, ^runtime, _}
    assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(task), c.server)
    send(runtime, :deliver_tools)
    assert_receive {:report_tool, %{"widgets" => [_]}}
    assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(pr_task("owner_review"), 1), c.server)
    assert {:ok, stopped} = Store.stop(c.project, chat["id"], c.auth, c.server)
    assert stopped["status"] in ["running", "interrupted"]
    settled = wait_chat(c, chat, &(&1["status"] == "interrupted"))
    assert List.last(settled["messages"])["text"] == "Agent response"
    assert length(List.last(settled["messages"])["widgets"]) == 1
    assert Enum.all?(Enum.filter(settled["messages"], &(&1["origin"] == "pr_update")), &(&1["widgets"] == [] and &1["status"] == "completed"))
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert restored["messages"] == settled["messages"]
  end

  test "report receipts ignore stale or foreign reads and cap host reports without deleting conversation history", c do
    task = pr_task()
    assert {:ok, chat} = Store.ensure_conversation(c.project, task.id, c.auth, c.server)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "hello", "user", c.auth, c.server)
    wait_chat(c, chat, &(&1["status"] == "idle"))

    for n <- 1..85 do
      updated = put_in(task, [:ledger, "active"], %{"run_id" => "run-#{n}", "work_id" => String.duplicate("a", 32)})
      assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(updated, n), c.server)
    end

    assert {:ok, full} = Store.get(c.project, chat["id"], c.auth, c.server)
    assert length(Enum.filter(full["messages"], &(&1["origin"] == "pr_update"))) == 80
    assert Enum.any?(full["messages"], &(&1["role"] == "user" and &1["text"] == "hello"))
    assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(pr_task("paused")), c.server)
    assert :ok = Store.sync_pr_updates(c.project, "foreign", report_board(pr_task("paused"), 100), c.server)
    unavailable = %{report_board(task, 100) | source_error: "Unavailable"}
    assert {:error, :board_unavailable} = Store.sync_pr_updates(c.project, "scope", unavailable, c.server)
    assert {:ok, same} = Store.get(c.project, chat["id"], c.auth, c.server)
    assert Enum.filter(same["messages"], &(&1["origin"] == "pr_update")) == Enum.filter(full["messages"], &(&1["origin"] == "pr_update"))
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
  end

  test "slow PR selection leaves streaming and cancellation responsive and rechecks access before creation", c do
    parent = self()

    reader = fn _task, session, context ->
      send(parent, {:selection_read, self()})

      receive do
        :continue -> Sessions.resolve(pr_task(), session, context.tracker_fingerprint)
      end
    end

    :sys.replace_state(c.server, &%{&1 | session_reader: reader})
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "active", c.auth, c.server)
    assert_receive {:runtime, _, _, "wait"}
    selecting = Task.async(fn -> Store.ensure_pr_conversation(c.project, pr_task().id, "pr:22", c.auth, c.server) end)
    assert_receive {:selection_read, reader_pid}
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
    assert {:ok, _} = Store.stop(c.project, chat["id"], c.auth, c.server)
    wait_chat(c, chat, &(&1["status"] == "interrupted"))
    Agent.update(c.access, fn _ -> false end)
    send(reader_pid, :continue)
    assert Task.await(selecting) == {:error, :unauthorized}
    Agent.update(c.access, fn _ -> true end)
    assert {:ok, [_]} = Store.list(c.project, c.auth, c.server)

    for failing <- [fn _, _, _ -> raise "reader failed" end, fn _, _, _ -> exit(:reader_stopped) end] do
      :sys.replace_state(c.server, &%{&1 | session_reader: failing})
      result = Store.ensure_pr_conversation(c.project, pr_task().id, "pr:22", c.auth, c.server)
      assert result == {:error, :pr_session_unavailable}
      assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
    end
  end

  test "report replay after a recipient write failure neither loses another recipient nor duplicates its reports", c do
    task = pr_task()
    assert {:ok, _} = Store.ensure_pr_conversation(c.project, task.id, "work:" <> String.duplicate("a", 32), c.auth, c.server)
    assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(task), c.server)

    [delivered_id, failed_id] =
      :sys.get_state(c.server).chats
      |> Enum.filter(fn {_, chat} -> chat["conversation_role"] == "task" or String.starts_with?(chat["session_id"] || "", "work:") end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    task = pr_task("owner_review")
    original = File.read!(Path.join(c.root, failed_id <> ".json"))
    block_record(c, %{"id" => failed_id})
    assert {:error, :chat_storage_unavailable} = Store.sync_pr_updates(c.project, "scope", report_board(task), c.server)
    delivered = File.read!(Path.join(c.root, delivered_id <> ".json")) |> Jason.decode!()
    assert delivered["messages"] != []
    stop_supervised!(Store)
    File.rmdir!(Path.join(c.root, failed_id <> ".json"))
    File.write!(Path.join(c.root, failed_id <> ".json"), original)
    server = start_supervised!({Store, c.opts})
    assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(task), server)
    assert {:ok, first} = Store.get(c.project, delivered_id, c.auth, server)
    assert first["messages"] == delivered["messages"]
    assert {:ok, second} = Store.get(c.project, failed_id, c.auth, server)
    assert second["messages"] != []
    assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(task), server)
    assert {:ok, unchanged} = Store.get(c.project, failed_id, c.auth, server)
    assert unchanged["messages"] == second["messages"]
  end

  test "a report storage fault cannot restore running status after all jobs have stopped", c do
    task = pr_task()
    assert {:ok, _} = Store.ensure_pr_conversation(c.project, task.id, "pr:22", c.auth, c.server)
    [failed_id, running_id] = :sys.get_state(c.server).chats |> Enum.reject(fn {_, chat} -> chat["conversation_role"] == "main" end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(task), c.server)
    assert {:ok, _} = Store.send_message(c.project, running_id, "wait", "active", c.auth, c.server)
    assert_receive {:runtime, runtime, _, "wait"}
    monitor = Process.monitor(runtime)
    # Settle this recipient's bootstrap receipt before replacing its record;
    # the other conversation remains active for the storage-fault assertion.
    wait_chat(c, %{"id" => failed_id}, &(&1["status"] == "idle"))
    block_record(c, %{"id" => failed_id})
    # Simulate recovery where only this recipient still needs the same report.
    :sys.replace_state(c.server, &put_in(&1, [:chats, failed_id, "pr_report_receipts"], %{}))
    assert {:error, reason} = Store.sync_pr_updates(c.project, "scope", report_board(task, 1), c.server)
    assert reason in [:chat_storage_unavailable, :board_unavailable]
    assert_receive {:DOWN, ^monitor, :process, ^runtime, _}
    assert :sys.get_state(c.server).jobs == %{}
    assert {:ok, stopped} = Store.get(c.project, running_id, c.auth, c.server)
    refute stopped["status"] == "running"
    assert {:error, :board_unavailable} = Store.sync_pr_updates(c.project, "scope", report_board(task, 2), c.server)
    assert {:ok, still_stopped} = Store.get(c.project, running_id, c.auth, c.server)
    refute still_stopped["status"] == "running"
  end

  test "repeated milestones get distinct message identities and multibyte reports remain within storage bounds", c do
    task = pr_task()
    assert {:ok, chat} = Store.ensure_conversation(c.project, task.id, c.auth, c.server)

    for {phase, n} <- Enum.with_index(["building", "reviewing", "building"]) do
      assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(pr_task(phase), n), c.server)
    end

    assert {:ok, changed} = Store.get(c.project, chat["id"], c.auth, c.server)
    assert length(changed["messages"]) == 5
    assert length(Enum.uniq_by(changed["messages"], & &1["id"])) == 5
    summary = String.duplicate("👨‍👩‍👧‍👦", 1500)
    task = put_in(pr_task("owner_review"), [:ledger, "pr_work", String.duplicate("a", 32), "handoff"], %{"summary" => summary})
    assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(task, 3), c.server)
    assert {:ok, bounded} = Store.get(c.project, chat["id"], c.auth, c.server)
    assert Enum.all?(bounded["messages"], &(String.valid?(&1["text"]) and byte_size(&1["text"]) <= 8000))
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
  end

  test "PR selection rejects mismatched lookup results and incompatible retained bindings", c do
    ensure = fn -> Store.ensure_pr_conversation(c.project, pr_task().id, "pr:22", c.auth, c.server) end
    reader = Keyword.fetch!(c.opts, :session_reader)
    :sys.replace_state(c.server, &%{&1 | session_reader: fn _, _, _ -> {:ok, %{"task_id" => "other", "session_id" => "pr:22"}} end})
    assert {:error, :pr_session_unavailable} = ensure.()
    assert {:ok, []} = Store.list(c.project, c.auth, c.server)
    :sys.replace_state(c.server, &%{&1 | session_reader: reader})
    assert {:ok, child} = ensure.()
    :sys.replace_state(c.server, &put_in(&1, [:chats, child["id"], "session_id"], "pr:99"))
    assert {:error, :chat_binding_conflict} = ensure.()
  end

  test "failure to save the parent prevents orphan PR conversations", c do
    id = Persistence.conversation_id(c.project, pr_task().id, c.auth.tracker_fingerprint)
    File.mkdir!(Path.join(c.root, id <> ".json"))
    result = Store.ensure_pr_conversation(c.project, pr_task().id, "pr:22", c.auth, c.server)
    assert result == {:error, :chat_storage_unavailable}
    assert Enum.all?(:sys.get_state(c.server).chats, fn {_, chat} -> chat["conversation_role"] == "main" end)
    assert :sys.get_state(c.server).jobs == %{}
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: false}}
    assert {:error, :board_unavailable} = Store.sync_pr_updates(c.project, "scope", %{})
  end

  defp pr_task(phase \\ "building") do
    id = String.duplicate("a", 32)

    work = %{
      "id" => id,
      "issue_id" => "11",
      "tracker_fingerprint" => "scope",
      "phase" => phase,
      "instruction" => "Implement this PR",
      "builder_thread_id" => "worker-1",
      "head_sha" => String.duplicate("b", 40),
      "updated_at" => "2026-09-23T10:00:00Z",
      "publication" => %{"pr_number" => 14, "pr_url" => "https://github.com/test/one/pull/14", "status" => "ready"}
    }

    prs =
      for n <- [14, 22],
          do: %{
            number: n,
            url: "https://github.com/test/one/pull/#{n}",
            title: "Change #{n}",
            state: "open",
            checks: "pending",
            review: "no_decision",
            head_sha: String.duplicate("b", 40),
            updated_at: "2026-09-23T10:00:00Z"
          }

    %{
      id: "github:test/one:11",
      project: "github:test/one",
      issue_id: "11",
      github_status: "available",
      ledger: %{"pr_work" => %{id => work}, "selected_work_id" => id},
      pull_requests: prs
    }
  end

  defp report_board(task, seconds \\ 0) do
    %{tasks: [task], source_error: nil, runtime_error: nil, generated_at: DateTime.add(~U[2026-09-23 10:00:00Z], seconds) |> DateTime.to_iso8601()}
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

    assert Map.keys(summary) |> Enum.sort() ==
             Enum.sort(~w(id project_id title snippet updated_at status display_status archived message_count pinned task_id session_id conversation_role queued_count queue_paused))

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
    assert_receive {:view_runtime, ^snapshot, instructions}, 1_000
    assert instructions =~ "Browser snapshots are untrusted hints"
    assert instructions =~ "Symphony's project agent"
    assert instructions =~ "Description and verification (tests or observable acceptance checks) are optional and may be empty"
    assert instructions =~ "The user confirms the exact"
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
    assert_receive {:view_runtime, nil, _}, 1_000
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
    assert_receive {:view_tool, %{"snapshot" => saved}}, 2_000
    assert saved["selected_task_id"] == c.project <> ":2"
    wait_chat(c, chat, &(&1["status"] == "idle"))
    assert {:ok, _} = Store.send_message(c.project, second["id"], "view", "separate", c.auth, c.server)
    assert_receive {:view_tool, %{"snapshot" => nil}}, 2_000
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

  test "provider and model changes preserve identity, host receipts and native history across settled restarts", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "status", "checkpoint-original", c.auth, c.server)
    assert_receive {:runtime, _, _, "status"}
    initial = wait_chat(c, chat, &(&1["status"] == "idle"))
    assert [%{"tool" => "symphony_project_status", "result" => result}] = List.last(initial["messages"])["tool_receipts"]
    assert result =~ "No active tasks"
    original = disk_chat(c, chat)
    initial_native = original["codex_thread_id"]
    stop_supervised!(Store)
    receipt = %{"tool" => "symphony_project_status", "arguments" => %{}, "result" => String.duplicate("x", 65_080)}
    oversized = List.last(original["messages"]) |> Map.put("text", String.duplicate("x", 600)) |> Map.put("tool_receipts", [receipt])
    receipt_only = oversized |> Map.put("id", String.duplicate("f", 32)) |> Map.put("text", "")
    saved = Map.put(original, "messages", [hd(original["messages"]), oversized, receipt_only])
    File.write!(Path.join(c.root, chat["id"] <> ".json"), Jason.encode!(saved))

    for {model, sequence} <- [{"deepseek/model-a", "a"}, {"deepseek/model-b", "b"}] do
      if sequence == "b", do: stop_supervised!(Store)
      settings = Keyword.fetch!(c.opts, :settings) |> Map.merge(%{provider: "openrouter", model: model, api_key: "private-fixture-key"})
      opts = c.opts |> Keyword.put(:settings, settings) |> Keyword.put(:runtime, CheckpointRuntime)
      server = start_supervised!({Store, opts})
      assert {:ok, _} = Store.send_message(c.project, chat["id"], "Continue " <> sequence, "checkpoint-" <> sequence, c.auth, server)
      assert_receive {:checkpoint, history, ^model, ^initial_native}
      assert hd(history) == %{"role" => "user", "content" => "status"}
      assert Enum.any?(history, &String.contains?(&1["content"], "symphony_project_status"))
      assert Enum.all?(history, &(String.valid?(&1["content"]) and byte_size(&1["content"]) <= 65_536))
      assert Enum.at(history, 1)["content"] =~ "Context truncated"
      assert Enum.at(history, 2)["content"] =~ "Host tool receipts"
      restored = wait_chat(%{c | server: server}, chat, &(&1["status"] == "idle"))
      assert restored["id"] == chat["id"]
      assert List.last(restored["messages"])["runtime"]["model"] == model
      assert disk_chat(c, chat)["codex_thread_id"] == initial_native
      refute Jason.encode!(restored) =~ "private-fixture-key"
    end
  end

  test "OpenRouter diagnostics distinguish credential capacity and protocol failures", c do
    for {reason, text} <- [
          {"auth", "OpenRouter key"},
          {"rate", "rate limited"},
          {"unavailable", "conversation is saved"},
          {"limit", "tool-call limit"},
          {"budget", "account budget"},
          {"unknown", "chat runtime"}
        ] do
      chat = create(c)
      assert {:ok, _} = Store.send_message(c.project, chat["id"], "provider-error:" <> reason, "error-" <> reason, c.auth, c.server)
      assert_receive {:runtime, _, _, _}
      failed = wait_chat(c, chat, &(&1["status"] == "error"))
      assert failed["error"] =~ text
      refute failed["error"] =~ "dedicated management-chat Codex"
      assert :sys.get_state(c.server).fault == nil
    end
  end

  test "an unresolved OpenRouter model is a configuration error rather than a storage failure", c do
    chat = create(c)
    stop_supervised!(Store)
    settings = Keyword.fetch!(c.opts, :settings) |> Map.merge(%{provider: "openrouter", model: nil, api_key: "private-fixture-key"})
    opts = c.opts |> Keyword.put(:settings, settings) |> Keyword.put(:runtime, SymphonyElixir.Chat.Provider)
    server = start_supervised!({Store, opts})
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "status", "invalid-model", c.auth, server)
    failed = wait_chat(%{c | server: server}, chat, &(&1["status"] == "error"))
    assert failed["error"] =~ "configured chat model"
    assert List.last(failed["messages"])["runtime"]["model"] == "unconfigured"
    assert :sys.get_state(server).fault == nil
    assert {:ok, %{"id" => _}} = Store.create(c.project, "Another chat", c.auth, server)
  end

  test "legacy tool callbacks and oversized receipts cannot corrupt saved conversation state", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "receipt-compatibility", c.auth, c.server)
    assert_receive {:runtime, pid, _, "wait"}
    assert_receive {:phase_ready, ^pid, "wait"}
    run = :sys.get_state(c.server).jobs[chat["id"]].run
    result = %{"message" => "Legacy callback"}
    assert ^result = GenServer.call(c.server, {:tool_result, chat["id"], run, result})
    large = %{"message" => String.duplicate("x", 65_536)}
    assert ^large = GenServer.call(c.server, {:tool_result, chat["id"], run, %{tool: "symphony_project_status", arguments: %{}}, large})
    send(pid, :finish)
    saved = wait_chat(c, chat, &(&1["status"] == "idle"))
    assert Map.get(List.last(saved["messages"]), "tool_receipts", []) == []
    assert :sys.get_state(c.server).fault == nil
  end

  test "Stop denies new tools and delegation while the current runtime settles", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "ignore stop", "stopping-tools", c.auth, c.server)
    assert_receive {:runtime, pid, _, "ignore stop"}
    assert_receive {:phase_ready, ^pid, "ignore stop"}
    run = :sys.get_state(c.server).jobs[chat["id"]].run
    assert {:ok, _} = Store.stop(c.project, chat["id"], c.auth, c.server)
    assert_receive :interrupt_received
    assert {:error, :stale_turn} = GenServer.call(c.server, {:tool_context, chat["id"], run, c.auth})
    assert {:error, :stale_turn} = GenServer.call(c.server, {:coordinate, chat["id"], run, "symphony_delegate", %{}, c.auth})
    send(pid, :finish)
    assert wait_chat(c, chat, &(&1["status"] == "interrupted"))["queued_count"] == 0
  end

  test "Stop cancels only chat execution and interrupted service restarts retain history", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "client", c.auth, c.server)
    assert_receive {:runtime, pid, _, "wait"}
    wait_chat(c, chat, &(get_in(&1, ["messages", Access.at(-1), "text"]) == "Partial response"))
    assert {:error, :chat_busy} = Store.archive(c.project, chat["id"], c.auth, c.server)
    assert {:ok, %{"queue" => [queued]}} = Store.send_message(c.project, chat["id"], "Again", "queued", c.auth, c.server)
    assert {:ok, _} = Store.remove_queued(c.project, chat["id"], queued["id"], c.auth, c.server)
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

    assert {:ok, %{"queued_count" => 1}} = Store.send_message(c.project, third["id"], "delay finish", "three", c.auth, c.server)
    assert {:ok, _} = Store.stop(c.project, first["id"], c.auth, c.server)
    wait_chat(c, first, &(&1["status"] == "interrupted"))
    assert_receive {:runtime, third_runtime, _, "delay finish"}
    assert_receive {:phase_ready, ^third_runtime, "delay finish"}
    send(third_runtime, :continue)
    wait_chat(c, third, &(&1["status"] == "idle" and &1["queued_count"] == 0))

    for {text, status} <- [{"error", "error"}, {"auth", "error"}, {"crash", "error"}, {"tool error", "idle"}, {"malformed tool", "idle"}] do
      assert {:ok, _} = Store.send_message(c.project, first["id"], text, text, c.auth, c.server)
      assert_receive {:runtime, _, _, ^text}
      wait_chat(c, first, &(&1["status"] == status and &1["queued_count"] == 0))
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

  test "PR work evidence and bound task survive proposal persistence, confirmation and uncertain receipt recovery", c do
    task_id = c.project <> ":1"
    evidence = %{"work_id" => String.duplicate("a", 32), "expected_head_sha" => nil}

    proposal = %{
      "action" => "continue_pr_work",
      "args" => %{"task_id" => "1", "work_id" => evidence["work_id"], "body" => "Address the review"},
      "pr_work" => evidence,
      "project_id" => c.project,
      "tracker_fingerprint" => "scope"
    }

    auth = Map.put(c.auth, :pr_work_proposal, proposal)
    assert {:ok, chat} = Store.ensure_conversation(c.project, task_id, auth, c.server)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "proposal", "pr-proposal", auth, c.server)
    saved = wait_chat(c, chat, &(&1["status"] == "idle"))
    [pending] = saved["proposals"]
    assert pending["pr_work"] == evidence
    assert pending["details"]["pr_work"] == evidence
    refute_receive {:confirmed, _}

    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, _} = Store.decide(c.project, chat["id"], pending["id"], "confirm", Map.put(auth, :action_result, :unknown), server)
    assert_receive {:confirmed, payload}
    assert payload["pr_work"] == evidence
    assert_receive {:confirmed_scope, ^task_id}
    wait_chat(%{c | server: server}, chat, &(hd(&1["proposals"])["status"] == "unknown"))
    assert {:ok, _} = Store.decide(c.project, chat["id"], pending["id"], "reconcile", auth, server)
    assert_receive {:reconciled, ^payload}
    assert_receive {:reconciled_scope, ^task_id}
    refute_receive {:confirmed, _}
    wait_chat(%{c | server: server}, chat, &(hd(&1["proposals"])["status"] == "completed"))
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
    assert {:ok, %{"queued_count" => 1}} = Store.send_message(c.project, third["id"], "Status", "capacity-test", c.auth, c.server)
    assert {:ok, pending} = Store.get(c.project, third["id"], c.auth, c.server)
    assert hd(pending["proposals"])["status"] == "pending"
    send(first_pid, :finish)
    wait_chat(c, first, &(hd(&1["proposals"])["status"] == "completed"))
    wait_chat(c, third, &(&1["queued_count"] == 0 and &1["status"] == "idle"))
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
      if phase != "delay thread", do: assert_receive({:phase_ready, ^pid, ^phase}, 1_000)
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

  test "canonical main and task bindings are unique, immutable and separate from retained legacy chats", c do
    legacy = create(c)
    task_id = c.project <> ":11"
    results = 1..8 |> Task.async_stream(fn _ -> Store.ensure_conversation(c.project, task_id, c.auth, c.server) end) |> Enum.map(fn {:ok, {:ok, chat}} -> chat end)
    assert length(Enum.uniq_by(results, & &1["id"])) == 1
    [chat | _] = results
    assert chat["task_id"] == task_id
    assert chat["conversation_role"] == "task"
    assert chat["queue"] == []
    assert {:error, :chat_busy} = Store.archive(c.project, chat["id"], c.auth, c.server)
    assert {:ok, main} = Store.ensure_conversation(c.project, nil, c.auth, c.server)
    assert main["conversation_role"] == "main"
    refute main["id"] in [chat["id"], legacy["id"]]
    changed_scope = %{c.auth | tracker_fingerprint: "new"}
    assert {:ok, other_scope} = Store.ensure_conversation(c.project, task_id, changed_scope, c.server)
    refute other_scope["id"] == chat["id"]

    for bad <- ["11", "github:test/two:11", c.project <> ":01", c.project <> ":0", c.project <> ":11\n", c.project <> ":../11"] do
      assert {:error, :invalid_task_scope} = Store.ensure_conversation(c.project, bad, c.auth, c.server)
    end

    assert {:error, :unauthorized} = Store.ensure_conversation(c.project, task_id, %{}, c.server)
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.ensure_conversation(c.project, task_id, c.auth, server)
    assert restored["id"] == chat["id"]
    assert {:ok, retained} = Store.get(c.project, legacy["id"], c.auth, server)
    assert retained["conversation_role"] == "legacy"
  end

  test "canonical conversation limits reject only new bindings and retain the existing main chat", c do
    assert {:ok, main} = Store.ensure_conversation(c.project, nil, c.auth, c.server)

    assert {:ok, parent} = Store.ensure_conversation(c.project, pr_task().id, c.auth, c.server)

    for number <- 1..498 do
      assert {:ok, _} = Store.create(c.project, "Retained conversation #{number}", c.auth, c.server)
    end

    assert length(Path.wildcard(Path.join(c.root, "*.json"))) == 500
    assert {:error, :chat_history_full} = Store.ensure_conversation(c.project, c.project <> ":12", c.auth, c.server)
    assert {:error, :chat_history_full} = Store.ensure_pr_conversation(c.project, pr_task().id, "pr:22", c.auth, c.server)
    assert {:ok, ^parent} = Store.get(c.project, parent["id"], c.auth, c.server)
    assert {:ok, existing} = Store.ensure_conversation(c.project, nil, c.auth, c.server)
    assert existing["id"] == main["id"]
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
    refute_receive {:runtime, _, _, _}
  end

  test "a failed dispatch save retains its accepted queue without starting or replaying a runtime", c do
    chat = create(c)
    {:ok, authorizations} = Agent.start_link(fn -> 0 end)
    path = Path.join(c.root, chat["id"] <> ".json")
    original_authorize = Keyword.fetch!(c.opts, :authorize)

    authorize = fn auth ->
      count = Agent.get_and_update(authorizations, &{&1 + 1, &1 + 1})
      # Initial access is checked before acceptance. The dispatch access check occurs
      # after the queued message is durable but before the running state is persisted.
      if count == 2, do: File.chmod!(c.root, 0o500)
      original_authorize.(auth)
    end

    :sys.replace_state(c.server, &%{&1 | authorize: authorize})

    try do
      assert {:error, :chat_storage_unavailable} = Store.send_message(c.project, chat["id"], "Accepted followup", "accepted", c.auth, c.server)
      refute_receive {:runtime, _, _, _}
      assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: false}}
      durable = Jason.decode!(File.read!(path))
      assert durable["status"] == "idle"
      assert durable["messages"] == []
      assert [%{"client_id" => "accepted", "text" => "Accepted followup"}] = durable["queue"]
    after
      File.chmod!(c.root, 0o700)
    end

    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert restored["queued_count"] == 1
    assert restored["queue_paused"]
    assert {:ok, replay} = Store.send_message(c.project, chat["id"], "Accepted followup", "accepted", c.auth, server)
    assert replay["queue"] == restored["queue"]
    refute_receive {:runtime, _, _, _}
    assert {:ok, _} = Store.resume_queue(c.project, chat["id"], c.auth, server)
    assert_receive {:runtime, _, _, "Accepted followup"}
    wait_chat(%{c | server: server}, chat, &(&1["status"] == "idle"))
    refute_receive {:runtime, _, _, _}
  end

  test "queued messages are durable FIFO turns with original IDs, context, and idempotency", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "first", c.auth, c.server)
    assert_receive {:runtime, first, _, "wait"}
    assert_receive {:phase_ready, ^first, "wait"}
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat_project:" <> c.project)
    assert {:ok, queued} = Store.send_message(c.project, chat["id"], "wait", "second", c.auth, c.server)
    assert [%{"client_id" => "second", "status" => "queued"} = second] = queued["queue"]
    assert queued["queued_count"] == 1
    assert length(queued["messages"]) == 2
    project = c.project
    assert_receive {:chat_list_updated, ^project}
    assert thread_summary(c, chat)["queued_count"] == 1
    path = Path.join(c.root, chat["id"] <> ".json")
    assert Jason.decode!(File.read!(path))["queue"] == queued["queue"]
    refute File.read!(path) =~ "test_pid"
    assert {:ok, duplicate} = Store.send_message(c.project, chat["id"], " wait ", "second", c.auth, c.server)
    assert duplicate["queue"] == [second]
    assert {:error, :message_id_conflict} = Store.send_message(c.project, chat["id"], "different", "second", c.auth, c.server)
    assert {:ok, %{"queued_count" => 2}} = Store.send_message(c.project, chat["id"], "final", "third", c.auth, c.server)
    refute_receive {:runtime, _, _, _}
    send(first, :finish)
    assert_receive {:runtime, next, thread_id, "wait"}
    assert is_binary(thread_id)
    assert {:ok, current} = Store.get(c.project, chat["id"], c.auth, c.server)
    assert Enum.at(current["messages"], 2)["id"] == second["id"]
    assert Enum.map(current["messages"], & &1["role"]) == ~w(user assistant user assistant)
    assert current["queued_count"] == 1
    send(next, :finish)
    assert_receive {:runtime, _, ^thread_id, "final"}
    completed = wait_chat(c, chat, &(&1["status"] == "idle"))
    assert completed["queued_count"] == 0
    assert length(completed["messages"]) == 6
  end

  test "queued entries can be sent next or removed without interrupting the active turn", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "active", c.auth, c.server)
    assert_receive {:runtime, first, _, "wait"}
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "removed", "remove", c.auth, c.server)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "last", "last", c.auth, c.server)
    assert {:ok, saved} = Store.send_message(c.project, chat["id"], "wait", "next", c.auth, c.server)
    [removed, last, next] = saved["queue"]
    assert {:ok, reordered} = Store.prioritize_queued(c.project, chat["id"], next["id"], c.auth, c.server)
    assert reordered["queue"] == [next, removed, last]
    assert Process.alive?(first)
    assert {:ok, retained} = Store.remove_queued(c.project, chat["id"], removed["id"], c.auth, c.server)
    assert retained["queue"] == [next, last]
    assert {:ok, replay} = Store.send_message(c.project, chat["id"], "removed", "remove", c.auth, c.server)
    assert replay["queue"] == [next, last]

    assert {:error, :queued_message_not_found} =
             Store.prioritize_queued(c.project, chat["id"], removed["id"], c.auth, c.server)

    assert {:error, :chat_not_found} = Store.remove_queued("github:test/two", chat["id"], next["id"], c.auth, c.server)
    assert {:error, :unauthorized} = Store.remove_queued(c.project, chat["id"], next["id"], %{}, c.server)
    assert {:error, :unauthorized} = Store.prioritize_queued(c.project, chat["id"], next["id"], %{}, c.server)
    send(first, :finish)
    assert_receive {:runtime, second, _, "wait"}
    send(second, :finish)
    assert_receive {:runtime, _, _, "last"}
    refute_receive {:runtime, _, _, "removed"}
  end

  test "stop pauses pending work even if the runtime reports success after interruption", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "ignore stop", "active", c.auth, c.server)
    assert_receive {:runtime, first, _, "ignore stop"}
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "next", "next", c.auth, c.server)
    assert {:ok, %{"queue_paused" => true}} = Store.stop(c.project, chat["id"], c.auth, c.server)
    assert_receive :interrupt_received
    send(first, :finish)
    saved = wait_chat(c, chat, &(&1["status"] == "interrupted"))
    assert saved["queued_count"] == 1
    assert saved["queue_paused"]
    refute_receive {:runtime, _, _, "next"}
    assert {:error, :unauthorized} = Store.resume_queue(c.project, chat["id"], %{}, c.server)
    assert {:ok, _} = Store.resume_queue(c.project, chat["id"], c.auth, c.server)
    assert_receive {:runtime, _, _, "next"}
  end

  test "restart retains queued work paused until an authenticated resume", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "active", c.auth, c.server)
    assert_receive {:runtime, first, _, "wait"}
    assert {:ok, queued} = Store.send_message(c.project, chat["id"], "resumed", "saved", c.auth, c.server)
    stop_supervised!(Store)
    refute Process.alive?(first)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert restored["queue"] == queued["queue"]
    assert restored["error"] =~ "Resume queue"
    assert restored["queue_paused"]
    assert {:ok, duplicate} = Store.send_message(c.project, chat["id"], "resumed", "saved", c.auth, server)
    assert duplicate["queue"] == restored["queue"]
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "after", "after", c.auth, server)
    refute_receive {:runtime, _, _, _}
    assert {:ok, _} = Store.resume_queue(c.project, chat["id"], c.auth, server)
    assert_receive {:runtime, _, _, "resumed"}
    assert_receive {:runtime, _, _, "after"}
  end

  test "runtime failure retains the next turn and dispatch rechecks revoked authorization", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "active", c.auth, c.server)
    assert_receive {:runtime, first, _, "wait"}
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "error", "error", c.auth, c.server)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "after error", "after", c.auth, c.server)
    send(first, :finish)
    assert_receive {:runtime, _, _, "error"}
    failed = wait_chat(c, chat, &(&1["status"] == "error"))
    assert failed["queue_paused"]
    assert failed["queued_count"] == 1
    refute_receive {:runtime, _, _, "after error"}
    assert {:ok, _} = Store.resume_queue(c.project, chat["id"], c.auth, c.server)
    assert_receive {:runtime, _, _, "after error"}
    wait_chat(c, chat, &(&1["status"] == "idle"))
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "active-again", c.auth, c.server)
    assert_receive {:runtime, active, _, "wait"}
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "auth resume", "auth-resume", c.auth, c.server)
    Agent.update(c.access, fn _ -> false end)
    send(active, :finish)
    refute_receive {:runtime, _, _, "auth resume"}
    Agent.update(c.access, fn _ -> true end)
    paused = wait_chat(c, chat, & &1["queue_paused"])
    assert paused["queued_count"] == 1
    assert {:ok, _} = Store.resume_queue(c.project, chat["id"], c.auth, c.server)
    assert_receive {:runtime, _, _, "auth resume"}
  end

  test "messages waiting for global capacity recheck authorization before any dispatch", c do
    first = create(c)
    second = create(c)
    waiting = create(c)
    assert {:ok, _} = Store.send_message(c.project, first["id"], "wait", "first", c.auth, c.server)
    assert_receive {:runtime, first_pid, _, "wait"}
    assert {:ok, _} = Store.send_message(c.project, second["id"], "wait", "second", c.auth, c.server)
    assert_receive {:runtime, second_pid, _, "wait"}
    assert {:ok, %{"queued_count" => 1, "status" => "idle"}} = Store.send_message(c.project, waiting["id"], "capacity followup", "waiting", c.auth, c.server)
    assert thread_summary(c, waiting)["display_status"] == "queued"
    Agent.update(c.access, fn _ -> false end)
    send(first_pid, :finish)
    refute_receive {:runtime, _, _, "capacity followup"}
    Agent.update(c.access, fn _ -> true end)
    paused = wait_chat(c, waiting, & &1["queue_paused"])
    assert paused["queued_count"] == 1
    assert {:ok, _} = Store.resume_queue(c.project, waiting["id"], c.auth, c.server)
    assert_receive {:runtime, _, _, "capacity followup"}
    send(second_pid, :finish)
  end

  test "queue capacity is bounded, and a failed queue save stops active work without dispatch", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "active", c.auth, c.server)
    assert_receive {:runtime, active, _, "wait"}
    for number <- 1..20, do: assert({:ok, _} = Store.send_message(c.project, chat["id"], "queued #{number}", "queue-#{number}", c.auth, c.server))
    assert {:error, :chat_queue_full} = Store.send_message(c.project, chat["id"], "overflow", "overflow", c.auth, c.server)
    assert {:ok, %{"queued_count" => 20}} = Store.get(c.project, chat["id"], c.auth, c.server)
    block_record(c, chat)
    assert {:error, :chat_storage_unavailable} = Store.stop(c.project, chat["id"], c.auth, c.server)
    refute Process.alive?(active)
    refute_receive {:runtime, _, _, "queued 1"}
  end

  test "bound task instructions survive missing board context and canonical chats exceed legacy length limit", c do
    task_id = c.project <> ":11"
    assert {:ok, chat} = Store.ensure_conversation(c.project, task_id, c.auth, c.server)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "view", "view", c.auth, c.server)
    assert_receive {:view_runtime, nil, instructions}
    assert instructions =~ "permanently associated with task #{task_id}"
    assert instructions =~ "continue_pr_work with its exact work_id"
    assert instructions =~ "fresh independent reviewer"
    assert instructions =~ "project agent -> task agent -> work agent"
    assert instructions =~ "A task kind never grants tool or deployment permission"
    assert_receive {:view_tool, %{"task_id" => ^task_id}}
    completed = wait_chat(c, chat, &(&1["status"] == "idle"))
    retained = List.duplicate(hd(completed["messages"]), 400)
    :sys.replace_state(c.server, fn state -> put_in(state, [:chats, chat["id"], "messages"], retained) end)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "after 400", "after-400", c.auth, c.server)
    assert_receive {:runtime, _, _, "after 400"}
    wait_chat(c, chat, &(&1["status"] == "idle"))
    :sys.replace_state(c.server, fn state -> put_in(state, [:chats, chat["id"], "padding"], String.duplicate("x", 6_500_001)) end)
    assert {:error, :chat_history_full} = Store.send_message(c.project, chat["id"], "full", "full", c.auth, c.server)
    before_reports = :sys.get_state(c.server).chats[chat["id"]]
    assert :ok = Store.sync_pr_updates(c.project, "scope", report_board(pr_task()), c.server)
    after_reports = :sys.get_state(c.server).chats[chat["id"]]
    assert Map.take(after_reports, ~w(messages proposals report_cursors)) == Map.take(before_reports, ~w(messages proposals report_cursors))
    assert after_reports["task_kind"] == "general"
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
  end

  test "growing history pauses accepted followups before the durable record limit", c do
    assert {:ok, chat} = Store.ensure_conversation(c.project, nil, c.auth, c.server)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "active", c.auth, c.server)
    assert_receive {:runtime, pid, _, "wait"}
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "retained", "retained", c.auth, c.server)
    :sys.replace_state(c.server, fn state -> put_in(state, [:chats, chat["id"], "padding"], String.duplicate("x", 6_500_001)) end)
    send(pid, :finish)
    paused = wait_chat(c, chat, & &1["queue_paused"])
    assert paused["error"] =~ "history is full"
    assert paused["queued_count"] == 1
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
    refute_receive {:runtime, _, _, "retained"}
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    assert {:ok, restored} = Store.get(c.project, chat["id"], c.auth, server)
    assert restored["queue"] == paused["queue"]
    assert {:ok, %{"queue_paused" => true}} = Store.resume_queue(c.project, chat["id"], c.auth, server)
    refute_receive {:runtime, _, _, "retained"}
  end

  test "runtime identity changes never silently resume a retained queue", c do
    chat = create(c)
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "wait", "active", c.auth, c.server)
    assert_receive {:runtime, _, _, "wait"}
    assert {:ok, _} = Store.send_message(c.project, chat["id"], "saved", "saved", c.auth, c.server)
    stop_supervised!(Store)
    settings = Keyword.fetch!(c.opts, :settings) |> Map.put(:codex_home, c.root <> "/different-runtime")
    server = start_supervised!({Store, Keyword.put(c.opts, :settings, settings)})
    assert {:error, :chat_runtime_changed} = Store.resume_queue(c.project, chat["id"], c.auth, server)
    assert {:error, :chat_runtime_changed} = Store.send_message(c.project, chat["id"], "new", "new", c.auth, server)
    assert {:ok, saved} = Store.get(c.project, chat["id"], c.auth, server)
    assert saved["queued_count"] == 1
    assert saved["queue_paused"]
    refute_receive {:runtime, _, _, "saved"}
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

  defp disk_chat(c, chat), do: c.root |> Path.join(chat["id"] <> ".json") |> File.read!() |> Jason.decode!()

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
