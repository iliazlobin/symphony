defmodule SymphonyElixir.TaskDependencies do
  @moduledoc "Explicit, bounded task prerequisites. Priority orders eligible tasks and never creates a prerequisite."

  alias SymphonyElixir.{IssueAcceptance, TaskIdentity, TaskRouting}
  alias SymphonyElixir.Tracker.Issue

  @kinds ~w(delivery design technical process)
  @instruction "Use exactly one line: Depends on: none or Depends on: #12, #34 (technical: required schema)."
  @reference ~r/\A#([1-9][0-9]{0,9})(?: \((delivery|design|technical|process)(?:: ([^(),\r\n]{1,160}))?\))?\z/

  def parse(description, id \\ nil)

  @spec parse(term(), String.t() | nil) :: {:ok, [map()]} | {:error, String.t()}
  def parse(description, id) when is_binary(description) do
    lines = description |> String.split(~r/\r?\n/) |> Enum.filter(&String.match?(&1, ~r/^\s*depends on\b/i))

    case lines do
      ["Depends on: none"] -> {:ok, []}
      ["Depends on: " <> refs] -> parse_references(String.split(refs, ", "), id)
      _ -> {:error, @instruction}
    end
  end

  def parse(_, _), do: {:error, @instruction}

  defp parse_references(refs, id) do
    records = Enum.map(refs, &reference/1)
    ids = Enum.map(records, &if(is_map(&1), do: &1["issue_id"]))

    cond do
      length(refs) > 20 -> {:error, "At most 20 dependencies are supported."}
      Enum.any?(records, &is_nil/1) -> {:error, @instruction}
      id in ids -> {:error, "An issue cannot depend on itself."}
      length(ids) != length(Enum.uniq(ids)) -> {:error, "List each dependency once."}
      true -> {:ok, records}
    end
  end

  defp reference(text) do
    case Regex.run(@reference, text, capture: :all_but_first) do
      [id | rest] ->
        [kind, reason] = Enum.take(rest ++ ["", ""], 2)
        %{"issue_id" => id, "kind" => if(kind == "", do: "delivery", else: kind), "blocking" => true, "reason" => if(reason == "", do: nil, else: reason)}

      _ ->
        nil
    end
  end

  @spec valid_records?(term()) :: boolean()
  def valid_records?(records) when is_list(records) do
    length(records) <= 20 and Enum.all?(records, &valid_record?/1) and
      length(records) == MapSet.size(MapSet.new(records, & &1["issue_id"]))
  end

  def valid_records?(_), do: false

  defp valid_record?(record) when is_map(record) do
    Enum.sort(Map.keys(record)) == Enum.sort(~w(issue_id kind blocking reason)) and
      is_binary(record["issue_id"]) and String.match?(record["issue_id"], ~r/\A[1-9][0-9]{0,9}\z/) and
      record["kind"] in @kinds and record["blocking"] == true and
      valid_reason?(record["reason"])
  end

  defp valid_record?(_), do: false
  defp valid_reason?(nil), do: true

  defp valid_reason?(reason),
    do: is_binary(reason) and byte_size(reason) in 1..640 and String.valid?(reason) and not String.contains?(reason, <<0>>)

  @doc "Validate declarations without remote dependency reads; only the native owner can evaluate local acceptance."
  @spec prepare([Issue.t()]) :: [Issue.t()]
  def prepare(issues), do: Enum.map(issues, &prepare_issue/1)

  defp prepare_issue(%Issue{dispatchable: false} = issue), do: issue

  defp prepare_issue(issue) do
    case parse(issue.description, issue.id) do
      {:ok, dependencies} -> %{issue | dependencies: dependencies}
      {:error, reason} -> hold(issue, reason, [])
    end
  end

  @doc "Use one immutable owner snapshot for every prerequisite; closed or merged tracker facts do not replace human acceptance."
  @spec evaluate([Issue.t()], map(), map()) :: [Issue.t()]
  def evaluate(issues, control, tracker) do
    records = records(control, issues, tracker)
    cycles = records |> cycle_nodes() |> Map.new(&{&1, true})
    Enum.map(issues, &evaluate_issue(&1, control, tracker, cycles))
  end

  @spec gate(Issue.t(), map(), map()) :: Issue.t()
  def gate(issue, control, tracker) do
    provisional = evaluate_issue(issue, control, tracker, %{})

    if provisional.dispatchable and provisional.dependencies != [],
      do: evaluate([issue], control, tracker) |> hd(),
      else: provisional
  end

  @spec evaluate_issue(Issue.t(), map(), map(), map()) :: Issue.t()
  defp evaluate_issue(%Issue{dispatchable: false} = issue, _control, _tracker, _cycles), do: issue

  defp evaluate_issue(issue, control, tracker, cycles) do
    native_ref = issue.native_ref || %{}

    if native_ref["repo"] == tracker.provider["repo"] do
      case parse(issue.description, issue.id) do
        {:error, reason} -> hold(issue, reason, [])
        {:ok, dependencies} -> evaluate_dependencies(%{issue | dependencies: dependencies}, control, tracker, cycles)
      end
    else
      hold(issue, "Task belongs to another project; no work is admitted.", [])
    end
  end

  @spec evaluate_dependencies(Issue.t(), map(), map(), map()) :: Issue.t()
  defp evaluate_dependencies(issue, control, tracker, cycles) do
    blockers =
      Enum.flat_map(issue.dependencies, fn dependency ->
        if satisfied?(control, dependency["issue_id"], tracker),
          do: [],
          else: [%{id: dependency["issue_id"], identifier: "GH-#{dependency["issue_id"]}", state: "awaiting_acceptance", kind: dependency["kind"], reason: dependency["reason"]}]
      end)

    cond do
      Map.has_key?(cycles, issue.id) -> hold(issue, "Dependency cycle: revise the declared prerequisites before work can start.", blockers)
      blockers != [] -> hold(issue, "Dependencies require human-accepted Done in this project.", blockers)
      true -> %{issue | blocked_by: [], native_ref: Map.delete(issue.native_ref || %{}, "admission_reason")}
    end
  end

  @spec satisfied?(map(), String.t(), map()) :: boolean()
  def satisfied?(control, id, tracker) do
    item = get_in(control, ["issues", id]) || %{}
    IssueAcceptance.accepted_in_scope?(item, TaskIdentity.project_id(tracker), TaskRouting.fingerprint(tracker))
  end

  @spec records(map(), [Issue.t()], map()) :: map()
  def records(control, issues, tracker) do
    fingerprint = TaskRouting.fingerprint(tracker)
    observed = control["tracker_issues"] || %{}

    known =
      observed
      |> Enum.filter(fn {_id, record} -> record["tracker_fingerprint"] == fingerprint and record["repository"] == tracker.provider["repo"] end)
      |> Map.new()

    Enum.reduce(issues, known, fn issue, acc ->
      case parse(issue.description, issue.id) do
        {:ok, dependencies} -> Map.put(acc, issue.id, %{"dependencies" => dependencies})
        _ -> Map.delete(acc, issue.id)
      end
    end)
  end

  @doc "Return every member of a dependency cycle in the bounded retained source graph."
  @spec cycle_nodes(map()) :: MapSet.t()
  def cycle_nodes(records), do: records |> cycle_groups() |> List.flatten() |> MapSet.new()

  @doc "Keep separate strongly connected dependency groups distinct for edge visualization."
  @spec cycle_groups(map()) :: [[String.t()]]
  def cycle_groups(records) do
    graph = :digraph.new()

    try do
      Enum.each(records, fn {id, _} -> :digraph.add_vertex(graph, id) end)

      Enum.each(records, fn {id, record} ->
        Enum.each(record["dependencies"] || [], fn dependency ->
          :digraph.add_vertex(graph, dependency["issue_id"])
          :digraph.add_edge(graph, id, dependency["issue_id"])
        end)
      end)

      graph
      |> :digraph_utils.strong_components()
      |> Enum.filter(fn
        [id] -> id in :digraph.out_neighbours(graph, id)
        members -> length(members) > 1
      end)
    after
      :digraph.delete(graph)
    end
  end

  defp hold(issue, reason, blockers), do: %{issue | dispatchable: false, blocked_by: blockers, native_ref: Map.put(issue.native_ref || %{}, "admission_reason", reason)}
end
