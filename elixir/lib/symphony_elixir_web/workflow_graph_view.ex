defmodule SymphonyElixirWeb.WorkflowGraphView do
  @moduledoc "Interactive read-only task dependency diagram."
  use Phoenix.Component
  alias SymphonyElixirWeb.GraphProjection

  @lanes ~w(backlog work in_progress review done)
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
  attr(:graph_index, :map, default: nil)
  attr(:graph_options, :map, default: %{})

  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    index =
      assigns[:graph_index] || GraphProjection.index(assigns.board, assigns.visible_task_ids)

    projection =
      GraphProjection.project(index, assigns.selected_id, assigns[:graph_options] || %{})

    selected = projection["selected"]
    unresolved = unresolved_level(projection["layout_nodes"])

    layout =
      positions(
        projection["layout_nodes"],
        &(&1["display_step"] || &1["start_step"] || unresolved)
      )

    layout_index = Map.new(layout, &{&1["id"], &1})
    task_positions = Enum.map(projection["nodes"], &layout_index[&1["id"]])

    routing = %{
      nodes: layout,
      by_id: layout_index,
      width: diagram_width(layout),
      row_ends:
        Map.new(Enum.group_by(layout, & &1.y), fn {y, row} ->
          {y, Enum.max(Enum.map(row, &(&1.y + &1.height)))}
        end)
    }

    paths =
      for edge <- projection["edges"],
          d = edge_path(edge, routing),
          not is_nil(d),
          do: %{edge: edge, d: d}

    assigns =
      assign(assigns,
        available: projection["available"],
        reason: projection["reason"],
        policy: get_in(assigns.board, [:workflow_graph, "policy"]),
        selected: selected,
        selection_active: Enum.any?(task_positions, &(selected && &1["id"] == selected["id"])),
        related_ids: projection["related_ids"],
        task_positions: task_positions,
        diagram_width: diagram_width(layout),
        diagram_height: diagram_height(layout),
        paths: paths,
        lanes: @lanes,
        projection: projection,
        options: projection["options"],
        search: projection["search"]
      )

    ~H"""
    <section id="workflow-graph" class="plan-view workflow-graph" phx-hook="WorkflowCanvas" data-canvas-scope={@project || "all"} data-plan-mode="dependencies" data-graph-mode={@options["mode"]} data-graph-group={@options["group"]} data-graph-historical={to_string(!is_nil(@board[:graph_version]))} data-projection-key={projection_key(@options, @board[:graph_version])} data-selected-id={@selected && @selected["id"]} data-selected-task-id={@selected && @selected["task_id"]} aria-label="Task dependencies">
      <div class="plan-toolbar">
        <span class="plan-title">Task dependencies</span>
        <div class="plan-tools" aria-label="Diagram viewport">
          <button type="button" data-canvas-action="out" aria-label="Zoom out">−</button>
          <output data-canvas-zoom aria-label="Diagram zoom">100%</output>
          <button type="button" data-canvas-action="in" aria-label="Zoom in">+</button>
          <button type="button" data-canvas-action="fit">Fit</button>
          <button type="button" data-canvas-action="center" disabled={!@selection_active}>Center selected</button>
        </div>
      </div>
      <p class="plan-caption">Prerequisites → dependent tasks. Priority orders peers. {completion_description(@policy)}</p>
      <p :if={!@available} class="board-warning" role="status">{@reason || "Graph unavailable. The board keeps its last-known tasks."}</p>
      <div :if={@available} class="graph-navigation" aria-label="Dependency navigation">
        <div class="plan-tools graph-modes">
          <button type="button" phx-click="graph-options" phx-value-mode="overview" phx-value-page="0" aria-pressed={to_string(@options["mode"] == "overview")}>Overview</button>
          <button type="button" phx-click="graph-options" phx-value-mode="focus" phx-value-page="0" disabled={is_nil(@selected)} aria-pressed={to_string(@options["mode"] == "focus")}>Focus</button>
          <button :if={@options["group"]} type="button" phx-click="graph-options" phx-value-mode="overview" phx-value-group="" phx-value-page="0">All groups</button>
        </div>
        <form phx-change="graph-options" class="graph-options">
          <label :if={@options["mode"] != "focus"}>Group
            <select name="group_by" aria-label="Group dependencies"><option value="milestone" selected={@options["group_by"] == "milestone"}>Milestone</option><option value="task_kind" selected={@options["group_by"] == "task_kind"}>Task kind</option></select>
          </label>
          <label :if={@options["mode"] == "focus"}>Direction
            <select name="direction" aria-label="Dependency direction"><option value="both" selected={@options["direction"] == "both"}>Both</option><option value="upstream" selected={@options["direction"] == "upstream"}>Prerequisites</option><option value="downstream" selected={@options["direction"] == "downstream"}>Dependents</option></select>
          </label>
          <label :if={@options["mode"] == "focus"}>Depth
            <select name="hops" aria-label="Dependency depth"><option value="1" selected={@options["hops"] == 1}>1 hop</option><option value="2" selected={@options["hops"] == 2}>2 hops</option></select>
          </label>
          <input type="hidden" name="page" value="0" />
          <input :if={is_map(get_in(@board, [:assurance, "tasks"]))} type="hidden" name="gaps_only" value="false" />
          <label :if={is_map(get_in(@board, [:assurance, "tasks"]))} class="graph-gap-filter"><input type="checkbox" name="gaps_only" value="true" checked={@options["gaps_only"]} />Coverage gaps</label>
        </form>
        <div class="graph-search">
          <form phx-change="graph-search" phx-submit="graph-search" role="search"><input id="graph-task-search" type="search" name="query" value={@options["query"]} maxlength="160" phx-debounce="180" placeholder="Find any task…" aria-label="Search all loaded tasks" aria-controls="graph-search-results" /></form>
          <div :if={@options["query"] != ""} id="graph-search-results" class="graph-search-results">
            <span class="graph-search-count" role="status">{@search.total} matching tasks across the loaded graph</span>
            <button :for={node <- @search.results} :key={node["id"]} type="button" phx-click="select-plan-task" phx-value-id={node["task_id"]} phx-value-focus="true" data-graph-search-result disabled={node["missing"] == true}><strong>{node_name(node)}</strong><span>{node_title(node)}</span><small :if={node["visible"] == false}>Outside filters</small></button>
            <div :if={@search.pages > 1} class="plan-tools"><button type="button" phx-click="graph-options" phx-value-search_page={@search.page - 1} disabled={@search.page == 0}>Previous results</button><span>{@search.page + 1}/{@search.pages}</span><button type="button" phx-click="graph-options" phx-value-search_page={@search.page + 1} disabled={@search.page + 1 >= @search.pages}>More results</button></div>
          </div>
        </div>
      </div>
      <div :if={@available} class="graph-summary" role="status">
        <span>{@projection["matching_tasks"]} matching / {@projection["total_tasks"]} loaded tasks · {@projection["total_edges"]} dependencies</span>
        <span :if={@options["mode"] == "overview"}>{length(@task_positions)} groups · open a group to browse its tasks</span>
        <span :if={@options["mode"] != "overview"}>{length(@task_positions)} of {@projection["scope_nodes"]} tasks in this view</span>
        <span :if={@projection["omitted_nodes"] > 0 || @projection["omitted_edges"] > @projection["filtered_edges"]} class="graph-omitted">{@projection["omitted_nodes"]} {if @options["mode"] == "overview", do: "groups", else: "tasks"} and {@projection["omitted_edges"] - @projection["filtered_edges"]} arrows outside this canvas. Select a task to inspect its links. Counts include every prerequisite.</span>
        <span :if={@projection["filtered_edges"] > 0} class="graph-omitted">Dependencies connecting tasks outside filters: {@projection["filtered_edges"]}. Search and focus a task to inspect every prerequisite and dependent.</span>
        <div :if={@projection["pages"] > 1} class="plan-tools"><button type="button" phx-click="graph-options" phx-value-page={@projection["page"] - 1} disabled={@projection["page"] == 0}>Previous</button><span>Page {@projection["page"] + 1}/{@projection["pages"]}</span><button type="button" phx-click="graph-options" phx-value-page={@projection["page"] + 1} disabled={@projection["page"] + 1 >= @projection["pages"]}>Next</button></div>
      </div>
      <div :if={@available} class="plan-main">
        <div id="plan-dependencies-panel" class="plan-panel" data-plan-panel="dependencies">
          <div class="plan-canvas" data-plan-canvas tabindex="0" role="region" aria-label="Task dependencies; drag background to pan, scroll to zoom, F to fit, C to center selected">
            <svg :if={@task_positions != []} class="plan-svg" data-plan-svg data-selection-active={to_string(@selection_active)} data-content-width={@diagram_width} data-content-height={@diagram_height} viewBox={"0 0 #{@diagram_width} #{@diagram_height}"} role="group" aria-label="Task dependencies">
              <title>Task dependencies</title>
              <desc>Arrows go from prerequisite to dependent. Open a group to browse tasks. Select a task node to open its agent; select its title for task details.</desc>
              <defs><marker id="dependencies-arrow" markerWidth="4" markerHeight="4" viewBox="0 0 4 4" refX="4" refY="2" markerUnits="strokeWidth" orient="auto"><path class="plan-edge-arrow" d="M0,0 L4,2 L0,4 Z" fill="context-stroke" /></marker></defs>
              <path :for={path <- @paths} :key={path.edge["id"] || dom_id("plan-edge", path.edge["source"] <> ":" <> path.edge["target"])} id={dom_id("plan-edge", path.edge["id"] || path.edge["source"] <> ":" <> path.edge["target"])} d={path.d} class="plan-edge" data-edge-source={path.edge["source"]} data-edge-target={path.edge["target"]} data-status={path.edge["status"]} data-related={to_string(related_edge?(path.edge, @selected))} vector-effect="non-scaling-stroke" stroke-linecap="round" stroke-linejoin="round" marker-end="url(#dependencies-arrow)"><title>{edge_description(path.edge)}</title></path>
              <g :for={node <- @task_positions} :key={node["id"]} id={dom_id("plan-node", node["id"])} class="plan-node" transform={"translate(#{node.x},#{node.y})"} data-plan-node data-node-id={node["id"]} data-plan-task-id={node["task_id"]} data-plan-visible={to_string(node["visible"] != false)} data-node-x={node.x} data-node-y={node.y} data-node-width="260" data-node-height={node.height} data-depth={node.depth} data-lane={node["lane"]} data-selected={to_string(!is_nil(@selected) && @selected["id"] == node["id"])} data-related={to_string(MapSet.member?(@related_ids, node["id"]))} data-missing={to_string(node["missing"] == true)} data-cycle={to_string(node["cycle"] == true)} data-filtered={to_string(node["visible"] == false)} data-coverage-status={get_in(node, ["coverage", "status"])}>
                <foreignObject width="260" height={node.height}>
                  <div class="plan-node-card">
                    <button :if={node["type"] == "group"} type="button" class="plan-node-select" phx-click="graph-options" phx-value-mode="tasks" phx-value-group={node["group_id"]} phx-value-page="0" aria-label={"Browse #{node["title"]}: #{node["task_count"]} tasks"}></button>
                    <button :if={node["type"] != "group" && !node["missing"]} type="button" class="plan-node-select" aria-description={node["dependency_description"]} aria-pressed={to_string(!is_nil(@selected) && @selected["id"] == node["id"])} phx-click="select-plan-task" phx-value-id={node["task_id"]} aria-label={"Open #{node_name(node)} task agent"}></button>
                    <div class="plan-node-meta"><span>{node_name(node)}</span><span :if={node["priority"]}>P{node["priority"]}</span></div>
                    <button :if={node["task_id"] && !node["missing"]} type="button" class="plan-node-title" phx-click="open-card" phx-value-id={node["task_id"]} title={node_title(node)}>{node_title(node)}</button>
                    <button :if={node["type"] == "group"} type="button" class="plan-node-title" phx-click="graph-options" phx-value-mode="tasks" phx-value-group={node["group_id"]} phx-value-page="0" title={node_title(node)}>{node_title(node)}</button>
                    <span :if={node["type"] != "group" && (!node["task_id"] || node["missing"])} class="plan-node-title" title={node_title(node)}>{node_title(node)}</span>
                    <div class="plan-node-meta"><span>{node_status(node)}</span><span :if={node["task_kind"] && node["task_kind"] != "general"}>{String.capitalize(node["task_kind"])}</span></div>
                    <span :if={node["type"] != "group" && node["graph_error"]} class="plan-node-note">{node["graph_error"]}</span>
                    <span :if={node["type"] != "group" && !node["graph_error"] && node["waiting_count"] > 0} class="plan-node-dependency-status" title={node["waiting_label"]}>{node["waiting_label"]}</span>
                    <span :if={node["type"] == "group"} class="plan-node-context">{node["accepted_count"]} accepted · {node["internal_edges"]} internal dependencies</span>
                    <span :if={node["type"] != "group"} class="plan-node-context">↑{node["upstream_count"] || 0} prerequisites · ↓{node["downstream_count"] || 0} dependents</span>
                    <span :if={is_map(node["coverage"])} class="plan-node-coverage" title={coverage_description(node["coverage"])}>{coverage_label(node["coverage"])}</span>
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

  defp unresolved_level(nodes), do: Enum.reduce(nodes, 0, &max(&1["start_step"] || 0, &2)) + 1
  defp related_edge?(_edge, nil), do: false
  defp related_edge?(edge, node), do: node["id"] in [edge["source"], edge["target"]]

  defp projection_key(options, version) do
    keys =
      if options["mode"] == "focus",
        do: ~w(mode direction hops group_by group anchor page gaps_only),
        else: ~w(mode group_by group page gaps_only)

    to_string(version || "live") <> "|" <> Enum.map_join(keys, ":", &to_string(options[&1]))
  end

  defp edge_description(edge), do: edge["reason"] || "Declared task dependency"

  defp coverage_label(%{"status" => "verified"} = coverage),
    do: "#{coverage["verified_count"] || 0}/#{coverage["criterion_count"] || 0} criteria verified"

  defp coverage_label(%{"status" => "unlinked"}), do: "No criterion linked"
  defp coverage_label(%{"status" => "stale"}), do: "Verification needs refresh"
  defp coverage_label(coverage), do: "#{coverage["gap_count"] || 0} coverage gaps"

  defp coverage_description(coverage),
    do: "#{coverage["verified_count"] || 0} verified of #{coverage["criterion_count"] || 0} linked criteria. #{coverage_label(coverage)}."

  defp positions(nodes, level) do
    rows =
      nodes
      |> Enum.group_by(level)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {depth, members} ->
        columns = if Enum.all?(members, &(&1["type"] == "group")), do: 5, else: 4
        members |> Enum.sort_by(&node_order/1) |> Enum.chunk_every(columns) |> Enum.map(&{depth, &1})
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
            Map.merge(node, %{
              x: offset + column * @column_step,
              y: y,
              height: node_height(node),
              depth: depth
            })
          end)

        {positioned, y + row_height + @row_gap}
      end)

    List.flatten(positions)
  end

  defp node_height(%{"type" => "group"} = node), do: max(110, 88 + wrapped_lines(node_title(node)) * 18)

  defp node_height(node) do
    status_height =
      cond do
        node["graph_error"] -> wrapped_lines(node["graph_error"]) * 16 + 8
        node["waiting_count"] > 0 -> wrapped_lines(node["waiting_label"]) * 16 + 8
        true -> 0
      end

    title_height = wrapped_lines(node_title(node)) * 18
    context_height = if(node["visible"] == false, do: 26, else: 0)

    max(
      @node_height,
      88 + title_height + status_height + context_height +
        if(is_map(node["coverage"]), do: 20, else: 0)
    )
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

  defp diagram_height(nodes),
    do:
      Enum.reduce(nodes, 220, fn node, height ->
        max(height, node.y + node.height + @padding + 44)
      end)

  defp diagram_width(nodes) do
    Enum.reduce(nodes, @node_width + 2 * @padding, fn node, width ->
      max(width, node.x + @node_width + @padding + 24)
    end)
  end

  defp edge_path(edge, routing) do
    source = routing.by_id[edge["source"]]
    target = routing.by_id[edge["target"]]

    if source && target do
      connector(target, source, routing)
    end
  end

  defp connector(from, to, routing) do
    x1 = from.x + div(@node_width, 2)
    x2 = to.x + div(@node_width, 2)
    y1 = from.y + from.height
    y2 = to.y
    channel = routing.width - 12

    cond do
      from.y >= to.y ->
        y1 = from.y + div(from.height * 2, 3)
        y2 = to.y + div(to.height, 3)
        from_x = from.x + @node_width
        to_x = to.x + @node_width
        gap = div(@column_step - @node_width, 2)
        exit_y = routing.row_ends[from.y] + div(@row_gap, 3)
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

      connector_obstructed?(from, to, routing.nodes) ->
        exit_y = routing.row_ends[from.y] + div(@row_gap, 3)
        entry_y = to.y - div(@row_gap, 3)

        rounded_path([
          {x1, y1},
          {x1, exit_y},
          {channel, exit_y},
          {channel, entry_y},
          {x2, entry_y},
          {x2, y2}
        ])

      true ->
        middle = div(y1 + y2, 2)
        rounded_path([{x1, y1}, {x1, middle}, {x2, middle}, {x2, y2}])
    end
  end

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
    do:
      x >= node.x and x <= node.x + @node_width and
        max(first, node.y) < min(last, node.y + node.height)

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
    radius =
      min(10, min(div(distance(before, corner), 2), div(distance(corner, after_corner), 2)))

    {in_x, in_y} = toward(corner, before, radius)
    {out_x, out_y} = toward(corner, after_corner, radius)
    " L#{in_x},#{in_y} Q#{x},#{y} #{out_x},#{out_y}"
  end

  defp distance({x1, y1}, {x2, y2}), do: abs(x2 - x1) + abs(y2 - y1)

  defp toward({x, y}, {target_x, target_y}, amount),
    do: {x + direction(target_x - x) * amount, y + direction(target_y - y) * amount}

  defp direction(value) when value < 0, do: -1
  defp direction(value) when value > 0, do: 1
  defp direction(_), do: 0
  defp dom_id(prefix, id), do: prefix <> "-" <> Base.url_encode64(id, padding: false)
  defp node_name(node), do: node["identifier"] || node["name"] || node["title"] || node["id"]
  defp node_title(node), do: node["title"] || node["name"] || node["identifier"] || "Untitled"
  defp node_status(%{"type" => "group"} = node), do: "#{node["waiting_count"]} waiting · #{node["unresolved_count"]} unresolved"
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
