defmodule SymphonyElixirWeb.WorkflowGraphView do
  @moduledoc "Bounded, read-only workflow and ownership diagrams with a text equivalent."
  use Phoenix.Component
  alias SymphonyElixir.TaskDependencies

  @lanes ~w(backlog work in_progress review done)
  @max_nodes 120
  @node_width 176
  @node_height 76
  @padding 40
  @column_step 204
  @row_step 140

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
    task_positions = tasks |> Enum.sort_by(& &1["id"]) |> Enum.take(@max_nodes) |> task_positions(dependencies)
    {waiting, warnings} = Enum.split_with(graph["warnings"] || [], &policy_wait_warning?/1)

    assigns =
      assign(assigns,
        available: graph["version"] == 1,
        completion_description: completion_description(graph["policy"]),
        graph: graph,
        warnings: warnings,
        waiting_count: length(waiting),
        tasks: tasks,
        dependencies: dependencies,
        node_names: Map.new(nodes, &{&1["id"], &1["identifier"] || &1["title"] || &1["name"] || &1["id"]}),
        task_positions: task_positions,
        hierarchy: hierarchy,
        contains: Enum.filter(edges, &(&1["type"] == "contains")),
        truncated: length(nodes) > @max_nodes,
        max_nodes: @max_nodes,
        task_height: diagram_height(task_positions, @node_height + @padding),
        task_width: diagram_width(task_positions),
        hierarchy_height: diagram_height(hierarchy),
        lanes: @lanes
      )

    ~H"""
    <section id="workflow-graph" class="workflow-graph" aria-label="Task dependencies and agent ownership">
      <p class="graph-description">Dependencies control admission. Priority orders eligible tasks. {@completion_description}</p>
      <p :if={!@available} class="board-warning" role="status">Graph unavailable. The board keeps its last-known tasks.</p>
      <p :if={@truncated} class="board-notice" role="status">Diagram shows the first {@max_nodes} nodes. The dependency list remains available below.</p>
      <p :if={@waiting_count > 0} class="graph-status" role="status">{@waiting_count} {if @waiting_count == 1, do: "task is", else: "tasks are"} waiting for accepted prerequisites.</p>
      <p :for={warning <- @warnings} class="board-warning" role="status">{warning}</p>
      <fieldset :if={@available} class="graph-view-picker"><legend class="visually-hidden">Graph view</legend>
        <label><input type="radio" name="graph-view" value="dependencies" checked />Dependencies</label>
        <label><input type="radio" name="graph-view" value="hierarchy" />Agents</label>
      </fieldset>
      <div :if={@available} class="graph-dependencies-view">
        <div class="graph-legend"><span :for={lane <- @lanes}><span class={"lane-dot lane-dot-#{lane}"} aria-hidden="true"></span>{lane_name(lane)}</span></div>
        <p class="graph-flow-caption">Read top to bottom: prerequisites → dependent tasks.</p>
        <div class="graph-canvas graph-dependency-canvas" tabindex="0" role="region" aria-label="Dependency diagram; scroll to explore">
          <svg width={@task_width} height={@task_height} viewBox={"0 0 #{@task_width} #{@task_height}"} role="img" aria-labelledby="dependencies-title dependencies-description">
            <title id="dependencies-title">Task dependency graph</title><desc id="dependencies-description">Arrows go from prerequisite to dependent, top to bottom. Labels show the task's current state. The dependency list below provides every relationship.</desc>
            <defs><marker id="dependency-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8" /></marker></defs>
            <path :for={edge <- @dependencies} :if={edge_path(edge, @task_positions)} d={edge_path(edge, @task_positions)} class="graph-edge" data-status={edge["status"]} marker-end="url(#dependency-arrow)" />
            <g :for={node <- @task_positions} transform={"translate(#{node.x},#{node.y})"} class="graph-node" data-node-id={node["id"]} data-depth={node.depth} data-lane={node["lane"]} data-missing={to_string(node["missing"] == true)} data-cycle={to_string(node["cycle"] == true)}>
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

  defp task_positions(tasks, edges) do
    depths = dependency_depths(tasks, edges)

    rows =
      tasks
      |> Enum.group_by(&depths[&1["id"]])
      |> Enum.sort_by(fn {depth, _nodes} -> depth end)
      |> Enum.flat_map(fn {depth, nodes} ->
        nodes |> Enum.sort_by(&node_order/1) |> Enum.chunk_every(4) |> Enum.map(&{depth, &1})
      end)

    columns = Enum.reduce(rows, 1, fn {_depth, nodes}, width -> max(width, length(nodes)) end)

    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {{depth, nodes}, row} ->
      offset = @padding + div((columns - length(nodes)) * @column_step, 2)
      nodes |> Enum.with_index() |> Enum.map(fn {node, column} -> Map.merge(node, %{x: offset + column * @column_step, y: @padding + row * @row_step, depth: depth}) end)
    end)
  end

  defp dependency_depths(tasks, edges) do
    ids = Map.new(tasks, &{&1["id"], &1["id"]})
    edges = Enum.filter(edges, &(Map.has_key?(ids, &1["source"]) and Map.has_key?(ids, &1["target"])))
    records = Map.new(ids, fn {id, _} -> {id, %{"dependencies" => Enum.filter(edges, &(&1["source"] == id)) |> Enum.map(&%{"issue_id" => &1["target"]})}} end)

    groups =
      records
      |> TaskDependencies.cycle_groups()
      |> Enum.reduce(ids, fn members, groups -> Enum.reduce(members, groups, &Map.put(&2, &1, Enum.min(members))) end)

    parents = Map.new(Map.values(groups), &{&1, MapSet.new()})

    parents =
      Enum.reduce(edges, parents, fn edge, parents ->
        from = groups[edge["source"]]
        to = groups[edge["target"]]
        if from == to, do: parents, else: Map.update!(parents, from, &MapSet.put(&1, to))
      end)

    levels = Enum.reduce(Map.keys(parents), %{}, fn id, levels -> elem(dependency_depth(id, parents, levels), 1) end)
    Map.new(groups, fn {id, group} -> {id, levels[group]} end)
  end

  defp dependency_depth(id, parents, levels) do
    case Map.fetch(levels, id) do
      {:ok, depth} ->
        {depth, levels}

      :error ->
        {depth, levels} =
          Enum.reduce(parents[id], {-1, levels}, fn parent, {highest, memo} ->
            {depth, memo} = dependency_depth(parent, parents, memo)
            {max(highest, depth), memo}
          end)

        {depth + 1, Map.put(levels, id, depth + 1)}
    end
  end

  defp node_order(node), do: {if(is_integer(node["priority"]), do: node["priority"], else: 999), node["identifier"] || node["id"]}

  defp hierarchy_positions(nodes) do
    nodes
    |> Enum.group_by(& &1["type"])
    |> Enum.flat_map(fn {type, group} ->
      column = %{"project" => 0, "task" => 1, "work" => 2}[type] || 2
      group |> Enum.sort_by(& &1["id"]) |> Enum.with_index() |> Enum.map(fn {node, row} -> Map.merge(node, %{x: 36 + column * 340, y: 12 + row * 106}) end)
    end)
  end

  defp diagram_height(nodes, padding \\ 100), do: Enum.reduce(nodes, 180, fn node, height -> max(height, node.y + padding) end)
  defp diagram_width(nodes), do: Enum.reduce(nodes, @node_width + 2 * @padding, fn node, width -> max(width, node.x + @node_width + @padding) end)

  defp edge_path(edge, nodes, reverse \\ true) do
    source = Enum.find(nodes, &(&1["id"] == edge["source"]))
    target = Enum.find(nodes, &(&1["id"] == edge["target"]))

    if source && target do
      {from, to} = if reverse, do: {target, source}, else: {source, target}

      if reverse do
        dependency_path(from, to, nodes)
      else
        "M#{from.x + 176},#{from.y + 38} C#{from.x + 195},#{from.y + 38} #{to.x - 20},#{to.y + 38} #{to.x},#{to.y + 38}"
      end
    end
  end

  defp dependency_path(from, to, nodes) do
    cond do
      from["id"] == to["id"] ->
        channel = diagram_width(nodes) - 12
        "M#{from.x + @node_width},#{from.y + 38} C#{channel},#{from.y + 14} #{channel},#{to.y + 62} #{to.x + @node_width},#{to.y + 38}"

      from.y > to.y or to.y - from.y > @row_step ->
        channel = diagram_width(nodes) - 12
        "M#{from.x + 88},#{from.y + @node_height} V#{from.y + @node_height + 18} H#{channel} V#{to.y - 18} H#{to.x + 88} V#{to.y}"

      from.y == to.y ->
        bend = from.y + @node_height + if(from.x < to.x, do: 26, else: 40)
        "M#{from.x + 88},#{from.y + @node_height} C#{from.x + 88},#{bend} #{to.x + 88},#{bend} #{to.x + 88},#{to.y + @node_height}"

      true ->
        middle = div(from.y + @node_height + to.y, 2)
        "M#{from.x + 88},#{from.y + @node_height} C#{from.x + 88},#{middle} #{to.x + 88},#{middle} #{to.x + 88},#{to.y}"
    end
  end

  defp policy_wait_warning?(warning),
    do: Regex.match?(~r/\AGH-[1-9][0-9]*: Dependencies require human-accepted Done in this project\.\z/, warning)

  defp completion_description("human_acceptance"), do: "Done records human acceptance."
  defp completion_description("tracker_completion"), do: "Done follows tracker completion."
  defp completion_description(_), do: "Completion policy unavailable."
  defp lane_name("in_progress"), do: "In progress"
  defp lane_name(lane) when lane in @lanes, do: String.capitalize(lane)
  defp lane_name(_), do: "Unknown"
  defp short_title(nil), do: "Untitled"
  defp short_title(title), do: if(String.length(title) > 24, do: String.slice(title, 0, 23) <> "…", else: title)
end
