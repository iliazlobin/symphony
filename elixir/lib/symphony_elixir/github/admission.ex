defmodule SymphonyElixir.GitHub.Admission do
  @moduledoc """
  Fail-closed dependency admission for controlled GitHub execution.

  One explicit declaration names no dependencies or up to twenty same-repository
  issue numbers. Only those issues' current states are read; their dependency
  declarations are never traversed. The adapter applies this to dispatch and refresh.
  """

  alias SymphonyElixir.Tracker.Issue

  @max_dependencies 20
  @declaration ~r/\ADepends on: (none|#[1-9][0-9]*(?:, #[1-9][0-9]*)*)\z/
  @instruction "Use exactly one line: Depends on: none or Depends on: #12, #34."

  @spec evaluate([Issue.t()], ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()})) :: [Issue.t()]
  def evaluate(issues, fetch_dependencies) do
    declarations = Enum.map(issues, &{&1, declaration(&1)})

    dependency_ids =
      declarations
      |> Enum.flat_map(fn
        {_issue, {:ok, ids}} -> ids
        _ -> []
      end)
      |> Enum.uniq()

    dependencies = read_dependencies(dependency_ids, fetch_dependencies)
    Enum.map(declarations, &admit(&1, dependencies))
  end

  defp declaration(%Issue{dispatchable: false}), do: {:error, "Not a dispatchable GitHub issue."}

  defp declaration(%Issue{description: description, id: id, native_ref: %{"repo" => repo}})
       when is_binary(description) and is_binary(repo) and repo != "" do
    lines =
      description
      |> String.split(~r/\r?\n/)
      |> Enum.filter(&String.match?(&1, ~r/^\s*depends on\b/i))

    case lines do
      [line] -> parse_declaration(line, id)
      _ -> {:error, @instruction}
    end
  end

  defp declaration(%Issue{}), do: {:error, @instruction}

  defp parse_declaration(line, id) do
    case Regex.run(@declaration, line) do
      [_, "none"] -> {:ok, []}
      [_, refs] -> validate_ids(String.split(refs, ", ") |> Enum.map(&String.trim_leading(&1, "#")), id)
      _ -> {:error, @instruction}
    end
  end

  defp validate_ids(ids, id) do
    cond do
      id in ids -> {:error, "An issue cannot depend on itself."}
      length(ids) != length(Enum.uniq(ids)) -> {:error, "List each dependency once."}
      length(ids) > @max_dependencies -> {:error, "At most #{@max_dependencies} dependencies are supported."}
      true -> {:ok, ids}
    end
  end

  defp read_dependencies([], _fetch), do: {:ok, %{}}

  defp read_dependencies(ids, fetch) do
    case fetch.(ids) do
      {:ok, issues} when is_list(issues) ->
        if Enum.all?(issues, &match?(%Issue{}, &1)) do
          {:ok, Map.new(issues, &{&1.id, &1})}
        else
          :unavailable
        end

      _ ->
        :unavailable
    end
  end

  defp admit({issue, {:error, reason}}, _dependencies), do: hold(issue, reason, [])
  defp admit({issue, {:ok, []}}, _dependencies), do: allow(issue)

  defp admit({issue, {:ok, ids}}, {:ok, dependencies}) do
    blockers =
      Enum.flat_map(ids, fn id ->
        dependency = Map.get(dependencies, id)

        if closed_issue?(dependency, issue.native_ref["repo"]) do
          []
        else
          [%{id: id, identifier: "GH-#{id}", state: dependency_state(dependency)}]
        end
      end)

    case blockers do
      [] -> allow(issue)
      _ -> hold(issue, "Dependencies must be visible, closed issues in this repository.", blockers)
    end
  end

  defp admit({issue, {:ok, ids}}, :unavailable) do
    blockers = Enum.map(ids, &%{id: &1, identifier: "GH-#{&1}", state: "unknown"})
    hold(issue, "Dependency state could not be read; retry after tracker access recovers.", blockers)
  end

  defp closed_issue?(%Issue{state: "closed", dispatchable: true, native_ref: %{"repo" => repo}}, repo), do: true
  defp closed_issue?(_dependency, _repo), do: false

  defp dependency_state(%Issue{state: state}) when is_binary(state), do: state
  defp dependency_state(_dependency), do: "unknown"

  defp allow(issue) do
    %{issue | dispatchable: true, blocked_by: [], native_ref: Map.delete(issue.native_ref || %{}, "admission_reason")}
  end

  defp hold(issue, reason, blockers) do
    %{
      issue
      | dispatchable: false,
        blocked_by: blockers,
        native_ref: Map.put(issue.native_ref || %{}, "admission_reason", reason)
    }
  end
end
