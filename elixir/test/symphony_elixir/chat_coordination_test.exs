defmodule SymphonyElixir.Chat.CoordinationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Chat.{Coordination, Graph, Persistence, Sessions, Store}

  defmodule ControlledRuntime do
    @spec run(map(), function(), function()) :: term()
    def run(opts, emit, tool) do
      emit.({:thread, opts.thread_id || "coordination-#{System.unique_integer([:positive])}"})
      send(opts.test_pid, {:coordination_runtime, self(), opts})
      respond(opts.test_pid, emit, tool)
    end

    defp respond(parent, emit, tool) do
      receive do
        {:tool, ref, name, args} ->
          send(parent, {:coordination_tool, ref, tool.(name, args)})
          respond(parent, emit, tool)

        {:finish, text} ->
          emit.({:delta, text})
          {:ok, %{status: :completed}}

        :interrupt ->
          {:ok, %{status: :interrupted}}
      end
    end
  end

  defmodule NoExternalTools do
    @spec specs() :: [map()]
    def specs, do: Coordination.specs()

    @spec call(String.t(), map(), map()) :: {:error, atom()}
    def call(_, _, _), do: {:error, :unexpected_external_tool}
  end

  defmodule ProposalOnlyTools do
    @spec specs() :: [map()]
    def specs, do: NoExternalTools.specs()

    @spec call(String.t(), map(), map()) :: term()
    def call("symphony_propose_action", %{"body" => body}, context) do
      proposal = %{
        "action" => "feedback",
        "args" => %{"body" => body},
        "project_id" => context.project_id,
        "tracker_fingerprint" => context.tracker_fingerprint
      }

      {:ok, %{"proposal" => proposal, "widgets" => [%{"type" => "proposal", "title" => "Review feedback"}]}}
    end

    def call(name, args, context), do: NoExternalTools.call(name, args, context)
  end

  setup do
    {:ok, tmp} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "symphony-coordination-#{System.unique_integer([:positive])}")
    access = start_supervised!({Agent, fn -> 1 end})
    source = start_supervised!({Agent, fn -> task() end}, id: :coordination_source)
    project = "github:test/one"
    auth = %{allowed: true, generation: 1, tracker_fingerprint: "scope"}

    opts = [
      name: nil,
      settings: %{
        enabled: true,
        state_path: root,
        codex_home: root <> "/runtime",
        executable: "/test/codex",
        timeout_ms: 5_000,
        max_concurrent: 5,
        test_pid: self()
      },
      projects: fn -> [%{"id" => project, "label" => "One"}, %{"id" => "github:test/two", "label" => "Two"}] end,
      authorize: fn auth -> is_map(auth) and auth[:allowed] == true and auth[:generation] == Agent.get(access, & &1) end,
      runtime: ControlledRuntime,
      tools: NoExternalTools,
      session_reader: fn task_id, session, context ->
        case source_task(Agent.get(source, & &1), task_id) do
          nil -> {:error, :pr_session_unavailable}
          task -> Sessions.resolve(task, session, context.tracker_fingerprint)
        end
      end
    ]

    server = start_supervised!({Store, opts})
    {:ok, parent} = Store.ensure_conversation(project, nil, auth, server)
    {:ok, issue} = Store.ensure_conversation(project, project <> ":11", auth, server)
    {:ok, feature} = Store.ensure_pr_conversation(project, project <> ":11", "pr:7", auth, server)
    on_exit(fn -> File.rm_rf(root) end)

    %{
      server: server,
      opts: opts,
      root: root,
      auth: auth,
      project: project,
      parent: parent,
      issue: issue,
      feature: feature,
      access: access,
      source: source
    }
  end

  test "reopening a legacy main conversation refreshes the persisted project agent identity", c do
    seed_chat(c, c.parent, %{"title" => "Main chat", "agent_name" => nil})
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    assert disk(c, c.parent)["agent_name"] == nil

    assert {:ok, parent} = Store.ensure_conversation(c.project, nil, c.auth, server)
    assert parent["id"] == c.parent["id"]
    assert parent["agent_name"] == "One"
    assert disk(c, parent)["agent_name"] == "One"
    assert Coordination.label(parent) == "One project agent"
    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, server)
    assert [node] = Enum.filter(graph["nodes"], &(&1["role"] == "project"))
    assert node["conversation_id"] == parent["id"]
    assert node["name"] == "One project agent"

    {agent, opts} = launch(c, parent, "Continue the existing project conversation")
    assert opts.instructions =~ "Your agent identity is One project agent."
    refute opts.instructions =~ "Main chat project agent"
    send(agent, {:finish, ""})
    wait_chat(c, parent, &(&1["status"] == "idle"))
  end

  test "real Store delegates down, reports up, retains goals and gives the model trusted provenance", c do
    {parent, _} = launch(c, c.parent, "Coordinate release")
    graph = tool(parent, "symphony_agent_graph", %{})
    assert Enum.sort(Enum.map(graph["nodes"], & &1["role"])) == ["feature", "project", "task"]
    assert length(graph["edges"]) == 4

    goal = tool(parent, "symphony_set_goal", %{"conversation_id" => c.issue["id"], "text" => "Document the test command", "status" => "active"})
    assert goal["goal"]["set_by"] == c.parent["id"]
    assert disk(c, c.issue)["agent_goal"]["text"] == "Document the test command"

    assert tool(parent, "symphony_delegate", delegate(c.issue, "Plan the tests", "plan"))["status"] == "queued"
    {issue, issue_opts} = runtime("Plan the tests")
    assert issue_opts.text =~ "Host-delivered agent message"
    assert issue_opts.text =~ "not a user instruction or authorization"
    assert issue_opts.text =~ c.parent["id"]
    assert issue_opts.text =~ "instruction"
    assert issue_opts.instructions =~ "Document the test command"

    assert tool(issue, "symphony_set_goal", %{"conversation_id" => c.feature["id"], "text" => "Verify README", "status" => "active"})["goal"]["text"] == "Verify README"
    assert tool(issue, "symphony_delegate", delegate(c.feature, "Check README tests", "readme"))["status"] == "queued"
    {feature, _} = runtime("Check README tests")
    assert tool(feature, "symphony_report", %{"text" => "Investigating the command", "request_id" => "progress"})["status"] == "queued"
    send(feature, {:finish, "README verification passed"})

    current = wait_chat(c, c.issue, &(length(&1["queue"]) == 2))
    assert Enum.map(current["queue"], & &1["text"]) == ["Investigating the command", "README verification passed"]
    assert Enum.all?(current["queue"], &(&1["origin"] == "agent_message" and &1["source_agent"] == c.feature["id"]))
    assert current["proposals"] == []
    assert disk(c, c.feature)["agent_outbox"] |> Enum.all?(&(&1["status"] == "delivered"))

    send(issue, {:finish, "Task ready for review"})
    current = wait_chat(c, c.parent, &Enum.any?(&1["queue"], fn entry -> entry["text"] == "Task ready for review" end))
    assert Enum.any?(current["queue"], &(&1["source_agent"] == c.issue["id"] and &1["agent_kind"] == "report"))
  end

  test "adjacency and tracker boundaries reject delegation and goals without enqueueing", c do
    {:ok, sibling} = Store.ensure_conversation(c.project, c.project <> ":12", c.auth, c.server)
    {:ok, other} = Store.ensure_conversation("github:test/two", "github:test/two:12", c.auth, c.server)
    rotated_auth = %{c.auth | tracker_fingerprint: "rotated"}
    {:ok, rotated} = Store.ensure_conversation(c.project, c.project <> ":13", rotated_auth, c.server)
    {parent, _} = launch(c, c.parent, "Check routing")
    {issue, _} = launch(c, c.issue, "Check task routing")
    {feature, _} = launch(c, c.feature, "Check feature routing")

    rejected = [{parent, c.feature}, {parent, other}, {parent, rotated}, {issue, sibling}, {feature, c.issue}]

    for {sender, target} <- rejected do
      assert tool(sender, "symphony_delegate", delegate(target, "Forbidden route", "route-" <> target["id"]))["error"]
    end

    assert tool(feature, "symphony_set_goal", %{"conversation_id" => c.issue["id"], "text" => "Rewrite parent goal", "status" => "achieved"})["error"]
    assert tool(parent, "symphony_delegate", %{"conversation_id" => c.issue["id"], "text" => "No request ID"})["error"]
    assert tool(feature, "symphony_set_goal", %{"text" => "My verified result", "status" => "achieved"})["goal"]["status"] == "achieved"
    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, c.server)
    refute Enum.any?(graph["nodes"], &(&1["conversation_id"] in [other["id"], rotated["id"]]))
    assert read(c, c.issue)["queue"] == []
    assert read(c, sibling)["queue"] == []
    assert disk(c, c.issue)["agent_goal"] == nil
  end

  test "queue-full automatic completion stays durable and replays once capacity returns", c do
    hold_full_parent(c)
    {issue, _} = launch(c, c.issue, "Finish child work")
    send(issue, {:finish, "Durable completed result"})
    wait_chat(c, c.issue, &(length(&1["agent_outbox"] || []) == 1))
    assert [%{"status" => "pending"}] = disk(c, c.issue)["agent_outbox"]
    assert length(read(c, c.parent)["queue"]) == 20

    remove_first(c, c.parent)
    wait_chat(c, c.issue, &Enum.all?(&1["agent_outbox"], fn entry -> entry["status"] == "delivered" end))
    assert length(read(c, c.parent)["queue"]) == 20
    assert Enum.count(read(c, c.parent)["queue"], &(&1["text"] == "Durable completed result")) == 1
    remove_first(c, c.parent)
    assert Enum.count(read(c, c.parent)["queue"], &(&1["text"] == "Durable completed result")) == 1
    assert map_size(disk(c, c.parent)["message_receipts"]) == 22
  end

  test "restart retains pending intent but waits for fresh authorization before replay", c do
    hold_full_parent(c)
    {issue, _} = launch(c, c.issue, "Result before restart")
    send(issue, {:finish, "Retained across restart"})
    wait_chat(c, c.issue, &(length(&1["agent_outbox"] || []) == 1))
    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    refute_receive {:coordination_runtime, _, _}, 30
    assert [%{"status" => "pending"}] = disk(c, c.issue)["agent_outbox"]
    assert read(c, c.parent)["queue_paused"]

    remove_first(c, c.parent)
    assert [%{"status" => "pending"}] = disk(c, c.issue)["agent_outbox"]
    {_, _} = launch(c, c.issue, "Resume supervisory work")
    assert [%{"status" => "delivered"}] = disk(c, c.issue)["agent_outbox"]
    assert Enum.count(read(c, c.parent)["queue"], &(&1["text"] == "Retained across restart")) == 1
    assert read(c, c.parent)["queue_paused"]
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "revoked browser authorization prevents queued delivery and stale runtime tools", c do
    {parent, _} = hold_full_parent(c)
    {issue, _} = launch(c, c.issue, "Report before revocation")
    send(issue, {:finish, "Requires renewed authorization"})
    wait_chat(c, c.issue, &(length(&1["agent_outbox"] || []) == 1))
    Agent.update(c.access, fn _ -> 2 end)
    assert tool(parent, "symphony_agent_graph", %{})["error"]
    assert {:error, :unauthorized} = Store.agent_graph(c.project, c.auth, c.server)
    send(parent, {:finish, ""})
    wait_disk(c, c.parent, &(&1["queue_paused"] == true))
    assert [%{"status" => "pending"}] = disk(c, c.issue)["agent_outbox"]
    refute_receive {:coordination_runtime, _, _}, 30

    c = %{c | auth: %{c.auth | generation: 2}}
    remove_first(c, c.parent)
    assert [%{"status" => "pending"}] = disk(c, c.issue)["agent_outbox"]
    launch(c, c.issue, "Freshly authorized follow-up")
    assert [%{"status" => "delivered"}] = disk(c, c.issue)["agent_outbox"]
    assert Enum.count(read(c, c.parent)["queue"], &(&1["text"] == "Requires renewed authorization")) == 1
  end

  test "Stop holds pending deliveries until that source is explicitly resumed", c do
    hold_full_parent(c)
    {issue, _} = launch(c, c.issue, "Result to hold")
    send(issue, {:finish, "Held pending result"})
    wait_chat(c, c.issue, &(length(&1["agent_outbox"] || []) == 1))
    assert {:ok, _} = Store.stop(c.project, c.issue["id"], c.auth, c.server)
    remove_first(c, c.parent)
    assert [%{"status" => "pending"}] = disk(c, c.issue)["agent_outbox"]
    assert {:ok, _} = Store.resume_queue(c.project, c.issue["id"], c.auth, c.server)
    assert [%{"status" => "delivered"}] = disk(c, c.issue)["agent_outbox"]
    assert Enum.count(read(c, c.parent)["queue"], &(&1["text"] == "Held pending result")) == 1
  end

  test "24 deliveries bound one causal root and retries never spend or deliver twice", c do
    {parent, _} = launch(c, c.parent, "Bounded supervision")
    launch(c, c.issue, "Keep the recipient busy")

    results = for index <- 1..24, do: tool(parent, "symphony_delegate", delegate(c.issue, "Instruction #{index}", "step-#{index}"))
    assert Enum.all?(results, &(&1["status"] in ["queued", "pending"]))
    assert tool(parent, "symphony_delegate", delegate(c.issue, "Instruction 25", "step-25"))["error"]
    assert length(disk(c, c.parent)["agent_outbox"]) == 24
    assert Map.values(disk(c, c.parent)["agent_chains"]) == [24]
    replay = tool(parent, "symphony_delegate", delegate(c.issue, "Instruction 1", "step-1"))
    assert replay["delivery_id"] == hd(results)["delivery_id"]
    assert tool(parent, "symphony_delegate", delegate(c.issue, "Different payload", "step-1"))["error"]
    assert Map.values(disk(c, c.parent)["agent_chains"]) == [24]
    assert Enum.count(read(c, c.issue)["queue"], &(&1["text"] == "Instruction 1")) == 1
  end

  test "alternating delegation and reporting cannot exceed causal depth six", c do
    {initial, _} = launch(c, c.parent, "Bounded recursive reasoning")

    final_parent =
      Enum.reduce(1..3, initial, fn round, parent ->
        assert tool(parent, "symphony_delegate", delegate(c.issue, "Depth instruction #{round}", "depth-#{round}"))["status"] == "queued"
        {issue, _} = runtime("Depth instruction #{round}")
        assert tool(issue, "symphony_report", %{"text" => "Depth report #{round}", "request_id" => "reply-#{round}"})["status"] == "queued"
        send(issue, {:finish, ""})
        wait_chat(c, c.issue, &(&1["status"] == "idle"))
        send(parent, {:finish, ""})
        {next, opts} = runtime("Depth report #{round}")
        assert opts.text =~ ~s("agent_depth":#{round * 2})
        next
      end)

    assert tool(final_parent, "symphony_delegate", delegate(c.issue, "Depth seven", "too-deep"))["error"]
    assert Enum.map(disk(c, c.parent)["agent_outbox"], & &1["depth"]) == [1, 3, 5]
    assert Enum.map(disk(c, c.issue)["agent_outbox"], & &1["depth"]) == [2, 4, 6]
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "new PR evidence remains pending under pressure and coalesces into one reasoning turn", c do
    launch(c, c.issue, "Keep task reasoning busy")
    fill_queue(c, c.issue)
    board = board(task())
    assert :ok = Store.sync_pr_updates(c.project, "scope", board, c.server)
    assert disk(c, c.issue)["agent_reflection_pending"]
    assert Enum.all?(read(c, c.issue)["queue"], &is_nil(&1["origin"]))

    changed = put_in(board, [:tasks, Access.at(0), :pull_requests, Access.at(0), :checks], "failure")
    assert :ok = Store.sync_pr_updates(c.project, "scope", changed, c.server)
    remove_first(c, c.issue)
    queued = Enum.filter(read(c, c.issue)["queue"], &(&1["origin"] == "agent_evidence"))
    assert length(queued) == 1
    assert hd(queued)["text"] =~ "CI: Failure"
    refute disk(c, c.issue)["agent_reflection_pending"]
    assert :ok = Store.sync_pr_updates(c.project, "scope", changed, c.server)
    assert Enum.count(read(c, c.issue)["queue"], &(&1["origin"] == "agent_evidence")) == 1
  end

  test "publication keeps one feature agent, ordered history, and the verified native binding", c do
    {discussion, _} = launch(c, c.feature, "Discuss the existing PR")
    send(discussion, {:finish, ""})
    wait_chat(c, c.feature, &(&1["status"] == "idle"))

    Agent.update(c.source, fn _ -> native_task(false, String.duplicate("x", 16_000)) end)
    {:ok, native} = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert byte_size(disk(c, native)["agent_name"]) == 16_000
    {worker, _} = launch(c, native, "Prepare the implementation")
    send(worker, {:finish, ""})
    wait_chat(c, native, &(&1["status"] == "idle"))
    {discussion, _} = launch(c, c.feature, "Latest discussion before publication")
    send(discussion, {:finish, ""})
    wait_chat(c, c.feature, &(&1["status"] == "idle"))

    Agent.update(c.source, fn _ -> native_task(true) end)
    assert {:ok, canonical} = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert canonical["id"] == native["id"]
    assert canonical["agent_session_id"] == work_session()
    assert read(c, c.feature)["id"] == native["id"]
    assert disk(c, c.feature)["alias_of"] == native["id"]
    assert disk(c, native)["codex_thread_id"] == nil

    texts = for entry <- canonical["messages"], entry["role"] == "user", do: entry["text"]
    assert texts == ["Discuss the existing PR", "Prepare the implementation", "Latest discussion before publication"]
    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, c.server)
    assert [feature] = Enum.filter(graph["nodes"], &(&1["role"] == "feature"))
    assert feature["aliases"] == [c.feature["id"]]
    assert feature["work_id"] == String.duplicate("b", 32)

    {_, opts} = launch(c, c.feature, "Continue the canonical thread")
    assert opts.instructions =~ "Latest discussion before publication"
    assert opts.instructions =~ work_session()
  end

  test "interrupted alias migration recovers each queued message once before any dispatch", c do
    native = create_native(c)
    launch(c, c.feature, "Hold the old discussion")

    for text <- ["First retained instruction", "Second retained instruction"] do
      assert {:ok, _} = Store.send_message(c.project, c.feature["id"], text, text, c.auth, c.server)
    end

    assert {:ok, _} = Store.stop(c.project, c.feature["id"], c.auth, c.server)
    wait_chat(c, c.feature, &(&1["status"] == "interrupted"))
    stop_supervised!(Store)
    old = disk(c, c.feature)
    canonical = disk(c, native)

    # Simulate a crash after the canonical copy, before the losing queue was cleared.
    intent = old |> Map.put("alias_of", native["id"]) |> Map.put("alias_pending", true)
    partial = canonical |> Map.put("queue", old["queue"]) |> Map.put("client_ids", old["client_ids"])
    partial = Map.put(partial, "message_receipts", old["message_receipts"])
    assert :ok = Persistence.put(%{path: c.root}, intent)
    assert :ok = Persistence.put(%{path: c.root}, partial)

    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    refute_receive {:coordination_runtime, _, _}, 30
    assert disk(c, c.feature)["alias_pending"] == false
    assert disk(c, c.feature)["queue"] == []
    assert length(disk(c, native)["queue"]) == 2
    assert disk(c, native)["queue_paused"]
    assert read(c, c.feature)["id"] == native["id"]

    assert {:ok, _} = Store.resume_queue(c.project, c.feature["id"], c.auth, c.server)
    {first, _} = runtime("First retained instruction")
    send(first, {:finish, ""})
    {second, _} = runtime("Second retained instruction")
    send(second, {:finish, ""})
    wait_chat(c, native, &(&1["status"] == "idle"))
    refute_receive {:coordination_runtime, _, _}, 30
    messages = read(c, native)["messages"]
    assert Enum.count(messages, &(&1["text"] == "First retained instruction")) == 1
    assert Enum.count(messages, &(&1["text"] == "Second retained instruction")) == 1
  end

  test "canonical authorization resumes a retained alias report without reviving its paused queue", c do
    native = create_native(c)
    launch(c, c.issue, "Hold the task recipient")
    fill_queue(c, c.issue)
    {feature, _} = launch(c, c.feature, "Produce an old-thread report")
    send(feature, {:finish, "Report retained on the old discussion"})
    wait_chat(c, c.feature, &(length(&1["agent_outbox"] || []) == 1))
    assert [%{"status" => "pending"}] = disk(c, c.feature)["agent_outbox"]
    assert {:ok, _} = Store.stop(c.project, c.feature["id"], c.auth, c.server)
    stop_supervised!(Store)

    old = disk(c, c.feature) |> Map.put("alias_of", native["id"]) |> Map.put("alias_pending", true)
    assert :ok = Persistence.put(%{path: c.root}, old)
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    refute_receive {:coordination_runtime, _, _}, 30
    assert disk(c, c.feature)["agent_delivery_paused"]
    assert read(c, native)["agent_delivery_counts"] == %{"report" => 1}
    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, c.server)
    assert Enum.find(graph["nodes"], &(&1["conversation_id"] == native["id"]))["pending_deliveries"] == 1
    remove_first(c, c.issue)
    assert [%{"status" => "pending"}] = disk(c, c.feature)["agent_outbox"]

    launch(c, native, "Fresh canonical authorization")
    assert [%{"status" => "delivered"}] = disk(c, c.feature)["agent_outbox"]
    assert read(c, native)["agent_delivery_counts"] == %{}
    reports = Enum.filter(read(c, c.issue)["queue"], &(&1["text"] == "Report retained on the old discussion"))
    assert [report] = reports
    assert report["source_agent"] == c.feature["id"]
    assert read(c, c.issue)["queue_paused"]
    assert disk(c, c.feature)["queue"] == []
    remove_first(c, c.issue)
    assert Enum.count(read(c, c.issue)["queue"], &(&1["id"] == report["id"])) == 1
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "merging a stopped discussion retains its delivery pause until canonical resume", c do
    native = create_native(c)
    {worker, _} = launch(c, native, "Previously authorized native conversation")
    send(worker, {:finish, ""})
    wait_chat(c, native, &(&1["status"] == "idle"))
    launch(c, c.issue, "Hold the task recipient")
    fill_queue(c, c.issue)
    {feature, _} = launch(c, c.feature, "Produce a report then stop delivery")
    send(feature, {:finish, "Stopped old discussion report"})
    wait_chat(c, c.feature, &(length(&1["agent_outbox"] || []) == 1))
    assert {:ok, _} = Store.stop(c.project, c.feature["id"], c.auth, c.server)

    Agent.update(c.source, fn _ -> native_task(true) end)
    assert {:ok, canonical} = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert canonical["id"] == native["id"]
    assert disk(c, native)["agent_delivery_paused"]
    remove_first(c, c.issue)
    assert [%{"status" => "pending"}] = disk(c, c.feature)["agent_outbox"]
    refute Enum.any?(read(c, c.issue)["queue"], &(&1["text"] == "Stopped old discussion report"))

    assert {:ok, _} = Store.resume_queue(c.project, native["id"], c.auth, c.server)
    assert [%{"status" => "delivered"}] = disk(c, c.feature)["agent_outbox"]
    assert Enum.count(read(c, c.issue)["queue"], &(&1["text"] == "Stopped old discussion report")) == 1
  end

  test "a failed goal save stops supervision without changing the retained goal", c do
    {parent, _} = launch(c, c.parent, "Set a child goal")
    original = block_record(c, c.issue)
    faulting_tool(c, parent, "symphony_set_goal", %{"conversation_id" => c.issue["id"], "text" => "Unsaved goal", "status" => "active"})
    assert read(c, c.issue)["agent_goal"] == nil
    assert Jason.decode!(original)["agent_goal"] == nil
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "missing and archived children reject messages before reserving a causal delivery", c do
    {parent, _} = launch(c, c.parent, "Find an available child")
    assert tool(parent, "symphony_delegate", delegate(%{"id" => String.duplicate("f", 32)}, "Missing child", "missing"))["error"]
    :sys.replace_state(c.server, &put_in(&1, [:chats, c.issue["id"], "archived"], true))
    assert tool(parent, "symphony_delegate", delegate(c.issue, "Archived child", "archived"))["error"]
    assert disk(c, c.parent)["agent_outbox"] in [nil, []]
    assert disk(c, c.parent)["agent_chains"] in [nil, %{}]
    assert read(c, c.issue)["queue"] == []
    assert Process.alive?(parent)
  end

  test "failure to reserve the causal root never records or dispatches an instruction", c do
    {parent, _} = launch(c, c.parent, "Start bounded delegation")
    original = block_record(c, c.parent)
    faulting_tool(c, parent, "symphony_delegate", delegate(c.issue, "Must not start", "root-failure"))
    assert Jason.decode!(original)["agent_outbox"] in [nil, []]
    assert read(c, c.issue)["queue"] == []
    assert read(c, c.issue)["messages"] == []
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "failure to persist a child outbox consumes only the reserved slot and never delivers", c do
    {parent, _} = launch(c, c.parent, "Delegate task planning")
    assert tool(parent, "symphony_delegate", delegate(c.issue, "Plan one feature", "plan-child"))["status"] == "queued"
    {issue, _} = runtime("Plan one feature")
    original = block_record(c, c.issue)
    faulting_tool(c, issue, "symphony_delegate", delegate(c.feature, "Must not reach feature", "outbox-failure"))
    assert Map.values(disk(c, c.parent)["agent_chains"]) == [2]
    assert Jason.decode!(original)["agent_outbox"] in [nil, []]
    assert read(c, c.feature)["messages"] == []
    assert read(c, c.feature)["queue"] == []
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "target queue write failure retains the source intent for exactly-once authorized recovery", c do
    {parent, _} = launch(c, c.parent, "Delegate a durable instruction")
    original = block_record(c, c.issue)
    faulting_tool(c, parent, "symphony_delegate", delegate(c.issue, "Recover this exact instruction", "target-failure"))
    assert [%{"status" => "pending"}] = disk(c, c.parent)["agent_outbox"]
    assert read(c, c.issue)["queue"] == []
    stop_supervised!(Store)
    restore_record(c, c.issue, original)
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    refute_receive {:coordination_runtime, _, _}, 30

    assert {:ok, _} = Store.send_message(c.project, c.parent["id"], "Authorize recovery", "recover-authority", c.auth, c.server)
    assert_receive {:coordination_runtime, _, %{text: "Authorize recovery"}}, 2_000
    {_, _} = runtime("Recover this exact instruction")
    assert [%{"status" => "delivered"}] = disk(c, c.parent)["agent_outbox"]
    assert Enum.count(read(c, c.issue)["messages"], &(&1["text"] == "Recover this exact instruction")) == 1
    assert {:ok, _} = Store.resume_queue(c.project, c.parent["id"], c.auth, c.server)
    assert Enum.count(read(c, c.issue)["messages"], &(&1["text"] == "Recover this exact instruction")) == 1
  end

  test "failed sender acknowledgement preserves a committed target receipt and replay never duplicates it", c do
    {parent, _} = launch(c, c.parent, "Delegate through a separate causal root")
    assert tool(parent, "symphony_delegate", delegate(c.issue, "Prepare a durable feature handoff", "ack-root"))["status"] == "queued"
    {issue, _} = runtime("Prepare a durable feature handoff")
    instruction = "This feature instruction must arrive exactly once"
    pad_before_ack(c, c.issue, c.feature, instruction)

    faulting_tool(c, issue, "symphony_delegate", delegate(c.feature, instruction, "ack-failure"))
    assert File.stat!(record_path(c, c.issue)).size == 8_000_000
    assert [%{"status" => "pending"} = pending] = disk(c, c.issue)["agent_outbox"]
    assert [received] = disk(c, c.feature)["queue"]
    assert received["text"] == instruction
    assert received["client_id"] == "agent:" <> pending["id"]
    receipts = disk(c, c.feature)["message_receipts"]
    assert Map.keys(receipts) == [received["client_id"]]
    assert Map.values(disk(c, c.parent)["agent_chains"]) == [2]
    refute_receive {:coordination_runtime, _, _}, 30

    stop_supervised!(Store)
    repaired = disk(c, c.issue) |> Map.delete("fault_padding")
    assert :ok = Persistence.put(%{path: c.root}, repaired)
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    refute_receive {:coordination_runtime, _, _}, 30

    assert {:ok, _} = Store.resume_queue(c.project, c.issue["id"], c.auth, c.server)
    assert [%{"status" => "delivered"}] = disk(c, c.issue)["agent_outbox"]
    assert read(c, c.feature)["queue"] == [received]
    assert read(c, c.feature)["queue_paused"]
    assert disk(c, c.feature)["message_receipts"] == receipts
    refute_receive {:coordination_runtime, _, _}, 30

    assert {:ok, _} = Store.resume_queue(c.project, c.feature["id"], c.auth, c.server)
    {feature, _} = runtime(instruction)
    send(feature, {:finish, ""})
    wait_chat(c, c.feature, &(&1["status"] == "idle"))
    assert {:ok, _} = Store.resume_queue(c.project, c.issue["id"], c.auth, c.server)
    assert Enum.count(read(c, c.feature)["messages"], &(&1["text"] == instruction)) == 1
    assert read(c, c.feature)["queue"] == []
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "a completed reply remains visible with an explicit notice when its causal budget is exhausted", c do
    {parent, _} = launch(c, c.parent, "Delegate bounded task")
    assert tool(parent, "symphony_delegate", delegate(c.issue, "Finish within this chain", "bounded-child"))["status"] == "queued"
    {issue, _} = runtime("Finish within this chain")

    :sys.replace_state(c.server, fn state ->
      chains = Map.new(state.chats[c.parent["id"]]["agent_chains"], fn {root, _count} -> {root, 24} end)
      put_in(state, [:chats, c.parent["id"], "agent_chains"], chains)
    end)

    send(issue, {:finish, "Completed result remains available"})
    current = wait_chat(c, c.issue, &(&1["status"] == "idle"))
    assert current["status"] == "idle"
    assert List.last(current["messages"])["text"] == "Completed result remains available"
    assert current["agent_notice"] =~ "This supervision chain reached its limit."
    assert disk(c, c.issue)["agent_outbox"] in [nil, []]
    assert read(c, c.parent)["queue"] == []
  end

  test "reconciliation waits for an active feature turn without changing ownership", c do
    native = create_native(c)
    {discussion, _} = launch(c, c.feature, "Keep discussion active")
    Agent.update(c.source, fn _ -> native_task(true) end)
    result = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert {:error, :chat_busy} = result
    assert disk(c, c.feature)["alias_of"] == nil
    assert disk(c, native)["messages"] == []
    send(discussion, {:finish, ""})
    wait_chat(c, c.feature, &(&1["status"] == "idle"))
    assert {:ok, canonical} = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert canonical["id"] == native["id"]
  end

  test "reconciliation cannot overflow either retained queue", c do
    native = create_native(c)

    for {chat, prefix} <- [{c.feature, "discussion"}, {native, "native"}] do
      launch(c, chat, "Hold #{prefix}")

      for index <- 1..11 do
        text = "#{prefix} queued #{index}"
        assert {:ok, _} = Store.send_message(c.project, chat["id"], text, text, c.auth, c.server)
      end

      assert {:ok, _} = Store.stop(c.project, chat["id"], c.auth, c.server)
      wait_chat(c, chat, &(&1["status"] == "interrupted"))
    end

    Agent.update(c.source, fn _ -> native_task(true) end)
    result = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert {:error, :chat_queue_full} = result
    assert disk(c, c.feature)["alias_of"] == nil
    assert length(disk(c, c.feature)["queue"]) == 11
    assert length(disk(c, native)["queue"]) == 11
    remove_first(c, c.feature)
    remove_first(c, native)
    assert {:ok, canonical} = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert canonical["queued_count"] == 20
    assert canonical["queue_paused"]
    assert disk(c, c.feature)["queue"] == []
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "reconciliation rejects an oversized combined history without fencing either record", c do
    native = create_native(c)
    seed_chat(c, c.feature, %{"messages" => history_messages(1..20)})
    seed_chat(c, native, %{"messages" => history_messages(21..40)})
    before = %{old: File.read!(record_path(c, c.feature)), native: File.read!(record_path(c, native))}
    Agent.update(c.source, fn _ -> native_task(true) end)
    result = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert {:error, :chat_history_full} = result
    assert File.read!(record_path(c, c.feature)) == before.old
    assert File.read!(record_path(c, native)) == before.native
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
  end

  test "failure to persist an alias fence leaves both original histories intact", c do
    native = create_native(c)
    old = block_record(c, c.feature)
    original_native = File.read!(record_path(c, native))
    Agent.update(c.source, fn _ -> native_task(true) end)
    result = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert {:error, :chat_storage_unavailable} = result
    assert File.read!(record_path(c, native)) == original_native
    assert Jason.decode!(old)["alias_of"] == nil
    stop_supervised!(Store)
    restore_record(c, c.feature, old)
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    assert {:ok, canonical} = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert canonical["id"] == native["id"]
    assert disk(c, c.feature)["alias_pending"] == false
  end

  test "a failed canonical copy replays its fenced alias and an old PR URL cannot overwrite it", c do
    native = create_native(c)
    {discussion, _} = launch(c, c.feature, "Retain the old discussion through a failed merge")
    send(discussion, {:finish, ""})
    wait_chat(c, c.feature, &(&1["status"] == "idle"))
    original = block_record(c, native)
    Agent.update(c.source, fn _ -> native_task(true) end)
    result = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert {:error, :chat_storage_unavailable} = result
    assert disk(c, c.feature)["alias_pending"]
    assert disk(c, c.feature)["alias_of"] == native["id"]
    stop_supervised!(Store)
    restore_record(c, native, original)
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    assert disk(c, c.feature)["alias_pending"] == false
    assert read(c, c.feature)["id"] == native["id"]
    assert {:ok, canonical} = Store.ensure_pr_conversation(c.project, c.issue["task_id"], "pr:7", c.auth, c.server)
    assert canonical["id"] == native["id"]
    assert Enum.count(canonical["messages"], &(&1["text"] == "Retain the old discussion through a failed merge")) == 1
    assert disk(c, c.feature)["alias_of"] == native["id"]
    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, c.server)
    assert Enum.count(graph["nodes"], &(&1["role"] == "feature")) == 1
  end

  test "failed verified metadata update preserves the last durable feature identity", c do
    original = block_record(c, c.feature)
    Agent.update(c.source, fn task -> put_in(task, [:pull_requests, Access.at(0), :title], "Renamed PR") end)
    result = Store.ensure_pr_conversation(c.project, c.issue["task_id"], "pr:7", c.auth, c.server)
    assert {:error, :chat_storage_unavailable} = result
    assert Jason.decode!(original)["agent_name"] == "README verification"
    assert read(c, c.feature)["agent_name"] == "README verification"
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: false}}
  end

  test "observation sync preserves existing conversations if a new task binding cannot be saved", c do
    added = %{task() | id: c.project <> ":12", issue_id: "12", title: "New observed task", pull_requests: []}
    record = %{"id" => Persistence.conversation_id(c.project, added.id, "scope")}
    existing = File.read!(record_path(c, c.issue))
    File.mkdir!(record_path(c, record))

    assert {:error, :chat_storage_unavailable} = Store.sync_pr_updates(c.project, "scope", board(added), c.server)
    assert File.read!(record_path(c, c.issue)) == existing
    refute Map.has_key?(:sys.get_state(c.server).chats, record["id"])
    refute_receive {:coordination_runtime, _, _}, 30

    stop_supervised!(Store)
    File.rmdir!(record_path(c, record))
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    assert :ok = Store.sync_pr_updates(c.project, "scope", board(added), c.server)
    assert read(c, record)["task_id"] == added.id
    assert read(c, record)["agent_name"] == "New observed task"
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "observation sync retries a feature binding without losing its task or an existing feature", c do
    observed = task()
    added_pr = %{hd(observed.pull_requests) | number: 8, url: "https://github.com/test/one/pull/8"}
    observed = %{observed | pull_requests: [added_pr]}
    record = %{"id" => Persistence.session_conversation_id(c.project, observed.id, "pr:8", "scope")}
    existing = File.read!(record_path(c, c.feature))
    File.mkdir!(record_path(c, record))

    assert {:error, :chat_storage_unavailable} = Store.sync_pr_updates(c.project, "scope", board(observed), c.server)
    assert File.read!(record_path(c, c.feature)) == existing
    refute Map.has_key?(:sys.get_state(c.server).chats, record["id"])
    assert disk(c, c.issue)["agent_name"] == observed.title
    refute_receive {:coordination_runtime, _, _}, 30

    stop_supervised!(Store)
    File.rmdir!(record_path(c, record))
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    assert :ok = Store.sync_pr_updates(c.project, "scope", board(observed), c.server)
    assert read(c, record)["session_id"] == "pr:8"
    assert read(c, c.feature)["session_id"] == "pr:7"
    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, c.server)
    assert Enum.count(graph["nodes"], &(&1["role"] == "feature")) == 2
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "failed reflection queue save preserves observations and retries only after fresh authorization", c do
    assert :ok = Store.sync_pr_updates(c.project, "scope", board(task()), c.server)
    assert disk(c, c.issue)["agent_reflection_pending"]
    original = block_record(c, c.issue)
    result = Store.send_message(c.project, c.parent["id"], "Review the observations", "reflection-auth", c.auth, c.server)
    assert {:error, :chat_storage_unavailable} = result
    assert Jason.decode!(original)["agent_reflection_pending"]
    assert Jason.decode!(original)["queue"] == []
    refute_receive {:coordination_runtime, _, _}, 30

    stop_supervised!(Store)
    restore_record(c, c.issue, original)
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    refute_receive {:coordination_runtime, _, _}, 30
    assert disk(c, c.issue)["agent_reflection_pending"]
    assert {:ok, _} = Store.resume_queue(c.project, c.issue["id"], c.auth, c.server)
    {issue, opts} = runtime("Review these feature observations")
    assert opts.text =~ "CI: Success"
    refute disk(c, c.issue)["agent_reflection_pending"]
    assert Enum.count(read(c, c.issue)["messages"], &(&1["origin"] == "agent_evidence")) == 1
    assert read(c, c.parent)["queue_paused"]
    send(issue, {:finish, ""})
    wait_chat(c, c.issue, &(&1["status"] == "idle"))
    assert {:ok, _} = Store.resume_queue(c.project, c.issue["id"], c.auth, c.server)
    assert Enum.count(read(c, c.issue)["messages"], &(&1["origin"] == "agent_evidence")) == 1
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "reconciliation deduplicates retained real proposals without changing their approval state", c do
    native = create_native(c)
    :sys.replace_state(c.server, &%{&1 | tools: ProposalOnlyTools})
    {discussion, _} = launch(c, c.feature, "Prepare feedback for review")
    old_proposal = tool(discussion, "symphony_propose_action", %{"body" => "Check the original approach"})["proposal"]
    send(discussion, {:finish, ""})
    wait_chat(c, c.feature, &(&1["status"] == "idle"))
    {worker, _} = launch(c, native, "Prepare native feedback for review")
    native_proposal = tool(worker, "symphony_propose_action", %{"body" => "Check the native implementation"})["proposal"]
    send(worker, {:finish, ""})
    wait_chat(c, native, &(&1["status"] == "idle"))

    # A retained partial copy may already contain the exact host-created proposal.
    seed_chat(c, native, %{"proposals" => [old_proposal, native_proposal]})
    Agent.update(c.source, fn _ -> native_task(true) end)
    result = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert {:ok, canonical} = result
    assert canonical["proposals"] == [old_proposal, native_proposal]
    assert Enum.all?(canonical["proposals"], &(&1["status"] == "pending"))

    result = Store.decide(c.project, c.feature["id"], old_proposal["id"], "cancel", c.auth, c.server)
    assert {:ok, updated} = result
    assert Enum.find(updated["proposals"], &(&1["id"] == old_proposal["id"]))["status"] == "cancelled"
    assert Enum.find(updated["proposals"], &(&1["id"] == native_proposal["id"])) == native_proposal
    assert length(updated["proposals"]) == 2
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "one shared PR retains its first discussion owner and other issue links grant no supervision", c do
    linked = linked_task(12)
    set_sources(c, [task(), linked])
    {:ok, second} = Store.ensure_conversation(c.project, linked.id, c.auth, c.server)
    result = Store.ensure_pr_conversation(c.project, linked.id, "pr:7", c.auth, c.server)
    assert {:ok, shared} = result
    assert shared["id"] == c.feature["id"]
    assert shared["task_id"] == c.issue["task_id"]
    assert shared["parent_id"] == c.issue["id"]
    assert shared["agent_task_refs"] == [task().id, linked.id]

    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, c.server)
    assert [feature] = Enum.filter(graph["nodes"], &(&1["role"] == "feature"))
    assert feature["conversation_id"] == c.feature["id"]
    assert reference_edge?(graph, second, shared)
    refute supervision_edge?(graph, second, shared)
    assert supervision_edge?(graph, c.issue, shared)

    {second_agent, _} = launch(c, second, "Inspect the shared feature association")
    assert tool(second_agent, "symphony_delegate", delegate(shared, "Cannot change the owning task", "reference-route"))["error"]
    assert read(c, c.feature)["queue"] == []
  end

  test "verified native ownership moves a shared PR to its owning issue without losing retained work", c do
    linked = linked_task(12)
    set_sources(c, [task(), linked])
    {:ok, owner} = Store.ensure_conversation(c.project, linked.id, c.auth, c.server)
    assert {:ok, _} = Store.ensure_pr_conversation(c.project, linked.id, "pr:7", c.auth, c.server)
    :sys.replace_state(c.server, &%{&1 | tools: ProposalOnlyTools})
    {discussion, _} = launch(c, c.feature, "Discuss the shared PR before native ownership is known")
    goal_args = %{"text" => "Complete the retained feature review", "status" => "active"}
    goal = tool(discussion, "symphony_set_goal", goal_args)["goal"]
    proposal = tool(discussion, "symphony_propose_action", %{"body" => "Keep the earlier review question"})["proposal"]
    queued_text = "Continue reviewing the same shared PR"
    assert {:ok, _} = Store.send_message(c.project, c.feature["id"], queued_text, "shared-followup", c.auth, c.server)
    assert {:ok, _} = Store.stop(c.project, c.feature["id"], c.auth, c.server)
    wait_chat(c, c.feature, &(&1["status"] == "interrupted"))
    [queued] = disk(c, c.feature)["queue"]

    native = linked_native_task(12, String.duplicate("b", 32))
    set_sources(c, [task(), native])
    result = Store.ensure_pr_conversation(c.project, native.id, work_session(), c.auth, c.server)
    assert {:ok, canonical} = result
    expected = Persistence.session_conversation_id(c.project, native.id, work_session(), "scope")
    assert canonical["id"] == expected
    assert canonical["task_id"] == native.id
    assert canonical["parent_id"] == owner["id"]
    assert canonical["agent_task_refs"] == [task().id, native.id]
    assert canonical["agent_session_id"] == work_session()
    assert canonical["queue"] == [queued]
    assert canonical["queue_paused"]
    assert canonical["proposals"] == [proposal]
    assert canonical["agent_goal"] == goal
    assert Enum.any?(canonical["messages"], &(&1["text"] == "Discuss the shared PR before native ownership is known"))
    assert disk(c, c.feature)["alias_of"] == expected
    assert disk(c, c.feature)["queue"] == []
    assert read(c, c.feature)["id"] == expected

    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    assert read(c, c.feature)["id"] == expected
    result = Store.ensure_pr_conversation(c.project, task().id, "pr:7", c.auth, c.server)
    assert {:ok, reopened} = result
    assert reopened["id"] == expected
    assert reopened["agent_session_id"] == work_session()
    assert reopened["proposals"] == [proposal]
    assert reopened["queue"] == [queued]
    assert reopened["agent_goal"] == goal
    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, c.server)
    assert Enum.count(graph["nodes"], &(&1["role"] == "feature")) == 1
    assert supervision_edge?(graph, owner, canonical)
    assert reference_edge?(graph, c.issue, canonical)
    refute supervision_edge?(graph, c.issue, canonical)
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "two different verified native owners of the same PR conflict without replacing its agent", c do
    first = native_task(true)
    second = linked_native_task(12, String.duplicate("c", 32))
    set_sources(c, [first, second])
    assert {:ok, retained} = Store.ensure_pr_conversation(c.project, first.id, work_session(), c.auth, c.server)
    second_session = "work:" <> String.duplicate("c", 32)
    result = Store.ensure_pr_conversation(c.project, second.id, second_session, c.auth, c.server)
    assert {:error, :chat_binding_conflict} = result
    assert read(c, retained)["task_id"] == first.id
    assert read(c, retained)["agent_session_id"] == work_session()
    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, c.server)
    assert [feature] = Enum.filter(graph["nodes"], &(&1["role"] == "feature"))
    assert feature["conversation_id"] == retained["id"]
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
  end

  test "failed native owner creation leaves the original shared PR history and queue unfenced", c do
    launch(c, c.feature, "Retain this discussion while discovering the native owner")
    followup = "Retain the queued review as well"
    result = Store.send_message(c.project, c.feature["id"], followup, "owner-save-followup", c.auth, c.server)
    assert {:ok, _} = result
    assert {:ok, _} = Store.stop(c.project, c.feature["id"], c.auth, c.server)
    wait_chat(c, c.feature, &(&1["status"] == "interrupted"))
    original = File.read!(record_path(c, c.feature))

    native = linked_native_task(12, String.duplicate("b", 32))
    set_sources(c, [task(), native])
    owner = %{"id" => Persistence.session_conversation_id(c.project, native.id, work_session(), "scope")}
    File.mkdir!(record_path(c, owner))
    result = Store.ensure_pr_conversation(c.project, native.id, work_session(), c.auth, c.server)
    assert {:error, :chat_storage_unavailable} = result
    assert File.read!(record_path(c, c.feature)) == original
    assert disk(c, c.feature)["alias_of"] == nil
    assert read(c, c.feature)["id"] == c.feature["id"]
    refute Map.has_key?(:sys.get_state(c.server).chats, owner["id"])
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: false}}

    stop_supervised!(Store)
    File.rmdir!(record_path(c, owner))
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    result = Store.ensure_pr_conversation(c.project, native.id, work_session(), c.auth, c.server)
    assert {:ok, migrated} = result
    assert migrated["id"] == owner["id"]
    assert migrated["messages"] == Jason.decode!(original)["messages"]
    assert migrated["queue"] == Jason.decode!(original)["queue"]
    assert migrated["queue_paused"]
    assert read(c, c.feature)["id"] == owner["id"]
    refute_receive {:coordination_runtime, _, _}, 30
  end

  test "cross-issue ownership waits for both an active turn and pending parent delivery", c do
    native = linked_native_task(12, String.duplicate("b", 32))
    set_sources(c, [task(), native])
    launch(c, c.issue, "Hold the original parent")
    fill_queue(c, c.issue)
    {discussion, _} = launch(c, c.feature, "Report to the original parent before moving")
    result = Store.ensure_pr_conversation(c.project, native.id, work_session(), c.auth, c.server)
    assert {:error, :chat_busy} = result
    assert disk(c, c.feature)["alias_of"] == nil
    send(discussion, {:finish, "Pending report for the original owning task"})
    wait_chat(c, c.feature, &(length(&1["agent_outbox"] || []) == 1))
    assert [%{"status" => "pending"}] = disk(c, c.feature)["agent_outbox"]

    result = Store.ensure_pr_conversation(c.project, native.id, work_session(), c.auth, c.server)
    assert {:error, :chat_busy} = result
    assert disk(c, c.feature)["alias_of"] == nil
    assert read(c, c.feature)["parent_id"] == c.issue["id"]
    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, c.server)
    assert Enum.count(graph["nodes"], &(&1["role"] == "feature")) == 1
  end

  test "a later native owner flattens both older PR aliases and retains their links after restart", c do
    linked = linked_task(12)
    set_sources(c, [task(), linked])
    {:ok, second_issue} = Store.ensure_conversation(c.project, linked.id, c.auth, c.server)
    original = disk(c, c.feature)
    second_id = Persistence.session_conversation_id(c.project, linked.id, "pr:7", "scope")

    # Model the two retained discussion records that predate one-agent-per-PR.
    legacy =
      Map.merge(original, %{
        "id" => second_id,
        "task_id" => linked.id,
        "parent_id" => second_issue["id"],
        "agent_task_refs" => [linked.id]
      })

    assert :ok = Persistence.put(%{path: c.root}, legacy)
    :sys.replace_state(c.server, &put_in(&1, [:chats, second_id], legacy))

    result = Store.ensure_pr_conversation(c.project, linked.id, "pr:7", c.auth, c.server)
    assert {:ok, intermediate} = result
    raw_records = [disk(c, c.feature), disk(c, %{"id" => second_id})]
    assert [earlier_alias] = Enum.filter(raw_records, &is_binary(&1["alias_of"]))
    assert earlier_alias["alias_of"] == intermediate["id"]

    native = linked_native_task(13, String.duplicate("b", 32))
    set_sources(c, [task(), linked, native])
    result = Store.ensure_pr_conversation(c.project, native.id, work_session(), c.auth, c.server)
    assert {:ok, canonical} = result
    assert canonical["task_id"] == native.id
    assert disk(c, earlier_alias)["alias_of"] == canonical["id"]
    assert disk(c, intermediate)["alias_of"] == canonical["id"]
    assert canonical["agent_task_refs"] == [task().id, linked.id, native.id]

    stop_supervised!(Store)
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}

    for {issue_id, raw_id} <- [{task().id, c.feature["id"]}, {linked.id, second_id}] do
      assert read(c, %{"id" => raw_id})["id"] == canonical["id"]
      result = Store.ensure_pr_conversation(c.project, issue_id, "pr:7", c.auth, c.server)
      assert {:ok, reopened} = result
      assert reopened["id"] == canonical["id"]
      assert reopened["agent_session_id"] == work_session()
    end

    assert {:ok, graph} = Store.agent_graph(c.project, c.auth, c.server)
    assert [feature] = Enum.filter(graph["nodes"], &(&1["role"] == "feature"))
    assert Enum.sort(feature["aliases"]) == Enum.sort([c.feature["id"], second_id])
    assert reference_edge?(graph, c.issue, canonical)
    assert reference_edge?(graph, second_issue, canonical)
  end

  for invalid_target <- ["missing", "different PR"] do
    test "an occupied PR slot with a #{invalid_target} alias target cannot be overwritten", c do
      target =
        case unquote(invalid_target) do
          "missing" ->
            String.duplicate("f", 32)

          "different PR" ->
            source = task()
            another = %{hd(source.pull_requests) | number: 8, url: "https://github.com/test/one/pull/8"}
            Agent.update(c.source, fn _ -> %{source | pull_requests: source.pull_requests ++ [another]} end)
            result = Store.ensure_pr_conversation(c.project, source.id, "pr:8", c.auth, c.server)
            assert {:ok, unrelated} = result
            unrelated["id"]
        end

      :sys.replace_state(c.server, &put_in(&1, [:chats, c.feature["id"], "alias_of"], target))
      occupied = :sys.get_state(c.server).chats[c.feature["id"]]
      original = File.read!(record_path(c, c.feature))
      result = Store.ensure_pr_conversation(c.project, task().id, "pr:7", c.auth, c.server)
      assert {:error, :chat_binding_conflict} = result
      assert :sys.get_state(c.server).chats[c.feature["id"]] == occupied
      assert File.read!(record_path(c, c.feature)) == original
      assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: true}}
      refute_receive {:coordination_runtime, _, _}, 30
    end
  end

  test "a newer canonical goal survives reconciliation with an older discussion goal", c do
    native = create_native(c)
    {discussion, _} = launch(c, c.feature, "Set the earlier review goal")
    old_goal = tool(discussion, "symphony_set_goal", %{"text" => "Review the initial design", "status" => "active"})["goal"]
    send(discussion, {:finish, ""})
    wait_chat(c, c.feature, &(&1["status"] == "idle"))
    {worker, _} = launch(c, native, "Set the current implementation goal")
    new_goal = tool(worker, "symphony_set_goal", %{"text" => "Validate the revised implementation", "status" => "active"})["goal"]
    send(worker, {:finish, ""})
    wait_chat(c, native, &(&1["status"] == "idle"))
    assert old_goal["updated_at"] < new_goal["updated_at"]

    Agent.update(c.source, fn _ -> native_task(true) end)
    result = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    assert {:ok, canonical} = result
    assert canonical["agent_goal"] == new_goal
    assert disk(c, native)["agent_goal"] == new_goal
    assert disk(c, c.feature)["agent_goal"] == old_goal
  end

  test "failure to save a flattened alias stops recovery and the retained chain recovers on restart", c do
    intermediate = retained_feature(c, 12)
    canonical = retained_feature(c, 13)
    stop_supervised!(Store)
    original = disk(c, c.feature)
    chain_fields = %{"alias_of" => intermediate["id"], "updated_at" => "2026-09-23T00:00:00Z", "fault_padding" => ""}
    chained = Map.merge(original, chain_fields)
    padding = String.duplicate("x", 8_000_000 - byte_size(Jason.encode!(chained)))
    chained = Map.put(chained, "fault_padding", padding)
    intermediate = Map.put(intermediate, "alias_of", canonical["id"])
    assert :ok = Persistence.put(%{path: c.root}, chained)
    assert :ok = Persistence.put(%{path: c.root}, intermediate)
    original_bytes = File.read!(record_path(c, c.feature))
    assert byte_size(original_bytes) == 8_000_000

    # Loading succeeds. Flattening adds timestamp precision and exceeds the record limit.
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    assert :sys.get_state(server).persistence != nil
    assert Map.has_key?(:sys.get_state(server).chats, c.feature["id"])
    assert Store.health(c.auth, server) == {:ok, %{enabled: true, healthy: false}}
    assert File.read!(record_path(c, c.feature)) == original_bytes
    assert disk(c, intermediate)["alias_of"] == canonical["id"]
    assert disk(c, canonical)["alias_of"] == nil
    result = Store.send_message(c.project, canonical["id"], "Must wait for storage recovery", "faulted-alias", c.auth, server)
    assert {:error, :chat_storage_unavailable} = result
    refute_receive {:coordination_runtime, _, _}, 30

    stop_supervised!(Store)
    assert :ok = Persistence.put(%{path: c.root}, Map.delete(chained, "fault_padding"))
    server = start_supervised!({Store, c.opts})
    c = %{c | server: server}
    assert Store.health(c.auth, server) == {:ok, %{enabled: true, healthy: true}}
    assert disk(c, c.feature)["alias_of"] == canonical["id"]
    assert read(c, c.feature)["id"] == canonical["id"]
    assert read(c, intermediate)["id"] == canonical["id"]
    assert disk(c, c.feature)["messages"] == original["messages"]
    refute_receive {:coordination_runtime, _, _}, 30
  end

  for invalid_binding <- ["cycle", "different PR"] do
    test "startup rejects a retained alias #{invalid_binding} without rewriting either record", c do
      source = disk(c, c.feature)

      target =
        case unquote(invalid_binding) do
          "cycle" ->
            c |> retained_feature(12) |> Map.put("alias_of", source["id"])

          "different PR" ->
            Map.merge(source, %{
              "id" => Persistence.session_conversation_id(c.project, task().id, "pr:8", "scope"),
              "session_id" => "pr:8",
              "agent_session_id" => "pr:8",
              "pr_number" => 8
            })
        end

      stop_supervised!(Store)
      source = Map.put(source, "alias_of", target["id"])
      assert :ok = Persistence.put(%{path: c.root}, source)
      assert :ok = Persistence.put(%{path: c.root}, target)
      source_bytes = File.read!(record_path(c, source))
      target_bytes = File.read!(record_path(c, target))
      server = start_supervised!({Store, c.opts})
      assert :sys.get_state(server).persistence != nil
      assert Store.health(c.auth, server) == {:ok, %{enabled: true, healthy: false}}
      assert File.read!(record_path(c, source)) == source_bytes
      assert File.read!(record_path(c, target)) == target_bytes
      assert Store.get(c.project, source["id"], c.auth, server) == {:error, :chat_binding_conflict}
      refute_receive {:coordination_runtime, _, _}, 30
    end
  end

  defp retained_feature(c, task_number) do
    task = linked_task(task_number)
    {:ok, parent} = Store.ensure_conversation(c.project, task.id, c.auth, c.server)

    chat =
      Map.merge(disk(c, c.feature), %{
        "id" => Persistence.session_conversation_id(c.project, task.id, "pr:7", "scope"),
        "task_id" => task.id,
        "parent_id" => parent["id"],
        "agent_task_refs" => [task.id]
      })

    assert :ok = Persistence.put(%{path: c.root}, chat)
    :sys.replace_state(c.server, &put_in(&1, [:chats, chat["id"]], chat))
    chat
  end

  defp source_task(%{tasks: tasks}, id), do: Map.get(tasks, id)
  defp source_task(%{id: id} = task, id), do: task
  defp source_task(_, _), do: nil

  defp set_sources(c, tasks), do: Agent.update(c.source, fn _ -> %{tasks: Map.new(tasks, &{&1.id, &1})} end)

  defp linked_task(number) do
    %{task() | id: "github:test/one:#{number}", issue_id: to_string(number), title: "Linked issue #{number}"}
  end

  defp linked_native_task(number, work_id) do
    source = linked_task(number)
    work = native_task(true).ledger["pr_work"][String.duplicate("b", 32)]
    work = Map.merge(work, %{"id" => work_id, "issue_id" => source.issue_id})
    %{source | ledger: %{"pr_work" => %{work_id => work}}}
  end

  defp reference_edge?(graph, source, target), do: graph_edge?(graph, "references", source, target)
  defp supervision_edge?(graph, source, target), do: graph_edge?(graph, "supervises", source, target)

  defp graph_edge?(graph, type, source, target) do
    Enum.any?(graph["edges"], fn edge ->
      edge["type"] == type and edge["source"] == Graph.node_id(source["id"]) and edge["target"] == Graph.node_id(target["id"])
    end)
  end

  defp faulting_tool(c, pid, name, args) do
    monitor = Process.monitor(pid)
    send(pid, {:tool, make_ref(), name, args})
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
    assert Store.health(c.auth, c.server) == {:ok, %{enabled: true, healthy: false}}
    assert :sys.get_state(c.server).jobs == %{}
  end

  defp record_path(c, chat), do: Path.join(c.root, chat["id"] <> ".json")

  defp block_record(c, chat) do
    path = record_path(c, chat)
    original = File.read!(path)
    File.rm!(path)
    File.mkdir!(path)
    original
  end

  defp restore_record(c, chat, original) do
    path = record_path(c, chat)
    File.rmdir!(path)
    File.write!(path, original)
  end

  defp seed_chat(c, chat, fields) do
    updated = Map.merge(disk(c, chat), fields)
    assert :ok = Persistence.put(%{path: c.root}, updated)
    :sys.replace_state(c.server, &put_in(&1, [:chats, chat["id"]], updated))
  end

  defp pad_before_ack(c, source, target, text) do
    state = :sys.get_state(c.server)
    cause = state.jobs[source["id"]].entry
    source = state.chats[source["id"]]

    # The host's generated IDs and timestamps have fixed encoded lengths. Fill the
    # durable envelope so pending fits, but the two extra bytes in delivered do not.
    envelope = %{
      "id" => String.duplicate("0", 32),
      "source_id" => source["id"],
      "source_name" => Coordination.label(source),
      "target_id" => target["id"],
      "text" => text,
      "kind" => "instruction",
      "root" => cause["agent_root"],
      "root_chat" => cause["agent_root_chat"],
      "depth" => cause["agent_depth"] + 1,
      "created_at" => source["updated_at"],
      "status" => "pending"
    }

    pending = source |> Map.put("fault_padding", "") |> Map.put("agent_outbox", [envelope])
    padding = String.duplicate("x", 8_000_000 - byte_size(Jason.encode!(pending)))
    assert byte_size(Jason.encode!(Map.put(pending, "fault_padding", padding))) == 8_000_000
    seed_chat(c, source, %{"fault_padding" => padding})
  end

  defp history_messages(range) do
    for index <- range do
      %{
        "id" => index |> Integer.to_string(16) |> String.pad_leading(32, "0"),
        "role" => "assistant",
        "status" => "completed",
        "text" => String.duplicate("x", 170_000),
        "widgets" => [],
        "created_at" => "2026-09-23T10:00:00Z"
      }
    end
  end

  defp create_native(c) do
    Agent.update(c.source, fn _ -> native_task(false) end)
    assert {:ok, native} = Store.ensure_pr_conversation(c.project, c.issue["task_id"], work_session(), c.auth, c.server)
    native
  end

  defp launch(c, chat, text) do
    assert {:ok, _} = Store.send_message(c.project, chat["id"], text, "user-#{System.unique_integer([:positive])}", c.auth, c.server)
    runtime(text)
  end

  defp runtime(text) do
    assert_receive {:coordination_runtime, pid, opts}, 2_000
    assert opts.text =~ text
    {pid, opts}
  end

  defp tool(pid, name, args) do
    ref = make_ref()
    send(pid, {:tool, ref, name, args})
    assert_receive {:coordination_tool, ^ref, result}, 2_000
    result
  end

  defp delegate(chat, text, request_id), do: %{"conversation_id" => chat["id"], "text" => text, "request_id" => request_id}

  defp read(c, chat) do
    assert {:ok, current} = Store.get(c.project, chat["id"], c.auth, c.server)
    current
  end

  defp disk(c, chat), do: c.root |> Path.join(chat["id"] <> ".json") |> File.read!() |> Jason.decode!()

  defp hold_full_parent(c) do
    parent = launch(c, c.parent, "Keep project reasoning busy")
    fill_queue(c, c.parent)
    parent
  end

  defp fill_queue(c, chat) do
    for index <- 1..20 do
      assert {:ok, _} = Store.send_message(c.project, chat["id"], "Queued #{index}", "queued-#{index}", c.auth, c.server)
    end

    assert length(read(c, chat)["queue"]) == 20
  end

  defp remove_first(c, chat) do
    queued = hd(read(c, chat)["queue"])
    assert {:ok, _} = Store.remove_queued(c.project, chat["id"], queued["id"], c.auth, c.server)
  end

  defp wait_chat(c, chat, predicate, attempts \\ 100) do
    current = read(c, chat)
    if predicate.(current), do: current, else: retry(fn -> wait_chat(c, chat, predicate, attempts - 1) end, attempts)
  end

  defp wait_disk(c, chat, predicate, attempts \\ 100) do
    current = disk(c, chat)
    if predicate.(current), do: current, else: retry(fn -> wait_disk(c, chat, predicate, attempts - 1) end, attempts)
  end

  defp retry(fun, attempts) do
    assert attempts > 0, "Store did not reach the expected durable state"
    Process.sleep(10)
    fun.()
  end

  defp task do
    %{
      id: "github:test/one:11",
      project: "github:test/one",
      issue_id: "11",
      title: "Document tests",
      ledger: %{},
      github_status: "available",
      pull_requests: [
        %{
          number: 7,
          title: "README verification",
          url: "https://github.com/test/one/pull/7",
          state: "open",
          checks: "success",
          review: "approved",
          head_sha: String.duplicate("a", 40)
        }
      ]
    }
  end

  defp board(task), do: %{tasks: [task], generated_at: DateTime.utc_now() |> DateTime.to_iso8601(), source_error: nil, runtime_error: nil}

  defp work_session, do: "work:" <> String.duplicate("b", 32)

  defp native_task(published, instruction \\ "Implement README guidance") do
    id = String.duplicate("b", 32)

    work = %{
      "id" => id,
      "issue_id" => "11",
      "tracker_fingerprint" => "scope",
      "phase" => "owner_review",
      "instruction" => instruction,
      "updated_at" => "2026-09-23T10:00:00Z"
    }

    work = if published, do: Map.put(work, "publication", %{"pr_number" => 7, "pr_url" => "https://github.com/test/one/pull/7"}), else: work
    %{task() | ledger: %{"pr_work" => %{id => work}}}
  end
end
