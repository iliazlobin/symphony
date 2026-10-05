defmodule SymphonyElixirWeb.GraphProjection do
  @moduledoc "Indexed, bounded task dependency navigation over the complete loaded graph."
  alias SymphonyElixirWeb.WorkflowPlan

  @max_nodes 80
  @max_edges 300
  @search_size 8

  @spec index(map(), :all | [String.t()]) :: map()
  def index(board, visible_task_ids \\ :all) do
    plan = WorkflowPlan.project(board, visible_task_ids)
    tasks = Enum.filter(plan["nodes"], &(&1["type"] == "task"))

    edges =
      plan["edges"] |> Enum.filter(&(&1["type"] == "depends_on")) |> Enum.sort_by(&edge_order/1)

    upstream = Enum.group_by(edges, & &1["source"])
    downstream = Enum.group_by(edges, & &1["target"])
    names = Map.new(tasks, &{&1["id"], name(&1)})
    coverage = get_in(board, [:assurance, "tasks"]) || %{}

    tasks =
      tasks
      |> Enum.map(
        &(dependency_status(&1, upstream[&1["id"]] || [], names)
          |> Map.put("coverage", coverage[&1["task_id"]])
          |> Map.put("search_text", search_text(&1)))
      )
      |> Enum.sort_by(&node_order/1)

    by_id = Map.new(tasks, &{&1["id"], &1})
    task_ids = Map.new(tasks, &{&1["task_id"], &1["id"]})
    visible = tasks |> Enum.filter(& &1["visible"]) |> Enum.map(& &1["id"])

    %{
      available: plan["available"],
      reason: plan["reason"],
      nodes: by_id,
      task_ids:
        Enum.reduce(plan["nodes"], task_ids, fn node, aliases ->
          if by_id[node["id"]] || is_nil(task_ids[node["task_id"]]),
            do: aliases,
            else: Map.put(aliases, node["id"], task_ids[node["task_id"]])
        end),
      ordered: tasks,
      visible: visible,
      upstream: upstream,
      downstream: downstream,
      edges: edges,
      groups: Map.new(~w(milestone task_kind), &{&1, group_index(visible, by_id, edges, &1)}),
      gap_groups:
        Map.new(
          ~w(milestone task_kind),
          &{&1, group_index(Enum.filter(visible, fn id -> gap?(by_id[id]) end), by_id, edges, &1)}
        )
    }
  end

  @spec project(map(), String.t() | nil, map()) :: map()
  def project(index, selected_id, options \\ %{}) do
    selected = resolve_node(index, selected_id)
    {context, options} = navigation_context(index, selected, options)
    {candidates, edges, groups, filtered_edges} = scope(index, context, options)
    selected_id = selected && selected["id"]
    context_id = context && context["id"]
    {nodes, page, pages} = page_nodes(candidates, context_id, options)
    displayed_ids = MapSet.new(nodes, & &1["id"])

    displayed_edges =
      edges
      |> Enum.filter(
        &(MapSet.member?(displayed_ids, &1["source"]) and
            MapSet.member?(displayed_ids, &1["target"]))
      )

    displayed_edges = bounded_edges(displayed_edges, context_id)

    options = Map.put(options, "page", page)

    %{
      "available" => index.available,
      "reason" => index.reason,
      "nodes" => nodes,
      "layout_nodes" => layout_nodes(index, nodes, options),
      "edges" => displayed_edges,
      "selected" => selected,
      "related_ids" => related_ids(index, selected_id),
      "options" => options,
      "page" => page,
      "pages" => pages,
      "groups" => groups,
      "max_nodes" => @max_nodes,
      "max_edges" => @max_edges,
      "total_tasks" => length(index.ordered),
      "matching_tasks" => matching_tasks(index, options),
      "total_edges" => length(index.edges),
      "scope_nodes" => length(candidates),
      "scope_edges" => length(edges) + filtered_edges,
      "omitted_nodes" => length(candidates) - length(nodes),
      "omitted_edges" => length(edges) - length(displayed_edges) + filtered_edges,
      "filtered_edges" => filtered_edges,
      "search" => search(index, options["query"], options["search_page"])
    }
  end

  defp resolve_node(index, id), do: index.nodes[id] || index.nodes[index.task_ids[id]]

  defp navigation_context(index, selected, options) do
    anchor = resolve_node(index, options["anchor"]) || selected
    options = normalize(options, length(index.visible), selected || anchor)

    if anchored?(options),
      do: {anchor, retain_anchor(options, anchor)},
      else: {selected, options}
  end

  defp anchored?(%{"mode" => "focus"}), do: true
  defp anchored?(%{"mode" => "tasks", "group" => group}), do: not is_nil(group)
  defp anchored?(_options), do: false

  defp retain_anchor(options, nil), do: options
  defp retain_anchor(options, anchor), do: Map.put(options, "anchor", anchor["task_id"] || anchor["id"])

  defp related_ids(index, selected_id) do
    related = incident(index, selected_id) |> Enum.flat_map(&[&1["source"], &1["target"]]) |> MapSet.new()
    if selected_id, do: MapSet.put(related, selected_id), else: related
  end

  defp layout_nodes(index, nodes, options) do
    if options["mode"] == "tasks" and is_nil(options["group"]) and length(index.ordered) <= @max_nodes,
      do: index.ordered,
      else: nodes
  end

  defp matching_tasks(index, %{"gaps_only" => true}), do: Enum.count(index.visible, &gap?(index.nodes[&1]))
  defp matching_tasks(index, _options), do: length(index.visible)

  @spec search(map(), String.t(), integer()) :: map()
  def search(index, query, page \\ 0) do
    query = query |> to_string() |> String.trim() |> String.slice(0, 160)
    needle = String.downcase(query)

    matches =
      if query == "",
        do: [],
        else: Enum.filter(index.ordered, &String.contains?(&1["search_text"], needle))

    matches = Enum.sort_by(matches, &{if(exact_search_match?(&1, needle), do: 0, else: 1), node_order(&1)})
    pages = max(1, ceil(length(matches) / @search_size))
    page = min(integer(page, 0), pages - 1)

    %{
      results: matches |> Enum.drop(page * @search_size) |> Enum.take(@search_size),
      total: length(matches),
      page: page,
      pages: pages
    }
  end

  defp navigation_mode(mode, count, selected) do
    case mode do
      "overview" -> "overview"
      "focus" when not is_nil(selected) -> "focus"
      "tasks" -> "tasks"
      _ when count > @max_nodes and not is_nil(selected) -> "focus"
      _ when count > @max_nodes -> "overview"
      _ -> "tasks"
    end
  end

  defp normalize(options, count, selected) do
    mode = navigation_mode(options["mode"], count, selected)

    %{
      "mode" => mode,
      "direction" => choice(options["direction"], ~w(both upstream downstream), "both"),
      "hops" => min(2, max(1, integer(options["hops"], 1))),
      "group_by" => choice(options["group_by"], ~w(milestone task_kind), "milestone"),
      "group" => if(is_binary(options["group"]) and options["group"] != "", do: options["group"]),
      "anchor" => if(is_binary(options["anchor"]), do: String.slice(options["anchor"], 0, 512)),
      "page" => integer(options["page"], 0),
      "query" => if(is_binary(options["query"]), do: String.slice(options["query"], 0, 160), else: ""),
      "search_page" => integer(options["search_page"], 0),
      "gaps_only" => options["gaps_only"] in [true, "true"]
    }
  end

  defp scope(index, _selected, %{"mode" => "overview"} = options) do
    groups =
      if(options["gaps_only"],
        do: index.gap_groups[options["group_by"]],
        else: index.groups[options["group_by"]]
      )

    {groups.nodes, groups.edges, groups.nodes, groups.filtered_edges}
  end

  defp scope(index, selected, %{"mode" => "focus"} = options) do
    distances = neighborhood(index, selected["id"], options["direction"], options["hops"])

    candidates =
      distances
      |> Enum.map(fn {id, distance} ->
        Map.merge(index.nodes[id], %{
          "focus_distance" => abs(distance),
          "display_step" => distance
        })
      end)

    candidates = Enum.sort_by(candidates, &{&1["focus_distance"], node_order(&1)})
    ids = MapSet.new(candidates, & &1["id"])
    edges = scoped_edges(index, ids)
    {candidates, edges, [], 0}
  end

  defp scope(index, selected, options) do
    ids =
      if options["group"] do
        index.visible
        |> Enum.filter(&(group_id(index.nodes[&1], options["group_by"]) == options["group"]))
        |> MapSet.new()
      else
        MapSet.new(index.visible)
      end

    ids =
      if options["gaps_only"],
        do: ids |> Enum.filter(&gap?(index.nodes[&1])) |> MapSet.new(),
        else: ids

    ids = context_ids(index, ids, selected, options["group"])

    {Enum.filter(index.ordered, &MapSet.member?(ids, &1["id"])), scoped_edges(index, ids), [], 0}
  end

  defp context_ids(_index, ids, nil, _group), do: ids
  defp context_ids(_index, ids, _selected, group) when not is_nil(group), do: ids

  defp context_ids(index, ids, selected, nil) do
    Enum.reduce(incident(index, selected["id"]), MapSet.put(ids, selected["id"]), fn edge, ids ->
      ids |> MapSet.put(edge["source"]) |> MapSet.put(edge["target"])
    end)
  end

  defp scoped_edges(index, ids) do
    ids
    |> Enum.flat_map(&(Map.get(index.upstream, &1, []) ++ Map.get(index.downstream, &1, [])))
    |> Enum.uniq_by(&edge_order/1)
    |> Enum.sort_by(&edge_order/1)
  end

  defp bounded_edges(edges, _selected_id) when length(edges) <= @max_edges, do: edges
  defp bounded_edges(edges, selected_id), do: edges |> Enum.sort_by(&{if(selected_id in [&1["source"], &1["target"]], do: 0, else: 1), edge_order(&1)}) |> Enum.take(@max_edges)

  defp page_nodes(candidates, _selected_id, _options) when length(candidates) <= @max_nodes, do: {candidates, 0, 1}

  defp page_nodes(candidates, _selected_id, %{"mode" => "overview", "page" => requested}),
    do: page(candidates, [], requested, @max_nodes)

  defp page_nodes(candidates, selected_id, options) do
    {pinned, remaining} = Enum.split_with(candidates, &(&1["id"] == selected_id))
    page(remaining, pinned, options["page"], @max_nodes - length(pinned))
  end

  defp page(candidates, pinned, requested, size) do
    pages = max(1, ceil(length(candidates) / size))
    page = min(requested, pages - 1)
    {pinned ++ (candidates |> Enum.drop(page * size) |> Enum.take(size)), page, pages}
  end

  defp neighborhood(index, id, "both", hops) do
    downstream = directional_neighborhood(index, id, "downstream", hops)

    upstream =
      directional_neighborhood(index, id, "upstream", hops)
      |> Map.new(fn {id, distance} -> {id, -distance} end)

    Map.merge(downstream, upstream)
  end

  defp neighborhood(index, id, "upstream", hops),
    do:
      directional_neighborhood(index, id, "upstream", hops)
      |> Map.new(fn {id, distance} -> {id, -distance} end)

  defp neighborhood(index, id, direction, hops),
    do: directional_neighborhood(index, id, direction, hops)

  defp directional_neighborhood(index, id, direction, hops) do
    Enum.reduce(1..hops, {%{id => 0}, [id]}, fn distance, {seen, frontier} ->
      next =
        frontier
        |> Enum.flat_map(&neighbors(index, &1, direction))
        |> Enum.uniq()
        |> Enum.reject(&Map.has_key?(seen, &1))

      {Enum.reduce(next, seen, &Map.put(&2, &1, distance)), next}
    end)
    |> elem(0)
  end

  defp neighbors(index, id, direction) do
    upstream =
      if direction in ~w(both upstream),
        do: Enum.map(index.upstream[id] || [], & &1["target"]),
        else: []

    downstream =
      if direction in ~w(both downstream),
        do: Enum.map(index.downstream[id] || [], & &1["source"]),
        else: []

    upstream ++ downstream
  end

  defp incident(_index, nil), do: []
  defp incident(index, id), do: (index.upstream[id] || []) ++ (index.downstream[id] || [])

  defp group_index(ids, nodes, edges, group_by) do
    members = Enum.group_by(ids, &group_id(nodes[&1], group_by))
    membership = Map.new(ids, &{&1, group_id(nodes[&1], group_by)})
    visible_edges = Enum.filter(edges, &(membership[&1["source"]] && membership[&1["target"]]))

    filtered_edges =
      Enum.count(edges, fn edge ->
        Map.has_key?(membership, edge["source"]) != Map.has_key?(membership, edge["target"])
      end)

    pairs = Enum.group_by(visible_edges, &{membership[&1["source"]], membership[&1["target"]]})

    groups =
      members
      |> Enum.map(fn {id, member_ids} ->
        tasks = Enum.map(member_ids, &nodes[&1])
        first = hd(tasks)
        internal = length(pairs[{id, id}] || [])

        %{
          "id" => id,
          "type" => "group",
          "group_id" => id,
          "title" => group_label(first, group_by),
          "identifier" => "#{length(tasks)} tasks",
          "visible" => true,
          "task_count" => length(tasks),
          "accepted_count" => Enum.count(tasks, &(&1["lane"] == "done")),
          "unresolved_count" => Enum.count(tasks, &(&1["planning_status"] in ~w(cycle unknown blocked))),
          "waiting_count" => Enum.count(tasks, &(&1["waiting_count"] > 0)),
          "waiting_label" => "#{Enum.count(tasks, &(&1["waiting_count"] > 0))} waiting · #{internal} internal dependencies",
          "internal_edges" => internal,
          "graph_error" =>
            if(Enum.any?(tasks, &(&1["planning_status"] in ~w(cycle unknown blocked))),
              do: "Includes unresolved dependencies"
            ),
          "lane" => "group"
        }
      end)
      |> Enum.sort_by(&{String.downcase(&1["title"]), &1["id"]})

    summarized =
      pairs
      |> Enum.reject(fn {{source, target}, _} -> source == target end)
      |> Enum.map(fn {{source, target}, dependencies} ->
        %{
          "id" => "#{source}->#{target}",
          "type" => "depends_on",
          "source" => source,
          "target" => target,
          "count" => length(dependencies),
          "status" => summary_status(dependencies),
          "reason" => "#{length(dependencies)} declared dependencies between groups"
        }
      end)
      |> Enum.sort_by(&edge_order/1)

    %{nodes: groups, edges: summarized, filtered_edges: filtered_edges}
  end

  defp gap?(%{"coverage" => coverage}) when is_map(coverage),
    do: (coverage["gap_count"] || 0) > 0 or coverage["status"] in ~w(unlinked stale missing)

  defp gap?(_node), do: false

  defp summary_status(edges),
    do:
      Enum.find(~w(cycle missing waiting satisfied), "waiting", fn status ->
        Enum.any?(edges, &(&1["status"] == status))
      end)

  defp group_id(node, "task_kind"), do: "group:kind:" <> (node["task_kind"] || "general")

  defp group_id(node, _),
    do:
      "group:milestone:" <>
        project_id(node) <> ":" <> to_string(get_in(node, ["milestone", "id"]) || "none")

  defp project_id(node),
    do:
      node["project_id"] ||
        node["task_id"] |> String.split(":") |> Enum.drop(-1) |> Enum.join(":")

  defp group_label(node, "task_kind"), do: String.capitalize(node["task_kind"] || "general")
  defp group_label(node, _), do: get_in(node, ["milestone", "title"]) || "No milestone"

  defp dependency_status(node, edges, names) do
    waiting = Enum.filter(edges, &(&1["status"] == "waiting" and &1["blocking"] != false))

    labels =
      waiting |> Enum.map(&(names[&1["target"]] || &1["target"])) |> Enum.uniq() |> Enum.sort()

    label =
      "Waiting on " <>
        Enum.join(Enum.take(labels, 3), ", ") <>
        if(length(labels) > 3, do: " +#{length(labels) - 3}", else: "")

    Map.merge(node, %{
      "waiting_count" => length(waiting),
      "waiting_label" => label,
      "graph_error" => node_error(node)
    })
  end

  defp node_error(%{"planning_status" => "cycle"}), do: "Dependency cycle. Revise prerequisites."

  defp node_error(%{
         "dependency_error" => "Dependencies require human-accepted Done in this project."
       }),
       do: nil

  defp node_error(node), do: node["dependency_error"]

  defp search_text(node),
    do:
      Enum.join(
        [
          name(node),
          node["title"],
          node["task_id"],
          node["id"],
          node["task_kind"],
          get_in(node, ["milestone", "title"])
        ],
        " "
      )
      |> String.downcase()

  defp exact_search_match?(node, needle),
    do: Enum.any?([node["identifier"], node["task_id"], node["id"]], &(is_binary(&1) and String.downcase(&1) == needle))

  defp name(node), do: node["identifier"] || node["title"] || node["id"]

  defp node_order(node),
    do: {node["priority"] || 999, node["identifier"] || node["id"], node["id"]}

  defp edge_order(edge),
    do: {edge["source"], edge["target"], edge["id"], edge["kind"], edge["reason"]}

  defp choice(value, values, fallback), do: if(value in values, do: value, else: fallback)
  defp integer(value, _fallback) when is_integer(value) and value >= 0, do: value

  defp integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> fallback
    end
  end

  defp integer(_value, fallback), do: fallback
end
