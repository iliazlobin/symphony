defmodule SymphonyElixirWeb.WorkflowPlanTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{IssueAcceptance, TaskIdentity, TaskRouting}
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixirWeb.{TaskBoard, WorkflowPlan}

  @sha String.duplicate("a", 40)

  test "branch and join sequence is deterministic; priority only orders peers" do
    issues = [issue("1", "none", 3), issue("2", "#1", 3), issue("3", "#1", 1), issue("4", "#2, #3", 1), issue("5", "none", 1)]
    plan = issues |> board() |> WorkflowPlan.project()
    assert plan["available"]
    assert plan["mode"] == "sequence"
    assert Enum.map(plan["rows"], & &1["issue_id"]) == ~w(5 1 3 2 4)
    assert Enum.map(plan["rows"], & &1["start_step"]) == [0, 0, 1, 1, 2]
    assert Enum.map(plan["rows"], & &1["end_step"]) == [1, 1, 2, 2, 3]
    assert plan["step_count"] == 3
    assert Enum.map(plan["stages"], &length(&1["task_ids"])) == [2, 2, 1]
    assert Enum.all?(plan["rows"], &(&1["planning_status"] == "sequenced"))
    assert Enum.all?(plan["rows"], &(Map.take(&1, ~w(start_at end_at duration due_at)) == %{}))
    assert Enum.count(plan["edges"], &(&1["type"] == "depends_on")) == 4
    assert plan == issues |> Enum.reverse() |> board() |> WorkflowPlan.project()
  end

  test "sequence never replaces acceptance policy or runtime state" do
    first = %{issue("1", "none") | state: "closed"}
    second = %{issue("2", "#1") | labels: []}
    waiting = [first, second] |> board() |> WorkflowPlan.project()
    assert row(waiting, "1")["lane"] == "review"
    assert row(waiting, "2")["dependency_state"] == "waiting"
    assert row(waiting, "2")["start_step"] == 1
    assert row(waiting, "2")["planning_status"] == "sequenced"

    accepted = board([first, second], %{"issues" => %{"1" => acceptance()}}) |> WorkflowPlan.project()
    assert row(accepted, "1")["lane"] == "done"
    assert row(accepted, "2")["dependency_state"] == "clear"
    assert row(accepted, "2")["lane"] == "backlog"
    assert row(accepted, "2")["execution_status"] == "idle"
  end

  test "cycles and their downstream chains have no fabricated sequence slots" do
    plan =
      [issue("1", "#2"), issue("2", "#1"), issue("3", "#1"), issue("4", "#3"), issue("5", "none")]
      |> board()
      |> WorkflowPlan.project()

    assert row(plan, "1")["planning_status"] == "cycle"
    assert row(plan, "2")["planning_status"] == "cycle"
    assert row(plan, "1")["dependency_state"] == "cycle"
    assert row(plan, "3")["planning_status"] == "blocked"
    assert row(plan, "4")["planning_status"] == "blocked"
    assert row(plan, "5")["start_step"] == 0

    for id <- ~w(1 2 3 4) do
      assert row(plan, id)["start_step"] == nil
      assert row(plan, id)["end_step"] == nil
    end

    assert plan["stages"] == [%{"index" => 0, "task_ids" => [canonical("5")]}]
    assert Enum.any?(plan["warnings"], &String.contains?(&1, "cycle"))
  end

  test "unavailable accepted context cannot override a satisfied native prerequisite" do
    original = board([issue("2", "#1")], %{"issues" => %{"1" => acceptance()}})
    plan = WorkflowPlan.project(original)
    assert row(plan, "1")["planning_status"] == "unknown"
    assert row(plan, "1")["lane"] == "done"
    assert row(plan, "2")["planning_status"] == "blocked"
    assert row(plan, "2")["start_step"] == nil
    assert row(plan, "2")["dependency_state"] == "clear"
    assert row(plan, "2")["execution_status"] == "idle"
    assert row(plan, "2")["lane"] == "work"
    assert Enum.find(plan["edges"], &(&1["type"] == "depends_on"))["status"] == "satisfied"
  end

  test "missing prerequisites and invalid declarations remain unknown and block downstream planning" do
    plan = [issue("1", "#99"), issue("2", "#1"), issue("3", "none")] |> board() |> WorkflowPlan.project()
    missing = Enum.find(plan["nodes"], &(&1["issue_id"] == "99"))
    assert missing["planning_status"] == "unknown"
    refute missing["visible"]
    assert row(plan, "1")["planning_status"] == "blocked"
    assert row(plan, "2")["planning_status"] == "blocked"
    assert row(plan, "1")["dependency_state"] == "unknown"
    assert row(plan, "1")["upstream_count"] == 1
    assert row(plan, "1")["upstream_unknown"] == 1
    assert row(plan, "1")["upstream_outside_filter"] == 0
    assert row(plan, "3")["start_step"] == 0

    invalid = %{issue("1", "none") | description: "No prerequisite declaration"}
    invalid_plan = [invalid, issue("2", "#1")] |> board() |> WorkflowPlan.project()
    assert row(invalid_plan, "1")["planning_status"] == "unknown"
    assert row(invalid_plan, "2")["planning_status"] == "blocked"
    assert invalid_plan["stages"] == []
  end

  test "a missing join prerequisite does not disrupt the sequenced branch sharing its parent" do
    plan =
      [issue("1", "none"), issue("2", "#1, #99"), issue("3", "#1"), issue("4", "#3"), issue("5", "#2")]
      |> board()
      |> WorkflowPlan.project()

    assert plan["available"]
    assert Enum.map(~w(1 3 4), &row(plan, &1)["start_step"]) == [0, 1, 2]
    assert Enum.all?(~w(1 3 4), &(row(plan, &1)["planning_status"] == "sequenced"))

    assert plan["stages"] == [
             %{"index" => 0, "task_ids" => [canonical("1")]},
             %{"index" => 1, "task_ids" => [canonical("3")]},
             %{"index" => 2, "task_ids" => [canonical("4")]}
           ]

    assert row(plan, "2")["upstream_known"] == 1
    assert row(plan, "2")["upstream_unknown"] == 1
    assert row(plan, "2")["dependency_state"] == "unknown"

    for id <- ~w(2 5) do
      assert row(plan, id)["planning_status"] == "blocked"
      assert row(plan, id)["start_step"] == nil
      assert row(plan, id)["end_step"] == nil
    end
  end

  test "filters preserve sequence and distinguish known hidden neighbors from unavailable prerequisites" do
    original = board([issue("1", "none"), issue("2", "#1"), issue("3", "#1"), issue("4", "#2, #3")])
    plan = WorkflowPlan.project(original, [canonical("2")])
    assert [second] = plan["rows"]
    assert second["start_step"] == 1
    assert second["upstream_count"] == 1
    assert second["upstream_known"] == 1
    assert second["upstream_outside_filter"] == 1
    assert second["upstream_unknown"] == 0
    assert second["downstream_count"] == 1
    assert second["downstream_outside_filter"] == 1
    assert Enum.count(plan["nodes"], &(&1["type"] == "task" and &1["visible"])) == 1
    assert Enum.find(plan["nodes"], &(&1["issue_id"] == "4"))["start_step"] == 2
    assert plan["edges"] == original.workflow_graph["edges"]

    empty = WorkflowPlan.project(original, [])
    assert empty["rows"] == []
    assert empty["stages"] == []
    assert empty["step_count"] == 0
    assert Enum.count(empty["nodes"], &(&1["type"] == "task")) == 4
    assert Enum.find(empty["nodes"], &(&1["issue_id"] == "4"))["upstream_outside_filter"] == 2
  end

  test "milestone and kind grouping keeps useful metadata without turning tags or priority into dependencies" do
    milestone = %{id: "7", title: "Pilot", state: "open", url: "https://github.com/example/tasks/milestone/7"}
    first = %{issue("1", "none") | milestone: milestone, labels: ~w(kind:feature category:testing api priority:1 ready)}
    second = %{issue("2", "none") | milestone: milestone, labels: ~w(kind:analysis category:performance)}
    plan = [first, second, issue("3", "none")] |> board() |> WorkflowPlan.project()
    assert row(plan, "1")["milestone"]["title"] == "Pilot"
    assert row(plan, "1")["tags"] == ~w(api category:testing)
    assert Enum.find(plan["groups"]["milestones"], &(&1["id"] == "7"))["task_ids"] == [canonical("1"), canonical("2")]
    assert Enum.map(plan["groups"]["kinds"], & &1["id"]) == ~w(analysis feature general)
    refute Enum.any?(plan["edges"], &(&1["type"] == "depends_on"))
  end

  test "nonblocking relationships keep counts and evidence without imposing sequence order" do
    original = board([issue("1", "none"), issue("2", "#1")])
    edges = Enum.map(original.workflow_graph["edges"], fn edge -> if edge["type"] == "depends_on", do: Map.put(edge, "blocking", false), else: edge end)
    plan = original |> put_in([:workflow_graph, "edges"], edges) |> WorkflowPlan.project()
    assert row(plan, "2")["start_step"] == 0
    assert row(plan, "2")["upstream_count"] == 1
    assert row(plan, "2")["dependency_state"] == "clear"
  end

  test "a recovered graph without a referenced node cannot claim a complete sequence" do
    original = board([issue("1", "#99"), issue("2", "#1"), issue("3", "none")])
    nodes = Enum.reject(original.workflow_graph["nodes"], &(&1["issue_id"] == "99"))
    plan = original |> put_in([:workflow_graph, "nodes"], nodes) |> WorkflowPlan.project()
    refute plan["available"]
    assert plan["rows"] == []
    assert plan["nodes"] == []

    graph_only = original |> Map.delete(:tasks) |> WorkflowPlan.project()
    assert Enum.map(graph_only["rows"], & &1["task_id"]) == Enum.map(WorkflowPlan.project(original)["rows"], & &1["task_id"])
    assert WorkflowPlan.project(original, :invalid)["rows"] == []
  end

  test "incomplete or malformed snapshots cannot produce a planning sequence" do
    original = board([issue("1", "none")])

    for changed <- [
          Map.put(original, :source_error, "Tracker unavailable"),
          Map.put(original, :runtime_error, "Control unavailable"),
          Map.delete(original, :workflow_graph),
          put_in(original, [:workflow_graph, "nodes"], [nil]),
          put_in(original, [:workflow_graph, "nodes"], original.workflow_graph["nodes"] ++ original.workflow_graph["nodes"]),
          put_in(original, [:workflow_graph, "edges"], [nil]),
          put_in(original, [:workflow_graph, "edges"], [%{"type" => "depends_on"}]),
          put_in(original, [:workflow_graph, "edges"], [%{"type" => "depends_on", "source" => "absent", "target" => "absent"}]),
          put_in(original, [:workflow_graph, "edges"], [%{"type" => "contains", "source" => "absent", "target" => "absent"}]),
          put_in(original, [:workflow_graph, "edges"], [%{"type" => "unknown", "source" => "absent", "target" => "absent"}]),
          put_in(original, [:workflow_graph, "nodes"], [%{"id" => "task:1", "type" => "task", "task_id" => nil}]),
          put_in(original, [:workflow_graph, "nodes"], [%{"id" => "", "type" => "project"}]),
          put_in(original, [:workflow_graph, "warnings"], "incomplete")
        ] do
      plan = WorkflowPlan.project(changed)
      refute plan["available"]
      assert plan["rows"] == []
      assert plan["stages"] == []
      assert plan["reason"] =~ "incomplete"
    end

    empty = [] |> board() |> WorkflowPlan.project()
    assert empty["available"]
    assert empty["rows"] == []
    assert empty["step_count"] == 0
  end

  test "malformed consumed metadata is unavailable while omitted fields and unknown extensions remain valid" do
    first = %{"id" => "task:1", "type" => "task", "task_id" => canonical("1"), "extension" => %{"future" => true}}
    second = %{"id" => "task:2", "type" => "task", "task_id" => canonical("2")}
    edge = %{"type" => "depends_on", "source" => "task:2", "target" => "task:1", "status" => "waiting"}
    graph = %{"version" => 1, "nodes" => [first, second], "edges" => [edge]}
    original = %{workflow_graph: graph}
    valid = WorkflowPlan.project(original)
    assert valid["available"]
    assert row(valid, "1")["extension"] == %{"future" => true}
    assert row(valid, "2")["start_step"] == 1

    invalid_nodes =
      Enum.map(~w(title name identifier task_kind lane phase dependency_error work_id task_id), &Map.put(first, &1, %{})) ++
        [
          Map.put(first, "priority", "P1"),
          Map.put(first, "milestone", "Launch"),
          Map.put(first, "milestone", %{"title" => [], "id" => 7}),
          Map.put(first, "milestone", %{"title" => "Launch", "id" => %{}})
        ]

    for node <- invalid_nodes do
      plan = original |> put_in([:workflow_graph, "nodes"], [node, second]) |> WorkflowPlan.project()
      refute plan["available"]
      assert plan["rows"] == []
    end

    for key <- ~w(reason status kind), type <- ~w(depends_on contains) do
      malformed = edge |> Map.put("type", type) |> Map.put(key, %{})
      plan = original |> put_in([:workflow_graph, "edges"], [malformed]) |> WorkflowPlan.project()
      refute plan["available"]
      assert plan["nodes"] == []
    end

    for milestone <- [%{"id" => nil, "title" => nil}, %{"id" => "7", "title" => "Launch"}, %{"id" => 7, "title" => "Launch"}] do
      node = Map.merge(first, %{"title" => nil, "task_kind" => nil, "priority" => nil, "milestone" => milestone})
      assert original |> put_in([:workflow_graph, "nodes"], [node, second]) |> WorkflowPlan.project() |> Map.fetch!("available")
    end
  end

  test "calendar drafts use explicit durations and prerequisite finishes without inventing capacity" do
    original = board([issue("1", "none"), issue("2", "#1"), issue("3", "#1"), issue("4", "#2, #3")])
    options = %{"anchor_on" => "2026-10-05", "durations" => %{canonical("1") => 3, canonical("2") => 2, canonical("3") => 5}}
    plan = WorkflowPlan.calendar(original, :all, ~D[2026-10-03], options)
    assert timing(plan, "1")["start_on"] == "2026-10-05"
    assert timing(plan, "1")["end_on"] == "2026-10-08"
    assert timing(plan, "2")["start_on"] == "2026-10-08"
    assert timing(plan, "3")["start_on"] == "2026-10-08"
    assert timing(plan, "4")["start_on"] == "2026-10-13"
    assert timing(plan, "4")["duration_days"] == 1
    assert Enum.all?(plan["rows"], &(&1["timeline"]["kind"] == "draft"))
    assert plan["calendar"]["today_on"] == "2026-10-03"
    assert plan["calendar"]["anchor_on"] == "2026-10-05"
    assert plan["edges"] == original.workflow_graph["edges"]
    assert original.control == %{}

    filtered = WorkflowPlan.calendar(original, [canonical("4")], ~D[2026-10-03], options)
    assert timing(filtered, "4") == timing(plan, "4")
    assert row(filtered, "4")["upstream_outside_filter"] == 2

    context_options = %{"context_task_id" => canonical("4"), "durations" => %{canonical("1") => 30, canonical("2") => 30, canonical("3") => 30}}
    context = WorkflowPlan.calendar(original, [canonical("1")], ~D[2026-10-03], context_options)
    assert length(context["rows"]) == 1
    assert context["calendar"]["end_on"] == "2026-12-03"
  end

  test "accepted dates are milestones and never infer work duration from tracker timestamps" do
    accepted = acceptance() |> put_in(["acceptance", "accepted_at"], "2026-10-01T20:00:00Z")
    original = board([issue("1", "none"), issue("2", "#1")], %{"issues" => %{"1" => accepted}})
    plan = WorkflowPlan.calendar(original, :all, ~D[2026-10-03])
    assert timing(plan, "1")["kind"] == "accepted"
    assert timing(plan, "1")["start_on"] == "2026-10-01"
    assert timing(plan, "1")["duration_days"] == 0
    assert timing(plan, "2")["start_on"] == "2026-10-03"
    assert timing(plan, "2")["kind"] == "draft"

    past_anchor = WorkflowPlan.calendar(original, :all, ~D[2026-10-03], %{"anchor_on" => "2026-09-20"})
    assert timing(past_anchor, "2")["start_on"] == "2026-10-01"

    absent = update_in(original.tasks, fn tasks -> Enum.map(tasks, &Map.put(&1, :acceptance, nil)) end)
    undated = WorkflowPlan.calendar(absent, :all, ~D[2026-10-03])
    assert timing(undated, "1")["kind"] == "unscheduled"
    assert timing(undated, "1")["start_on"] == nil
    assert timing(undated, "2")["start_on"] == "2026-10-03"

    future_record = put_in(accepted, ["acceptance", "accepted_at"], "2026-10-10T20:00:00Z")
    future = board([issue("1", "none")], %{"issues" => %{"1" => future_record}}) |> WorkflowPlan.calendar(:all, ~D[2026-10-03])
    assert timing(future, "1")["kind"] == "unscheduled"
    assert timing(future, "1")["start_on"] == nil
  end

  test "active starts are recorded separately from estimated remaining work and dependent starts" do
    runtime = %{running: [%{issue_id: "1", issue_identifier: "GH-1", started_at: "2026-10-01T23:00:00-07:00"}]}
    original = TaskBoard.project([issue("1", "none"), issue("2", "#1")], runtime, %{}, settings())
    plan = WorkflowPlan.calendar(original, :all, ~D[2026-10-03], %{"durations" => %{canonical("1") => 4}})
    assert timing(plan, "1")["kind"] == "running"
    assert timing(plan, "1")["start_on"] == "2026-10-02"
    assert timing(plan, "1")["observed_through_on"] == "2026-10-03"
    assert timing(plan, "1")["draft_start_on"] == "2026-10-03"
    assert timing(plan, "1")["end_on"] == "2026-10-07"
    assert timing(plan, "2")["start_on"] == "2026-10-07"

    stale = %{original | generated_at: "2026-10-02T23:59:00Z"} |> WorkflowPlan.calendar(:all, ~D[2026-10-03])
    assert stale["calendar"]["today_on"] == "2026-10-03"
    assert timing(stale, "1")["observed_through_on"] == "2026-10-02"
    assert timing(stale, "1")["draft_start_on"] == "2026-10-03"

    future = %{original | generated_at: "2026-10-10T23:59:00Z"} |> WorkflowPlan.calendar(:all, ~D[2026-10-03])
    assert timing(future, "1")["observed_through_on"] == "2026-10-03"

    datetime = put_in(original.tasks, Enum.map(original.tasks, fn task -> if task.issue_id == "1", do: put_in(task, [:runtime, :started_at], ~U[2026-10-02 09:00:00Z]), else: task end))
    assert WorkflowPlan.calendar(datetime, :all, ~D[2026-10-03]) |> timing("1") |> Map.fetch!("start_on") == "2026-10-02"
  end

  test "foreign, malformed and future execution timing cannot create recorded intervals" do
    graph = board([issue("1", "none")]).workflow_graph
    graph = update_in(graph["nodes"], fn nodes -> Enum.map(nodes, &if(&1["type"] == "task", do: Map.put(&1, "execution_status", "running"), else: &1)) end)

    for runtime <- [
          nil,
          "bad",
          %{status: "running", issue_id: "2", started_at: "2026-10-01T10:00:00Z"},
          %{status: "running", issue_id: "1", started_at: "bad"},
          %{status: "running", issue_id: "1", started_at: "2026-10-09T10:00:00Z"}
        ] do
      original = %{workflow_graph: graph, tasks: [%{id: canonical("1"), issue_id: "1", runtime: runtime}]}
      plan = WorkflowPlan.calendar(original, :all, ~D[2026-10-03])
      assert timing(plan, "1")["kind"] == "unscheduled"
      assert timing(plan, "1")["reason"] =~ "active run"
      assert timing(plan, "1")["start_on"] == nil
    end
  end

  test "calendar bounds and draft defaults remain finite for oversized or invalid estimates" do
    original = board([issue("1", "none"), issue("2", "#1"), issue("3", "#2")])
    options = %{"anchor_on" => "2020-01-01", "durations" => %{canonical("1") => 365, canonical("2") => 2}}
    plan = WorkflowPlan.calendar(original, :all, ~D[2026-10-03], options)
    assert plan["calendar"]["anchor_on"] == "2026-10-03"
    assert timing(plan, "1")["kind"] == "draft"
    assert timing(plan, "2")["kind"] == "unscheduled"
    assert timing(plan, "2")["reason"] =~ "date range"
    assert timing(plan, "3")["kind"] == "unscheduled"
    assert timing(plan, "3")["reason"] =~ "finish estimate"
    assert plan["calendar"]["day_count"] <= 733

    for bad <- [0, -1, 366, "10", nil] do
      defaults = WorkflowPlan.calendar(original, :all, ~D[2026-10-03], %{"anchor_on" => "bad", "durations" => %{canonical("1") => bad}})
      assert timing(defaults, "1")["duration_days"] == 1
      assert defaults["calendar"]["anchor_on"] == "2026-10-03"
    end

    assert WorkflowPlan.calendar(original, :all, ~D[2026-10-03], %{"anchor_on" => ~D[2026-10-05], "durations" => "bad"})["calendar"]["anchor_on"] == "2026-10-05"
  end

  test "calendar uncertainty preserves task control states and old recorded dates retain a bounded window" do
    original = board([issue("1", "#2"), issue("2", "#1"), issue("3", "#99")])
    plan = WorkflowPlan.calendar(original, :all, ~D[2026-10-03])
    assert Enum.all?(plan["rows"], &(&1["timeline"]["kind"] == "unscheduled"))
    assert row(plan, "1")["lane"] == row(WorkflowPlan.project(original), "1")["lane"]
    assert timing(plan, "1")["reason"] =~ "prerequisites"
    assert WorkflowPlan.calendar(%{}, :all, ~D[2026-10-03])["calendar"]["day_count"] == 29

    accepted = acceptance() |> put_in(["acceptance", "accepted_at"], "2000-01-01T00:00:00Z")
    history = board([issue("1", "none")], %{"issues" => %{"1" => accepted}}) |> WorkflowPlan.calendar(:all, ~D[2026-10-03])
    assert timing(history, "1")["start_on"] == "2000-01-01"
    assert history["calendar"]["start_on"] == Date.to_iso8601(Date.add(~D[2026-10-03], -366))
    assert history["calendar"]["day_count"] <= 733

    source = %{workflow_graph: original.workflow_graph, tasks: nil}
    assert WorkflowPlan.calendar(source, [], ~D[2026-10-03])["rows"] == []
    assert WorkflowPlan.calendar(%{source | tasks: [nil]}, [], ~D[2026-10-03])["rows"] == []
  end

  defp timing(plan, id), do: row(plan, id)["timeline"]
  defp row(plan, id), do: Enum.find(plan["rows"], &(&1["task_id"] == canonical(id)))
  defp canonical(id), do: "github:example/tasks:" <> id
  defp board(issues, control \\ %{}), do: TaskBoard.project(issues, %{}, control, settings())

  defp issue(id, dependencies, priority \\ 2) do
    %Issue{
      id: id,
      identifier: "GH-" <> id,
      title: "Task " <> id,
      description: "Depends on: " <> dependencies,
      state: "open",
      native_ref: %{"repo" => "example/tasks"},
      dispatchable: true,
      priority: priority,
      updated_at: ~U[2026-10-01 10:00:00Z],
      labels: ["ready"]
    }
  end

  defp acceptance do
    tracker = settings().tracker
    verified = %{id: "1", state: "closed", updated_at: "2026-10-01T10:00:00Z", terminal: true}

    params = %{
      "issue_id" => "1",
      "command_id" => "accept",
      "expected_revision" => 0,
      "expected_candidate_sha" => @sha,
      "expected_updated_at" => verified.updated_at,
      "expected_tracker_state" => verified.state
    }

    context = %{
      tracker_fingerprint: TaskRouting.fingerprint(tracker),
      project_id: TaskIdentity.project_id(tracker),
      acceptance_issue: verified
    }

    {:ok, item} = IssueAcceptance.accept(%{"handoff" => %{"candidate_sha" => @sha}}, params, context)
    item
  end

  defp settings do
    %{
      tracker: %{
        kind: "github",
        provider: %{"repo" => "example/tasks", "token" => "fixture"},
        project_slug: nil,
        required_labels: ["ready"],
        active_states: ["open"],
        terminal_states: ["closed"]
      },
      control: %{enabled: true}
    }
  end
end
