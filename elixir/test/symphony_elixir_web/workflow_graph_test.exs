defmodule SymphonyElixirWeb.WorkflowGraphTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{IssueAcceptance, TaskIdentity, TaskRouting}
  alias SymphonyElixirWeb.{TaskBoard, WorkflowGraph}

  @sha String.duplicate("a", 40)

  test "real task prerequisites and native works retain independent status, priority and evidence" do
    settings = settings()

    first = %{
      issue("1", "Depends on: none", "open")
      | milestone: %{id: "7", title: "Pilot", state: "open", url: nil},
        labels: ["ready", "kind:feature", "priority:1", "symphony:ready", "work:coding", "category:testing", "api"]
    }

    second = issue("2", "Depends on: #1 (design: approved baseline)", "open")
    accepted = accepted(settings.tracker)

    work = %{
      "issue_id" => "2",
      "tracker_fingerprint" => TaskRouting.fingerprint(settings.tracker),
      "instruction" => "Implement contract\nExtra detail",
      "purpose" => "coding",
      "phase" => "owner_review",
      "handoff" => %{"candidate_sha" => @sha},
      "publication" => %{"pr_number" => 9}
    }

    control = %{"enabled" => true, "issues" => %{"1" => accepted, "2" => %{"pr_work" => %{"work-id" => work}}}}
    runtime = %{running: [%{issue_id: "2", issue_identifier: "GH-2", status: "running"}]}
    board = TaskBoard.project([first, second], runtime, control, settings)
    graph = board.workflow_graph
    assert graph["version"] == 1
    assert graph["policy"] == "human_acceptance"
    assert graph["project_id"] == "github:example/tasks"
    assert Enum.find(graph["nodes"], &(&1["issue_id"] == "1"))["lane"] == "done"
    assert Enum.find(graph["nodes"], &(&1["issue_id"] == "2"))["lane"] == "in_progress"
    assert Enum.find(graph["nodes"], &(&1["type"] == "work"))["pr_number"] == 9
    assert Enum.find(graph["nodes"], &(&1["type"] == "work"))["candidate_sha"] == @sha
    assert Enum.count(graph["edges"], &(&1["type"] == "contains")) == 3
    assert [dependency] = Enum.filter(graph["edges"], &(&1["type"] == "depends_on"))
    assert dependency["source"] == "task:github:example/tasks:2"
    assert dependency["target"] == "task:github:example/tasks:1"
    assert dependency["kind"] == "design"
    assert dependency["reason"] == "approved baseline"
    assert dependency["status"] == "satisfied"
    assert dependency["evidence"]["candidate_sha"] == @sha
    assert graph["warnings"] == []
    first_node = Enum.find(graph["nodes"], &(&1["issue_id"] == "1"))
    second_node = Enum.find(graph["nodes"], &(&1["issue_id"] == "2"))
    assert first_node["task_id"] == "github:example/tasks:1"
    assert first_node["milestone"] == %{"id" => "7", "title" => "Pilot", "state" => "open", "url" => nil}
    assert first_node["tags"] == ["api", "category:testing"]
    assert first_node["task_kind"] == "feature"
    assert first_node["upstream_count"] == 0
    assert first_node["downstream_count"] == 1
    assert second_node["upstream_count"] == 1
    assert second_node["upstream_known"] == 1
    assert second_node["upstream_unknown"] == 0
  end

  test "cycles and unavailable prerequisites are explicit; closed alone is waiting on controlled boards" do
    settings = settings()
    a = issue("1", "Depends on: #2 (technical), #99", "closed")
    b = issue("2", "Depends on: #1 (process)", "open")
    c = issue("3", "Depends on: #1", "open")
    tasks = TaskBoard.project([a, b, c], %{}, %{}, settings).tasks
    graph = WorkflowGraph.export(tasks, %{"enabled" => true}, settings.tracker)
    assert Enum.count(graph["nodes"], & &1["cycle"]) == 2
    assert Enum.find(graph["nodes"], &(&1["issue_id"] == "99"))["missing"]
    assert Enum.any?(graph["warnings"], &String.contains?(&1, "cycle"))
    assert Enum.any?(graph["warnings"], &String.contains?(&1, "unavailable"))
    assert Enum.find(graph["edges"], &(&1["source"] == "task:github:example/tasks:3" and &1["type"] == "depends_on"))["status"] == "waiting"
    refute Enum.any?(graph["edges"], &(&1["kind"] == "priority"))

    uncontrolled = WorkflowGraph.export(tasks, %{"enabled" => false}, settings.tracker)
    assert uncontrolled["policy"] == "tracker_completion"
    assert Enum.find(uncontrolled["edges"], &(&1["source"] == "task:github:example/tasks:3" and &1["type"] == "depends_on"))["status"] == "satisfied"
  end

  test "ordinary acceptance waiting remains dependency status without an error or warning" do
    settings = settings()
    first = issue("1", "Depends on: none", "open")
    second = issue("2", "Depends on: #1", "open")
    graph = TaskBoard.project([first, second], %{}, %{}, settings).workflow_graph
    dependent = Enum.find(graph["nodes"], &(&1["issue_id"] == "2"))
    assert dependent["dependency_error"] == nil
    assert graph["warnings"] == []
    assert [%{"status" => "waiting"}] = Enum.filter(graph["edges"], &(&1["type"] == "depends_on"))
    assert Enum.any?(graph["edges"], &(&1["type"] == "contains"))
  end

  test "retained prerequisites preserve cycles and typed edges while remaining unavailable source facts" do
    settings = settings()
    a = issue("1", "Depends on: #2 (design: baseline)", "open")
    b = issue("2", "Depends on: #1 (technical: API)", "open")
    observation = TaskRouting.observation(b, settings.tracker)
    control = %{"tracker_issues" => %{"2" => observation}, "issues" => %{"2" => accepted(settings.tracker, "2")}}
    board = TaskBoard.project([a], %{}, control, settings)
    assert Enum.find(board.tasks, &(&1.issue_id == "1")).dependency_error =~ "cycle"
    assert [%{"issue_id" => "1"}] = Enum.find(board.tasks, &(&1.issue_id == "2")).dependencies
    graph = board.workflow_graph
    assert Enum.count(graph["nodes"], & &1["cycle"]) == 2
    assert Enum.find(graph["nodes"], &(&1["issue_id"] == "2"))["missing"]
    assert Enum.count(graph["edges"], &(&1["status"] == "cycle")) == 2
    retained = Enum.find(graph["nodes"], &(&1["issue_id"] == "2"))
    assert retained["milestone"] == nil
    assert retained["tags"] == []
    assert Enum.find(graph["nodes"], &(&1["issue_id"] == "1"))["upstream_unknown"] == 1

    graph_only = TaskBoard.project([a], %{}, %{control | "issues" => %{}}, settings).workflow_graph
    assert Enum.count(graph_only["nodes"], & &1["cycle"]) == 2
    assert Enum.count(graph_only["edges"], &(&1["status"] == "cycle")) == 2

    foreign = put_in(control, ["tracker_issues", "2", "repository"], "other/tasks")
    foreign_graph = TaskBoard.project([a], %{}, %{foreign | "issues" => %{}}, settings).workflow_graph
    refute Enum.any?(foreign_graph["nodes"], & &1["cycle"])
    assert Enum.count(foreign_graph["edges"], &(&1["type"] == "depends_on")) == 1
  end

  test "an edge between separate cycles is not itself labeled a cycle edge" do
    settings = settings()

    issues = [
      issue("1", "Depends on: #2, #3", "open"),
      issue("2", "Depends on: #1", "open"),
      issue("3", "Depends on: #4", "open"),
      issue("4", "Depends on: #3", "open")
    ]

    graph = TaskBoard.project(issues, %{}, %{}, settings).workflow_graph
    cross = Enum.find(graph["edges"], &(&1["source"] == "task:github:example/tasks:1" and &1["target"] == "task:github:example/tasks:3"))
    assert cross["status"] == "waiting"
    assert Enum.count(graph["edges"], &(&1["status"] == "cycle")) == 4
  end

  test "native work projection is isolated by issue and project, with checked historic publication evidence" do
    settings = settings()
    tasks = TaskBoard.project([issue("2", "Depends on: none", "open")], %{}, %{}, settings).tasks
    base = %{"issue_id" => "2", "tracker_fingerprint" => "old", "instruction" => "Result", "phase" => "published", "handoff" => %{"candidate_sha" => @sha}}
    receipt = %{"pr_number" => 9, "pr_url" => "https://github.com/example/tasks/pull/9", "candidate_sha" => @sha}
    historic = Map.put(base, "publication", receipt)

    works = %{
      "current" => Map.put(base, "tracker_fingerprint", TaskRouting.fingerprint(settings.tracker)),
      "historic" => historic,
      "foreign" => put_in(historic, ["publication", "pr_url"], "https://github.com/other/tasks/pull/9"),
      "wrong_issue" => Map.put(historic, "issue_id", "8"),
      "advanced" => put_in(historic, ["handoff", "candidate_sha"], String.duplicate("b", 40)),
      "unpublished" => base,
      "invalid_sha" => put_in(historic, ["publication", "candidate_sha"], "invalid"),
      "missing_sha" => Map.put(base, "publication", Map.delete(receipt, "candidate_sha"))
    }

    control = %{"issues" => %{"2" => %{"pr_work" => works}}}
    graph = WorkflowGraph.export(tasks, control, settings.tracker)
    assert Enum.filter(graph["nodes"], &(&1["type"] == "work")) |> Enum.map(& &1["work_id"]) == ["current", "historic"]
    assert graph["nodes"] == Enum.sort_by(graph["nodes"], & &1["id"])
    assert graph["edges"] == Enum.sort_by(graph["edges"], & &1["id"])
  end

  defp accepted(tracker, id \\ "1") do
    verified = %{id: id, state: "open", updated_at: "2026-10-01T10:00:00Z", terminal: true}

    params = %{
      "issue_id" => id,
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

  defp issue(id, description, state),
    do: %Issue{
      id: id,
      identifier: "GH-" <> id,
      title: "Task " <> id,
      description: description,
      state: state,
      native_ref: %{"repo" => "example/tasks"},
      dispatchable: true,
      priority: 2,
      updated_at: ~U[2026-10-01 10:00:00Z],
      labels: ["ready"]
    }

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
