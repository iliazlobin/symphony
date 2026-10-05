defmodule SymphonyElixirWeb.TaskRework do
  @moduledoc "Builds a bounded, human-reviewed correction command from the displayed issue and PR session."
  alias SymphonyElixir.{Feedback, PRWork}

  @spec options(map()) :: [map()]
  def options(task) do
    (task.ledger["pr_work"] || %{})
    |> Map.values()
    |> Enum.filter(&continuable?(&1, Map.get(task, :pull_requests, [])))
    |> Enum.sort_by(& &1["updated_at"], :desc)
    |> Enum.map(fn work ->
      number = get_in(work, ["publication", "pr_number"])
      label = if number, do: "Continue PR ##{number}", else: "Continue session #{String.slice(work["id"], 0, 8)}"
      %{id: work["id"], label: label}
    end)
  end

  defp continuable?(work, prs) do
    receipt = work["publication"] || %{}
    pr = Enum.find(prs, &(&1.number == receipt["pr_number"]))

    work["phase"] == "owner_review" and receipt["status"] != "merged" and
      (is_nil(pr) or String.downcase(pr.state) == "open")
  end

  @spec prepare(map(), map(), non_neg_integer(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def prepare(task, params, revision, command_id, base_sha) do
    with true <- task.stage == "review" or {:error, :task_not_in_review},
         true <- String.downcase(task.tracker_state || "") == "open" or {:error, :reopen_issue_required},
         {:ok, feedback} <- selected_feedback(task, Map.get(params, "feedback_ids", [])),
         {:ok, instruction} <- instruction(params["instruction"], feedback),
         {:ok, fields} <- work_fields(task, params["work_id"], command_id, base_sha) do
      command = Map.merge(fields, %{"issue_id" => task.issue_id, "command_id" => command_id, "expected_revision" => revision, "instruction" => instruction, "feedback" => feedback})
      if PRWork.valid_command?(command), do: {:ok, command}, else: {:error, :invalid_command}
    else
      {:error, _} = error -> error
    end
  end

  defp selected_feedback(task, ids) when is_list(ids) and length(ids) <= 20 do
    available = get_in(task, [:feedback, :items]) || []
    items = Enum.filter(available, &(&1["id"] in ids)) |> Enum.map(&Map.take(&1, ~w(id revision url body author source pr_number)))
    if length(Enum.uniq(ids)) == length(items) and Feedback.valid_items?(items), do: {:ok, items}, else: {:error, :feedback_changed}
  end

  defp selected_feedback(_, _), do: {:error, :invalid_feedback}

  defp instruction(value, items) when is_binary(value) and byte_size(value) <= 8_000 do
    value = String.trim(value)

    cond do
      value != "" -> {:ok, value}
      items != [] -> {:ok, "Address the selected human feedback for this issue. Preserve the issue scope and acceptance checks; report evidence for each comment."}
      true -> {:error, :corrections_required}
    end
  end

  defp instruction(_, _), do: {:error, :corrections_required}

  defp work_fields(_task, "new", id, base), do: {:ok, %{"action" => "create_pr_work", "work_id" => id, "base_sha" => base}}

  defp work_fields(task, id, _command_id, _base) do
    if Enum.any?(options(task), &(&1.id == id)) do
      {:ok, %{"action" => "continue_pr_work", "work_id" => id, "expected_head_sha" => get_in(task, [:ledger, "pr_work", id, "head_sha"])}}
    else
      {:error, :pr_work_not_found}
    end
  end
end
