defmodule SymphonyElixirWeb.WorkflowGanttViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.WorkflowGanttView

  @today ~D[2026-10-03]

  test "calendar shows real date columns, editable draft estimates and recorded acceptance" do
    nodes = [task(1, "done", %{"milestone" => %{"title" => "Launch"}}), task(2, "work", %{"priority" => 1, "task_kind" => "testing"}), task(3, "review", %{"priority" => 3})]
    source = [%{id: "issue:1", acceptance: %{"accepted_at" => "2026-10-01T10:00:00Z"}}]
    html = draw(nodes, [dep(2, 1), dep(3, 1)], selected_id: "issue:2", tasks: source)
    assert html =~ "Task calendar timeline"
    assert html =~ "Draft · saved in this browser"
    assert html =~ "1d defaults are assumptions"
    assert html =~ "October 2026"
    assert html =~ "Week of Sep 21"
    assert html =~ "data-calendar-date=\"2026-10-03\""
    assert html =~ "data-today=\"true\""
    assert html =~ "data-calendar-anchor"
    assert html =~ "data-calendar-action=\"week\""
    assert html =~ "data-calendar-action=\"today\""
    assert html =~ "data-calendar-action=\"fit\""
    assert html =~ "Launch"
    assert html =~ "Testing"
    assert html =~ "P1"
    assert html =~ "~1d"
    assert length(find(html, "[data-calendar-duration]")) == 2
    assert length(find(html, "[data-timeline-kind=accepted]")) == 2
    assert length(find(html, ".plan-gantt-arrows .plan-edge")) == 2
    assert Enum.all?(Floki.attribute(find(html, ".plan-gantt-arrows .plan-edge"), "d"), &(String.contains?(&1, " Q") and not String.contains?(&1, " C")))
    assert length(find(html, ".plan-edge[data-related=true]")) == 1
    assert length(find(html, "tr[data-selected=true]")) == 1
    assert html =~ "vector-effect=\"non-scaling-stroke\""
    assert html =~ "preserveAspectRatio=\"none\""
    refute html =~ "Step 1"
    refute html =~ "data-task-id="
    assert html =~ "phx-click=\"select-plan-task\""
    assert html =~ "phx-click=\"open-card\""
    assert find(html, ".plan-inspector, [data-board-view-link]") == []
    assert find(html, ".plan-accessible-list") == []
    refute html =~ "Text view"
    refute html =~ "dependency notice"
  end

  test "filtered prerequisites remain honest context without visible arrows or inflated matching rows" do
    html = draw([task(1, "work"), task(2, "work")], [dep(2, 1)], visible_task_ids: ["issue:2"], selected_id: "issue:2")
    assert length(find(html, "tbody tr")) == 1
    assert html =~ "data-timeline-start-offset=\"8\""
    assert Floki.attribute(find(html, ".plan-gantt-bar"), "aria-description") == ["Prerequisite GH-1: awaiting acceptance"]
    assert find(html, ".plan-gantt-arrows .plan-edge") == []
    assert find(html, ".plan-accessible-list") == []
  end

  test "timeline resource links preserve internal details, selection and draft estimates" do
    url = "https://github.com/example/fixture/issues/19"
    html = draw([task(19, "work", %{"url" => url})], [], selected_id: "issue:19", plan_options: %{"durations" => %{"issue:19" => 3}})
    link = find(html, ".plan-node-meta a")
    assert Floki.attribute(link, "href") == [url]
    assert Floki.attribute(link, "target") == ["_blank"]
    assert Floki.attribute(link, "rel") == ["noopener noreferrer"]
    assert Floki.attribute(link, "aria-label") == ["Open GH-19 in the issue tracker"]
    assert Floki.text(link) == "GH-19"
    assert Floki.attribute(link, "phx-click") == []
    assert length(find(html, "tr[data-selected=true]")) == 1
    assert Floki.attribute(find(html, ".plan-row-title"), "phx-click") == ["open-card"]
    assert Floki.attribute(find(html, "[data-calendar-duration]"), "value") == ["3"]
  end

  test "missing or unsafe timeline resource URLs remain plain text" do
    for url <- [
          nil,
          %{},
          "javascript:alert(1)",
          "//example.com/issues/1",
          "https://user:secret@example.com/1",
          "https://example.com\\@evil.com/1",
          "https://example.com/\n1",
          "https://example.com/\u00001",
          "https://[broken/1"
        ] do
      html = draw([task(1, "work", %{"url" => url})], [])
      assert find(html, ".plan-node-meta a") == []
      assert Floki.text(find(html, ".plan-node-meta")) =~ "GH-1"
      assert length(find(html, "[data-calendar-duration]")) == 1
    end
  end

  test "selected filtered task stays visible and expands the calendar bounds without changing filters" do
    options = %{"durations" => %{"issue:1" => 60, "issue:2" => 30}}
    html = draw([task(1, "work"), task(2, "work")], [dep(2, 1)], visible_task_ids: [], selected_id: "issue:2", plan_options: options)
    assert length(find(html, "tbody tr[data-selected=true][data-plan-visible=false]")) == 1
    assert html =~ "Outside filters"
    assert html =~ "data-calendar-date=\"2027-01-01\""
    assert html =~ "~30d"
    assert html =~ "data-calendar-days=\"98\""
  end

  test "cycles and missing prerequisites show inline fixes without fictitious dated bars" do
    nodes = [task(1, "work"), task(2, "work"), task(3, "review"), task(4, "backlog", %{"dependency_error" => "Invalid prerequisite."}), task(5, "work"), task(999, "unknown", %{"missing" => true})]
    edges = [dep(1, 2), dep(2, 1), dep(3, 1), dep(5, 999)]
    html = draw(nodes, edges, selected_id: "task:4", warnings: ["Revise cycle"])
    assert html =~ "Revise cycle"
    assert html =~ "Check prerequisites"
    assert html =~ "Revise the declared prerequisites"
    assert length(find(html, ".plan-gantt-unresolved")) == 5
    assert find(html, ".plan-gantt-arrows .plan-edge") == []
    assert find(html, ".plan-warnings") == []
    refute html =~ "Step 1"
  end

  test "unfocused calendar arrows stay neutral and invalid relations remain actionable" do
    html = draw([task(1, "work"), task(2, "work")], [dep(2, 1)], [])
    assert length(find(html, ".plan-edge[data-related=false]")) == 1
    assert find(html, ".plan-inspector") == []

    edges = Enum.map([dep(1, 2), dep(2, 1)], &Map.put(&1, "status", "cycle"))
    html = draw([task(1, "work"), task(2, "work")], edges, selected_id: "issue:1")
    assert Floki.text(find(html, ".plan-gantt-unresolved")) =~ "Revise cycle"
    assert find(html, ".plan-gantt-arrows .plan-edge") == []

    missing = task(999, "unknown", %{"missing" => true})
    html = draw([task(1, "work"), missing], [Map.put(dep(1, 999), "status", "unknown")], selected_id: "issue:1")
    assert Floki.text(find(html, ".plan-gantt-unresolved")) =~ "Check prerequisites"
    assert find(html, ".plan-gantt-arrows .plan-edge") == []
  end

  test "running spans distinguish recorded start from estimated remaining days" do
    source = [%{id: "issue:1", issue_id: "1", runtime: %{issue_id: "1", status: "running", started_at: "2026-10-01T10:00:00Z"}}]
    html = draw([task(1, "in_progress", %{"execution_status" => "running"})], [], selected_id: "issue:1", tasks: source, plan_options: %{"durations" => %{"issue:1" => 3}})
    assert html =~ "~3d left"
    assert html =~ "Recorded start 2026-10-01; observed through 2026-10-03; estimated finish 2026-10-06"
    assert length(find(html, ".plan-gantt-recorded")) == 1
    assert html =~ "In progress"
    assert html =~ "Estimated days for GH-1"

    default = draw([task(1, "in_progress", %{"execution_status" => "running"})], [], tasks: source)
    assert default =~ "~1d left"
    assert Floki.attribute(find(default, ".plan-gantt-recorded"), "style") == ["width:calc(var(--timeline-day-width, 36px) * 2 - 6px)"]

    same_day = [%{hd(source) | runtime: %{issue_id: "1", status: "running", started_at: "2026-10-03T10:00:00Z"}}]
    today = draw([task(1, "in_progress", %{"execution_status" => "running"})], [], tasks: same_day)
    assert Floki.attribute(find(today, ".plan-gantt-recorded"), "style") == ["width:0px"]
  end

  test "old recorded acceptance is clipped explicitly without turning it into work duration" do
    source = [%{id: "issue:1", acceptance: %{"accepted_at" => "2000-01-01T10:00:00Z"}}]
    html = draw([task(1, "done")], [], selected_id: "issue:1", tasks: source)
    assert html =~ "Older recorded dates appear at the left edge"
    assert html =~ "2000-01-01"
    assert html =~ "width:20px"
    assert find(html, "[data-calendar-duration]") == []
  end

  test "no matches and incomplete observations have clear fallbacks" do
    html = render_component(&WorkflowGanttView.content/1, board: %{}, today: @today)
    assert html =~ "Planning data is incomplete"
    refute html =~ "<table"
    html = draw([], [], visible_task_ids: [])
    assert html =~ "No matching tasks"
    refute html =~ "<table"
  end

  test "untrusted titles remain escaped and complete" do
    title = "<script>alert()</script> " <> String.duplicate("Long name ", 30)
    html = draw([task(1, nil, %{"title" => title, "task_kind" => nil})], [], selected_id: "issue:1")
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;alert()"
    assert html =~ String.trim(title |> String.replace("<script>", "&lt;script&gt;") |> String.replace("</script>", "&lt;/script&gt;"))
    assert html =~ "General"
    assert html =~ "Unknown"
    assert Floki.attribute(find(html, ".plan-row-title"), "title") == [title]
    assert find(html, ".plan-inspector, [data-board-view-link]") == []
    html = draw([task(1, "work"), task(2, "review")], [Map.merge(dep(2, 1), %{"reason" => "<img onerror=bad()>", "kind" => "technical", "status" => "satisfied"})], selected_id: "issue:1")
    assert Floki.attribute(find(html, "tr[data-plan-task-id='issue:2'] .plan-gantt-bar"), "aria-description") == ["Prerequisite GH-1: accepted (technical: <img onerror=bad()>)"]
    refute html =~ "<img onerror"
  end

  test "Today stays current while a stale snapshot bounds recorded execution" do
    graph = %{"version" => 1, "nodes" => [task(1, "in_progress", %{"execution_status" => "running"})], "edges" => []}
    source = [%{id: "issue:1", issue_id: "1", runtime: %{status: "running", issue_id: "1", started_at: "2026-10-01T10:00:00Z"}}]
    board = %{workflow_graph: graph, tasks: source, generated_at: "2026-10-02T23:00:00Z"}
    html = render_component(&WorkflowGanttView.content/1, board: board, today: @today)
    assert html =~ "value=\"2026-10-03\""
    assert html =~ "data-calendar-date=\"2026-10-03\" data-today=\"true\""
    assert html =~ "observed through 2026-10-02"
    assert html =~ "estimated finish 2026-10-04"
    assert Floki.attribute(find(html, ".plan-gantt-recorded"), "style") == ["width:calc(var(--timeline-day-width, 36px) * 1 - 6px)"]

    for generated <- [nil, "bad", "2020-01-01T00:00:00Z"] do
      html = render_component(&WorkflowGanttView.content/1, board: %{workflow_graph: graph, generated_at: generated})
      assert html =~ "value=\"#{Date.to_iso8601(Date.utc_today())}\""
    end
  end

  defp task(id, lane, extra \\ %{}),
    do: Map.merge(%{"id" => "task:#{id}", "task_id" => "issue:#{id}", "type" => "task", "identifier" => "GH-#{id}", "title" => "Task #{id}", "lane" => lane, "task_kind" => "general"}, extra)

  defp dep(source, target), do: %{"source" => "task:#{source}", "target" => "task:#{target}", "type" => "depends_on", "status" => "waiting"}

  defp draw(nodes, edges, opts) do
    {warnings, opts} = Keyword.pop(opts, :warnings, [])
    {source, opts} = Keyword.pop(opts, :tasks, [])
    graph = %{"version" => 1, "nodes" => nodes, "edges" => edges, "warnings" => warnings}

    render_component(
      &WorkflowGanttView.content/1,
      Keyword.merge([board: %{workflow_graph: graph, tasks: source}, today: @today, visible_task_ids: Enum.flat_map(nodes, &if(&1["missing"], do: [], else: [&1["task_id"]]))], opts)
    )
  end

  defp find(html, selector), do: html |> Floki.parse_fragment!() |> Floki.find(selector)
end
