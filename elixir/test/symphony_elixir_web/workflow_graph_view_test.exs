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

  test "topological arrows, satisfied edges and long names stay compact" do
    graph = %{
      "version" => 1,
      "nodes" => [task("1", "done", %{"title" => String.duplicate("long title ", 20)}), task("2", "done")],
      "edges" => [dependency("2", "1", "satisfied")]
    }

    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    assert html =~ "data-status=\"satisfied\""
    assert html =~ "…"
    assert html =~ "viewBox=\"0 0 256 296\""
    assert html =~ "<path d=\"M"
  end

  test "onboarding dependencies use depth rather than lifecycle and order peers by priority" do
    nodes = [
      task("6", "done"),
      task("11", "done"),
      task("19", "backlog", %{"priority" => 1}),
      task("20", "backlog", %{"priority" => 3}),
      task("21", "backlog", %{"priority" => 1}),
      task("22", "backlog", %{"priority" => 2}),
      task("23", "backlog"),
      task("24", "backlog")
    ]

    edges = Enum.map(20..23, &dependency(to_string(&1), "19", "waiting")) ++ Enum.map(20..23, &dependency("24", to_string(&1), "waiting"))
    waits = Enum.map(20..24, &"GH-#{&1}: Dependencies require human-accepted Done in this project.")
    graph = %{"version" => 1, "policy" => "human_acceptance", "nodes" => nodes, "edges" => edges, "warnings" => waits}
    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    nodes = positions(html)

    for id <- ["6", "11", "19"], do: assert(nodes["task:" <> id].depth == 0)
    for id <- ~w(20 21 22 23), do: assert(nodes["task:" <> id].depth == 1)
    assert nodes["task:24"].depth == 2
    assert nodes["task:19"].y < nodes["task:21"].y
    assert nodes["task:21"].y < nodes["task:24"].y
    assert Enum.sort_by(~w(20 21 22 23), &nodes["task:" <> &1].x) == ~w(21 22 20 23)
    assert html =~ "5 tasks are waiting for accepted prerequisites."
    refute html =~ "Dependencies require human-accepted Done"
    assert find(html, ".board-warning") == []
    assert length(find(html, "[data-dependency-status=waiting]")) == 8
    assert html =~ "Read top to bottom"
    assert html =~ "viewBox=\"0 0 868 436\""
    assert length(find(html, ".graph-dependencies-view [data-lane=done]")) == 2

    shuffled = %{graph | "nodes" => Enum.reverse(graph["nodes"]), "edges" => Enum.reverse(edges)}
    assert positions(render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: shuffled})) == nodes
  end

  test "cycles collapse to a finite shared depth and missing details stay visible" do
    graph = %{
      "version" => 1,
      "nodes" => [task("1", "work", %{"cycle" => true}), task("2", "review", %{"cycle" => true}), task("404", "unknown", %{"missing" => true}), task("3", "backlog")],
      "edges" => [dependency("1", "2", "cycle"), dependency("2", "1", "cycle"), dependency("3", "1", "waiting"), dependency("3", "404", "missing")],
      "warnings" => ["Dependency cycle: GH-1, GH-2. Revise prerequisites.", "GH-404 is unavailable.", "GH-3: Dependencies require human-accepted Done in this project."]
    }

    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    nodes = positions(html)
    assert nodes["task:1"].depth == nodes["task:2"].depth
    assert nodes["task:3"].depth > nodes["task:1"].depth
    assert html =~ "1 task is waiting for accepted prerequisites."
    assert html =~ "GH-404 is unavailable"
    assert html =~ "Revise prerequisites"
    assert length(find(html, ".board-warning")) == 2
    assert length(find(html, "[data-dependency-status=cycle]")) == 2
    assert length(find(html, "[data-dependency-status=missing]")) == 1
    assert length(find(html, ".graph-dependencies-view [data-cycle=true]")) == 2
    assert html =~ "data-missing=\"true\""
  end

  test "wrapped cycle and skipped-depth arrows stay bounded and every edge remains accessible" do
    cycle_edges = Enum.map(1..5, &dependency(to_string(&1), to_string(rem(&1, 5) + 1), "cycle"))
    nodes = Enum.map(1..5, &task(to_string(&1), "work", %{"cycle" => true}))

    graph = %{
      "version" => 1,
      "nodes" => nodes ++ [task("6", "review"), task("7", "backlog")],
      "edges" =>
        cycle_edges ++
          [
            dependency("6", "1", "waiting"),
            dependency("7", "6", "waiting"),
            dependency("7", "1", "waiting"),
            dependency("7", "7", "cycle")
          ]
    }

    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    nodes = positions(html)
    assert MapSet.size(MapSet.new(Enum.map(nodes, fn {_id, node} -> {node.x, node.y} end))) == 7
    assert Enum.all?(Enum.map(1..5, &nodes["task:#{&1}"].depth), &(&1 == 0))
    assert nodes["task:6"].depth == 1
    assert nodes["task:7"].depth == 2
    assert length(find(html, "[data-dependency-status]")) == 9
    assert html =~ " V"
  end

  test "large diagrams expose truncation and preserve full dependency evidence" do
    graph = %{"version" => 1, "nodes" => Enum.map(1..125, &task(to_string(&1), "work")), "edges" => [dependency("125", "1", "waiting")]}
    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    assert html =~ "first 120 nodes"
    assert html =~ "GH-125"
    assert html =~ "dependency list remains available"
  end

  test "last-row backward cycle curves remain entirely inside the SVG viewport" do
    graph = %{
      "version" => 1,
      "nodes" => Enum.map(1..8, &task(to_string(&1), "work", %{"cycle" => true})),
      "edges" => Enum.map(1..8, &dependency(to_string(&1), to_string(rem(&1, 8) + 1), "cycle"))
    }

    html = render_component(&WorkflowGraphView.content/1, board: %{workflow_graph: graph})
    assert html =~ "viewBox=\"0 0 868 296\""

    for {_tag, attributes, _children} <- find(html, ".graph-dependencies-view .graph-edge") do
      path = attributes |> Map.new() |> Map.fetch!("d")

      if String.contains?(path, " C") do
        [x0, y0, x1, y1, x2, y2, x3, y3] = ~r/[0-9]+/ |> Regex.scan(path) |> List.flatten() |> Enum.map(&String.to_integer/1)

        for t <- [0.0, 0.25, 0.5, 0.75, 1.0] do
          x = bezier(t, x0, x1, x2, x3)
          y = bezier(t, y0, y1, y2, y3)
          assert x >= 0 and x <= 868
          assert y >= 0 and y <= 296
        end
      end
    end
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

  defp positions(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(".graph-dependencies-view .graph-node")
    |> Map.new(fn {_tag, attributes, _children} ->
      attributes = Map.new(attributes)
      [_, x, y] = Regex.run(~r/translate\(([0-9]+),([0-9]+)\)/, attributes["transform"])
      {attributes["data-node-id"], %{x: String.to_integer(x), y: String.to_integer(y), depth: String.to_integer(attributes["data-depth"])}}
    end)
  end

  defp find(html, selector), do: html |> Floki.parse_fragment!() |> Floki.find(selector)
  defp bezier(t, a, b, c, d), do: (1 - t) ** 3 * a + 3 * (1 - t) ** 2 * t * b + 3 * (1 - t) * t ** 2 * c + t ** 3 * d
end
