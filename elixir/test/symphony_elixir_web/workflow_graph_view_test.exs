defmodule SymphonyElixirWeb.WorkflowGraphViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.WorkflowGraphView

  test "dependencies display lifecycle, reasons and exact missing or cyclic relationships" do
    graph = %{
      "version" => 1,
      "policy" => "human_acceptance",
      "nodes" => [project(), task("1", "backlog"), task("2", "in_progress"), task("3", "unknown", %{"missing" => true, "cycle" => true})],
      "edges" => [dependency("2", "1", "waiting"), dependency("3", "2", "cycle")],
      "warnings" => ["Cycle requires review"]
    }

    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    assert html =~ "data-lane=\"in_progress\""
    assert html =~ "In progress"
    assert html =~ "data-missing=\"true\""
    assert html =~ "data-cycle=\"true\""
    assert html =~ "technical · Requires schema"
    assert html =~ "Cycle requires review"
    assert html =~ "data-dependency-status=\"cycle\""
    assert html =~ "Arrows go from prerequisite to dependent"
    assert html =~ "human acceptance"
    refute html =~ "priority dependency"
  end

  test "completion explanation follows the exported policy" do
    for {policy, explanation} <- [{"human_acceptance", "Done records human acceptance."}, {"tracker_completion", "Done follows tracker completion."}, {nil, "Completion policy unavailable."}] do
      html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: %{"version" => 1, "policy" => policy}})
      assert html =~ explanation
      if policy != "human_acceptance", do: refute(html =~ "Done records human acceptance.")
    end
  end

  test "hierarchy is ownership and every dependency has a text equivalent" do
    work = %{"id" => "work:1", "type" => "work", "title" => "Check changes", "phase" => "validating"}

    graph = %{
      "version" => 1,
      "nodes" => [project(), task("1", "review"), work],
      "edges" => [contains("project:p", "task:1"), contains("task:1", "work:1"), dependency("1", "404", "missing")]
    }

    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    assert html =~ "name=\"graph-view\""
    assert html =~ "Agent ownership diagram"
    assert html =~ "validating"
    assert html =~ "GH-1 → Check changes"
    assert html =~ "task:404"
    assert html =~ "not dependencies"
  end

  test "same-column arrows, satisfied edges and long names stay bounded" do
    graph = %{
      "version" => 1,
      "nodes" => [task("1", "done", %{"title" => String.duplicate("long title ", 20)}), task("2", "done")],
      "edges" => [dependency("2", "1", "satisfied")]
    }

    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    assert html =~ "data-status=\"satisfied\""
    assert html =~ "…"
    assert html =~ "viewBox=\"0 0 1040"
    assert html =~ "<path d=\"M"
  end

  test "large diagrams expose truncation and preserve full dependency evidence" do
    graph = %{"version" => 1, "nodes" => Enum.map(1..125, &task(to_string(&1), "work")), "edges" => [dependency("125", "1", "waiting")]}
    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    assert html =~ "first 120 nodes"
    assert html =~ "GH-125"
    assert html =~ "dependency list remains available"
  end

  test "unknown and empty graph observations have a clear fallback" do
    html = render_component(&WorkflowGraphView.content/1, board: %{})
    assert html =~ "Graph unavailable"
    refute html =~ "<svg"
    empty = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: %{"version" => 1}})
    assert empty =~ "No tasks yet"

    no_deps =
      render_component(&WorkflowGraphView.content/1,
        board: %{workflow_graph: %{"version" => 1, "nodes" => [task("1", nil, %{"title" => nil})]}}
      )

    assert no_deps =~ "No declared dependencies"
    assert no_deps =~ "Untitled"
    assert no_deps =~ "Unknown"
  end

  test "untrusted graph names and reasons remain escaped" do
    graph = %{
      "version" => 1,
      "nodes" => [project(), task("1", "review", %{"title" => "<script>bad()</script>"})],
      "edges" => [contains("missing", "task:1"), Map.put(dependency("1", "1", "cycle"), "reason", nil)],
      "warnings" => ["<img onerror=bad()>"]
    }

    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    refute html =~ "<script>"
    refute html =~ "<img onerror"
    assert html =~ "&lt;img"
  end

  defp project, do: %{"id" => "project:p", "type" => "project", "name" => "Fixture"}
  defp task(id, lane, extra \\ %{}), do: Map.merge(%{"id" => "task:" <> id, "type" => "task", "identifier" => "GH-" <> id, "title" => "Task " <> id, "lane" => lane}, extra)

  defp dependency(source, target, status),
    do: %{"source" => "task:" <> source, "target" => "task:" <> target, "type" => "depends_on", "kind" => "technical", "reason" => "Requires schema", "status" => status}

  defp contains(source, target), do: %{"source" => source, "target" => target, "type" => "contains"}
end
