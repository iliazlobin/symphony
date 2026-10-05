defmodule SymphonyElixir.Assurance.GraphSnapshot do
  @moduledoc "Immutable task graph snapshots with a small, explicit public field whitelist."
  alias SymphonyElixir.Design.Persistence

  @node_fields ~w(id type task_id issue_id identifier title lane stage execution_status task_kind priority milestone tags dependency_error url missing cycle upstream_count upstream_known upstream_unknown downstream_count downstream_known downstream_unknown)
  @edge_fields ~w(id type source target kind blocking reason status satisfaction evidence)
  @max_input_nodes 210_001
  @max_input_edges 260_000
  @max_warning_bytes 4_000

  @spec capture(term(), String.t()) :: {:ok, map()} | {:error, :invalid_assurance_graph}
  def capture(graph, project) when is_map(graph) do
    if list?(graph["nodes"], @max_input_nodes) and list?(graph["edges"], @max_input_edges) do
      nodes = retained_nodes(graph["nodes"])

      sanitized = %{
        "version" => graph["version"],
        "project_id" => graph["project_id"],
        "policy" => graph["policy"],
        "nodes" => nodes,
        "edges" => retained_edges(graph["edges"]),
        "warnings" => compact_warnings(graph["warnings"], nodes)
      }

      snapshot(sanitized, project)
    else
      {:error, :invalid_assurance_graph}
    end
  end

  def capture(_, _), do: {:error, :invalid_assurance_graph}

  defp snapshot(graph, project) do
    if graph?(graph, project) do
      {:ok, %{"captured_at" => DateTime.utc_now() |> DateTime.to_iso8601(), "content_ref" => Persistence.scope_ref(graph), "graph" => graph}}
    else
      {:error, :invalid_assurance_graph}
    end
  end

  # Only native warning prose derived exactly from retained cycle flags may be
  # compacted. The complete immutable task/edge facts remain in the snapshot.
  defp compact_warnings(warnings, nodes) when is_list(warnings) do
    case cycle_warning(nodes) do
      {:ok, detailed, compact} -> Enum.map(warnings, &compact_warning(&1, detailed, compact))
      :none -> warnings
    end
  end

  defp compact_warnings(warnings, _nodes), do: warnings

  defp cycle_warning(nodes) do
    ids =
      nodes
      |> Enum.filter(&(&1["type"] == "task" and &1["cycle"] == true))
      |> Enum.map(& &1["issue_id"])

    if ids != [] and length(ids) <= 10_000 and Enum.all?(ids, &text?(&1, 256)) do
      labels = Enum.map_join(Enum.sort(ids), ", ", &("GH-" <> &1))
      detailed = "Dependency cycle: " <> labels <> ". Revise these prerequisites before work starts."

      compact =
        Enum.join([
          "Dependency cycle: #{length(ids)} tasks. Task labels truncated in this warning;",
          " all cycle nodes and prerequisite edges are retained. Revise these prerequisites before work starts."
        ])

      {:ok, detailed, compact}
    else
      :none
    end
  end

  defp compact_warning(warning, detailed, compact) when is_binary(warning) and byte_size(warning) > @max_warning_bytes,
    do: if(warning == detailed, do: compact, else: warning)

  defp compact_warning(warning, _detailed, _compact), do: warning

  @spec valid?(term(), String.t()) :: boolean()
  def valid?(snapshot, project) do
    exact?(snapshot, ~w(captured_at content_ref graph)) and time?(snapshot["captured_at"]) and graph?(snapshot["graph"], project) and
      snapshot["content_ref"] == Persistence.scope_ref(snapshot["graph"])
  end

  @spec diff(map() | nil, map() | nil) :: map()
  def diff(before, after_snapshot) do
    Map.new(~w(nodes edges), fn key ->
      left = if(before, do: Map.new(before["graph"][key], &{&1["id"], &1}), else: %{})
      right = if(after_snapshot, do: Map.new(after_snapshot["graph"][key], &{&1["id"], &1}), else: %{})

      {key,
       %{
         "added" => Enum.sort(Map.keys(right) -- Map.keys(left)),
         "removed" => Enum.sort(Map.keys(left) -- Map.keys(right)),
         "changed" => left |> Enum.filter(fn {id, item} -> Map.has_key?(right, id) and right[id] != item end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
       }}
    end)
  end

  defp graph?(graph, project) do
    exact?(graph, ~w(version project_id policy nodes edges warnings)) and graph["version"] == 1 and graph["project_id"] == project and
      graph["policy"] in ~w(human_acceptance tracker_completion) and graph_content?(graph, project)
  end

  defp nodes?(nodes, project) do
    Enum.all?(nodes, &is_map/1) and Enum.count(nodes, &(&1["type"] == "project")) == 1 and unique?(nodes) and Enum.all?(nodes, &node?(&1, project))
  end

  defp node?(%{"type" => "project"} = node, project), do: exact?(node, ~w(id type name)) and node["id"] == "project:" <> project and node["name"] == project

  defp node?(%{"type" => "task"} = node, project) do
    exact?(node, @node_fields) and task_identity?(node, project) and task_content?(node) and task_counts?(node)
  end

  defp node?(_, _), do: false

  defp edges?(edges, nodes) do
    ids = MapSet.new(Enum.filter(nodes, &(&1["type"] == "task")), & &1["id"])

    unique?(edges) and Enum.all?(edges, &edge?(&1, ids))
  end

  defp graph_content?(graph, project) do
    list?(graph["nodes"], 10_001) and list?(graph["edges"], 50_000) and list?(graph["warnings"], 10_000) and
      Enum.all?(graph["warnings"], &text?(&1, @max_warning_bytes)) and nodes?(graph["nodes"], project) and edges?(graph["edges"], graph["nodes"]) and
      byte_size(Jason.encode!(graph)) <= 8_000_000
  end

  defp task_content?(node) do
    text?(node["title"], 2_000) and Enum.all?(~w(issue_id identifier lane stage execution_status task_kind), &text?(node[&1], 256)) and
      nullable?(node["priority"], &priority?/1) and milestone?(node["milestone"]) and task_labels?(node)
  end

  defp task_identity?(node, project) do
    text?(node["task_id"], 512) and String.starts_with?(node["task_id"], project <> ":") and node["id"] == "task:" <> node["task_id"]
  end

  defp priority?(value), do: is_integer(value) and value >= 0 and value <= 100

  defp task_labels?(node) do
    list?(node["tags"], 100) and Enum.all?(node["tags"], &text?(&1, 256)) and nullable?(node["dependency_error"], &text?(&1, 4_000)) and
      nullable?(node["url"], &url?/1) and is_boolean(node["missing"]) and is_boolean(node["cycle"])
  end

  defp task_counts?(node) do
    names = ~w(upstream_count upstream_known upstream_unknown downstream_count downstream_known downstream_unknown)
    Enum.all?(names, &(is_integer(node[&1]) and node[&1] >= 0 and node[&1] <= 50_000))
  end

  defp edge?(edge, ids) do
    exact?(edge, @edge_fields) and edge["type"] == "depends_on" and text?(edge["id"], 2_000) and
      MapSet.member?(ids, edge["source"]) and MapSet.member?(ids, edge["target"]) and edge_context?(edge)
  end

  defp edge_context?(edge) do
    edge["kind"] in ~w(delivery design technical process) and is_boolean(edge["blocking"]) and nullable?(edge["reason"], &text?(&1, 4_000)) and
      edge["status"] in ~w(cycle satisfied missing waiting) and edge["satisfaction"] in ~w(human_acceptance tracker_completion) and evidence?(edge["evidence"])
  end

  defp retained_nodes(nodes), do: nodes |> Enum.filter(&(is_map(&1) and &1["type"] in ~w(project task))) |> Enum.map(&sanitize_node/1) |> Enum.sort_by(& &1["id"])
  defp retained_edges(edges), do: edges |> Enum.filter(&(is_map(&1) and &1["type"] == "depends_on")) |> Enum.map(&sanitize_edge/1) |> Enum.sort_by(& &1["id"])

  defp sanitize_node(%{"type" => "project"} = node), do: Map.take(node, ~w(id type name))
  defp sanitize_node(node), do: Map.take(node, @node_fields) |> Map.update("milestone", nil, &if(is_map(&1), do: Map.take(&1, ~w(id title state url)), else: nil))
  defp sanitize_edge(edge), do: Map.take(edge, @edge_fields) |> Map.update("evidence", %{}, &if(is_map(&1), do: Map.take(&1, ~w(accepted_at candidate_sha)), else: %{}))
  defp milestone?(nil), do: true

  defp milestone?(value) do
    exact?(value, ~w(id title state url)) and nullable?(value["id"], &milestone_id?/1) and
      Enum.all?(~w(title state), &nullable?(value[&1], fn item -> text?(item, 512) end)) and nullable?(value["url"], &url?/1)
  end

  defp milestone_id?(value), do: text?(value, 512) or (is_integer(value) and value > 0 and value <= 9_007_199_254_740_991)

  defp evidence?(value) do
    is_map(value) and Enum.all?(Map.keys(value), &(&1 in ~w(accepted_at candidate_sha))) and
      Enum.all?(value, fn {key, item} -> receipt_field?(key, item) end)
  end

  defp receipt_field?("accepted_at", value), do: time?(value)
  defp receipt_field?("candidate_sha", value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{40}\z/, value)
  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp list?(value, max), do: is_list(value) and length(value) <= max
  defp unique?(values), do: length(values) == MapSet.size(MapSet.new(Enum.map(values, &if(is_map(&1), do: &1["id"]))))
  defp text?(value, max), do: is_binary(value) and String.valid?(value) and byte_size(value) <= max
  defp url?(value), do: text?(value, 2_000) and String.starts_with?(value, "https://github.com/")
  defp nullable?(nil, _), do: true
  defp nullable?(value, predicate), do: predicate.(value)
  defp time?(value) when is_binary(value), do: match?({:ok, _, 0}, DateTime.from_iso8601(value))
  defp time?(_), do: false
end
