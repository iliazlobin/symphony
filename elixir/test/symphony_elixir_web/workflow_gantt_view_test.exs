defmodule SymphonyElixirWeb.WorkflowGanttViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.WorkflowGanttView

  test "relative sequence shows dependency direction, priority, kinds and milestone without dates" do
    nodes = [task(1, "done", %{"milestone" => %{"title" => "Launch"}}), task(2, "in_progress", %{"priority" => 1, "task_kind" => "testing"}), task(3, "review", %{"priority" => 3})]
    html = draw(nodes, [dep(2, 1), dep(3, 1)], selected_id: "issue:2")
    assert html =~ "Relative steps"
    assert html =~ "not estimated"
    assert html =~ "not a duration"
    assert html =~ "Step 1"
    assert html =~ "Step 2"
    assert html =~ "Launch"
    assert html =~ "Testing"
    assert html =~ "P1"
    assert html =~ "In progress"
    assert html =~ "M166,44 C190,44 190,132 214,132"
    assert length(find(html, ".plan-gantt-arrows .plan-edge")) == 2
    assert length(find(html, ".plan-edge[data-related=true]")) == 1
    assert length(find(html, "tr[data-selected=true]")) == 1
    refute html =~ "data-task-id="
    assert html =~ "phx-click=\"select-plan-task\""
    assert html =~ "phx-click=\"open-card\""
    assert html =~ "Show graph"
    assert html =~ "Show on board"
    assert length(find(html, ".plan-inspector [data-plan-reference='task:1'][phx-value-id='issue:1']")) == 1
  end

  test "filtered prerequisites remain honest context and do not create visible arrows" do
    html = draw([task(1, "done"), task(2, "work")], [dep(2, 1)], visible_task_ids: ["issue:2"], selected_id: "issue:2")
    assert length(find(html, "tbody tr")) == 1
    assert html =~ "Step 2"
    assert html =~ "1 outside filters"
    assert html =~ "GH-2 requires GH-1"
    assert find(html, ".plan-gantt-arrows .plan-edge") == []
  end

  test "selected filtered task remains an explicit context row without changing the filter" do
    html = draw([task(1, "done"), task(2, "work")], [dep(2, 1)], visible_task_ids: [], selected_id: "issue:2")
    assert length(find(html, "tbody tr[data-selected=true][data-plan-visible=false]")) == 1
    assert html =~ "Outside filters"
    assert html =~ "Step 2"
    assert html =~ "1 outside filters"
  end

  test "cycles, unknown prerequisites and downstream sequence uncertainty get no fabricated slots" do
    nodes = [task(1, "work"), task(2, "work"), task(3, "review"), task(4, "backlog", %{"dependency_error" => "Invalid prerequisite."}), task(5, "work"), task(999, "unknown", %{"missing" => true})]
    edges = [dep(1, 2), dep(2, 1), dep(3, 1), dep(5, 999)]
    html = draw(nodes, edges, selected_id: "task:4", warnings: ["Revise cycle"])
    assert html =~ "Needs attention"
    assert html =~ "Dependency cycle"
    assert html =~ "Unknown prerequisites"
    assert html =~ "Sequence unresolved"
    assert html =~ "not sequenced"
    assert html =~ "1 unavailable"
    assert html =~ "Invalid prerequisite"
    assert html =~ "1 dependency notice"
    assert length(find(html, ".plan-gantt-unresolved")) == 5
    assert find(html, ".plan-gantt-arrows .plan-edge") == []
    refute html =~ "Step 1"
  end

  test "no matches and incomplete observations have clear fallbacks" do
    html = render_component(&WorkflowGanttView.content/1, board: %{})
    assert html =~ "Planning data is incomplete"
    refute html =~ "<table"
    html = draw([], [], visible_task_ids: [])
    assert html =~ "No matching tasks"
    assert html =~ "No declared dependencies"
    refute html =~ "<table"
  end

  test "untrusted titles and reasons are escaped and complete, and empty inspector is concise" do
    title = "<script>alert()</script> " <> String.duplicate("Long name ", 30)
    html = draw([task(1, nil, %{"title" => title, "task_kind" => nil})], [], selected_id: "issue:1")
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;alert()"
    assert html =~ String.trim(title |> String.replace("<script>", "&lt;script&gt;") |> String.replace("</script>", "&lt;/script&gt;"))
    assert html =~ "No declared dependencies"
    assert html =~ "General"
    assert html =~ "Unknown"
    html = draw([task(1, "work"), task(2, "review")], [Map.merge(dep(2, 1), %{"reason" => "<img onerror=bad()>", "kind" => "technical", "status" => "satisfied"})])
    assert html =~ "&lt;img"
    assert html =~ "technical"
    assert html =~ "satisfied"
    refute html =~ "<img onerror"
  end

  defp task(id, lane, extra \\ %{}),
    do: Map.merge(%{"id" => "task:#{id}", "task_id" => "issue:#{id}", "type" => "task", "identifier" => "GH-#{id}", "title" => "Task #{id}", "lane" => lane, "task_kind" => "general"}, extra)

  defp dep(source, target), do: %{"source" => "task:#{source}", "target" => "task:#{target}", "type" => "depends_on", "status" => "waiting"}

  defp draw(nodes, edges, opts \\ []) do
    {warnings, opts} = Keyword.pop(opts, :warnings, [])
    graph = %{"version" => 1, "nodes" => nodes, "edges" => edges, "warnings" => warnings}
    render_component(&WorkflowGanttView.content/1, Keyword.merge([board: %{workflow_graph: graph}], opts))
  end

  defp find(html, selector), do: html |> Floki.parse_fragment!() |> Floki.find(selector)
end
