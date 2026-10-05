defmodule SymphonyElixir.Specification.TaskLinks do
  @moduledoc "Projects requirement-to-task coverage from immutable specifications and durable creation receipts."

  alias SymphonyElixir.Specification.Document
  alias SymphonyElixir.{TaskDraft, WorkEvidence}

  @source ~r/^Specification source: ([a-f0-9]{64})\/([A-Za-z][A-Za-z0-9_-]{0,63})\/requirements\/([A-Za-z][A-Za-z0-9_-]{0,63})\/([A-Za-z0-9_,-]+)$/m

  @spec reference(term()) :: map() | nil
  def reference(body) when is_binary(body) do
    with [_] <- Regex.scan(~r/^Specification source:/m, body),
         [[_line, ref, document, item, ids]] <- Regex.scan(@source, body),
         criteria = String.split(ids, ","),
         true <- length(criteria) in 1..30 and criteria == Enum.uniq(criteria) and Enum.all?(criteria, &Document.identifier?/1) do
      %{ref: ref, document: document, item: item, criteria: criteria}
    else
      _ -> nil
    end
  end

  def reference(_body), do: nil

  @spec display_body(String.t()) :: String.t()
  def display_body(body), do: if(reference(body), do: Regex.replace(@source, body, "") |> String.trim(), else: body)

  @spec requirement(term(), String.t()) :: map() | nil
  def requirement(%{"sections" => %{"requirements" => %{"items" => items}}}, id), do: Enum.find(items, &(&1["id"] == id))
  def requirement(_document, _id), do: nil

  @spec actionable?(term()) :: boolean()
  def actionable?(%{"title" => title, "body" => body, "criteria" => [_ | _] = criteria}) do
    String.trim(title) != "" and String.trim(body) != "" and Enum.all?(criteria, &(String.trim(&1["statement"]) != ""))
  end

  def actionable?(_item), do: false

  @spec action_args(map(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def action_args(document, ref, id) do
    if Document.valid?(document, document["project"]) and Document.content_ref(document) == ref do
      task_args(document, ref, requirement(document, id))
    else
      {:error, :specification_criteria_required}
    end
  end

  defp task_args(document, ref, item) do
    if actionable?(item) do
      ids = Enum.map_join(item["criteria"], ",", & &1["id"])
      source = "Specification source: #{ref}/#{document["document_id"]}/requirements/#{item["id"]}/#{ids}"
      criteria = Enum.map_join(item["criteria"], "\n\n", &quote_text("#{&1["id"]} (#{&1["method"]}): #{&1["statement"]}"))
      fields = %{"title" => item["title"], "description" => "Reviewed requirement:\n\n#{quote_text(item["body"])}\n\n#{source}", "verification" => criteria}

      case TaskDraft.action_args(fields) do
        {:ok, args} -> {:ok, args}
        {:error, _} -> {:error, :specification_task_too_large}
      end
    else
      {:error, :specification_criteria_required}
    end
  end

  @doc "Missing data is unknown, and a task label or human acceptance alone never verifies a criterion."
  @spec coverage(map() | nil, String.t() | nil, {:ok, list()} | {:error, term()}, [map()], boolean()) :: map()
  def coverage(nil, _ref, _records, _tasks, _available), do: %{}

  def coverage(document, ref, records, tasks, available) do
    available = available and Document.valid?(document, document["project"]) and Document.content_ref(document) == ref

    Map.new(document["sections"]["requirements"]["items"], fn item ->
      {item["id"], coverage_row(document, ref, item, records, tasks, available)}
    end)
  end

  defp coverage_row(document, ref, item, {:ok, records}, tasks, true) do
    case task_args(document, ref, item) do
      {:ok, args} ->
        bindings =
          for record <- records,
              record["project_id"] == document["project"],
              proposal <- record["proposals"] || [],
              proposal["action"] == "create_task",
              matches?(proposal["args"], args),
              do: with_preview(binding(proposal, document["project"], tasks), record["id"])

        links = Enum.reject(bindings, &is_nil/1)

        %{status: coverage_status(links), criteria_count: length(item["criteria"]), links: links}

      {:error, _} ->
        %{status: "incomplete", criteria_count: length(Map.get(item, "criteria", [])), links: []}
    end
  end

  defp coverage_row(_document, _ref, item, _records, _tasks, _available),
    do: %{status: "unknown", criteria_count: length(Map.get(item, "criteria", [])), links: []}

  defp coverage_status(links) do
    Enum.find(~w(linked changed unknown pending), "missing", fn status -> Enum.any?(links, &(&1.status == status)) end)
  end

  defp binding(%{"status" => "completed"} = proposal, project, tasks) do
    with %{"widgets" => widgets} when is_list(widgets) <- proposal["receipt"],
         [%{"task_id" => id}] <- Enum.filter(widgets, &(&1["type"] == "receipt" and &1["proposal_id"] == proposal["id"])),
         true <- is_binary(id) and String.starts_with?(id, project <> ":") do
      task = Enum.find(tasks, &(&1.id == id and &1.project == project))
      task_binding(proposal, id, task)
    else
      _ -> %{status: "unknown", task_id: nil, title: "Creation receipt unavailable", stage: nil, candidate: nil}
    end
  end

  defp binding(%{"status" => status}, _project, _tasks) when status in ~w(pending executing unknown) do
    %{
      status: if(status == "unknown", do: "unknown", else: "pending"),
      task_id: nil,
      title: if(status == "unknown", do: "Creation outcome uncertain", else: "Task preview pending"),
      stage: nil,
      candidate: nil
    }
  end

  defp binding(_proposal, _project, _tasks), do: nil

  defp task_binding(_proposal, id, nil), do: %{status: "unknown", task_id: id, title: "Task not in the current board", stage: nil, candidate: nil}

  defp task_binding(proposal, id, task) do
    args = proposal["args"]
    expected = args["body"] <> "\n\n<!-- symphony-chat:" <> proposal["id"] <> " -->"
    current = task.title == args["title"] and task.description == expected
    status = if task[:source_missing], do: "unknown", else: if(current, do: "linked", else: "changed")
    %{status: status, task_id: id, title: task[:identifier] || task.title, stage: task.stage, candidate: candidate(task)}
  end

  defp candidate(task) do
    works = get_in(task, [:ledger, "pr_work"]) || %{}

    works
    |> Map.values()
    |> Enum.filter(&(&1["issue_id"] == task[:issue_id]))
    |> Enum.sort_by(&(&1["updated_at"] || ""), :desc)
    |> Enum.map(&WorkEvidence.for_task(&1, task))
    |> List.first()
  end

  defp matches?(input, args), do: is_map(input) and Map.take(input, ~w(title body)) == Map.take(args, ~w(title body))
  defp with_preview(nil, _id), do: nil
  defp with_preview(binding, id), do: Map.put(binding, :preview_id, id)
  defp quote_text(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
end
