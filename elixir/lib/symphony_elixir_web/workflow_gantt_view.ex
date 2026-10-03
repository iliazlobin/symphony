defmodule SymphonyElixirWeb.WorkflowGanttView do
  @moduledoc "Read-only dependency sequence. Display slots never imply dates or duration."
  use Phoenix.Component
  alias SymphonyElixirWeb.{WorkflowGraphView, WorkflowPlan}

  @step_width 190
  @row_height 88

  attr(:board, :map, required: true)
  attr(:project, :string, default: nil)
  attr(:filters, :map, default: %{})
  attr(:selected_id, :string, default: nil)
  attr(:visible_task_ids, :any, default: :all)

  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    plan = WorkflowPlan.project(assigns.board, assigns.visible_task_ids)
    selected = Enum.find(plan["nodes"], &(&1["type"] == "task" && !&1["missing"] && (&1["task_id"] == assigns.selected_id or &1["id"] == assigns.selected_id)))
    rows = context_rows(plan["rows"], selected)
    unresolved = Enum.any?(rows, &is_nil(&1["start_step"]))
    steps = Enum.reduce(rows, 0, &max(&1["end_step"] || 0, &2))
    columns = max(1, steps + if(unresolved, do: 1, else: 0))
    positions = rows |> Enum.with_index() |> Map.new(fn {row, index} -> {row["id"], Map.put(row, "row_index", index)} end)
    dependencies = Enum.filter(plan["edges"], &(&1["type"] == "depends_on"))
    paths = Enum.flat_map(dependencies, &arrow(&1, positions))
    names = Map.new(plan["nodes"], &{&1["id"], &1["identifier"] || &1["title"] || &1["id"]})
    related = Enum.filter(dependencies, &related?(&1, selected))

    assigns =
      assign(assigns,
        available: plan["available"],
        reason: plan["reason"],
        rows: rows,
        selected: selected,
        steps: steps,
        columns: columns,
        unresolved: unresolved,
        paths: paths,
        dependencies: dependencies,
        related: related,
        names: names,
        by_id: Map.new(plan["nodes"], &{&1["id"], &1}),
        width: columns * @step_width,
        height: length(rows) * @row_height,
        warnings: plan["warnings"]
      )

    ~H"""
    <section id="workflow-gantt" class="plan-view workflow-gantt" phx-hook="WorkflowCanvas" data-canvas-scope={@project || "all"} data-plan-mode="timeline" data-selected-id={@selected_id} aria-label="Task dependency sequence">
      <div class="plan-toolbar"><strong>Dependency sequence</strong><span class="plan-caption">Relative steps · dates and duration are not estimated</span></div>
      <p class="plan-caption">Tasks in the same step can be eligible together. Priority orders peers; scheduling still checks dependencies, capacity and holds.</p>
      <p :if={!@available} class="board-warning" role="status">{@reason || "Sequence unavailable. The board keeps its last-known tasks."}</p>
      <details :if={@warnings != []} class="plan-warnings"><summary>{length(@warnings)} dependency {if length(@warnings) == 1, do: "notice", else: "notices"}</summary><ul><li :for={warning <- @warnings}>{warning}</li></ul></details>
      <div :if={@available} class="plan-gantt-scroll" tabindex="0" role="region" aria-label="Dependency sequence; scroll to see more tasks and steps">
        <div :if={@rows != []} class="plan-gantt-frame" style={"width:#{@width + 280}px"}>
          <table class="plan-gantt-table">
            <caption class="sr-only">Each bar is one dependency display slot, not a duration. Arrows point from prerequisite to dependent. Select a bar for its agent, or its title for task details.</caption>
            <thead><tr><th scope="col" class="plan-row-name">Task</th><th scope="col" class="plan-gantt-steps"><div style={"width:#{@width}px"}><span :for={step <- step_range(@steps)}>Step {step + 1}</span><span :if={@unresolved}>Needs attention</span><span :if={@steps == 0 && !@unresolved}>No sequence</span></div></th></tr></thead>
            <tbody><tr :for={row <- @rows} data-plan-task-id={row["task_id"]} data-plan-visible={to_string(row["visible"])} data-selected={to_string(!is_nil(@selected) && @selected["id"] == row["id"])} data-lane={row["lane"]}>
              <th scope="row" class="plan-row-name">
                <button type="button" class="plan-row-title" phx-click="open-card" phx-value-id={row["task_id"]} title={row["title"]}>{row["title"] || row["identifier"]}</button>
                <div class="plan-node-meta"><span>{row["identifier"]}</span><span :if={row["priority"]}>P{row["priority"]}</span><span>{kind_name(row["task_kind"])}</span><span :if={row["visible"] == false} class="plan-node-context">Outside filters</span></div>
                <div :if={milestone_title(row)} class="plan-row-milestone" title={milestone_title(row)}>{milestone_title(row)}</div>
              </th>
              <td class="plan-gantt-track" style={"width:#{@width}px"}>
                <button type="button" class={if is_nil(row["start_step"]), do: "plan-gantt-unresolved", else: "plan-gantt-bar"} style={slot_style(row, @steps)} phx-click="select-plan-task" phx-value-id={row["task_id"]} aria-label={bar_label(row)} title={bar_label(row)} data-planning-status={row["planning_status"]}>
                  <span class={"lane-dot lane-dot-#{row["lane"]}"} aria-hidden="true"></span><span>{bar_status(row)}</span>
                  <small :if={row["upstream_outside_filter"] > 0}>{row["upstream_outside_filter"]} outside filters</small>
                  <small :if={row["upstream_unknown"] > 0}>{row["upstream_unknown"]} unavailable</small>
                </button>
              </td>
            </tr></tbody>
          </table>
          <svg class="plan-gantt-arrows" width={@width} height={@height} viewBox={"0 0 #{@width} #{@height}"} aria-hidden="true">
            <defs><marker id="gantt-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8" /></marker></defs>
            <path :for={path <- @paths} d={path.d} class="plan-edge" data-status={path.edge["status"]} data-related={to_string(related?(path.edge, @selected))} marker-end="url(#gantt-arrow)" />
          </svg>
        </div>
        <p :if={@rows == []} class="plan-empty">No matching tasks. Describe a task to the project agent or adjust filters.</p>
      </div>
      <aside :if={@available && @selected} class="plan-inspector" aria-label="Selected task dependencies">
        <h3>{@selected["identifier"]} · {@selected["title"]}</h3>
        <p>{@selected["upstream_count"]} prerequisites · {@selected["downstream_count"]} dependents</p>
        <p :if={@selected["dependency_error"]}>{@selected["dependency_error"]}</p>
        <ul><li :for={edge <- @related}><WorkflowGraphView.reference node={@by_id[edge["source"]]} fallback={edge["source"]} /> requires <WorkflowGraphView.reference node={@by_id[edge["target"]]} fallback={edge["target"]} /><span :if={edge["reason"]}> · {edge["reason"]}</span><span :if={edge["status"]}> · {edge["status"]}</span></li></ul>
        <p :if={@related == []}>No declared dependencies.</p>
        <div class="plan-inspector-links"><button type="button" phx-click="switch-view" phx-value-view="kanban" phx-value-id={@selected["task_id"]} data-board-view-link="kanban" data-board-view-task={@selected["task_id"]}>Show on board</button><button type="button" phx-click="switch-view" phx-value-view="graph" phx-value-id={@selected["task_id"]} data-board-view-link="graph" data-board-view-task={@selected["task_id"]}>Show graph</button></div>
      </aside>
      <details :if={@available} class="plan-accessible-list"><summary>Text view · {length(@dependencies)} dependencies</summary><p :if={@dependencies == []}>No declared dependencies.</p><ul><li :for={edge <- @dependencies}>{relationship(edge, @names)}<span :if={edge["kind"]}> · {edge["kind"]}</span><span :if={edge["reason"]}> · {edge["reason"]}</span><span :if={edge["status"]}> · {edge["status"]}</span></li></ul></details>
    </section>
    """
  end

  defp context_rows(rows, %{"visible" => false} = selected) do
    [selected | rows] |> Enum.sort_by(&{&1["start_step"] || 999_999, &1["priority"] || 999, &1["identifier"] || &1["id"]})
  end

  defp context_rows(rows, _selected), do: rows

  defp step_range(0), do: []
  defp step_range(steps), do: 0..(steps - 1)
  defp kind_name(kind) when is_binary(kind), do: String.capitalize(kind)
  defp kind_name(_), do: "General"
  defp milestone_title(%{"milestone" => %{"title" => title}}) when is_binary(title), do: title
  defp milestone_title(_), do: nil
  defp slot_style(row, steps), do: "left:#{(row["start_step"] || steps) * @step_width + 24}px;width:#{@step_width - 48}px"
  defp bar_status(%{"planning_status" => "cycle"}), do: "Dependency cycle"
  defp bar_status(%{"planning_status" => "unknown"}), do: "Unknown prerequisites"
  defp bar_status(%{"planning_status" => "blocked"}), do: "Sequence unresolved"
  defp bar_status(%{"lane" => "in_progress"}), do: "In progress"
  defp bar_status(row), do: String.capitalize(row["lane"] || "unknown")
  defp bar_label(row), do: "#{row["identifier"]}: #{row["title"]}; #{if is_nil(row["start_step"]), do: "not sequenced", else: "Step #{row["start_step"] + 1}"}; #{bar_status(row)}"
  defp related?(_edge, nil), do: false
  defp related?(edge, selected), do: selected["id"] in [edge["source"], edge["target"]]
  defp relationship(edge, names), do: "#{names[edge["source"]] || edge["source"]} requires #{names[edge["target"]] || edge["target"]}"

  defp arrow(edge, positions) do
    from = positions[edge["target"]]
    to = positions[edge["source"]]

    if from && to && is_integer(from["start_step"]) && is_integer(to["start_step"]) do
      x1 = from["end_step"] * @step_width - 24
      x2 = to["start_step"] * @step_width + 24
      y1 = from["row_index"] * @row_height + div(@row_height, 2)
      y2 = to["row_index"] * @row_height + div(@row_height, 2)
      middle = div(x1 + x2, 2)
      [%{edge: edge, d: "M#{x1},#{y1} C#{middle},#{y1} #{middle},#{y2} #{x2},#{y2}"}]
    else
      []
    end
  end
end
