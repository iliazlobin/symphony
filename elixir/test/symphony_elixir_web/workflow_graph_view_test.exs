defmodule SymphonyElixirWeb.WorkflowGraphViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.WorkflowGraphView

  test "dependency layers are independent of lifecycle and peer ordering is stable" do
    nodes = [task(1, "done"), task(2, "work", %{"priority" => 3}), task(3, "in_progress", %{"priority" => 1}), task(4, "backlog")]
    edges = [dep(2, 1), dep(3, 1), dep(4, 2), dep(4, 3)]
    html = draw(nodes, edges)
    positions = positions(html)
    assert positions["task:1"].depth == 0
    assert positions["task:2"].depth == 1
    assert positions["task:3"].depth == 1
    assert positions["task:4"].depth == 2
    assert positions["task:3"].x < positions["task:2"].x
    assert positions["task:1"].y < positions["task:2"].y
    assert positions["task:2"].y < positions["task:4"].y
    assert positions(draw(Enum.reverse(nodes), Enum.reverse(edges))) == positions
    assert html =~ "In progress"
    assert html =~ "Priority orders peers"
    assert length(find(html, "#plan-dependencies-panel .plan-edge")) == 4
  end

  test "ten independent tasks use compact rows rather than a long single column" do
    html = draw(Enum.map(1..10, &task(&1, "work")))
    nodes = positions(html)
    assert MapSet.size(MapSet.new(nodes, fn {_id, node} -> node.x end)) == 4
    assert MapSet.size(MapSet.new(nodes, fn {_id, node} -> node.y end)) == 3
    assert html =~ "data-content-height=\"600\""
    assert html =~ "phx-hook=\"WorkflowCanvas\""
    assert html =~ "data-canvas-action=\"fit\""
    assert html =~ "drag background to pan"
    refute html =~ "data-task-id="
  end

  test "selected task highlights its direct edges and includes hidden prerequisite context" do
    html =
      draw([task(1, "done"), task(2, "review"), task(3, "backlog")], [dep(2, 1), dep(3, 2)],
        selected_id: "issue:2",
        visible_task_ids: ["issue:2"]
      )

    assert length(find(html, "#plan-dependencies-panel [data-selected=true]")) == 1
    assert length(find(html, "#plan-dependencies-panel .plan-edge[data-related=true]")) == 2
    assert length(find(html, "#plan-dependencies-panel [data-filtered=true]")) == 2
    assert html =~ "1 prerequisites outside filters"
    assert html =~ "Show on board"
    assert html =~ "Show sequence"
    assert html =~ "phx-click=\"select-plan-task\""
    assert html =~ "phx-click=\"open-card\""
    assert html =~ "phx-value-id=\"issue:2\""
  end

  test "agent ownership shows visible task works and uses scoped navigation" do
    project = %{"id" => "project:p", "type" => "project", "name" => "Project name"}
    work = %{"id" => "work:1", "type" => "work", "task_id" => "issue:1", "work_id" => "native1", "title" => "Validate candidate", "phase" => "validating"}
    other = %{"id" => "work:2", "type" => "work", "task_id" => "issue:2"}

    html =
      draw(
        [project, task(1, "review"), task(2, "backlog"), work, other],
        [contains("project:p", "task:1"), contains("task:1", "work:1")],
        visible_task_ids: ["issue:1"]
      )

    assert html =~ "phx-click=\"main-chat\""
    assert html =~ "Project name"
    assert html =~ "phx-value-work_id=\"native1\""
    assert html =~ "validating"
    assert length(find(html, "#plan-agents-panel [data-plan-node]")) == 3
    refute html =~ "data-node-id=\"work:2\""
    assert html =~ "GH-1 → Validate candidate"
  end

  test "unresolved dependencies remain a separate band with exact accessible evidence" do
    missing = task(404, "unknown", %{"missing" => true})
    bad = task(5, "work", %{"dependency_error" => "Revise malformed prerequisites."})
    nodes = [task(1, "work"), task(2, "review"), task(3, "backlog"), missing, bad]
    edges = [dep(1, 2, "cycle"), dep(2, 1, "cycle"), dep(3, 404, "missing")]
    html = draw(nodes, edges, selected_id: "issue:3", warnings: ["Dependency cycle: GH-1, GH-2.", "GH-3: Dependencies require human-accepted Done in this project."])
    assert html =~ "Dependency cycle"
    assert html =~ "Unknown sequence"
    assert html =~ "Sequence unresolved"
    assert html =~ "Unavailable"
    assert html =~ "1 prerequisites unavailable"
    assert html =~ "1 task is waiting for accepted prerequisites"
    assert html =~ "1 dependency issue"
    refute html =~ "<p class=\"board-warning\""
    assert length(find(html, "[data-dependency-status=cycle]")) == 2
    assert length(find(html, "[data-dependency-status=missing]")) == 1
    assert length(find(html, "#plan-dependencies-panel .plan-node")) == 5
  end

  test "selected node without relationships shows concise empty inspector and short error" do
    html = draw([task(1, "work", %{"dependency_error" => "Invalid prerequisite."})], [], selected_id: "task:1", visible_task_ids: [])
    assert html =~ "No declared relationships"
    assert html =~ "Invalid prerequisite"
    assert length(find(html, "#plan-dependencies-panel [data-selected=true]")) == 1
    assert html =~ "Outside filters"
  end

  test "project agent uses the directory label rather than its canonical identity" do
    project = %{"id" => "project:github:example/repo", "type" => "project", "name" => "github:example/repo"}
    graph = %{"version" => 1, "nodes" => [project], "edges" => []}
    board = %{workflow_graph: graph, projects: [%{id: "other", label: "Other"}, %{id: "github:example/repo", label: "Project name"}]}
    html = render_component(&WorkflowGraphView.content/1, board: board)
    assert html =~ "Open Project name project agent"
  end

  test "cycle curves and skipped relationships stay inside the full content bounds" do
    nodes = Enum.map(1..8, &task(&1, "work")) ++ [task(100, "unknown", %{"missing" => true})]
    edges = Enum.map(1..8, &dep(&1, rem(&1, 8) + 1, "cycle")) ++ [dep(8, 100)]
    html = draw(nodes, edges)
    [{_, attrs, _}] = find(html, "#plan-dependencies-panel svg")
    [_, _, width, height] = attrs |> Map.new() |> Map.fetch!("viewbox") |> String.split() |> Enum.map(&String.to_integer/1)
    assert length(find(html, "#plan-dependencies-panel .plan-edge")) == 8

    for {_tag, attrs, _} <- find(html, "#plan-dependencies-panel .plan-edge") do
      coords = ~r/[0-9]+/ |> Regex.scan(Map.new(attrs)["d"]) |> List.flatten() |> Enum.map(&String.to_integer/1)
      for [x, y] <- Enum.chunk_every(coords, 2), do: assert(x <= width && y <= height)
    end

    assert html =~ "GH-100"
  end

  test "long titles remain complete in tooltip and accessible text, never become markup" do
    title = "<script>bad()</script> " <> String.duplicate("Long title ", 24)
    html = draw([task(1, "review", %{"title" => title})], [Map.put(dep(1, 1), "reason", "<img onerror=bad()>")], selected_id: "issue:1", warnings: ["<script>warning</script>"])
    refute html =~ "<script>"
    refute html =~ "<img onerror"
    assert html =~ "&lt;script&gt;bad()&lt;/script&gt;"
    assert html =~ String.duplicate("Long title ", 24) |> String.trim()
    assert html =~ "title=\"&lt;script&gt;"
    [{_, attrs, _}] = find(html, "#plan-dependencies-panel [data-plan-node]")
    assert String.to_integer(Map.new(attrs)["data-node-height"]) > 200
  end

  test "dynamic height leaves following dependency rows below complete long titles" do
    html = draw([task(1, "done", %{"title" => String.duplicate("Long title ", 24)}), task(2, "work")], [dep(2, 1)])
    positions = positions(html)
    [{_, attrs, _}] = find(html, "#plan-dependencies-panel [data-node-id='task:1']")
    height = String.to_integer(Map.new(attrs)["data-node-height"])
    assert positions["task:2"].y > positions["task:1"].y + height
    assert html =~ "M"
  end

  test "large diagrams announce truncation and preserve full relationship evidence" do
    html = draw(Enum.map(1..125, &task(&1, "work")), [dep(125, 1)])
    assert length(find(html, "#plan-dependencies-panel .plan-node")) == 120
    assert html =~ "up to 120 nodes"
    assert html =~ "GH-125 requires GH-1"
    assert html =~ "All relationships remain available"
  end

  test "late selected task and its direct prerequisite survive the rendering bound" do
    html = draw(Enum.map(1..125, &task(&1, "work")), [dep(125, 1)], selected_id: "issue:125")
    assert length(find(html, "#plan-dependencies-panel .plan-node")) == 120
    assert length(find(html, "#plan-dependencies-panel [data-node-id='task:125'][data-selected=true]")) == 1
    assert length(find(html, "#plan-dependencies-panel [data-node-id='task:1'][data-related=true]")) == 1
    assert length(find(html, ".plan-inspector [data-plan-reference='task:1'][phx-value-id='issue:1']")) == 1
  end

  test "selected work opens the agents scene and relationship references remain scoped" do
    project = %{"id" => "project:p", "type" => "project", "name" => "Fixture"}
    work = %{"id" => "work:1", "type" => "work", "task_id" => "issue:1", "work_id" => "native1", "title" => "Review candidate"}
    html = draw([project, task(1, "review"), work], [contains("project:p", "task:1"), contains("task:1", "work:1")], selected_id: "work:1")
    assert html =~ "data-plan-mode=\"agents\""
    assert Floki.attribute(find(html, "#plan-agents-panel"), "hidden") == []
    assert length(find(html, ".plan-inspector [data-plan-reference='work:1'][phx-value-work_id='native1']")) == 1
    html = draw([project, task(1, "work")], [contains("project:p", "task:1")], selected_id: "project:p")
    assert length(find(html, ".plan-inspector [data-plan-reference='project:p'][phx-click='main-chat']")) == 1
    assert render_component(&WorkflowGraphView.reference/1, fallback: "Unavailable") =~ "Unavailable"
  end

  test "fallback, empty selection and completion policies are honest" do
    html = render_component(&WorkflowGraphView.content/1, board: %{})
    assert html =~ "Planning data is incomplete"
    refute html =~ "<svg"
    html = draw([], [], visible_task_ids: [])
    assert html =~ "No matching tasks"
    assert find(html, "[data-plan-svg]") == []
    assert html =~ "No declared dependencies"
    refute html =~ "class=\"plan-inspector\""

    for {policy, label} <- [{"human_acceptance", "Done records human acceptance"}, {"tracker_completion", "Done follows tracker completion"}, {nil, "Completion policy unavailable"}] do
      assert draw([task(1, nil, %{"title" => nil, "identifier" => nil, "task_kind" => "security"})], [], policy: policy) =~ label
    end

    assert draw([%{"id" => "project:p", "type" => "project"}, task(1, nil, %{"title" => nil, "identifier" => nil})]) =~ "Untitled"
    assert draw([task(1, nil)], []) =~ "Unknown"
    assert draw([%{"id" => "work:1", "type" => "work", "task_id" => "issue:1"}, task(1, "work")]) =~ "Supervision"
  end

  defp task(id, lane, extra \\ %{}),
    do: Map.merge(%{"id" => "task:#{id}", "task_id" => "issue:#{id}", "type" => "task", "identifier" => "GH-#{id}", "title" => "Task #{id}", "lane" => lane, "task_kind" => "general"}, extra)

  defp dep(source, target, status \\ "waiting"),
    do: %{"source" => "task:#{source}", "target" => "task:#{target}", "type" => "depends_on", "kind" => "technical", "reason" => "Requires schema", "status" => status}

  defp contains(source, target), do: %{"source" => source, "target" => target, "type" => "contains"}

  defp draw(nodes, edges \\ [], opts \\ []) do
    {policy, opts} = Keyword.pop(opts, :policy, "human_acceptance")
    {warnings, opts} = Keyword.pop(opts, :warnings, [])
    graph = %{"version" => 1, "nodes" => nodes, "edges" => edges, "warnings" => warnings, "policy" => policy}
    render_component(&WorkflowGraphView.content/1, Keyword.merge([board: %{workflow_graph: graph}, project: "p"], opts))
  end

  defp find(html, selector), do: html |> Floki.parse_fragment!() |> Floki.find(selector)

  defp positions(html),
    do:
      html
      |> find("#plan-dependencies-panel [data-plan-node]")
      |> Map.new(fn {_tag, attrs, _} ->
        attrs = Map.new(attrs)

        position = %{
          x: String.to_integer(attrs["data-node-x"]),
          y: String.to_integer(attrs["data-node-y"]),
          depth: String.to_integer(attrs["data-depth"])
        }

        {attrs["data-node-id"], position}
      end)
end
