defmodule SymphonyElixirWeb.TaskFilters do
  @moduledoc "Read-only task visibility shared by the board's planning views."

  alias SymphonyElixir.TaskKind
  alias SymphonyElixirWeb.TaskOperator

  @filters ~w(project status priority kind milestone label assignee)
  @metadata ~w(milestone label assignee)
  @statuses ~w(backlog work in_progress review done ready running attention)
  @priorities ~w(P1 P2 P3 P4 —)

  @spec visible_ids(map(), map(), String.t() | nil) :: [String.t()]
  def visible_ids(board, filters, project) when is_map(board) and is_map(filters) do
    selections = Map.new(@filters, &{&1, selection(filters[&1], &1)})
    query = query(filters["q"])

    board
    |> Map.get(:tasks, [])
    |> tasks()
    |> Enum.filter(&visible?(&1, selections, query, project, board[:control] || %{}))
    |> Enum.map(&field(&1, :id))
    |> Enum.uniq()
  end

  def visible_ids(_board, _filters, _project), do: []

  defp tasks(tasks) when is_list(tasks), do: Enum.filter(tasks, &(is_map(&1) and is_binary(field(&1, :id))))
  defp tasks(_tasks), do: []

  defp visible?(task, selections, query, project, control) do
    card = card(task, control)

    in_project?(card.project, project) and
      filters_match?(card, selections) and search?(task, card.kind, card.metadata, query)
  end

  defp card(task, control) do
    stage = field(task, :stage)

    %{
      project: field(task, :project),
      stage: stage,
      lane: if(stage in ["ready", "running"], do: lane(stage), else: field(task, :lane) || stage),
      priority: priority(field(task, :priority)),
      kind: field(task, :task_kind) || TaskKind.from_labels(list(field(task, :labels))),
      attention: TaskOperator.attention?(task, control),
      metadata: metadata(task)
    }
  end

  defp in_project?(_task_project, nil), do: true
  defp in_project?(task_project, project), do: task_project == project

  defp filters_match?(card, selections) do
    Enum.all?(selections, fn {key, values} -> matches?(values, &value_matches?(card, key, &1)) end)
  end

  defp value_matches?(card, "project", value), do: value == card.project
  defp value_matches?(card, "status", value), do: value in @statuses and status_matches?(card, value)
  defp value_matches?(card, "priority", value), do: value in @priorities and value == card.priority
  defp value_matches?(card, "kind", value), do: value in ["invalid" | TaskKind.values()] and value == card.kind

  defp value_matches?(card, key, value) do
    valid_metadata?(key, value) and metadata_matches?(card.metadata[key], value)
  end

  defp status_matches?(card, "attention"), do: card.attention
  defp status_matches?(card, value), do: value in [card.stage, card.lane]
  defp metadata_matches?(values, "__none__"), do: values == []
  defp metadata_matches?(values, value), do: value in values

  defp selection(value, _key) when value in [nil, ""], do: []

  defp selection(value, key) when is_binary(value) and byte_size(value) <= 2_000 do
    if key in @metadata do
      case Jason.decode(value) do
        {:ok, values} when is_list(values) -> bounded_metadata(values)
        _ -> :invalid
      end
    else
      String.split(value, ",")
    end
  end

  defp selection(_value, _key), do: :invalid

  defp bounded_metadata(values) do
    if length(values) <= 20 and Enum.all?(values, &(is_binary(&1) and byte_size(&1) <= 240)) do
      values
    else
      :invalid
    end
  end

  defp matches?([], _predicate), do: true
  defp matches?(:invalid, _predicate), do: false
  defp matches?(values, predicate), do: Enum.any?(values, predicate)

  defp metadata(task) do
    milestone = milestone(field(task, :milestone))

    %{
      "label" => Enum.map(subject_tags(field(task, :labels)), &("label:" <> &1)),
      "assignee" => Enum.map(strings(field(task, :assignees)), &("assignee:" <> &1)),
      "milestone" => if(milestone, do: ["milestone:#{field(task, :project)}:#{milestone.id}"], else: []),
      "milestone_title" => if(milestone, do: milestone.title, else: "")
    }
  end

  defp subject_tags(labels), do: labels |> strings() |> Enum.filter(&TaskKind.subject_tag?/1)

  defp valid_metadata?(_key, "__none__"), do: true
  defp valid_metadata?("milestone", value), do: String.match?(value, ~r/\Amilestone:.+:[1-9][0-9]*\z/) and not String.contains?(value, <<0>>)
  defp valid_metadata?("label", "label:" <> label), do: label != "" and TaskKind.subject_tag?(label) and not String.contains?(label, <<0>>)
  defp valid_metadata?("assignee", "assignee:" <> login), do: login != "" and not String.contains?(login, <<0>>)
  defp valid_metadata?(_key, _value), do: false

  defp milestone(value) when is_map(value) do
    id = field(value, :id)
    title = field(value, :title)
    if ((is_binary(id) and id != "") or (is_integer(id) and id != 0)) and is_binary(title), do: %{id: id, title: title}
  end

  defp milestone(_value), do: nil

  defp query(value) when value in [nil, ""], do: ""
  defp query(value) when is_binary(value) and byte_size(value) <= 2_000, do: String.downcase(value)
  defp query(_value), do: :invalid
  defp search?(_task, _kind, _metadata, :invalid), do: false
  defp search?(_task, _kind, _metadata, ""), do: true

  defp search?(task, kind, metadata, query) do
    [field(task, :title), field(task, :identifier), kind, metadata["milestone_title"]]
    |> Kernel.++(subject_tags(field(task, :labels)))
    |> Kernel.++(Enum.map(strings(field(task, :assignees)), &("@" <> &1)))
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
    |> String.contains?(query)
  end

  defp lane("ready"), do: "work"
  defp lane("running"), do: "in_progress"
  defp priority(value) when is_integer(value) and value > 0, do: "P#{value}"
  defp priority(_value), do: "—"
  defp strings(values), do: values |> list() |> Enum.filter(&(is_binary(&1) and &1 != ""))
  defp list(values) when is_list(values), do: values
  defp list(_values), do: []
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
