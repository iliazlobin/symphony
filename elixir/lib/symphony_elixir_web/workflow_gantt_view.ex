defmodule SymphonyElixirWeb.WorkflowGanttView do
  @moduledoc "Calendar timeline with recorded facts and explicitly estimated browser drafts."
  use Phoenix.Component
  alias SymphonyElixirWeb.TaskPresentation
  alias SymphonyElixirWeb.WorkflowPlan

  @day_width 36
  @row_height 54

  attr(:board, :map, required: true)
  attr(:project, :string, default: nil)
  attr(:filters, :map, default: %{})
  attr(:selected_id, :string, default: nil)
  attr(:session, :string, default: nil)
  attr(:visible_task_ids, :any, default: :all)
  attr(:plan_options, :map, default: %{})
  attr(:today, :any, default: nil)

  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    today = assigns.today || Date.utc_today()
    options = Map.put(assigns.plan_options, "context_task_id", assigns.selected_id)
    plan = WorkflowPlan.calendar(assigns.board, assigns.visible_task_ids, today, options)
    selected = Enum.find(plan["nodes"], &(&1["type"] == "task" && !&1["missing"] && (&1["task_id"] == assigns.selected_id or &1["id"] == assigns.selected_id)))
    rows = context_rows(plan["rows"], selected)
    calendar = plan["calendar"]
    start = Date.from_iso8601!(calendar["start_on"])
    days = Enum.to_list(Date.range(start, Date.from_iso8601!(calendar["end_on"])))
    positions = rows |> Enum.with_index() |> Map.new(fn {row, index} -> {row["id"], Map.put(row, "row_index", index)} end)
    dependencies = Enum.filter(plan["edges"], &(&1["type"] == "depends_on"))

    assigns =
      assign(assigns,
        available: plan["available"],
        reason: plan["reason"],
        rows: rows,
        selected: selected,
        calendar: calendar,
        days: days,
        start: start,
        today_offset: Date.diff(today, start),
        min_anchor: Date.to_iso8601(Date.add(today, -365)),
        max_anchor: Date.to_iso8601(Date.add(today, 365)),
        months: date_groups(days, &{&1.year, &1.month}, &Calendar.strftime(&1, "%B %Y")),
        weeks: date_groups(days, &Date.add(&1, 1 - Date.day_of_week(&1)), &Calendar.strftime(Date.add(&1, 1 - Date.day_of_week(&1)), "%b %-d")),
        paths: Enum.flat_map(dependencies, &arrow(&1, positions, start, length(days))),
        width: length(days) * @day_width,
        height: length(rows) * @row_height,
        clipped: Enum.any?(rows, &(is_integer(start_offset(&1, start)) and start_offset(&1, start) < 0))
      )

    ~H"""
    <section id="workflow-gantt" class="plan-view workflow-gantt" phx-hook="WorkflowCanvas" data-canvas-scope={@project || "all"} data-plan-mode="timeline" data-selected-id={@selected_id} data-calendar-scale="day" data-calendar-days={length(@days)} data-calendar-today-offset={@today_offset} aria-label="Task calendar timeline">
      <div class="plan-toolbar plan-calendar-toolbar">
        <strong>Timeline</strong><span class="plan-caption" data-calendar-storage-label>Draft · saved in this browser</span>
        <label class="plan-calendar-anchor">Start <input type="date" data-calendar-anchor value={@calendar["anchor_on"]} min={@min_anchor} max={@max_anchor} aria-label="Draft start date" /></label>
        <div class="plan-calendar-controls" role="group" aria-label="Timeline scale and focus"><button type="button" data-calendar-action="day" aria-pressed="true">Day</button><button type="button" data-calendar-action="week" aria-pressed="false">Week</button><button type="button" data-calendar-action="today">Today</button><button type="button" data-calendar-action="fit">Fit</button></div>
      </div>
      <div class="plan-calendar-legend"><span>Solid: recorded · Dashed: estimate</span><span>1d defaults are assumptions. Dependencies order the draft; capacity and admission remain separate.</span></div>
      <p :if={@clipped} class="plan-caption">Older recorded dates appear at the left edge of this bounded date range.</p>
      <p :if={!@available} class="board-warning" role="status">{@reason}</p>
      <div :if={@available} class="plan-gantt-scroll" tabindex="0" role="region" aria-label="Calendar timeline; scroll to see more dates and tasks">
        <div :if={@rows != []} class="plan-gantt-frame" style={"width:calc(var(--timeline-name-width, 260px) + var(--timeline-day-width, 36px) * #{length(@days)})"}>
          <table class="plan-gantt-table">
            <caption class="sr-only">Dates are UTC. Dashed bars are editable draft estimates, not execution promises. Solid segments show recorded active execution; diamonds show human acceptance. Arrows point from prerequisite to dependent.</caption>
            <thead><tr><th scope="col" class="plan-row-name">Task <span class="plan-caption">· estimate</span></th><th scope="col" class="plan-calendar-header"><div class="plan-calendar-months"><span :for={group <- @months} style={group_style(group)}>{group.title}</span></div><div class="plan-calendar-weeks"><span :for={group <- @weeks} style={group_style(group)}>Week of {group.title}</span></div><div class="plan-calendar-days"><span :for={day <- @days} data-calendar-date={Date.to_iso8601(day)} data-today={to_string(Date.to_iso8601(day) == @calendar["today_on"])} title={Calendar.strftime(day, "%A, %B %-d, %Y")}>{day.day}</span></div></th></tr></thead>
            <tbody><tr :for={row <- @rows} id={dom_id("gantt-row", row["id"])} data-plan-task-id={row["task_id"]} data-plan-visible={to_string(row["visible"])} data-selected={to_string(!is_nil(@selected) && @selected["id"] == row["id"])} data-lane={row["lane"]} data-timeline-kind={row["timeline"]["kind"]}>
              <th scope="row" class="plan-row-name">
                <div class="plan-row-heading"><span class={"lane-dot lane-dot-#{row["lane"]}"} title={lane_name(row["lane"])} aria-label={lane_name(row["lane"])}></span><button type="button" class="plan-row-title" phx-click="open-card" phx-value-id={row["task_id"]} title={row_title(row)}>{row["title"] || row["identifier"]}</button><label :if={row["lane"] != "done"} class="plan-calendar-estimate"><input type="number" min="1" max="365" value={row["timeline"]["duration_days"] || 1} data-calendar-duration data-calendar-task-id={row["task_id"]} aria-label={"Estimated days for #{row["identifier"] || row["title"]}"} />d</label></div>
                <TaskPresentation.identity class="plan-node-meta" identifier={row["identifier"]} url={row["url"]} kind={row["task_kind"]} priority={row["priority"]}>
                  <TaskPresentation.dependencies task_id={row["task_id"]} identifier={row["identifier"]} upstream={row["upstream_count"] || 0} downstream={row["downstream_count"] || 0} filters={@filters} session={if row["task_id"] == @selected_id, do: @session} />
                </TaskPresentation.identity>
                <span :if={row["visible"] == false} class="sr-only">Outside filters</span>
              </th>
              <td class="plan-gantt-track">
                <button type="button" class={if row["timeline"]["kind"] == "unscheduled", do: "plan-gantt-unresolved", else: "plan-gantt-bar"} style={bar_style(row, @start, length(@days))} phx-click="select-plan-task" phx-value-id={row["task_id"]} aria-pressed={to_string(!is_nil(@selected) && @selected["id"] == row["id"])} aria-label={bar_label(row)} aria-description={row["dependency_description"]} title={bar_label(row)} data-planning-status={row["planning_status"]} data-timeline-kind={row["timeline"]["kind"]} data-timeline-start-offset={start_offset(row, @start)} data-timeline-days={row["timeline"]["duration_days"]}>
                  <span :if={row["timeline"]["kind"] == "running"} class="plan-gantt-recorded" style={recorded_style(row, @start)} aria-hidden="true"></span><span class="plan-gantt-label">{bar_status(row)}</span>
                </button>
              </td>
            </tr></tbody>
          </table>
          <div class="plan-calendar-today" style={"left:calc(var(--timeline-name-width, 260px) + var(--timeline-day-width, 36px) * #{@today_offset})"} aria-hidden="true"><span>Today</span></div>
          <svg class="plan-gantt-arrows" width={@width} height={@height} viewBox={"0 0 #{@width} #{@height}"} preserveAspectRatio="none" aria-hidden="true"><defs><marker id="gantt-arrow" markerWidth="4" markerHeight="4" refX="3" refY="2" orient="auto"><path d="M0,0 L4,2 L0,4" /></marker></defs><path :for={path <- @paths} id={dom_id("gantt-edge", path.edge["id"] || path.edge["source"] <> ":" <> path.edge["target"])} data-edge-source={path.edge["source"]} data-edge-target={path.edge["target"]} d={path.d} class="plan-edge" data-status={path.edge["status"]} data-related={to_string(related?(path.edge, @selected))} vector-effect="non-scaling-stroke" marker-end="url(#gantt-arrow)" /></svg>
        </div>
        <p :if={@rows == []} class="plan-empty">No matching tasks. Describe a task to the project agent or adjust filters.</p>
      </div>
    </section>
    """
  end

  defp context_rows(rows, %{"visible" => false} = selected), do: [selected | rows]
  defp context_rows(rows, _selected), do: rows

  defp lane_name("in_progress"), do: "In progress"
  defp lane_name(lane) when is_binary(lane), do: String.capitalize(lane)
  defp lane_name(_lane), do: "Unknown"
  defp milestone_title(%{"milestone" => %{"title" => title}}) when is_binary(title), do: title
  defp milestone_title(_row), do: nil
  defp row_title(row), do: Enum.join(Enum.filter([row["title"] || row["identifier"], milestone_title(row)], &is_binary/1), " · ")
  defp group_style(group), do: "width:calc(var(--timeline-day-width, 36px) * #{group.days})"

  defp date_groups(days, key, title) do
    days |> Enum.chunk_by(key) |> Enum.map(fn group -> %{title: title.(hd(group)), days: length(group)} end)
  end

  defp start_offset(%{"timeline" => %{"start_on" => nil}}, _start), do: nil
  defp start_offset(row, start), do: Date.diff(Date.from_iso8601!(row["timeline"]["start_on"]), start)

  defp bar_style(%{"timeline" => %{"kind" => "unscheduled"}}, _start, _days), do: nil

  defp bar_style(row, start, days) do
    first = max(0, start_offset(row, start))
    finish = min(days, Date.diff(Date.from_iso8601!(row["timeline"]["end_on"]), start))

    if row["timeline"]["kind"] == "accepted",
      do: "left:calc(var(--timeline-day-width, 36px) * #{first} + 8px);width:20px",
      else: "left:calc(var(--timeline-day-width, 36px) * #{first} + 3px);width:calc(var(--timeline-day-width, 36px) * #{max(1, finish - first)} - 6px)"
  end

  defp recorded_style(row, start) do
    observed = Date.from_iso8601!(row["timeline"]["observed_through_on"])
    days = Date.diff(observed, start) - max(0, start_offset(row, start))
    if days > 0, do: "width:calc(var(--timeline-day-width, 36px) * #{days} - 6px)", else: "width:0px"
  end

  defp bar_status(%{"timeline" => %{"kind" => "accepted"}}), do: "◇"
  defp bar_status(%{"timeline" => %{"kind" => "running", "duration_days" => duration}}), do: "~#{duration}d left"
  defp bar_status(%{"timeline" => %{"kind" => "draft", "duration_days" => duration}}), do: "~#{duration}d"
  defp bar_status(%{"planning_status" => "cycle"}), do: "Revise cycle"
  defp bar_status(%{"planning_status" => "unknown"}), do: "Check prerequisites"
  defp bar_status(%{"planning_status" => "blocked"}), do: "Check prerequisites"
  defp bar_status(_row), do: "Unscheduled"

  defp bar_label(row) do
    timing = row["timeline"]
    interval = timing_label(timing)
    "#{row["identifier"]}: #{row["title"]}; #{lane_name(row["lane"])}; #{timing["kind"]}; #{interval}; #{bar_status(row)}"
  end

  defp timing_label(%{"kind" => "accepted", "start_on" => date}), do: "Accepted on #{date}"

  defp timing_label(%{"kind" => "running"} = timing),
    do: "Recorded start #{timing["start_on"]}; observed through #{timing["observed_through_on"]}; estimated finish #{timing["end_on"]} (exclusive)"

  defp timing_label(%{"kind" => "draft"} = timing), do: "Estimated #{timing["start_on"]} → #{timing["end_on"]} (exclusive)"
  defp timing_label(timing), do: timing["reason"]

  defp dom_id(prefix, id), do: prefix <> "-" <> Base.url_encode64(id, padding: false)
  defp related?(_edge, nil), do: false
  defp related?(edge, selected), do: selected["id"] in [edge["source"], edge["target"]]

  defp arrow(edge, positions, start, days) do
    from = positions[edge["target"]]
    to = positions[edge["source"]]

    if from && to && from["timeline"]["start_on"] && to["timeline"]["start_on"] do
      x1 = endpoint(from, start, days, :finish)
      x2 = endpoint(to, start, days, :start)
      y1 = from["row_index"] * @row_height + div(@row_height, 2)
      y2 = to["row_index"] * @row_height + div(@row_height, 2)
      middle = div(y1 + y2, 2)
      points = [{x1, y1}, {x1 + 10, y1}, {x1 + 10, middle}, {x2 - 10, middle}, {x2 - 10, y2}, {x2, y2}]
      [%{edge: edge, d: rounded_path(points)}]
    else
      []
    end
  end

  defp endpoint(row, start, days, side) do
    offset = if side == :finish, do: Date.diff(Date.from_iso8601!(row["timeline"]["end_on"]), start), else: start_offset(row, start)

    if row["timeline"]["kind"] == "accepted",
      do: min(days - 1, max(0, start_offset(row, start))) * @day_width + if(side == :finish, do: 28, else: 8),
      else: min(days, max(0, offset)) * @day_width + if(side == :finish, do: -3, else: 3)
  end

  defp rounded_path(points) do
    {x, y} = hd(points)
    corners = points |> Enum.chunk_every(3, 1, :discard) |> Enum.map_join(" ", &rounded_corner/1)
    {last_x, last_y} = List.last(points)
    "M#{x},#{y} #{corners} L#{last_x},#{last_y}"
  end

  defp rounded_corner([previous, {x, y} = current, next]) do
    radius = min(3, min(distance(current, previous), distance(current, next)) / 2)
    {before_x, before_y} = towards(current, previous, radius)
    {after_x, after_y} = towards(current, next, radius)
    "L#{before_x},#{before_y} Q#{x},#{y} #{after_x},#{after_y}"
  end

  defp distance({x, y}, {other_x, other_y}), do: abs(x - other_x) + abs(y - other_y)

  defp towards({x, y} = current, {other_x, other_y} = target, radius) do
    size = max(1, distance(current, target))
    {x + (other_x - x) * radius / size, y + (other_y - y) * radius / size}
  end
end
