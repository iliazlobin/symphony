defmodule SymphonyElixirWeb.WorkflowGraphView do
  @moduledoc "Interactive read-only task dependency diagram."
  use Phoenix.Component
  alias SymphonyElixirWeb.WorkflowPlan

  @lanes ~w(backlog work in_progress review done)
  @max_nodes 120
  @node_width 260
  @node_height 116
  @padding 44
  @column_step 304
  @row_gap 60

  attr(:board, :map, required: true)
  attr(:project, :string, default: nil)
  attr(:filters, :map, default: %{})
  attr(:selected_id, :string, default: nil)
  attr(:visible_task_ids, :any, default: :all)

  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    plan = WorkflowPlan.project(assigns.board, assigns.visible_task_ids)
    edges = Enum.filter(plan["edges"], &(&1["type"] == "depends_on"))
    tasks = Enum.filter(plan["nodes"], &(&1["type"] == "task"))
    names = Map.new(tasks, &{&1["id"], node_name(&1)})
    nodes = Enum.map(tasks, &with_dependency_status(&1, edges, names))
    selected = selected_task(plan["nodes"], nodes, assigns.selected_id)
    related = Enum.filter(edges, &related_edge?(&1, selected))
    related_ids = MapSet.new(Enum.flat_map(related, &[&1["source"], &1["target"]]))
    related_ids = if selected, do: MapSet.put(related_ids, selected["id"]), else: related_ids
    last_step = Enum.reduce(nodes, 0, &max(&1["start_step"] || 0, &2))
    layout = positions(nodes, &(&1["start_step"] || last_step + 1))
    tasks = Enum.filter(layout, &(&1["visible"] == true or MapSet.member?(related_ids, &1["id"])))
    task_positions = bounded_nodes(tasks, selected, related_ids)
    displayed_ids = MapSet.new(task_positions, & &1["id"])

    paths =
      for edge <- edges,
          MapSet.member?(displayed_ids, edge["source"]) and MapSet.member?(displayed_ids, edge["target"]),
          d = edge_path(edge, layout),
          not is_nil(d),
          do: %{edge: edge, d: d}

    assigns =
      assign(assigns,
        available: plan["available"],
        reason: plan["reason"],
        policy: get_in(assigns.board, [:workflow_graph, "policy"]),
        selected: selected,
        related_ids: related_ids,
        task_positions: task_positions,
        diagram_width: diagram_width(layout),
        diagram_height: diagram_height(layout),
        paths: paths,
        truncated: length(tasks) > @max_nodes,
        max_nodes: @max_nodes,
        lanes: @lanes
      )

    ~H"""
    <section id="workflow-graph" class="plan-view workflow-graph" phx-hook="WorkflowCanvas" data-canvas-scope={@project || "all"} data-plan-mode="dependencies" data-selected-id={@selected && @selected["id"]} data-selected-task-id={@selected && @selected["task_id"]} aria-label="Task dependencies">
      <div class="plan-toolbar">
        <span class="plan-title">Task dependencies</span>
        <div class="plan-tools" aria-label="Diagram viewport">
          <button type="button" data-canvas-action="out" aria-label="Zoom out">−</button>
          <output data-canvas-zoom aria-label="Diagram zoom">100%</output>
          <button type="button" data-canvas-action="in" aria-label="Zoom in">+</button>
          <button type="button" data-canvas-action="fit">Fit</button>
          <button type="button" data-canvas-action="center" disabled={is_nil(@selected)}>Center selected</button>
        </div>
      </div>
      <p class="plan-caption">Prerequisites → dependent tasks. Priority orders peers. {completion_description(@policy)}</p>
      <p :if={!@available} class="board-warning" role="status">{@reason || "Graph unavailable. The board keeps its last-known tasks."}</p>
      <p :if={@truncated} class="board-notice" role="status">Diagram shows up to {@max_nodes} nodes, with the selected relationships first. Narrow filters or select a task to focus its dependencies.</p>
      <div :if={@available} class="plan-main">
        <div id="plan-dependencies-panel" class="plan-panel" data-plan-panel="dependencies">
          <div class="plan-canvas" data-plan-canvas tabindex="0" role="region" aria-label="Task dependencies; drag background to pan, scroll to zoom, F to fit, C to center selected">
            <svg :if={@task_positions != []} class="plan-svg" data-plan-svg data-selection-active={to_string(!is_nil(@selected))} data-content-width={@diagram_width} data-content-height={@diagram_height} viewBox={"0 0 #{@diagram_width} #{@diagram_height}"} role="group" aria-label="Task dependencies">
              <title>Task dependencies</title>
              <desc>Arrows go from prerequisite to dependent. Select a node to open its agent; select its title for task details.</desc>
              <defs><marker id="dependencies-arrow" markerWidth="4" markerHeight="4" viewBox="0 0 4 4" refX="4" refY="2" markerUnits="strokeWidth" orient="auto"><path class="plan-edge-arrow" d="M0,0 L4,2 L0,4 Z" fill="context-stroke" /></marker></defs>
              <path :for={path <- @paths} :key={path.edge["id"] || dom_id("plan-edge", path.edge["source"] <> ":" <> path.edge["target"])} id={dom_id("plan-edge", path.edge["id"] || path.edge["source"] <> ":" <> path.edge["target"])} d={path.d} class="plan-edge" data-edge-source={path.edge["source"]} data-edge-target={path.edge["target"]} data-status={path.edge["status"]} data-related={to_string(related_edge?(path.edge, @selected))} vector-effect="non-scaling-stroke" stroke-linecap="round" stroke-linejoin="round" marker-end="url(#dependencies-arrow)" />
              <g :for={node <- @task_positions} :key={node["id"]} id={dom_id("plan-node", node["id"])} class="plan-node" transform={"translate(#{node.x},#{node.y})"} data-plan-node data-node-id={node["id"]} data-plan-task-id={node["task_id"]} data-plan-visible={to_string(node["visible"] != false)} data-node-x={node.x} data-node-y={node.y} data-node-width="260" data-node-height={node.height} data-depth={node.depth} data-lane={node["lane"]} data-selected={to_string(!is_nil(@selected) && @selected["id"] == node["id"])} data-related={to_string(MapSet.member?(@related_ids, node["id"]))} data-missing={to_string(node["missing"] == true)} data-cycle={to_string(node["cycle"] == true)} data-filtered={to_string(node["visible"] == false)}>
                <foreignObject width="260" height={node.height}>
                  <div class="plan-node-card">
                    <button :if={!node["missing"]} type="button" class="plan-node-select" aria-description={node["dependency_description"]} aria-pressed={to_string(!is_nil(@selected) && @selected["id"] == node["id"])} phx-click="select-plan-task" phx-value-id={node["task_id"]} aria-label={"Open #{node_name(node)} task agent"}></button>
                    <div class="plan-node-meta"><span>{node_name(node)}</span><span :if={node["priority"]}>P{node["priority"]}</span></div>
                    <button :if={node["task_id"] && !node["missing"]} type="button" class="plan-node-title" phx-click="open-card" phx-value-id={node["task_id"]} title={node_title(node)}>{node_title(node)}</button>
                    <span :if={!node["task_id"] || node["missing"]} class="plan-node-title" title={node_title(node)}>{node_title(node)}</span>
                    <div class="plan-node-meta"><span>{node_status(node)}</span><span :if={node["task_kind"] && node["task_kind"] != "general"}>{String.capitalize(node["task_kind"])}</span></div>
                    <span :if={node["graph_error"]} class="plan-node-note">{node["graph_error"]}</span>
                    <span :if={!node["graph_error"] && node["waiting_count"] > 0} class="plan-node-dependency-status" title={node["waiting_label"]}>{node["waiting_label"]}</span>
                    <span :if={node["visible"] == false} class="plan-node-context">Outside filters</span>
                  </div>
                </foreignObject>
              </g>
            </svg>
            <p :if={@task_positions == []} class="plan-empty">No matching tasks. Describe a task to the project agent or adjust filters.</p>
          </div>
        </div>
      </div>
      <div :if={@available} class="plan-legend"><span :for={lane <- @lanes}><span class={"lane-dot lane-dot-#{lane}"} aria-hidden="true"></span>{lane_name(lane)}</span><span>Drag to pan · Scroll to zoom</span></div>
    </section>
    """
  end

  defp selected_task(all_nodes, tasks, selected_id) do
    node = Enum.find(all_nodes, &(&1["id"] == selected_id or (&1["type"] == "task" and &1["task_id"] == selected_id)))
    if node, do: Enum.find(tasks, &(&1["task_id"] == node["task_id"]))
  end

  defp with_dependency_status(node, edges, names) do
    waiting = Enum.filter(edges, &(&1["source"] == node["id"] and &1["status"] == "waiting" and &1["blocking"] != false))
    labels = Enum.map(waiting, &(names[&1["target"]] || &1["target"])) |> Enum.uniq() |> Enum.sort()
    label = "Waiting on " <> Enum.join(Enum.take(labels, 3), ", ") <> if(length(labels) > 3, do: " +#{length(labels) - 3}", else: "")
    Map.merge(node, %{"waiting_count" => length(waiting), "waiting_label" => label, "graph_error" => node_error(node)})
  end

  defp node_error(%{"planning_status" => "cycle"}), do: "Dependency cycle. Revise prerequisites."
  defp node_error(%{"dependency_error" => "Dependencies require human-accepted Done in this project."}), do: nil
  defp node_error(node), do: node["dependency_error"]

  defp related_edge?(_edge, nil), do: false
  defp related_edge?(edge, node), do: node["id"] in [edge["source"], edge["target"]]

  defp bounded_nodes(nodes, _selected, _related) when length(nodes) <= @max_nodes, do: nodes

  defp bounded_nodes(nodes, selected, related) do
    nodes
    |> Enum.sort_by(fn node ->
      rank =
        cond do
          selected && node["id"] == selected["id"] -> 0
          MapSet.member?(related, node["id"]) -> 1
          true -> 2
        end

      {rank, node["id"]}
    end)
    |> Enum.take(@max_nodes)
  end

  defp positions(nodes, level) do
    rows =
      nodes
      |> Enum.group_by(level)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {depth, members} ->
        members |> Enum.sort_by(&node_order/1) |> Enum.chunk_every(4) |> Enum.map(&{depth, &1})
      end)

    columns = Enum.reduce(rows, 1, fn {_depth, members}, width -> max(width, length(members)) end)

    {positions, _height} =
      Enum.map_reduce(rows, @padding, fn {depth, members}, y ->
        offset = @padding + div((columns - length(members)) * @column_step, 2)
        row_height = Enum.reduce(members, @node_height, &max(node_height(&1), &2))

        positioned =
          members
          |> Enum.with_index()
          |> Enum.map(fn {node, column} ->
            Map.merge(node, %{x: offset + column * @column_step, y: y, height: node_height(node), depth: depth})
          end)

        {positioned, y + row_height + @row_gap}
      end)

    List.flatten(positions)
  end

  defp node_height(node) do
    status_height =
      cond do
        node["graph_error"] -> wrapped_lines(node["graph_error"]) * 16 + 8
        node["waiting_count"] > 0 -> wrapped_lines(node["waiting_label"]) * 16 + 8
        true -> 0
      end

    title_height = wrapped_lines(node_title(node)) * 18
    context_height = if(node["visible"] == false, do: 26, else: 0)
    max(@node_height, 72 + title_height + status_height + context_height)
  end

  defp wrapped_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      units = line |> String.to_charlist() |> Enum.map(&glyph_units/1) |> Enum.sum()
      max(1, div(units + 29, 30))
    end)
    |> Enum.sum()
  end

  defp glyph_units(char) when char in ~c"WM@" or char >= 0x2E80, do: 2
  defp glyph_units(_char), do: 1

  defp node_order(node), do: {node["priority"] || 999, node["identifier"] || node["id"]}
  defp diagram_height(nodes), do: Enum.reduce(nodes, 220, fn node, height -> max(height, node.y + node.height + @padding + 44) end)

  defp diagram_width(nodes) do
    Enum.reduce(nodes, @node_width + 2 * @padding, fn node, width -> max(width, node.x + @node_width + @padding + 24) end)
  end

  defp edge_path(edge, nodes) do
    source = Enum.find(nodes, &(&1["id"] == edge["source"]))
    target = Enum.find(nodes, &(&1["id"] == edge["target"]))

    if source && target do
      connector(target, source, nodes)
    end
  end

  defp connector(from, to, nodes) do
    x1 = from.x + div(@node_width, 2)
    x2 = to.x + div(@node_width, 2)
    y1 = from.y + from.height
    y2 = to.y
    channel = diagram_width(nodes) - 12

    cond do
      from.y >= to.y ->
        y1 = from.y + div(from.height * 2, 3)
        y2 = to.y + div(to.height, 3)
        from_x = from.x + @node_width
        to_x = to.x + @node_width
        gap = div(@column_step - @node_width, 2)
        exit_y = row_end(from, nodes) + div(@row_gap, 3)
        entry_y = to.y - div(@row_gap, 3)

        rounded_path([
          {from_x, y1},
          {from_x + gap, y1},
          {from_x + gap, exit_y},
          {channel, exit_y},
          {channel, entry_y},
          {to_x + gap, entry_y},
          {to_x + gap, y2},
          {to_x, y2}
        ])

      connector_obstructed?(from, to, nodes) ->
        exit_y = row_end(from, nodes) + div(@row_gap, 3)
        entry_y = to.y - div(@row_gap, 3)
        rounded_path([{x1, y1}, {x1, exit_y}, {channel, exit_y}, {channel, entry_y}, {x2, entry_y}, {x2, y2}])

      true ->
        middle = div(y1 + y2, 2)
        rounded_path([{x1, y1}, {x1, middle}, {x2, middle}, {x2, y2}])
    end
  end

  defp row_end(from, nodes),
    do: nodes |> Enum.filter(&(&1.y == from.y)) |> Enum.map(&(&1.y + &1.height)) |> Enum.max()

  defp connector_obstructed?(from, to, nodes) do
    x1 = from.x + div(@node_width, 2)
    x2 = to.x + div(@node_width, 2)
    y1 = from.y + from.height
    middle = div(y1 + to.y, 2)

    Enum.any?(nodes, fn node ->
      node["id"] not in [from["id"], to["id"]] and
        (crosses_vertical?(x1, y1, middle, node) or crosses_vertical?(x2, middle, to.y, node) or
           crosses_horizontal?(middle, x1, x2, node))
    end)
  end

  defp crosses_vertical?(x, first, last, node),
    do: x >= node.x and x <= node.x + @node_width and max(first, node.y) < min(last, node.y + node.height)

  defp crosses_horizontal?(y, first, last, node),
    do:
      y >= node.y and y <= node.y + node.height and
        max(min(first, last), node.x) < min(max(first, last), node.x + @node_width)

  defp rounded_path(points) do
    points = Enum.dedup(points)
    {x, y} = hd(points)
    {last_x, last_y} = List.last(points)
    corners = points |> Enum.chunk_every(3, 1, :discard) |> Enum.map_join(&rounded_corner/1)
    "M#{x},#{y}" <> corners <> " L#{last_x},#{last_y}"
  end

  defp rounded_corner([before, {x, y} = corner, after_corner]) do
    radius = min(10, min(div(distance(before, corner), 2), div(distance(corner, after_corner), 2)))
    {in_x, in_y} = toward(corner, before, radius)
    {out_x, out_y} = toward(corner, after_corner, radius)
    " L#{in_x},#{in_y} Q#{x},#{y} #{out_x},#{out_y}"
  end

  defp distance({x1, y1}, {x2, y2}), do: abs(x2 - x1) + abs(y2 - y1)
  defp toward({x, y}, {target_x, target_y}, amount), do: {x + direction(target_x - x) * amount, y + direction(target_y - y) * amount}
  defp direction(value) when value < 0, do: -1
  defp direction(value) when value > 0, do: 1
  defp direction(_), do: 0
  defp dom_id(prefix, id), do: prefix <> "-" <> Base.url_encode64(id, padding: false)
  defp node_name(node), do: node["identifier"] || node["name"] || node["title"] || node["id"]
  defp node_title(node), do: node["title"] || node["name"] || node["identifier"] || "Untitled"
  defp node_status(%{"missing" => true}), do: "Unavailable"
  defp node_status(%{"planning_status" => "cycle"}), do: "Dependency cycle"
  defp node_status(%{"planning_status" => "blocked"}), do: "Sequence unresolved"
  defp node_status(%{"planning_status" => "unknown"}), do: "Unknown sequence"
  defp node_status(node), do: lane_name(node["lane"])
  defp completion_description("human_acceptance"), do: "Done records human acceptance."
  defp completion_description("tracker_completion"), do: "Done follows tracker completion."
  defp completion_description(_), do: "Completion policy unavailable."
  defp lane_name("in_progress"), do: "In progress"
  defp lane_name(lane) when lane in @lanes, do: String.capitalize(lane)
  defp lane_name(_), do: "Unknown"
end
