defmodule SymphonyElixirWeb.AssuranceActions do
  @moduledoc "Small pure edits of the fetched assurance draft; persistence and authorization remain with its owner."

  alias SymphonyElixir.Assurance.Contract

  @errors %{
    stale_assurance_revision: "This draft changed in another session. Refresh and apply your edit again.",
    invalid_assurance_revision: "The saved revision is missing. Refresh before editing.",
    unknown_assurance_requirement: "That requirement is no longer in this draft. Refresh before editing.",
    unknown_assurance_criterion: "That criterion is no longer in this draft. Refresh before editing.",
    unknown_assurance_task: "Choose a task from this project's current board.",
    assurance_task_unobserved: "The current task revision is unavailable. Refresh before linking it.",
    unknown_assurance_evidence: "Choose current observed receipts for this release ID.",
    unknown_assurance_dependency: "Choose a prerequisite declared in this project's current task graph.",
    unknown_assurance_dependency_review: "Choose an existing reviewed baseline or leave the review reference blank.",
    duplicate_assurance_id: "This item already exists. Edit the existing item or use different text.",
    invalid_assurance_release: "Provide a release ID, linked task IDs, full integrated SHA, immutable digest, target, configuration and required checks and gates.",
    invalid_assurance_document: "Use a short title, observable criterion and distinct check names.",
    assurance_not_reviewable: "Every included requirement needs a title, observable criterion and required checks before review.",
    assurance_plan_incomplete: "Every included requirement needs a title, observable criterion and required checks before review.",
    assurance_not_saved: "Save the draft before reviewing a baseline.",
    assurance_record_conflict: "This immutable record ID already exists. Use a new ID for a new candidate.",
    unauthorized: "This session cannot edit assurance records."
  }

  @spec expected_revision(map()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def expected_revision(%{"storage_revision" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {revision, ""} when revision >= 0 -> {:ok, revision}
      _ -> {:error, :invalid_assurance_revision}
    end
  end

  def expected_revision(_), do: {:error, :invalid_assurance_revision}

  @spec edit(map(), String.t(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def edit(draft, action, params, board) when is_map(draft) and is_map(params) and is_map(board) do
    with true <- Contract.valid_document?(draft, draft["project"]),
         {:ok, edited} <- change(draft, action, params, board),
         true <- Contract.valid_document?(edited, draft["project"]) do
      {:ok, edited}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_assurance_document}
    end
  end

  def edit(_, _, _, _), do: {:error, :invalid_assurance_document}

  @spec release(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def release(draft, params, board) do
    ids = names(params["task_ids"])
    selected_evidence = names(params["evidence_ids"])
    observations = get_in(board, [:assurance_observations, "evidence"]) || []
    linked = MapSet.new(Enum.map(draft["task_links"] || [], & &1["task_id"]))

    record = %{
      "id" => text(params["release_id"] || params["id"]),
      "baseline_ref" => text(params["baseline_ref"]),
      "task_ids" => ids,
      "integrated_sha" => text(params["integrated_sha"]),
      "artifact_digest" => text(params["artifact_digest"]),
      "target" => text(params["target"]),
      "configuration_ref" => text(params["configuration_ref"]),
      "required_checks" => names(params["required_checks"]),
      "required_gates" => names(params["required_gates"]),
      "evidence_ids" => selected_evidence
    }

    cond do
      not release_tasks?(ids, linked, board, draft["project"]) ->
        {:error, :unknown_assurance_task}

      not release_evidence?(selected_evidence, observations, record["id"]) ->
        {:error, :unknown_assurance_evidence}

      not Contract.valid_release?(record) ->
        {:error, :invalid_assurance_release}

      true ->
        {:ok, record}
    end
  end

  @spec error_message(term()) :: String.t()
  def error_message(reason), do: Map.get(@errors, reason, "The assurance record could not be saved. Refresh and try again.")

  defp release_tasks?(ids, linked, board, project), do: ids != [] and Enum.all?(ids, &(MapSet.member?(linked, &1) and controlled_task?(board, &1, project)))

  defp release_evidence?(ids, observations, release_id) do
    observed_ids = observations |> Enum.filter(&(&1["release_id"] == release_id and &1["origin"] in ~w(native github))) |> MapSet.new(& &1["id"])
    Enum.all?(ids, &MapSet.member?(observed_ids, &1))
  end

  defp change(draft, "save-requirement", params, _board) do
    existing_id = parameter_id(params, "requirement_id")
    title = text(params["title"])
    id = if existing_id == "", do: generated_id("req", [title]), else: existing_id
    existing = Enum.find(draft["requirements"], &(&1["id"] == id))

    cond do
      existing_id != "" and is_nil(existing) ->
        {:error, :unknown_assurance_requirement}

      existing_id == "" and existing ->
        {:error, :duplicate_assurance_id}

      true ->
        requirement = %{
          "id" => id,
          "title" => title,
          "kind" => params["kind"] || "functional",
          "exclusion" => nullable(params["exclusion"]),
          "criteria" => if(existing, do: existing["criteria"], else: [])
        }

        {:ok, Map.put(draft, "requirements", replace(draft["requirements"], id, requirement))}
    end
  end

  defp change(draft, "save-criterion", params, _board) do
    with {:ok, requirement} <- requirement(draft, params["requirement_id"]) do
      existing_id = parameter_id(params, "criterion_id")
      criterion_text = text(params["text"])
      id = if existing_id == "", do: generated_id("crit", [requirement["id"], criterion_text]), else: existing_id
      existing = Enum.find(requirement["criteria"], &(&1["id"] == id))

      cond do
        existing_id != "" and is_nil(existing) ->
          {:error, :unknown_assurance_criterion}

        existing_id == "" and Enum.any?(Contract.criteria(draft), &(&1["id"] == id)) ->
          {:error, :duplicate_assurance_id}

        true ->
          criterion = %{"id" => id, "text" => criterion_text, "required_checks" => names(params["required_checks"])}
          updated = Map.put(requirement, "criteria", replace(requirement["criteria"], id, criterion))
          {:ok, Map.put(draft, "requirements", replace(draft["requirements"], requirement["id"], updated))}
      end
    end
  end

  defp change(draft, "remove-requirement", params, _board) do
    with {:ok, requirement} <- requirement(draft, params["id"]) do
      removed = MapSet.new(Enum.map(requirement["criteria"], & &1["id"]))
      {:ok, draft |> Map.update!("requirements", &Enum.reject(&1, fn item -> item["id"] == requirement["id"] end)) |> remove_links(removed)}
    end
  end

  defp change(draft, "remove-criterion", params, _board) do
    with {:ok, requirement} <- requirement(draft, params["requirement_id"]),
         true <- Enum.any?(requirement["criteria"], &(&1["id"] == params["id"])) do
      updated = Map.update!(requirement, "criteria", &Enum.reject(&1, fn item -> item["id"] == params["id"] end))
      {:ok, draft |> Map.put("requirements", replace(draft["requirements"], requirement["id"], updated)) |> remove_links(MapSet.new([params["id"]]))}
    else
      {:error, _} = error -> error
      _ -> {:error, :unknown_assurance_criterion}
    end
  end

  defp change(draft, "link-task", params, board) do
    task_id = params["task_id"]
    criterion_id = params["criterion_id"]
    observation = Enum.find(get_in(board, [:assurance_observations, "tasks"]) || [], &(&1["id"] == task_id))

    cond do
      not Enum.any?(Contract.criteria(draft), &(&1["id"] == criterion_id and not &1["excluded"])) ->
        {:error, :unknown_assurance_criterion}

      not controlled_task?(board, task_id, draft["project"]) ->
        {:error, :unknown_assurance_task}

      is_nil(observation) ->
        {:error, :assurance_task_unobserved}

      true ->
        link = %{"task_id" => task_id, "criterion_id" => criterion_id, "task_revision" => observation["revision"], "subject" => observation["subject"]}
        other_links = Enum.reject(draft["task_links"], &(&1["task_id"] == task_id and &1["criterion_id"] == criterion_id))
        {:ok, Map.put(draft, "task_links", other_links ++ [link])}
    end
  end

  defp change(draft, "unlink-task", params, board) do
    if controlled_task?(board, params["task_id"], draft["project"]) do
      {:ok, Map.update!(draft, "task_links", &Enum.reject(&1, fn link -> link["task_id"] == params["task_id"] and link["criterion_id"] == params["criterion_id"] end))}
    else
      {:error, :unknown_assurance_task}
    end
  end

  defp change(draft, "save-dependency", params, board) do
    with :ok <- dependency_tasks(draft, params, board),
         true <- declared_dependency?(board, params) or {:error, :unknown_assurance_dependency},
         :ok <- dependency_review(params, board) do
      record = %{
        "task_id" => params["task_id"],
        "depends_on" => params["depends_on"],
        "reason" => text(params["reason"]),
        "output" => text(params["output"]),
        "reviewed_ref" => nullable(params["reviewed_ref"])
      }

      other = Enum.reject(draft["dependencies"], &dependency_pair?(&1, params))
      {:ok, Map.put(draft, "dependencies", other ++ [record])}
    end
  end

  defp change(draft, "remove-dependency", params, board) do
    with :ok <- dependency_tasks(draft, params, board),
         true <- Enum.any?(draft["dependencies"], &dependency_pair?(&1, params)) or {:error, :unknown_assurance_dependency} do
      {:ok, Map.update!(draft, "dependencies", &Enum.reject(&1, fn item -> dependency_pair?(item, params) end))}
    end
  end

  defp change(_draft, _action, _params, _board), do: {:error, :invalid_assurance_action}

  defp dependency_pair?(item, params), do: item["task_id"] == params["task_id"] and item["depends_on"] == params["depends_on"]

  defp dependency_tasks(draft, params, board) do
    controlled = Enum.all?([params["task_id"], params["depends_on"]], &controlled_task?(board, &1, draft["project"]))

    if controlled and is_nil(board[:runtime_error]),
      do: :ok,
      else: {:error, :unknown_assurance_task}
  end

  defp declared_dependency?(board, params) do
    graph = board[:workflow_graph] || %{}
    ids = Map.new(graph["nodes"] || [], &{&1["id"], &1["task_id"]})

    graph["version"] == 1 and
      Enum.any?(graph["edges"] || [], fn edge ->
        edge["type"] == "depends_on" and ids[edge["source"]] == params["task_id"] and ids[edge["target"]] == params["depends_on"]
      end)
  end

  defp dependency_review(params, board) do
    reference = nullable(params["reviewed_ref"])
    known = Enum.any?(board[:assurance_baselines] || [], &(&1["ref"] == reference))
    if is_nil(reference) or known, do: :ok, else: {:error, :unknown_assurance_dependency_review}
  end

  defp controlled_task?(board, id, project), do: is_nil(board[:source_error]) and Enum.any?(board[:tasks] || [], &(&1[:id] == id and &1[:project] == project))

  defp requirement(draft, id) do
    case Enum.find(draft["requirements"], &(&1["id"] == id)) do
      nil -> {:error, :unknown_assurance_requirement}
      item -> {:ok, item}
    end
  end

  defp replace(items, id, item), do: if(Enum.any?(items, &(&1["id"] == id)), do: Enum.map(items, &if(&1["id"] == id, do: item, else: &1)), else: items ++ [item])
  defp remove_links(draft, removed), do: Map.update!(draft, "task_links", &Enum.reject(&1, fn link -> MapSet.member?(removed, link["criterion_id"]) end))
  defp generated_id(prefix, values), do: prefix <> "-" <> (Contract.ref(values) |> binary_part(0, 12))
  defp names(value) when is_binary(value), do: value |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  defp names(value) when is_list(value), do: value |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  defp names(_), do: []
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_), do: ""
  defp parameter_id(params, field), do: text(params[field] || params["id"])

  defp nullable(value) do
    case text(value) do
      "" -> nil
      text -> text
    end
  end
end
