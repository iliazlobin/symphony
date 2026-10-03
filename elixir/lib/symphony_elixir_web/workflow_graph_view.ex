defmodule SymphonyElixirWeb.WorkflowGraphView do
  @moduledoc "Interactive read-only dependency and agent diagrams with accessible relationship evidence."
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
    nodes = Enum.map(plan["nodes"], &display_node(&1, assigns.board))
    edges = plan["edges"]
    selected = Enum.find(nodes, &(&1["id"] == assigns.selected_id or (&1["type"] == "task" and &1["task_id"] == assigns.selected_id)))
    related = Enum.filter(edges, &related_edge?(&1, selected))
    related_ids = MapSet.new(Enum.flat_map(related, &[&1["source"], &1["target"]]))
    related_ids = if selected, do: MapSet.put(related_ids, selected["id"]), else: related_ids
    visible_ids = nodes |> Enum.filter(&(&1["type"] == "task" && &1["visible"])) |> MapSet.new(& &1["task_id"])
    shown = Enum.filter(nodes, &shown?(&1, related_ids, visible_ids))
    tasks = Enum.filter(shown, &(&1["type"] == "task"))
    last_step = Enum.reduce(tasks, 0, &max(&1["start_step"] || 0, &2))
    dependencies = Enum.filter(edges, &(&1["type"] == "depends_on"))
    task_positions = tasks |> bounded_nodes(selected, related_ids) |> positions(&(&1["start_step"] || last_step + 1))
    hierarchy = shown |> bounded_nodes(selected, related_ids) |> positions(&%{"project" => 0, "task" => 1, "work" => 2}[&1["type"]])
    {waiting, warnings} = Enum.split_with(plan["warnings"], &policy_wait_warning?/1)

    assigns =
      assign(assigns,
        available: plan["available"],
        reason: plan["reason"],
        policy: get_in(assigns.board, [:workflow_graph, "policy"]),
        selected: selected,
        initial_mode: if(selected && selected["type"] in ~w(project work), do: "agents", else: "dependencies"),
        related_ids: related_ids,
        related: related,
        names: Map.new(nodes, &{&1["id"], node_name(&1)}),
        by_id: Map.new(nodes, &{&1["id"], &1}),
        text_nodes: tasks,
        warnings: warnings,
        waiting_count: length(waiting),
        dependencies: dependencies,
        task_positions: task_positions,
        hierarchy: hierarchy,
        contains: Enum.filter(edges, &(&1["type"] == "contains")),
        edges: edges,
        truncated: length(shown) > @max_nodes,
        max_nodes: @max_nodes,
        lanes: @lanes,
        scenes: [
          %{id: "dependencies", label: "Task dependencies", nodes: task_positions, edges: dependencies},
          %{id: "agents", label: "Agent ownership", nodes: hierarchy, edges: Enum.filter(edges, &(&1["type"] == "contains"))}
        ]
      )

    ~H"""
    <section id="workflow-graph" class="plan-view workflow-graph" phx-hook="WorkflowCanvas" data-canvas-scope={@project || "all"} data-plan-mode={@initial_mode} data-selected-id={@selected_id} data-selected-task-id={@selected && @selected["task_id"]} aria-label="Task dependencies and agent ownership">
      <div class="plan-toolbar">
        <div class="plan-view-picker" role="tablist" aria-label="Graph relationships">
          <button id="plan-dependencies-tab" type="button" role="tab" aria-controls="plan-dependencies-panel" aria-selected={to_string(@initial_mode == "dependencies")} tabindex={if @initial_mode == "dependencies", do: "0", else: "-1"} data-canvas-mode="dependencies">Dependencies</button>
          <button id="plan-agents-tab" type="button" role="tab" aria-controls="plan-agents-panel" aria-selected={to_string(@initial_mode == "agents")} tabindex={if @initial_mode == "agents", do: "0", else: "-1"} data-canvas-mode="agents">Agents</button>
        </div>
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
      <p :if={@truncated} class="board-notice" role="status">Diagram shows up to {@max_nodes} nodes, with the selected relationships first. All relationships remain available in the text view.</p>
      <p :if={@waiting_count > 0} class="plan-caption">{@waiting_count} {if @waiting_count == 1, do: "task is", else: "tasks are"} waiting for accepted prerequisites.</p>
      <details :if={@warnings != []} class="plan-warnings"><summary>{length(@warnings)} dependency {if length(@warnings) == 1, do: "issue", else: "issues"}</summary><ul><li :for={warning <- @warnings}>{warning}</li></ul></details>
      <div :if={@available} class="plan-main">
        <div :for={scene <- @scenes} id={"plan-#{scene.id}-panel"} class="plan-panel" role="tabpanel" aria-labelledby={"plan-#{scene.id}-tab"} data-plan-panel={scene.id} hidden={scene.id != @initial_mode}>
          <div class="plan-canvas" data-plan-canvas tabindex="0" role="region" aria-label={scene.label <> "; drag background to pan, scroll to zoom, F to fit, C to center selected"}>
            <svg :if={scene.nodes != []} class="plan-svg" data-plan-svg data-content-width={diagram_width(scene.nodes)} data-content-height={diagram_height(scene.nodes)} viewBox={"0 0 #{diagram_width(scene.nodes)} #{diagram_height(scene.nodes)}"} role="group" aria-label={scene.label}>
              <title>{scene.label}</title>
              <desc>Arrows go from prerequisite to dependent. Select a node to open its agent; select its title for task details. The text view provides every relationship.</desc>
              <defs><marker id={"#{scene.id}-arrow"} markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8" /></marker></defs>
              <path :for={edge <- scene.edges} :if={edge_path(edge, scene.nodes)} d={edge_path(edge, scene.nodes)} class="plan-edge" data-status={edge["status"]} data-related={to_string(related_edge?(edge, @selected))} marker-end={"url(##{scene.id}-arrow)"} />
              <g :for={node <- scene.nodes} class="plan-node" transform={"translate(#{node.x},#{node.y})"} data-plan-node data-node-id={node["id"]} data-plan-task-id={node["task_id"]} data-plan-visible={to_string(node["visible"] != false)} data-node-x={node.x} data-node-y={node.y} data-node-width="260" data-node-height={node.height} data-depth={node.depth} data-lane={node["lane"]} data-selected={to_string(!is_nil(@selected) && @selected["id"] == node["id"])} data-related={to_string(MapSet.member?(@related_ids, node["id"]))} data-missing={to_string(node["missing"] == true)} data-cycle={to_string(node["cycle"] == true)} data-filtered={to_string(node["visible"] == false)}>
                <foreignObject width="260" height={node.height}>
                  <div class="plan-node-card">
                    <button :if={node["type"] != "project" && node["task_id"] && !node["missing"]} type="button" class="plan-node-select" phx-click="select-plan-task" phx-value-id={node["task_id"]} phx-value-work_id={node["work_id"]} aria-label={"Open #{node_name(node)} agent"}></button>
                    <button :if={node["type"] == "project"} type="button" class="plan-node-select" phx-click="main-chat" aria-label={"Open #{node_name(node)} project agent"}></button>
                    <div class="plan-node-meta"><span>{node["identifier"] || String.capitalize(node["type"]) <> " agent"}</span><span :if={node["priority"]}>P{node["priority"]}</span></div>
                    <button :if={node["task_id"] && !node["missing"]} type="button" class="plan-node-title" phx-click="open-card" phx-value-id={node["task_id"]} title={node_title(node)}>{node_title(node)}</button>
                    <span :if={!node["task_id"] || node["missing"]} class="plan-node-title" title={node_title(node)}>{node_title(node)}</span>
                    <div class="plan-node-meta"><span>{node_status(node)}</span><span :if={node["task_kind"] && node["task_kind"] != "general"}>{String.capitalize(node["task_kind"])}</span></div>
                    <span :if={node["visible"] == false} class="plan-node-context">Outside filters</span>
                  </div>
                </foreignObject>
              </g>
            </svg>
            <p :if={scene.nodes == []} class="plan-empty">No matching tasks. Describe a task to the project agent or adjust filters.</p>
          </div>
        </div>
        <aside :if={@selected} class="plan-inspector" aria-label="Selected node relationships">
          <h3>{node_name(@selected)}</h3>
          <p>{node_title(@selected)}</p>
          <div class="plan-related-counts"><span>{@selected["upstream_count"] || 0} prerequisites</span><span>{@selected["downstream_count"] || 0} dependents</span></div>
          <p :if={(@selected["upstream_outside_filter"] || 0) > 0}>{@selected["upstream_outside_filter"]} prerequisites outside filters.</p>
          <p :if={(@selected["upstream_unknown"] || 0) > 0}>{@selected["upstream_unknown"]} prerequisites unavailable.</p>
          <p :if={@selected["dependency_error"]}>{@selected["dependency_error"]}</p>
          <ul><li :for={edge <- @related}><.reference node={@by_id[edge["source"]]} fallback={edge["source"]} /> {if edge["type"] == "depends_on", do: "requires", else: "→"} <.reference node={@by_id[edge["target"]]} fallback={edge["target"]} /><span :if={edge["reason"]}> · {edge["reason"]}</span><span :if={edge["status"]}> · {edge["status"]}</span></li></ul>
          <p :if={@related == []}>No declared relationships.</p>
          <div class="plan-inspector-links"><button type="button" phx-click="switch-view" phx-value-view="kanban" phx-value-id={@selected["task_id"]} data-board-view-link="kanban" data-board-view-task={@selected["task_id"]}>Show on board</button><button type="button" phx-click="switch-view" phx-value-view="gantt" phx-value-id={@selected["task_id"]} data-board-view-link="gantt" data-board-view-task={@selected["task_id"]}>Show sequence</button></div>
        </aside>
      </div>
      <div :if={@available} class="plan-legend"><span :for={lane <- @lanes}><span class={"lane-dot lane-dot-#{lane}"} aria-hidden="true"></span>{lane_name(lane)}</span><span>Drag to pan · Scroll to zoom</span></div>
      <details :if={@available} class="plan-accessible-list"><summary>Text view · {length(@edges)} relationships</summary>
        <p :if={@dependencies == []}>No declared dependencies.</p>
        <ul><li :for={node <- @text_nodes}>{node_name(node)} · {node_title(node)} · {node_status(node)}</li></ul>
        <ul><li :for={edge <- @edges} data-dependency-status={edge["status"]}>{relationship(edge, @names)}<span :if={edge["kind"]}> · {edge["kind"]}</span><span :if={edge["reason"]}> · {edge["reason"]}</span><span :if={edge["status"]}> · {edge["status"]}</span></li></ul>
      </details>
    </section>
    """
  end

  attr(:node, :map, default: nil)
  attr(:fallback, :string, required: true)

  @spec reference(map()) :: Phoenix.LiveView.Rendered.t()
  def reference(assigns) do
    node = assigns.node || %{}

    event =
      cond do
        node["type"] == "project" -> "main-chat"
        is_binary(node["task_id"]) and node["missing"] != true -> "select-plan-task"
        true -> nil
      end

    assigns = assign(assigns, label: if(assigns.node, do: node_name(node), else: assigns.fallback), event: event)

    ~H"""
    <button :if={@event} type="button" class="plan-reference" phx-click={@event} phx-value-id={@node["task_id"]} phx-value-work_id={@node["work_id"]} data-plan-reference={@node["id"]}>{@label}</button>
    <span :if={!@event}>{@label}</span>
    """
  end

  defp display_node(%{"type" => "project"} = node, board) do
    project = String.replace_prefix(node["id"], "project:", "")
    label = Enum.find_value(board[:projects] || [], fn entry -> if entry[:id] == project, do: entry[:label] end)
    if label, do: Map.put(node, "name", label), else: node
  end

  defp display_node(node, _board), do: node
  defp shown?(%{"type" => "project"}, _related, _visible), do: true
  defp shown?(%{"type" => "work"} = node, related, visible), do: MapSet.member?(visible, node["task_id"]) or MapSet.member?(related, node["id"])
  defp shown?(node, related, _visible), do: node["visible"] == true or MapSet.member?(related, node["id"])

  defp related_edge?(_edge, nil), do: false
  defp related_edge?(edge, node), do: node["id"] in [edge["source"], edge["target"]]

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
    lines = node_title(node) |> String.split("\n") |> Enum.map(&max(1, div(String.length(&1) + 29, 30))) |> Enum.sum()
    max(@node_height, 72 + lines * 18 + if(node["visible"] == false, do: 18, else: 0))
  end

  defp node_order(node), do: {node["priority"] || 999, node["identifier"] || node["id"]}
  defp diagram_height(nodes), do: Enum.reduce(nodes, 220, fn node, height -> max(height, node.y + node.height + @padding + 44) end)

  defp diagram_width(nodes) do
    Enum.reduce(nodes, @node_width + 2 * @padding, fn node, width -> max(width, node.x + @node_width + @padding + 24) end)
  end

  defp edge_path(edge, nodes) do
    source = Enum.find(nodes, &(&1["id"] == edge["source"]))
    target = Enum.find(nodes, &(&1["id"] == edge["target"]))

    if source && target do
      {from, to} = if edge["type"] == "depends_on", do: {target, source}, else: {source, target}
      curve(from, to, diagram_width(nodes))
    end
  end

  defp curve(from, to, width) do
    x1 = from.x + div(@node_width, 2)
    x2 = to.x + div(@node_width, 2)
    y1 = from.y + from.height
    y2 = to.y

    if from.y >= to.y do
      channel = width - 12
      "M#{from.x + @node_width},#{from.y + div(from.height, 2)} C#{channel},#{from.y + from.height + 24} #{channel},#{to.y + to.height + 24} #{to.x + @node_width},#{to.y + div(to.height, 2)}"
    else
      middle = div(y1 + y2, 2)
      "M#{x1},#{y1} C#{x1},#{middle} #{x2},#{middle} #{x2},#{y2}"
    end
  end

  defp relationship(%{"type" => "depends_on"} = edge, names), do: "#{names[edge["source"]] || edge["source"]} requires #{names[edge["target"]] || edge["target"]}"
  defp relationship(edge, names), do: "#{names[edge["source"]] || edge["source"]} → #{names[edge["target"]] || edge["target"]}"
  defp node_name(node), do: node["identifier"] || node["name"] || node["title"] || node["id"]
  defp node_title(node), do: node["title"] || node["name"] || node["identifier"] || "Untitled"
  defp node_status(%{"missing" => true}), do: "Unavailable"
  defp node_status(%{"planning_status" => "cycle"}), do: "Dependency cycle"
  defp node_status(%{"planning_status" => "blocked"}), do: "Sequence unresolved"
  defp node_status(%{"planning_status" => "unknown"}), do: "Unknown sequence"
  defp node_status(%{"type" => "task"} = node), do: lane_name(node["lane"])
  defp node_status(node), do: node["phase"] || "Supervision"
  defp policy_wait_warning?(warning), do: Regex.match?(~r/\AGH-[1-9][0-9]*: Dependencies require human-accepted Done in this project\.\z/, warning)
  defp completion_description("human_acceptance"), do: "Done records human acceptance."
  defp completion_description("tracker_completion"), do: "Done follows tracker completion."
  defp completion_description(_), do: "Completion policy unavailable."
  defp lane_name("in_progress"), do: "In progress"
  defp lane_name(lane) when lane in @lanes, do: String.capitalize(lane)
  defp lane_name(_), do: "Unknown"
end
