defmodule SymphonyElixir.WorkEvidence do
  @moduledoc "Projects retained coding evidence against its exact work, instruction revision, base and current head. Never accepts a task."

  @spec result(map() | nil) :: map() | nil
  def result(nil), do: nil

  def result(work) do
    handoff = map(work["handoff"])
    review = map(handoff["review"])
    checks = handoff["checks"] || []
    current = current?(work, handoff, review)

    %{
      "scope" => "retained_candidate",
      "status" => status(work, review, current, checks),
      "current" => current,
      "goal_revision" => Map.get(handoff, "goal_revision", 1),
      "candidate_sha" => handoff["candidate_sha"],
      "base_sha" => handoff["base_sha"],
      "reviewed_sha" => review["candidate_sha"],
      "run_id" => handoff["run_id"],
      "review_verdict" => review["verdict"],
      "checks_status" => checks_status(checks),
      "checks" => if(valid_checks?(checks), do: Enum.map(checks, &Map.take(&1, ~w(name result details))), else: []),
      "limitations" => if(is_list(handoff["limitations"]), do: Enum.filter(handoff["limitations"], &is_binary/1), else: [])
    }
  end

  @doc "Fence retained readiness against an associated PR's observed head; missing GitHub evidence never confirms currentness."
  @spec for_task(map() | nil, map()) :: map() | nil
  def for_task(nil, _task), do: nil

  def for_task(work, task) do
    result = result(work)
    head_state = external_head_state(work, task)
    current = result["current"] and head_state in ~w(current not_published)
    status = if head_state == "changed", do: "stale", else: if(current, do: result["status"], else: "unverified")

    Map.merge(result, %{"native_current" => result["current"], "external_head_state" => head_state, "current" => current, "status" => status})
  end

  defp external_head_state(work, task) do
    case work["publication"] do
      %{"pr_number" => number, "pr_url" => url} ->
        pr = Enum.find(task[:pull_requests] || [], &(&1[:number] == number and &1[:url] == url))
        observed_head_state(pr, work, task[:github_status])

      _ ->
        "not_published"
    end
  end

  defp observed_head_state(pr, work, source) when is_map(pr) and source in ~w(available partial) do
    cond do
      not sha?(pr[:head_sha]) -> "unavailable"
      pr[:head_sha] == work["head_sha"] -> "current"
      true -> "changed"
    end
  end

  defp observed_head_state(_pr, _work, _source), do: "unavailable"

  defp current?(work, handoff, review) do
    valid_identity?(work, handoff) and valid_revision?(work, handoff) and
      review["candidate_sha"] == handoff["candidate_sha"]
  end

  defp valid_identity?(work, handoff) do
    sha?(work["head_sha"]) and sha?(work["base_sha"]) and is_binary(handoff["run_id"]) and handoff["run_id"] != "" and
      handoff["work_id"] == work["id"] and handoff["candidate_sha"] == work["head_sha"] and handoff["base_sha"] == work["base_sha"]
  end

  defp valid_revision?(work, handoff) do
    revision = Map.get(handoff, "goal_revision", 1)
    is_integer(revision) and revision > 0 and revision == Map.get(work, "goal_revision", 1)
  end

  defp status(_work, _review, false, _checks), do: "unverified"
  defp status(%{"phase" => phase}, _review, true, _checks) when phase != "owner_review", do: "stale"
  defp status(_work, %{"verdict" => "blocked"}, true, _checks), do: "blocked"
  defp status(_work, %{"verdict" => "request_changes"}, true, _checks), do: "changes_requested"

  defp status(_work, %{"verdict" => "approve", "findings" => []}, true, checks) do
    if checks_status(checks) == "passed", do: "ready", else: "reviewed"
  end

  defp status(_work, _review, true, _checks), do: "unverified"

  defp checks_status([]), do: "not_reported"

  defp checks_status(checks) do
    cond do
      not valid_checks?(checks) -> "invalid"
      Enum.any?(checks, &(&1["result"] == "failed")) -> "failed"
      Enum.all?(checks, &(&1["result"] == "passed")) -> "passed"
      true -> "not_run"
    end
  end

  defp valid_checks?(checks), do: is_list(checks) and Enum.all?(checks, &valid_check?/1)
  defp valid_check?(%{"name" => name, "result" => result, "details" => details}), do: is_binary(name) and String.trim(name) != "" and result in ~w(passed failed not_run) and is_binary(details)
  defp valid_check?(_), do: false
  defp map(value) when is_map(value), do: value
  defp map(_), do: %{}

  defp sha?(value), do: is_binary(value) and String.match?(value, ~r/\A[a-f0-9]{40}\z/)
end
