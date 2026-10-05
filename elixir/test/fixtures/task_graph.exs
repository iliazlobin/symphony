defmodule SymphonyElixirWeb.TaskGraphFixture do
  @moduledoc false

  alias SymphonyElixir.{TaskIdentity, TaskRouting}
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixirWeb.{TaskBoard, WorkflowGraph}
  @preview_label "Synthetic scale preview · execution disabled"

  def board do
    nodes = Enum.map(1..1_000, &task/1)
    hub = Enum.map(2..401, &dep(1, &1))

    dependencies =
      for source <- 401..999,
          factor <- 1..3,
          do: dep(source, rem(source * factor, 300) + 1, factor)

    chain = Enum.map(3..803, &dep(&1, &1 - 1))

    %{
      workflow_graph: %{
        "version" => 1,
        "nodes" => nodes,
        "edges" => hub ++ dependencies ++ chain ++ [dep(998, 999), dep(999, 998)],
        "policy" => "human_acceptance"
      }
    }
  end

  # Complete board for the endpoint-only preview. This deliberately exceeds the
  # tracker admission limit at its 400-prerequisite hub; it is presentation data,
  # never a fixture accepted by the scheduler or native task intake.
  def preview_board(settings, topology \\ :dag) do
    tracker = settings.tracker

    issues =
      Enum.map(1..1_000, fn id ->
        %Issue{
          id: to_string(id),
          identifier: "GH-#{id}",
          title: "Synthetic task #{id}",
          description: "Synthetic navigation fixture.\nDepends on: none",
          state: "open",
          priority: rem(id, 4) + 1,
          labels: ["ready", if(rem(id, 3) == 0, do: "kind:delivery", else: "kind:security"), "preview"],
          dispatchable: true,
          native_ref: %{"repo" => tracker.provider["repo"]},
          milestone: %{id: to_string(rem(id, 20) + 1), title: "Milestone #{rem(id, 20) + 1}", state: "open", url: nil}
        }
      end)

    control = %{
      "enabled" => false,
      "mode" => "paused",
      "revision" => 0,
      "fault" => nil,
      "tracker_fingerprint" => TaskRouting.fingerprint(tracker),
      "issues" => %{},
      "reservations" => %{}
    }

    runtime = %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      rate_limits: nil
    }

    base = TaskBoard.project(issues, runtime, control, settings)
    project = TaskIdentity.project_id(tracker)

    edges =
      Enum.map(preview_edges(topology), fn edge ->
        source = String.replace_prefix(edge["source"], "task:", "")
        target = String.replace_prefix(edge["target"], "task:", "")

        edge
        |> Map.put("source", "task:" <> project <> ":" <> source)
        |> Map.put("target", "task:" <> project <> ":" <> target)
        |> Map.merge(%{
          "kind" => "technical",
          "blocking" => true,
          "satisfaction" => "human_acceptance",
          "evidence" => %{}
        })
      end)

    base
    |> Map.update!(:projects, fn [item] -> [%{item | label: @preview_label}] end)
    |> preview_graph(edges, tracker)
  end

  def preview_changed(board, tracker) do
    tasks = Enum.map(board.tasks, &changed_task/1)

    edges =
      board.workflow_graph["edges"]
      |> Enum.filter(&(&1["type"] == "depends_on"))
      |> Enum.map(fn
        %{"id" => "dep:1:2:0"} = edge ->
          Map.put(edge, "reason", "Synthetic schema contract revised to version 2")

        %{"id" => "dep:1:3:0"} = edge ->
          edge
          |> Map.put("id", "dep:1:402:preview")
          |> Map.put("target", "task:" <> hd(tasks).project <> ":402")

        edge ->
          edge
      end)

    preview_graph(%{board | tasks: tasks}, edges, tracker)
  end

  defp changed_task(%{issue_id: "1"} = task) do
    %{
      task
      | title: "Synthetic task 1 · schema integration revised",
        description: task.description <> "\nPreview revision 2."
    }
  end

  defp changed_task(task), do: task

  defp preview_graph(board, edges, tracker) do
    by_source = Enum.group_by(edges, & &1["source"])

    tasks = Enum.map(board.tasks, &preview_task(&1, by_source))

    graph = WorkflowGraph.export(tasks, Map.put(board.control, "enabled", true), tracker)

    statuses =
      graph["edges"]
      |> Enum.filter(&(&1["type"] == "depends_on"))
      |> Map.new(&{{&1["source"], &1["target"]}, &1["status"]})

    edges = Enum.map(edges, &Map.put(&1, "status", statuses[{&1["source"], &1["target"]}] || "waiting"))
    contains = Enum.filter(graph["edges"], &(&1["type"] == "contains"))
    graph = Map.put(graph, "edges", contains ++ edges)
    %{board | tasks: tasks, workflow_graph: graph}
  end

  defp preview_edges(:dag) do
    hub = Enum.map(2..401, &dep(1, &1))
    chain = Enum.map(2..996, &dep(&1, &1 + 1, 1))
    fanout = for source <- 2..535, factor <- 1..3, do: dep(source, source + factor * 100, factor + 1)
    hub ++ chain ++ fanout ++ [dep(2, 700), dep(998, 999), dep(999, 998)]
  end

  defp preview_edges(:dense_cycle) do
    ring = Enum.map(1..1_000, &dep(&1, rem(&1, 1_000) + 1))
    fanout = for source <- 1..1_000, factor <- 1..2, do: dep(source, rem(source + factor * 100 - 1, 1_000) + 1, factor)
    ring ++ fanout
  end

  defp preview_task(task, by_source) do
    dependencies =
      Enum.map(by_source["task:" <> task.id] || [], fn edge ->
        %{
          "issue_id" => String.replace_prefix(edge["target"], "task:" <> task.project <> ":", ""),
          "kind" => edge["kind"],
          "blocking" => edge["blocking"],
          "reason" => edge["reason"]
        }
      end)

    %{task | dependencies: dependencies, project_label: @preview_label, url: nil, links: []}
  end

  defp task(id) do
    %{
      "id" => "task:#{id}",
      "task_id" => "issue:#{id}",
      "type" => "task",
      "identifier" => "GH-#{id}",
      "title" => "Task #{id}",
      "lane" => "work",
      "task_kind" => if(rem(id, 3) == 0, do: "delivery", else: "security"),
      "milestone" => %{"id" => rem(id, 20), "title" => "Milestone #{rem(id, 20)}"}
    }
  end

  defp dep(source, target, variant \\ 0),
    do: %{
      "id" => "dep:#{source}:#{target}:#{variant}",
      "source" => "task:#{source}",
      "target" => "task:#{target}",
      "type" => "depends_on",
      "status" => "waiting",
      "reason" => "Declared reason"
    }
end
