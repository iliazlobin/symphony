defmodule SymphonyElixirWeb.WorkflowGraphViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Phoenix.LiveView.{Diff, Socket}
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
    assert html =~ "Outside filters"

    assert Floki.attribute(find(html, "[data-node-id='task:2'] .plan-node-select"), "aria-description") == [
             "Prerequisite GH-1: awaiting acceptance (technical: Requires schema); Dependent GH-3: awaiting acceptance (technical: Requires schema)"
           ]

    assert find(html, ".plan-inspector, [data-board-view-link]") == []
    assert length(find(html, "[data-node-id='task:1'] .plan-node-select[phx-value-id='issue:1']")) == 1
    assert length(find(html, "[data-node-id='task:3'] .plan-node-select[phx-value-id='issue:3']")) == 1
    assert html =~ "phx-click=\"select-plan-task\""
    assert html =~ "phx-click=\"open-card\""
    assert html =~ "phx-value-id=\"issue:2\""
  end

  test "selection preserves node identity and geometry while changing highlights" do
    nodes = Enum.map(1..10, &task(&1, "work"))
    edges = [dep(5, 1), dep(6, 2), dep(10, 5)]
    first = draw(nodes, edges, selected_id: "issue:1")
    second = draw(nodes, edges, selected_id: "issue:10")
    assert positions(first) == positions(second)
    assert Floki.attribute(find(first, "[data-plan-node]"), "id") == Floki.attribute(find(second, "[data-plan-node]"), "id")
    assert Floki.attribute(find(first, ".plan-edge"), "id") == Floki.attribute(find(second, ".plan-edge"), "id")
    assert Floki.attribute(find(first, ".plan-edge"), "d") == Floki.attribute(find(second, ".plan-edge"), "d")
    assert length(find(second, ".plan-edge[data-edge-source='task:10'][data-edge-target='task:5'][data-related=true]")) == 1
    assert find(second, ".plan-inspector") == []
  end

  test "filtered context selection leaves every common card and content bound unchanged" do
    nodes = Enum.map(1..12, &task(&1, "work"))
    edges = Enum.map(1..5, &dep(10, &1)) ++ [dep(11, 6)]
    filters = [visible_task_ids: ["issue:10", "issue:11", "issue:12"]]
    first = draw(nodes, edges, Keyword.put(filters, :selected_id, "issue:10"))
    second = draw(nodes, edges, Keyword.put(filters, :selected_id, "issue:11"))
    context = draw(nodes, edges, Keyword.put(filters, :selected_id, "issue:6"))
    first_positions = positions(first)
    second_positions = positions(second)
    context_positions = positions(context)

    for id <- ["task:10", "task:11", "task:12"] do
      assert first_positions[id] == second_positions[id]
      assert second_positions[id] == context_positions[id]
    end

    assert second_positions["task:6"] == context_positions["task:6"]
    assert length(find(context, "[data-node-id='task:6'][data-plan-visible=false][data-selected=true] .plan-node-select[aria-pressed=true]")) == 1
    edge_selector = ".plan-edge[data-edge-source='task:11'][data-edge-target='task:6']"
    assert Floki.attribute(find(second, edge_selector), "d") == Floki.attribute(find(context, edge_selector), "d")

    for attribute <- ["data-content-width", "data-content-height", "viewbox"] do
      assert Floki.attribute(find(first, "[data-plan-svg]"), attribute) == Floki.attribute(find(second, "[data-plan-svg]"), attribute)
      assert Floki.attribute(find(second, "[data-plan-svg]"), attribute) == Floki.attribute(find(context, "[data-plan-svg]"), attribute)
    end
  end

  test "growing filtered context retains each task's child diff identity" do
    nodes = Enum.map(1..12, &task(&1, "work"))
    edges = Enum.map(1..5, &dep(10, &1)) ++ [dep(11, 6)]
    graph = %{"version" => 1, "nodes" => nodes, "edges" => edges}
    board = %{workflow_graph: graph}
    visible_ids = ["issue:10", "issue:11", "issue:12"]
    assigns = %{__changed__: nil, board: board, project: "p", filters: %{}, visible_task_ids: visible_ids}
    first = WorkflowGraphView.content(Map.put(assigns, :selected_id, "issue:11"))
    next = WorkflowGraphView.content(Map.put(assigns, :selected_id, "issue:10"))
    socket = %Socket{assigns: %{__changed__: %{}}}
    {_first_diff, prints, components} = Diff.render(socket, first, Diff.new_fingerprints(), Diff.new_components())
    {_next_diff, next_prints, _components} = Diff.render(socket, next, prints, components)
    entries = task_diff_entries(prints, "task:10")
    next_entries = task_diff_entries(next_prints, "task:10")
    assert is_map(entries)
    assert is_map(next_entries)
    assert map_size(entries) == 4
    assert map_size(next_entries) == 8
    assert entries["task:10"].index != next_entries["task:10"].index
    assert entries["task:10"].child_prints == next_entries["task:10"].child_prints
    assert entries["task:12"].child_prints == next_entries["task:12"].child_prints
  end

  test "dependency diagram omits agent ownership while retaining task navigation" do
    project = %{"id" => "project:p", "type" => "project", "name" => "Project name"}
    work = %{"id" => "work:1", "type" => "work", "task_id" => "issue:1", "work_id" => "native1", "title" => "Validate candidate", "phase" => "validating"}
    other = %{"id" => "work:2", "type" => "work", "task_id" => "issue:2"}

    html =
      draw(
        [project, task(1, "review"), task(2, "backlog"), work, other],
        [contains("project:p", "task:1"), contains("task:1", "work:1")],
        visible_task_ids: ["issue:1"]
      )

    refute html =~ "phx-click=\"main-chat\""
    refute html =~ "Project name"
    refute html =~ "phx-value-work_id"
    refute html =~ "Validate candidate"
    refute html =~ "Agents"
    assert length(find(html, "#plan-dependencies-panel [data-plan-node]")) == 1
    assert find(html, "#plan-agents-panel") == []
    assert find(html, "[data-canvas-mode]") == []
    refute html =~ "data-node-id=\"work:2\""
    assert find(html, ".plan-accessible-list") == []
    refute html =~ "Text view"
  end

  test "unresolved dependencies remain a separate band with inline evidence" do
    missing = task(404, "unknown", %{"missing" => true})
    bad = task(5, "work", %{"dependency_error" => "Revise malformed prerequisites."})
    nodes = [task(1, "work"), task(2, "review"), task(3, "backlog"), missing, bad]
    edges = [dep(1, 2, "cycle"), dep(2, 1, "cycle"), dep(3, 404, "missing")]
    html = draw(nodes, edges, selected_id: "issue:3", warnings: ["Dependency cycle: GH-1, GH-2.", "GH-3: Dependencies require human-accepted Done in this project."])
    assert html =~ "Dependency cycle"
    assert html =~ "Unknown sequence"
    assert html =~ "Sequence unresolved"
    assert html =~ "Unavailable"
    assert Floki.text(find(html, "[data-node-id='task:404']")) =~ "GH-404"
    refute html =~ "plan-warnings"
    refute html =~ "Dependencies require human-accepted Done"
    assert html =~ "Dependency cycle. Revise prerequisites."
    assert html =~ "Revise malformed prerequisites."
    refute html =~ "<p class=\"board-warning\""
    assert length(find(html, ".plan-edge[data-status=cycle]")) == 2
    assert length(find(html, ".plan-edge[data-status=missing]")) == 1
    assert length(find(html, "#plan-dependencies-panel .plan-node")) == 5
  end

  test "selected node without relationships preserves its inline error without an inspector" do
    html = draw([task(1, "work", %{"dependency_error" => "Invalid prerequisite."})], [], selected_id: "task:1", visible_task_ids: [])
    refute html =~ "Text view"
    assert html =~ "Invalid prerequisite"
    assert length(find(html, "#plan-dependencies-panel [data-selected=true]")) == 1
    assert html =~ "Outside filters"
  end

  test "a project without tasks has an empty dependency diagram" do
    project = %{"id" => "project:github:example/repo", "type" => "project", "name" => "github:example/repo"}
    graph = %{"version" => 1, "nodes" => [project], "edges" => []}
    board = %{workflow_graph: graph, projects: [%{id: "other", label: "Other"}, %{id: "github:example/repo", label: "Project name"}]}
    html = render_component(&WorkflowGraphView.content/1, board: board)
    assert html =~ "No matching tasks"
    refute html =~ "Project name"
    assert find(html, "[data-plan-node]") == []
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

    assert find(html, "[data-node-id='task:100']") == []
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

  test "wide unbroken titles reserve their full wrapped height and preserve task ports" do
    for title <- [String.duplicate("W", 120), String.duplicate("界", 120)] do
      html = draw([task(1, "done", %{"title" => title}), task(2, "work")], [dep(2, 1)])
      [{_, attrs, _}] = find(html, "[data-node-id='task:1']")
      height = String.to_integer(Map.new(attrs)["data-node-height"])
      nodes = positions(html)
      assert height >= 216
      assert nodes["task:2"].y > nodes["task:1"].y + height
      assert Floki.attribute(find(html, "[data-node-id='task:1'] .plan-node-title"), "title") == [title]
      assert html =~ "M#{nodes["task:1"].x + 130},#{nodes["task:1"].y + height}"
    end
  end

  test "skipped layers route around intervening nodes only when the normal path is obstructed" do
    html = draw([task(1, "done"), task(2, "work"), task(3, "work")], [dep(2, 1), dep(3, 2), dep(3, 1)])
    nodes = positions(html)
    skip = dependency_path(html, nodes["task:1"], nodes["task:3"])
    [{_, svg_attrs, _}] = find(html, "[data-plan-svg]")
    channel = String.to_integer(Map.new(svg_attrs)["data-content-width"]) - 12
    assert skip =~ "Q#{channel},"
    assert skip =~ " L#{nodes["task:3"].x + 130},#{nodes["task:3"].y}"
    refute dependency_path(html, nodes["task:1"], nodes["task:2"]) =~ "Q#{channel},"

    peers = Enum.map(1..10, &task(&1, "work"))
    edges = [dep(5, 2), dep(6, 3)] ++ Enum.map(7..10, &dep(&1, 5)) ++ [dep(10, 1)]
    html = draw(peers, edges)
    nodes = positions(html)
    skip = dependency_path(html, nodes["task:1"], nodes["task:10"])
    assert nodes["task:1"].x == nodes["task:10"].x
    [{_, svg_attrs, _}] = find(html, "[data-plan-svg]")
    channel = String.to_integer(Map.new(svg_attrs)["data-content-width"]) - 12
    refute skip =~ "Q#{channel},"
  end

  test "a wrapped dependency layer cannot obscure a connector to its direct dependent" do
    html = draw(Enum.map(1..11, &task(&1, "work")), [dep(11, 1)])
    nodes = positions(html)
    assert nodes["task:11"].depth - nodes["task:1"].depth == 1
    assert nodes["task:11"].y - nodes["task:1"].y > 3 * 116
    [{_, svg_attrs, _}] = find(html, "[data-plan-svg]")
    channel = String.to_integer(Map.new(svg_attrs)["data-content-width"]) - 12
    assert dependency_path(html, nodes["task:1"], nodes["task:11"]) =~ "Q#{channel},"
  end

  test "cycle connectors clear peer cards through column and row gaps" do
    nodes = Enum.map(1..8, &task(&1, "work"))
    edges = Enum.map(1..8, &dep(&1, rem(&1, 8) + 1, "cycle"))
    html = draw(nodes, edges)
    positions = positions(html)
    [{_, svg_attrs, _}] = find(html, "[data-plan-svg]")
    channel = String.to_integer(Map.new(svg_attrs)["data-content-width"]) - 12
    side_paths = html |> find(".plan-edge") |> Floki.attribute("d") |> Enum.filter(&String.contains?(&1, "Q#{channel},"))
    assert side_paths != []

    for path <- side_paths do
      [[_, x, _y]] = Regex.scan(~r/^M(\d+),(\d+)/, path)
      gap_x = String.to_integer(x) + 22
      assert path =~ "Q#{gap_x},"
      assert Enum.all?(positions, fn {_id, node} -> gap_x < node.x or gap_x > node.x + 260 end)
    end
  end

  test "large diagrams announce truncation and explain how to focus dependencies" do
    html = draw(Enum.map(1..125, &task(&1, "work")), [dep(125, 1)])
    assert length(find(html, "#plan-dependencies-panel .plan-node")) == 120
    assert html =~ "up to 120 nodes"
    assert html =~ "Narrow filters or select a task"
    assert find(html, ".plan-accessible-list") == []
  end

  test "late selected task and its direct prerequisite survive the rendering bound" do
    html = draw(Enum.map(1..125, &task(&1, "work")), [dep(125, 1)], selected_id: "issue:125")
    assert length(find(html, "#plan-dependencies-panel .plan-node")) == 120
    assert length(find(html, "#plan-dependencies-panel [data-node-id='task:125'][data-selected=true]")) == 1
    assert length(find(html, "#plan-dependencies-panel [data-node-id='task:1'][data-related=true]")) == 1
    assert length(find(html, "[data-node-id='task:1'] .plan-node-select[phx-value-id='issue:1']")) == 1
  end

  test "selected work focuses its owning task without agent relationships" do
    project = %{"id" => "project:p", "type" => "project", "name" => "Fixture"}
    work = %{"id" => "work:1", "type" => "work", "task_id" => "issue:1", "work_id" => "native1", "title" => "Review candidate"}
    html = draw([project, task(1, "review"), work], [contains("project:p", "task:1"), contains("task:1", "work:1")], selected_id: "work:1")
    assert html =~ "data-plan-mode=\"dependencies\""
    assert length(find(html, "#plan-dependencies-panel [data-node-id='task:1'][data-selected=true]")) == 1
    assert html =~ "data-selected-task-id=\"issue:1\""
    refute html =~ "work:1"
    refute html =~ "Text view"
    html = draw([project, task(1, "work")], [contains("project:p", "task:1")], selected_id: "project:p")
    assert find(html, ".plan-inspector") == []
  end

  test "fallback, empty selection and completion policies are honest" do
    html = render_component(&WorkflowGraphView.content/1, board: %{})
    assert html =~ "Planning data is incomplete"
    refute html =~ "<svg"
    html = draw([], [], visible_task_ids: [])
    assert html =~ "No matching tasks"
    assert find(html, "[data-plan-svg]") == []
    refute html =~ "Text view"
    refute html =~ "class=\"plan-inspector\""

    for {policy, label} <- [{"human_acceptance", "Done records human acceptance"}, {"tracker_completion", "Done follows tracker completion"}, {nil, "Completion policy unavailable"}] do
      assert draw([task(1, nil, %{"title" => nil, "identifier" => nil, "task_kind" => "security"})], [], policy: policy) =~ label
    end

    assert draw([%{"id" => "project:p", "type" => "project"}, task(1, nil, %{"title" => nil, "identifier" => nil})]) =~ "Untitled"
    assert draw([task(1, nil)], []) =~ "Unknown"
    refute draw([%{"id" => "work:1", "type" => "work", "task_id" => "issue:1"}, task(1, "work")]) =~ "Supervision"
  end

  test "expected waiting is a node status while malformed prerequisites remain inline" do
    waiting = task(2, "work", %{"dependency_error" => "Dependencies require human-accepted Done in this project."})
    html = draw([task(1, "review"), waiting], [dep(2, 1)], selected_id: "issue:2", warnings: ["An obsolete global notice"])
    assert length(find(html, "[data-node-id='task:2'] .plan-node-dependency-status")) == 1
    assert html =~ "Waiting on GH-1"
    refute html =~ "Dependencies require human-accepted Done"
    refute html =~ "An obsolete global notice"
    assert find(html, ".plan-node-note") == []

    html = draw([task(1, "done"), task(2, "review")], [dep(2, 1, "satisfied")])
    assert find(html, ".plan-node-dependency-status") == []
  end

  test "waiting context is bounded and excludes optional prerequisites" do
    nodes = Enum.map(1..6, &task(&1, "work"))
    optional = Map.put(dep(6, 5), "blocking", false)
    html = draw(nodes, Enum.map(1..4, &dep(6, &1)) ++ [optional])
    assert html =~ "Waiting on GH-1, GH-2, GH-3 +1"
    [{_, _, children}] = find(html, "[data-node-id='task:6'] .plan-node-dependency-status")
    refute Floki.text(children) =~ "GH-5"
  end

  test "rounded connectors attach to stable task ports and inherit the line color" do
    html = draw([task(1, "done"), task(2, "work"), task(3, "review")], [dep(2, 1), dep(3, 1)], selected_id: "issue:2")
    nodes = positions(html)
    [{_, attrs, _} | _] = find(html, ".plan-edge")
    attrs = Map.new(attrs)
    assert attrs["d"] =~ "M#{nodes["task:1"].x + 130},#{nodes["task:1"].y + 116}"
    assert attrs["d"] =~ " L#{nodes["task:2"].x + 130},#{nodes["task:2"].y}"
    assert attrs["d"] =~ " Q"
    refute attrs["d"] =~ " C"
    assert attrs["vector-effect"] == "non-scaling-stroke"
    assert attrs["stroke-linejoin"] == "round"
    assert length(find(html, ".plan-edge[data-related=true]")) == 1
    assert html =~ "data-selection-active=\"true\""
    [{_, marker_attrs, _}] = find(html, "#dependencies-arrow")
    assert Map.new(marker_attrs)["markerwidth"] == "4"
    assert Floki.attribute(find(html, ".plan-edge-arrow"), "fill") == ["context-stroke"]
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

  defp task_diff_entries({_fingerprint, children}, id), do: task_diff_entries(children, id)

  defp task_diff_entries(children, id) when is_map(children) do
    if Map.has_key?(children, id), do: children, else: Enum.find_value(Map.values(children), &task_diff_entries(&1, id))
  end

  defp task_diff_entries(_value, _id), do: nil

  defp dependency_path(html, from, to) do
    start = "M#{from.x + 130},#{from.y + 116}"
    finish = " L#{to.x + 130},#{to.y}"

    html
    |> find(".plan-edge")
    |> Floki.attribute("d")
    |> Enum.find(&(String.starts_with?(&1, start) and String.ends_with?(&1, finish)))
  end

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
