defmodule SymphonyElixirWeb.WorkflowGraphView do
  @moduledoc "Bounded, read-only workflow and ownership diagrams with a text equivalent."
  use Phoenix.Component

  @lanes ~w(backlog work in_progress review done)
  @max_nodes 120

  attr(:board, :map, required: true)
  attr(:project, :string, default: nil)
  attr(:filters, :map, default: %{})

  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    graph = Map.get(assigns.board, :workflow_graph) || %{}
    nodes = graph["nodes"] || []
    edges = graph["edges"] || []
    tasks = Enum.filter(nodes, &(&1["type"] == "task"))
    dependencies = Enum.filter(edges, &(&1["type"] == "depends_on"))
    hierarchy = nodes |> Enum.reject(&(&1["missing"] == true)) |> Enum.take(@max_nodes) |> hierarchy_positions()
    task_positions = tasks |> Enum.take(@max_nodes) |> task_positions()

    assigns =
      assign(assigns,
        available: graph["version"] == 1,
        completion_description: completion_description(graph["policy"]),
        graph: graph,
        tasks: tasks,
        dependencies: dependencies,
        node_names: Map.new(nodes, &{&1["id"], &1["identifier"] || &1["title"] || &1["name"] || &1["id"]}),
        task_positions: task_positions,
        hierarchy: hierarchy,
        contains: Enum.filter(edges, &(&1["type"] == "contains")),
        truncated: length(nodes) > @max_nodes,
        max_nodes: @max_nodes,
        task_height: diagram_height(task_positions),
        task_width: if(Enum.any?(tasks, &(&1["lane"] not in @lanes)), do: 1240, else: 1040),
        hierarchy_height: diagram_height(hierarchy),
        lanes: @lanes
      )

    ~H"""
    <section id="workflow-graph" class="workflow-graph" aria-label="Task dependencies and agent ownership">
      <p class="graph-description">Dependencies control admission. Priority orders eligible tasks. {@completion_description}</p>
      <p :if={!@available} class="board-warning" role="status">Graph unavailable. The board keeps its last-known tasks.</p>
      <p :if={@truncated} class="board-notice" role="status">Diagram shows the first {@max_nodes} nodes. The dependency list remains available below.</p>
      <p :for={warning <- @graph["warnings"] || []} class="board-warning" role="status">{warning}</p>
      <fieldset :if={@available} class="graph-view-picker"><legend class="visually-hidden">Graph view</legend>
        <label><input type="radio" name="graph-view" value="dependencies" checked />Dependencies</label>
        <label><input type="radio" name="graph-view" value="hierarchy" />Agents</label>
      </fieldset>
      <div :if={@available} class="graph-dependencies-view">
        <div class="graph-legend"><span :for={lane <- @lanes}><span class={"lane-dot lane-dot-#{lane}"} aria-hidden="true"></span>{lane_name(lane)}</span></div>
        <div class="graph-canvas" tabindex="0" role="region" aria-label="Dependency diagram; scroll to explore">
          <svg width={@task_width} height={@task_height} viewBox={"0 0 #{@task_width} #{@task_height}"} role="img" aria-labelledby="dependencies-title dependencies-description">
            <title id="dependencies-title">Task dependency graph</title><desc id="dependencies-description">Arrows go from prerequisite to dependent. Labels show the task's current column. The dependency list below provides every relationship.</desc>
            <defs><marker id="dependency-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8" /></marker></defs>
            <path :for={edge <- @dependencies} :if={edge_path(edge, @task_positions)} d={edge_path(edge, @task_positions)} class="graph-edge" data-status={edge["status"]} marker-end="url(#dependency-arrow)" />
            <g :for={node <- @task_positions} transform={"translate(#{node.x},#{node.y})"} class="graph-node" data-lane={node["lane"]} data-missing={to_string(node["missing"] == true)} data-cycle={to_string(node["cycle"] == true)}>
              <rect width="176" height="76" rx="8" /><text x="12" y="20" class="graph-node-id">{node["identifier"]}</text>
              <text x="12" y="40">{short_title(node["title"])}</text><text x="12" y="61" class="graph-node-status">{if node["missing"], do: "Unavailable", else: lane_name(node["lane"])}{if node["cycle"], do: " · cycle"}</text>
              <title>{node["identifier"]}: {node["title"]} · {lane_name(node["lane"])} · {node["execution_status"]}</title>
            </g>
          </svg>
        </div>
        <p :if={@tasks == []} class="graph-empty">No tasks yet. Describe one to the project agent.</p>
        <p :if={@dependencies == [] && @tasks != []} class="graph-empty">No declared dependencies.</p>
        <div :if={@dependencies != []} class="graph-relationship-list"><h3>Dependencies</h3>
          <table><thead><tr><th>Task</th><th>Requires</th><th>Reason</th><th>Status</th></tr></thead><tbody>
            <tr :for={edge <- @dependencies} data-dependency-status={edge["status"]}><td>{Map.get(@node_names, edge["source"], edge["source"])}</td><td>{Map.get(@node_names, edge["target"], edge["target"])}</td><td>{edge["kind"]}{if edge["reason"], do: " · " <> edge["reason"]}</td><td>{edge["status"]}</td></tr>
          </tbody></table>
        </div>
      </div>
      <div :if={@available} class="graph-hierarchy-view">
        <p class="graph-description">Project agent → task agents → work agents. Parent agents supervise; work reports return through the same hierarchy.</p>
        <div class="graph-canvas" tabindex="0" role="region" aria-label="Agent ownership diagram; scroll to explore">
          <svg width="1040" height={@hierarchy_height} viewBox={"0 0 1040 #{@hierarchy_height}"} role="img" aria-labelledby="hierarchy-title hierarchy-description">
            <title id="hierarchy-title">Project, task and work agent hierarchy</title><desc id="hierarchy-description">Contains edges express ownership, not dependencies or additional execution authority.</desc>
            <defs><marker id="hierarchy-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8" /></marker></defs>
            <path :for={edge <- @contains} :if={edge_path(edge, @hierarchy, false)} d={edge_path(edge, @hierarchy, false)} class="graph-edge graph-ownership" marker-end="url(#hierarchy-arrow)" />
            <g :for={node <- @hierarchy} transform={"translate(#{node.x},#{node.y})"} class="graph-node" data-lane={node["lane"]}>
              <rect width="176" height="76" rx="8" /><text x="12" y="20" class="graph-node-id">{String.capitalize(node["type"])} agent</text>
              <text x="12" y="40">{short_title(node["identifier"] || node["name"] || node["title"])}</text><text x="12" y="61" class="graph-node-status">{node["phase"] || if(node["type"] == "task", do: lane_name(node["lane"]), else: "Supervision")}</text>
              <title>{node["title"] || node["name"] || node["identifier"]}</title>
            </g>
          </svg>
        </div>
        <ul class="graph-ownership-list"><li :for={edge <- @contains}>{Map.get(@node_names, edge["source"], edge["source"])} → {Map.get(@node_names, edge["target"], edge["target"])}</li></ul>
      </div>
    </section>
    """
  end

  defp task_positions(tasks) do
    tasks
    |> Enum.group_by(&(&1["lane"] || "unknown"))
    |> Enum.sort_by(fn {lane, _} -> Enum.find_index(@lanes, &(&1 == lane)) || 5 end)
    |> Enum.flat_map(fn {lane, nodes} ->
      column = Enum.find_index(@lanes, &(&1 == lane)) || 5
      nodes |> Enum.sort_by(& &1["identifier"]) |> Enum.with_index() |> Enum.map(fn {node, row} -> Map.merge(node, %{x: 12 + column * 205, y: 12 + row * 106}) end)
    end)
  end

  defp hierarchy_positions(nodes) do
    nodes
    |> Enum.group_by(& &1["type"])
    |> Enum.flat_map(fn {type, group} ->
      column = %{"project" => 0, "task" => 1, "work" => 2}[type] || 2
      group |> Enum.sort_by(& &1["id"]) |> Enum.with_index() |> Enum.map(fn {node, row} -> Map.merge(node, %{x: 36 + column * 340, y: 12 + row * 106}) end)
    end)
  end

  defp diagram_height(nodes), do: Enum.reduce(nodes, 180, fn node, height -> max(height, node.y + 100) end)

  defp edge_path(edge, nodes, reverse \\ true) do
    source = Enum.find(nodes, &(&1["id"] == edge["source"]))
    target = Enum.find(nodes, &(&1["id"] == edge["target"]))

    if source && target do
      {from, to} = if reverse, do: {target, source}, else: {source, target}

      if from.x == to.x do
        x = from.x + 176
        "M#{x},#{from.y + 38} C#{x + 26},#{from.y + 38} #{x + 26},#{to.y + 38} #{x},#{to.y + 38}"
      else
        "M#{from.x + 176},#{from.y + 38} C#{from.x + 195},#{from.y + 38} #{to.x - 20},#{to.y + 38} #{to.x},#{to.y + 38}"
      end
    end
  end

  defp completion_description("human_acceptance"), do: "Done records human acceptance."
  defp completion_description("tracker_completion"), do: "Done follows tracker completion."
  defp completion_description(_), do: "Completion policy unavailable."
  defp lane_name("in_progress"), do: "In progress"
  defp lane_name(lane) when lane in @lanes, do: String.capitalize(lane)
  defp lane_name(_), do: "Unknown"
  defp short_title(nil), do: "Untitled"
  defp short_title(title), do: if(String.length(title) > 24, do: String.slice(title, 0, 23) <> "…", else: title)
end
