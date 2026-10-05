defmodule SymphonyElixir.Assurance.GraphIntegrationTest do
  use ExUnit.Case, async: true
  Code.require_file("../fixtures/task_graph.exs", __DIR__)

  alias SymphonyElixir.Assurance.{Contract, GraphSnapshot, Store}
  alias SymphonyElixir.{PathSafety, TaskRouting, Tracker.Issue}
  alias SymphonyElixirWeb.{TaskBoard, TaskGraphFixture}

  test "the actual board export retains ten tasks and an unavailable prerequisite as a versioned snapshot" do
    tracker = %{
      kind: "github",
      provider: %{"repo" => "example/coverage"},
      project_slug: nil,
      active_states: ["open"],
      terminal_states: ["closed"],
      required_labels: ["ready"]
    }

    fingerprint = TaskRouting.fingerprint(tracker)

    issues =
      Enum.map(1..10, fn n ->
        %Issue{
          id: "#{n}",
          identifier: "GH-#{n}",
          title: "Task #{n}",
          state: "open",
          description: if(n == 1, do: "Depends on: #999 (technical: reviewed schema)", else: "Depends on: none"),
          labels: ["ready"],
          dispatchable: true,
          native_ref: %{"repo" => "example/coverage"},
          url: "https://github.com/example/coverage/issues/#{n}"
        }
      end)

    work = %{"issue_id" => "1", "tracker_fingerprint" => fingerprint, "instruction" => "PRIVATE WORK INSTRUCTION", "phase" => "review", "purpose" => "coding"}
    control = %{"enabled" => true, "tracker_fingerprint" => fingerprint, "issues" => %{"1" => %{"pr_work" => %{"work-1" => work}}}}
    board = TaskBoard.project(issues, %{}, control, %{tracker: tracker, control: %{enabled: true}})
    assert {:ok, captured} = GraphSnapshot.capture(board.workflow_graph, "github:example/coverage")
    graph = captured["graph"]
    assert Enum.count(graph["nodes"], &(&1["type"] == "task")) == 11
    assert Enum.any?(graph["nodes"], &(&1["issue_id"] == "999" and &1["missing"] == true))
    assert Enum.count(graph["nodes"], &(&1["type"] == "project")) == 1
    assert [%{"reason" => "reviewed schema", "status" => "missing"}] = graph["edges"]
    refute Jason.encode!(captured) =~ "PRIVATE WORK INSTRUCTION"
    assert GraphSnapshot.valid?(captured, "github:example/coverage")
  end

  test "a native 1000-task cycle freezes complete facts with only derived warning prose compacted" do
    tracker = %{
      kind: "github",
      provider: %{"repo" => "example/coverage"},
      project_slug: nil,
      active_states: ["open"],
      terminal_states: ["closed"],
      required_labels: ["ready"]
    }

    project = "github:example/coverage"
    board = TaskGraphFixture.preview_board(%{tracker: tracker, control: %{enabled: false}}, :dense_cycle)
    graph = board.workflow_graph
    assert [warning] = graph["warnings"]
    assert byte_size(warning) > 4_000
    assert {:ok, captured} = GraphSnapshot.capture(graph, project)
    assert GraphSnapshot.valid?(captured, project)
    assert [compact] = captured["graph"]["warnings"]
    assert compact =~ "1000 tasks"
    assert compact =~ "Task labels truncated"
    assert Enum.count(captured["graph"]["nodes"], &(&1["cycle"] == true)) == 1_000
    assert length(captured["graph"]["edges"]) == 3_000
    assert captured["graph"]["edges"] == graph["edges"] |> Enum.filter(&(&1["type"] == "depends_on")) |> Enum.sort_by(& &1["id"])

    {:ok, root} = PathSafety.canonicalize(Path.join(System.tmp_dir!(), "assurance-dense-cycle-#{System.unique_integer([:positive])}"))
    on_exit(fn -> File.rm_rf(root) end)

    owner_options = [
      name: nil,
      state_dir: root,
      project: project,
      scope: fn -> "dense-cycle" end,
      authorize: fn token -> token == :operator end
    ]

    owner = start_supervised!({Store, owner_options})

    document =
      Contract.document(project)
      |> Map.put("requirements", [
        %{
          "id" => "REQ-GRAPH",
          "title" => "Retain graph history",
          "kind" => "functional",
          "exclusion" => nil,
          "criteria" => [%{"id" => "AC-GRAPH", "text" => "Retain every cycle task and prerequisite edge.", "required_checks" => ["graph-navigation"]}]
        }
      ])

    assert {:ok, %{"storage_revision" => 1}} = Store.save(project, 0, document, :operator, owner)
    assert {:ok, %{"reviewed" => baseline}} = Store.baseline_graph(project, 1, graph, :operator, owner)
    assert baseline["graph_snapshot"]["graph"] == captured["graph"]
    assert {:ok, ^baseline} = Store.reviewed(project, baseline["ref"], :operator, owner)

    assert {:error, :invalid_assurance_graph} = GraphSnapshot.capture(Map.put(graph, "warnings", [warning <> " unknown task"]), project)
    assert {:error, :invalid_assurance_graph} = GraphSnapshot.capture(Map.put(graph, "warnings", [String.duplicate("arbitrary", 1_000)]), project)
    assert {:error, :invalid_assurance_graph} = GraphSnapshot.capture(Map.put(graph, "warnings", %{}), project)
    assert {:error, :invalid_assurance_graph} = GraphSnapshot.capture(Map.put(graph, "warnings", [nil]), project)

    mismatched_nodes = Enum.map(graph["nodes"], fn node -> if node["issue_id"] == "1", do: Map.put(node, "cycle", false), else: node end)
    assert {:error, :invalid_assurance_graph} = GraphSnapshot.capture(Map.put(graph, "nodes", mismatched_nodes), project)
  end
end
