defmodule SymphonyElixirWeb.AssuranceObservationsTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Assurance.Contract
  alias SymphonyElixirWeb.{AssuranceObservations, BoardCache, Endpoint, TaskBoard}

  @project "github:example/observations"
  @sha String.duplicate("a", 40)

  defmodule FixtureRuntime do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call(:control_snapshot, _from, state) do
      send(state.owner, :fixture_control_read)
      {:reply, state.control, state}
    end

    def handle_call({:control, control}, _from, state), do: {:reply, :ok, %{state | control: control}}
  end

  test "scope revisions ignore presentation churn and invalidate changed goals" do
    task = task()
    assert AssuranceObservations.revision(task) == AssuranceObservations.revision(Map.merge(task, %{updated_at: "later", stage: "done"}))
    changed_goal = put_in(task, [:ledger, "pr_work", "work", "goal_revision"], 2)
    refute AssuranceObservations.revision(task) == AssuranceObservations.revision(changed_goal)
    refute AssuranceObservations.revision(task) == AssuranceObservations.revision(Map.put(task, :description, "Different scope"))
  end

  test "new reviews and receipts require successful source state no older than 120 seconds" do
    current = board(task())
    assert AssuranceObservations.source_current?(current)
    assert AssuranceObservations.source_current?(%{current | generated_at: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()})

    for invalid <- [
          %{current | source_error: "tracker unavailable"},
          %{current | runtime_error: "native controls unavailable"},
          %{current | generated_at: DateTime.utc_now() |> DateTime.add(-121) |> DateTime.to_iso8601()},
          %{current | generated_at: "2099-01-01T00:00:00Z"},
          %{current | generated_at: nil},
          %{current | generated_at: "invalid"},
          Map.delete(current, :generated_at),
          nil,
          []
        ] do
      refute AssuranceObservations.source_current?(invalid)
    end
  end

  test "only exact independently reviewed candidate and trusted app checks become observations" do
    task = task()
    observed = observe(task)
    assert Contract.valid_observations?(observed)
    assert [%{"subject" => %{"kind" => "pr", "revision" => @sha, "pr_number" => 7}}] = observed["tasks"]
    assert Enum.map(observed["evidence"], &{&1["check"], &1["result"]}) == [{"independent-review", "passed"}, {"ci:unit", "passed"}]
    refute Enum.any?(observed["evidence"], &(&1["check"] == "unit"))
    untrusted = put_in(task, [:pull_requests, Access.at(0), :check_runs, Access.at(0), :app_slug], "other-app")
    assert length(observe(untrusted)["evidence"]) == 1
    contexts = put_in(task, [:pull_requests, Access.at(0), :check_runs, Access.at(0), :kind], "status_context")
    assert length(observe(contexts)["evidence"]) == 1
    assert Enum.any?(observe(task)["evidence"], &(&1["origin"] == "github"))
  end

  test "skipped, pending and failed runs remain distinct from passing checks" do
    for {status, conclusion, expected} <- [{"completed", "skipped", "skipped"}, {"completed", "neutral", "skipped"}, {"completed", "failure", "failed"}, {"queued", "success", "pending"}] do
      task = task() |> put_in([:pull_requests, Access.at(0), :check_runs, Access.at(0), :status], status) |> put_in([:pull_requests, Access.at(0), :check_runs, Access.at(0), :conclusion], conclusion)
      assert Enum.find(observe(task)["evidence"], &(&1["check"] == "ci:unit"))["result"] == expected
    end
  end

  test "missing source, stale reads and changed PR head never inherit receipts" do
    task = task()

    for changed <- [
          put_in(task, [:pull_requests, Access.at(0), :head_sha], String.duplicate("b", 40)),
          put_in(task, [:ledger, "pr_work", "work", "goal_revision"], 2),
          put_in(task, [:github_status], "unavailable")
        ] do
      assert observe(changed)["evidence"] == []
    end

    for board <- [
          %{board(task) | source_error: "failed"},
          %{board(task) | runtime_error: "failed"},
          %{board(task) | generated_at: "2020-01-01T00:00:00Z"},
          %{board(task) | generated_at: "2099-01-01T00:00:00Z"},
          %{board(task) | generated_at: nil},
          %{board(task) | generated_at: "broken"}
        ] do
      observations = AssuranceObservations.from_board(board, doc(task))
      assert observations["evidence"] == []
      assert hd(observations["tasks"])["subject"] == nil
    end

    assert AssuranceObservations.from_board(board(task), %{"project" => "other", "task_links" => []}) == %{"tasks" => [], "evidence" => []}
    assert AssuranceObservations.from_board(board(task), %{"project" => @project, "task_links" => [%{"task_id" => "unknown"}]})["evidence"] == []
  end

  test "old links, partial details, malformed check names and unapproved review fail closed" do
    task = task()
    stale = put_in(doc(task), ["task_links", Access.at(0), "task_revision"], "old")
    assert AssuranceObservations.from_board(board(task), stale)["evidence"] == []
    partial = put_in(task, [:pull_requests, Access.at(0), :check_details_status], "partial")
    assert length(observe(partial)["evidence"]) == 1
    long_name = put_in(task, [:pull_requests, Access.at(0), :check_runs, Access.at(0), :name], String.duplicate("x", 300))
    assert length(observe(long_name)["evidence"]) == 1
    blocked = put_in(task, [:ledger, "pr_work", "work", "handoff", "review", "verdict"], "request_changes")
    assert Enum.all?(observe(blocked)["evidence"], &(&1["origin"] == "github"))
    assert Enum.empty?(AssuranceObservations.from_board(board(%{task | ledger: %{}}), doc(task))["evidence"])
    unpublished = update_in(task, [:ledger, "pr_work", "work"], &Map.delete(&1, "publication"))
    assert hd(observe(unpublished)["tasks"])["subject"]["kind"] == "source"
  end

  test "badges expose unlinked, stale, missing and verified criteria separately" do
    observed = %{"tasks" => for(n <- 1..4, do: %{"id" => "t#{n}"})}

    rows = [
      %{"task_ids" => ["t2"], "status" => "stale", "issues" => ["stale"]},
      %{"task_ids" => ["t3"], "status" => "unreviewed", "issues" => ["unreviewed"]},
      %{"task_ids" => ["t4"], "status" => "covered", "issues" => []}
    ]

    badges = AssuranceObservations.badges(%{"criteria" => rows}, observed)["tasks"]
    assert Enum.map(1..4, &badges["t#{&1}"]["status"]) == ~w(unlinked stale missing verified)
    assert AssuranceObservations.badges(%{}, %{})["tasks"] == %{}
    refute AssuranceObservations.verify(@project, %{"subject" => %{}})
  end

  test "trusted verification refreshes real scoped cache data and accepts only exact host receipts" do
    fixture = trusted_fixture()
    receipts = AssuranceObservations.from_board(fixture.board, doc(hd(fixture.board.tasks)))["evidence"]
    assert length(receipts) == 2
    assert Enum.all?(receipts, &AssuranceObservations.verify(@project, &1))
    assert_receive :fixture_control_read

    receipt = Enum.find(receipts, &(&1["origin"] == "native"))

    for {field, value} <- [{"run_id", "other-run"}, {"producer", "untrusted-producer"}, {"origin", "manual"}, {"id", "forged-id"}, {"release_id", "claimed-release"}, {"result", "failed"}] do
      refute AssuranceObservations.verify(@project, Map.put(receipt, field, value))
    end

    refute AssuranceObservations.verify("github:other/repo", receipt)
    refute AssuranceObservations.verify(@project, :malformed_receipt)
    refute AssuranceObservations.verify(@project, put_in(receipt, ["subject", "revision"], String.duplicate("c", 40)))
    assert AssuranceObservations.verify(@project, Map.put(receipt, "observed_at", "2020-01-01T00:00:00Z"))
  end

  test "cached candidate receipts fail after native goal or runtime scope changes" do
    fixture = trusted_fixture()
    receipt = AssuranceObservations.from_board(fixture.board, doc(hd(fixture.board.tasks)))["evidence"] |> hd()
    assert AssuranceObservations.verify(@project, receipt)
    changed = put_in(fixture.control, ["issues", "1", "pr_work", "work", "goal_revision"], 2)
    assert :ok = GenServer.call(fixture.runtime, {:control, changed})
    refute AssuranceObservations.verify(@project, receipt)
    assert :ok = GenServer.call(fixture.runtime, {:control, Map.put(fixture.control, "fault", "native controls unavailable")})
    refute AssuranceObservations.verify(@project, receipt)
    assert :ok = GenServer.call(fixture.runtime, {:control, Map.put(fixture.control, "tracker_fingerprint", "different-source")})
    refute AssuranceObservations.verify(@project, receipt)
  end

  test "verification rejects missing, expired and stale source cache without tracker reads" do
    fixture = trusted_fixture()
    receipt = AssuranceObservations.from_board(fixture.board, doc(hd(fixture.board.tasks)))["evidence"] |> hd()
    assert AssuranceObservations.verify(@project, receipt)
    assert :ok = BoardCache.put("different-scope", fixture.board)
    refute AssuranceObservations.verify(@project, receipt)

    for timestamp <- [DateTime.utc_now() |> DateTime.add(-121) |> DateTime.to_iso8601(), "2099-01-01T00:00:00Z", nil, "invalid"] do
      assert :ok = BoardCache.put(fixture.scope, %{fixture.board | generated_at: timestamp})
      refute AssuranceObservations.verify(@project, receipt)
    end

    assert :ok = BoardCache.put(fixture.scope, fixture.board)

    :sys.replace_state(BoardCache, fn state ->
      {scope, board, at} = state.entry
      %{state | entry: {scope, %{board | source_error: "source unavailable"}, at}}
    end)

    refute AssuranceObservations.verify(@project, receipt)
    assert :ok = BoardCache.put(fixture.scope, fixture.board)
    expired_clock = fn -> System.monotonic_time(:millisecond) + 90_001 end
    :sys.replace_state(BoardCache, fn state -> %{state | clock: expired_clock} end)
    refute AssuranceObservations.verify(@project, receipt)
  end

  test "configuration rotation and loss of the configured runtime invalidate cached receipts" do
    fixture = trusted_fixture()
    receipt = AssuranceObservations.from_board(fixture.board, doc(hd(fixture.board.tasks)))["evidence"] |> hd()
    assert AssuranceObservations.verify(@project, receipt)
    previous = Application.get_env(:symphony_elixir, Endpoint)
    Endpoint.config_change([{Endpoint, Keyword.put(previous, :orchestrator, :missing_assurance_fixture)}], [])
    refute AssuranceObservations.verify(@project, receipt)
    Endpoint.config_change([{Endpoint, Keyword.put(previous, :orchestrator, fixture.runtime)}], [])
    assert AssuranceObservations.verify(@project, receipt)
    write_configuration("example/changed")
    refute AssuranceObservations.verify(@project, receipt)
    write_configuration("example/observations")
    assert AssuranceObservations.verify(@project, receipt)
    File.write!(Workflow.workflow_file_path(), "---\ntracker: broken\n---\nInvalid")
    assert {:error, {:invalid_workflow_config, _}} = WorkflowStore.force_reload()
    assert AssuranceObservations.verify(@project, receipt)
    workflow_owner = Process.whereis(WorkflowStore)
    Process.unregister(WorkflowStore)

    try do
      assert {:error, _} = Config.settings()
      refute AssuranceObservations.verify(@project, receipt)
    after
      Process.register(workflow_owner, WorkflowStore)
    end

    Application.put_env(:symphony_elixir, Endpoint, previous)
  end

  defp trusted_fixture do
    write_configuration("example/observations")
    original_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])
    original_cache = :sys.get_state(BoardCache)
    settings = Config.settings!()

    control = %{
      "enabled" => true,
      "tracker_fingerprint" => Orchestrator.tracker_fingerprint(),
      "issues" => %{"1" => task().ledger}
    }

    runtime = start_supervised!({FixtureRuntime, %{control: control, owner: self()}})
    endpoint_config = [server: false, secret_key_base: String.duplicate("c", 64), orchestrator: runtime]
    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, original_endpoint)
      :sys.replace_state(BoardCache, fn _ -> original_cache end)
    end)

    issue = %Issue{
      id: "1",
      identifier: "GH-1",
      title: "Bounded change",
      state: "open",
      description: "Requirements",
      labels: ["kind:feature"],
      dispatchable: true,
      native_ref: %{"repo" => "example/observations"}
    }

    board = TaskBoard.project([issue], %{running: [], retrying: [], blocked: []}, control, settings)
    evidence = Map.take(task(), [:pull_requests, :github_status])
    board = update_in(board.tasks, fn [projected] -> [Map.merge(projected, evidence)] end)
    scope = BoardCache.scope(runtime)
    assert is_binary(scope)
    assert :ok = BoardCache.put(scope, board)
    %{runtime: runtime, board: board, scope: scope, control: control}
  end

  defp write_configuration(repository) do
    configuration = %{
      tracker: %{
        kind: "github",
        provider: %{repo: repository, token: "test-token"},
        active_states: ["open"],
        terminal_states: ["closed"],
        required_labels: ["ready"]
      },
      control: %{enabled: false},
      observability: %{dashboard_enabled: false}
    }

    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(configuration) <> "\n---\nFixture")
    assert :ok = WorkflowStore.force_reload()
  end

  defp observe(task), do: AssuranceObservations.from_board(board(task), doc(task))
  defp board(task), do: %{tasks: [task], source_error: nil, runtime_error: nil, generated_at: DateTime.utc_now() |> DateTime.to_iso8601()}

  defp doc(task) do
    raw = AssuranceObservations.from_board(board(task), %{"project" => @project, "task_links" => []})

    %{
      "project" => @project,
      "task_links" => [%{"task_id" => task.id, "criterion_id" => "criterion", "task_revision" => AssuranceObservations.revision(task), "subject" => hd(raw["tasks"])["subject"]}]
    }
  end

  defp task do
    work = %{
      "id" => "work",
      "head_sha" => @sha,
      "base_sha" => String.duplicate("b", 40),
      "phase" => "owner_review",
      "goal_revision" => 1,
      "publication" => %{"pr_number" => 7, "pr_url" => "https://github.com/example/observations/pull/7"},
      "handoff" => %{
        "work_id" => "work",
        "candidate_sha" => @sha,
        "base_sha" => String.duplicate("b", 40),
        "goal_revision" => 1,
        "run_id" => "run",
        "review" => %{"candidate_sha" => @sha, "verdict" => "approve", "findings" => []},
        "checks" => []
      }
    }

    %{
      id: @project <> ":1",
      project: @project,
      title: "Bounded change",
      description: "Requirements",
      task_kind: "feature",
      dependencies: [],
      ledger: %{"pr_work" => %{"work" => work}},
      github_status: "available",
      pull_requests: [
        %{
          number: 7,
          url: "https://github.com/example/observations/pull/7",
          head_sha: @sha,
          check_details_status: "available",
          check_runs: [%{id: "check-run", kind: "check_run", app_slug: "github-actions", name: "unit", status: "completed", conclusion: "success"}]
        }
      ]
    }
  end
end
