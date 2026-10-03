defmodule SymphonyElixirWeb.WorkflowPlan do
  @moduledoc """
  Read-only dependency sequence shared by planning views.

  Steps are relative dependency levels. Each display slot has width one; it is
  neither a duration nor a promised start date. Priority orders peers only.
  Native scheduling, capacity, holds and human acceptance remain authoritative.
  A blocked sequence means its order is unresolved, not that execution is blocked.
  """

  alias SymphonyElixir.TaskDependencies

  @normal_wait "Dependencies require human-accepted Done in this project."
  @cycle_wait "Dependency cycle: revise the declared prerequisites before work can start."
  @node_strings ~w(title name identifier task_kind lane phase dependency_error work_id task_id)
  @edge_strings ~w(reason status kind)

  @spec project(map(), :all | [String.t()]) :: map()
  def project(board, visible_task_ids \\ :all) do
    graph = board[:workflow_graph]

    if complete?(board, graph) do
      sequence(graph, visible_ids(board, graph, visible_task_ids))
    else
      unavailable()
    end
  end

  defp complete?(board, graph) when is_map(graph) do
    is_nil(board[:source_error]) and is_nil(board[:runtime_error]) and graph["version"] == 1 and
      is_list(graph["nodes"]) and is_list(graph["edges"]) and
      Enum.all?(graph["nodes"], &valid_node?/1) and valid_edges?(graph) and valid_warnings?(graph["warnings"]) and
      length(graph["nodes"]) == MapSet.size(MapSet.new(graph["nodes"], & &1["id"]))
  end

  defp complete?(_board, _graph), do: false

  defp valid_node?(%{"type" => "task"} = node),
    do: nonempty_string?(node["id"]) and nonempty_string?(node["task_id"]) and valid_node_metadata?(node)

  defp valid_node?(node) when is_map(node),
    do: nonempty_string?(node["id"]) and node["type"] in ~w(project work) and valid_node_metadata?(node)

  defp valid_node?(_node), do: false

  defp valid_node_metadata?(node),
    do: optional_strings?(node, @node_strings) and valid_priority?(node["priority"]) and valid_milestone?(node["milestone"])

  defp valid_priority?(priority), do: is_nil(priority) or is_integer(priority)
  defp valid_milestone?(nil), do: true

  defp valid_milestone?(milestone) when is_map(milestone),
    do: optional_strings?(milestone, ~w(title)) and valid_milestone_id?(milestone["id"])

  defp valid_milestone?(_milestone), do: false
  defp valid_milestone_id?(id), do: is_nil(id) or is_binary(id) or is_integer(id)
  defp optional_strings?(record, keys), do: Enum.all?(keys, &(is_nil(record[&1]) or is_binary(record[&1])))

  defp valid_edges?(graph) do
    nodes = Map.new(graph["nodes"], &{&1["id"], &1})
    Enum.all?(graph["edges"], &valid_edge?(&1, nodes))
  end

  defp valid_edge?(%{"type" => "depends_on"} = edge, nodes),
    do:
      match?(%{"type" => "task"}, nodes[edge["source"]]) and match?(%{"type" => "task"}, nodes[edge["target"]]) and
        optional_strings?(edge, @edge_strings)

  defp valid_edge?(%{"type" => "contains"} = edge, nodes),
    do: Map.has_key?(nodes, edge["source"]) and Map.has_key?(nodes, edge["target"]) and optional_strings?(edge, @edge_strings)

  defp valid_edge?(_edge, _nodes), do: false
  defp valid_warnings?(nil), do: true
  defp valid_warnings?(warnings) when is_list(warnings), do: Enum.all?(warnings, &is_binary/1)
  defp valid_warnings?(_warnings), do: false
  defp nonempty_string?(value), do: is_binary(value) and value != ""

  # The literal empty constructor is compiler-inlined and loses MapSet opacity.
  @spec empty_set() :: MapSet.t()
  defp empty_set, do: MapSet.new([], &Function.identity/1)

  @spec visible_ids(map(), map(), :all | [String.t()]) :: MapSet.t()
  defp visible_ids(board, graph, :all) do
    case board[:tasks] do
      tasks when is_list(tasks) -> MapSet.new(tasks, & &1.id)
      _ -> graph["nodes"] |> Enum.filter(&(&1["type"] == "task" and &1["missing"] != true)) |> MapSet.new(& &1["task_id"])
    end
  end

  defp visible_ids(_board, _graph, ids) when is_list(ids), do: MapSet.new(ids)
  defp visible_ids(_board, _graph, _ids), do: empty_set()

  defp sequence(graph, visible) do
    tasks = Enum.filter(graph["nodes"], &(&1["type"] == "task"))
    by_id = Map.new(tasks, &{&1["id"], &1})
    edges = Enum.filter(graph["edges"], &(&1["type"] == "depends_on"))
    {parents, children} = adjacency(tasks, Enum.reject(edges, &(&1["blocking"] == false)))
    {upstream, downstream} = adjacency(tasks, edges)
    statuses = planning_statuses(tasks, parents, children)
    levels = levels(statuses, parents, children)

    context = %{
      statuses: statuses,
      levels: levels,
      upstream: upstream,
      downstream: downstream,
      nodes: by_id,
      edges: Enum.group_by(edges, & &1["source"]),
      visible: visible
    }

    tasks = Enum.map(tasks, &task_plan(&1, context))
    rows = tasks |> Enum.filter(& &1["visible"]) |> Enum.sort_by(&row_order/1)
    task_index = Map.new(tasks, &{&1["id"], &1})

    %{
      "version" => 1,
      "available" => true,
      "reason" => nil,
      "mode" => "sequence",
      "rows" => rows,
      "step_count" => Enum.reduce(rows, 0, &max(&1["end_step"] || 0, &2)),
      "stages" => stages(rows),
      "nodes" => Enum.map(graph["nodes"], &(task_index[&1["id"]] || &1)),
      "edges" => graph["edges"],
      "warnings" => graph["warnings"] || [],
      "groups" => %{"milestones" => groups(rows, "milestone"), "kinds" => groups(rows, "task_kind")}
    }
  end

  defp adjacency(tasks, edges) do
    empty = Map.new(tasks, &{&1["id"], empty_set()})

    Enum.reduce(edges, {empty, empty}, fn edge, {parents, children} ->
      source = edge["source"]
      target = edge["target"]
      parents = Map.update(parents, source, MapSet.new([target]), &MapSet.put(&1, target))
      children = Map.update(children, target, MapSet.new([source]), &MapSet.put(&1, source))
      {parents, children}
    end)
  end

  defp planning_statuses(tasks, parents, children) do
    records = Map.new(parents, fn {id, targets} -> {id, %{"dependencies" => Enum.map(targets, &%{"issue_id" => &1})}} end)
    cycles = TaskDependencies.cycle_nodes(records)
    unknown = tasks |> Enum.filter(&unknown?/1) |> MapSet.new(& &1["id"])
    absent = MapSet.difference(MapSet.new(Map.keys(children)), MapSet.new(tasks, & &1["id"]))
    unknown = MapSet.union(unknown, absent)
    blocked = descendants(MapSet.to_list(MapSet.union(cycles, unknown)), children, empty_set())

    Map.new(tasks, fn task ->
      id = task["id"]

      status =
        cond do
          MapSet.member?(cycles, id) -> "cycle"
          MapSet.member?(unknown, id) -> "unknown"
          MapSet.member?(blocked, id) -> "blocked"
          true -> "sequenced"
        end

      {id, status}
    end)
  end

  defp unknown?(task),
    do: task["missing"] == true or task["dependency_error"] not in [nil, @normal_wait, @cycle_wait]

  @spec descendants([String.t()], map(), MapSet.t()) :: MapSet.t()
  defp descendants([], _children, seen), do: seen

  defp descendants([id | rest], children, seen) do
    if MapSet.member?(seen, id) do
      descendants(rest, children, seen)
    else
      next = Map.get(children, id, empty_set()) |> MapSet.to_list()
      descendants(next ++ rest, children, MapSet.put(seen, id))
    end
  end

  defp levels(statuses, parents, children) do
    ordered = statuses |> Enum.filter(fn {_id, status} -> status == "sequenced" end) |> Enum.map(&elem(&1, 0))
    degrees = Map.new(ordered, &{&1, MapSet.size(parents[&1])})
    roots = ordered |> Enum.filter(&(degrees[&1] == 0)) |> Enum.sort()
    assign_levels(roots, children, degrees, Map.new(roots, &{&1, 0}))
  end

  defp assign_levels([], _children, _degrees, levels), do: levels

  defp assign_levels([id | rest], children, degrees, levels) do
    {queue, degrees, levels} =
      Enum.reduce(children[id] || empty_set(), {rest, degrees, levels}, &assign_child_level(&1, &2, id))

    assign_levels(queue, children, degrees, levels)
  end

  defp assign_child_level(child, {queue, degrees, levels} = state, parent) do
    if Map.has_key?(degrees, child) do
      degree = degrees[child] - 1
      queue = if degree == 0, do: [child | queue], else: queue
      levels = Map.update(levels, child, levels[parent] + 1, &max(&1, levels[parent] + 1))
      {queue, Map.put(degrees, child, degree), levels}
    else
      state
    end
  end

  defp task_plan(task, context) do
    id = task["id"]
    step = context.levels[id]

    task
    |> Map.merge(%{
      "planning_status" => context.statuses[id],
      "dependency_state" => dependency_state(task, context.edges[id] || [], context.statuses[id]),
      "start_step" => step,
      "end_step" => if(is_integer(step), do: step + 1),
      "visible" => MapSet.member?(context.visible, task["task_id"])
    })
    |> neighbor_counts("upstream", context.upstream[id] || empty_set(), context.nodes, context.visible)
    |> neighbor_counts("downstream", context.downstream[id] || empty_set(), context.nodes, context.visible)
  end

  @spec neighbor_counts(map(), String.t(), MapSet.t(), map(), MapSet.t()) :: map()
  defp neighbor_counts(node, direction, ids, by_id, visible) do
    known = Enum.filter(ids, &(is_map(by_id[&1]) and by_id[&1]["missing"] != true))
    outside = Enum.count(known, &(not MapSet.member?(visible, by_id[&1]["task_id"])))

    Map.merge(node, %{
      (direction <> "_count") => MapSet.size(ids),
      (direction <> "_known") => length(known),
      (direction <> "_unknown") => MapSet.size(ids) - length(known),
      (direction <> "_outside_filter") => outside
    })
  end

  defp dependency_state(task, edges, planning_status) do
    statuses = edges |> Enum.reject(&(&1["blocking"] == false)) |> Enum.map(& &1["status"])

    cond do
      planning_status == "cycle" or "cycle" in statuses -> "cycle"
      unknown?(task) or Enum.any?(statuses, &(&1 not in ~w(satisfied waiting cycle))) -> "unknown"
      "waiting" in statuses -> "waiting"
      true -> "clear"
    end
  end

  defp row_order(task) do
    priority = if is_integer(task["priority"]) and task["priority"] > 0, do: task["priority"], else: 999
    {is_nil(task["start_step"]), task["start_step"] || 0, priority, task["identifier"] || task["id"], task["id"]}
  end

  defp stages(rows) do
    rows
    |> Enum.filter(&is_integer(&1["start_step"]))
    |> Enum.group_by(& &1["start_step"], & &1["task_id"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {index, ids} -> %{"index" => index, "task_ids" => ids} end)
  end

  defp groups(rows, key) do
    rows
    |> Enum.group_by(&group_identity(&1, key))
    |> Enum.sort_by(fn {{id, title}, _rows} -> {title, id || ""} end)
    |> Enum.map(fn {{id, title}, members} -> %{"id" => id, "title" => title, "task_ids" => Enum.map(members, & &1["task_id"])} end)
  end

  defp group_identity(task, "milestone") do
    milestone = task["milestone"] || %{}
    {milestone["id"], milestone["title"] || "No milestone"}
  end

  defp group_identity(task, "task_kind") do
    kind = task["task_kind"] || "general"
    {kind, String.capitalize(kind)}
  end

  defp unavailable do
    %{
      "version" => 1,
      "available" => false,
      "reason" => "Planning data is incomplete. The board keeps its last-known tasks.",
      "mode" => "sequence",
      "rows" => [],
      "step_count" => 0,
      "stages" => [],
      "nodes" => [],
      "edges" => [],
      "warnings" => [],
      "groups" => %{"milestones" => [], "kinds" => []}
    }
  end
end
