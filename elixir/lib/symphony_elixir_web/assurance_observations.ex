defmodule SymphonyElixirWeb.AssuranceObservations do
  @moduledoc "Server-owned, exact candidate observations. Declarations and rollup success are never test receipts."

  alias SymphonyElixir.Assurance.Contract
  alias SymphonyElixir.{Config, Orchestrator, WorkEvidence}
  alias SymphonyElixirWeb.{BoardCache, Endpoint, TaskBoard}

  @doc "Current source and native state are required for new graph reviews and evidence."
  @spec source_current?(term()) :: boolean()
  def source_current?(board) when is_map(board),
    do: is_nil(board[:source_error]) and is_nil(board[:runtime_error]) and fresh?(board[:generated_at])

  def source_current?(_board), do: false

  @spec from_board(map(), map()) :: map()
  def from_board(board, document) do
    tasks = Enum.filter(board[:tasks] || [], &(&1[:project] == document["project"]))
    complete = source_current?(board)
    observations = Enum.map(tasks, fn task -> %{"id" => task[:id], "revision" => revision(task), "subject" => if(complete, do: subject(task))} end)
    links = document["task_links"] || []
    timestamp = board[:generated_at]
    evidence = if complete, do: Enum.flat_map(links, &link_evidence(&1, tasks, timestamp)), else: []
    %{"tasks" => observations, "evidence" => Enum.uniq_by(evidence, & &1["id"])}
  end

  @spec revision(map()) :: String.t()
  def revision(task) do
    goals = (get_in(task, [:ledger, "pr_work"]) || %{}) |> Enum.map(fn {id, work} -> [id, work["goal_revision"] || 1] end) |> Enum.sort()
    Contract.ref([task[:id], task[:title], task[:description], task[:dependencies] || [], task[:task_kind], goals])
  end

  @doc "Rechecks an exact host receipt against the current scoped source cache and native decisions."
  @spec verify(String.t(), map()) :: boolean()
  def verify(project, record) do
    with {:ok, board} <- trusted_board(),
         true <- source_current?(board) do
      board[:tasks]
      |> Enum.filter(&(&1[:project] == project and subject(&1) == record["subject"]))
      |> Enum.flat_map(&candidate_evidence(&1, record["criterion_id"], board[:generated_at]))
      |> Enum.any?(&(Map.delete(&1, "observed_at") == Map.delete(record, "observed_at")))
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp trusted_board do
    server = Endpoint.config(:orchestrator) || Orchestrator

    with {:ok, _settings} <- Config.settings(),
         {:ok, board} <- BoardCache.get(BoardCache.scope(server)) do
      refreshed = TaskBoard.refresh_control(board, Orchestrator.control_snapshot(server))
      if source_current?(refreshed), do: {:ok, refreshed}, else: :unavailable
    end
  end

  @spec badges(map(), map()) :: map()
  def badges(projection, observations) do
    rows = projection["criteria"] || []

    tasks =
      Map.new(observations["tasks"] || [], fn task ->
        linked = Enum.filter(rows, &(task["id"] in &1["task_ids"]))
        verified = Enum.count(linked, &(&1["status"] == "covered"))

        status =
          cond do
            linked == [] -> "unlinked"
            Enum.any?(linked, &("stale" in &1["issues"])) -> "stale"
            length(linked) == verified -> "verified"
            true -> "missing"
          end

        {task["id"], %{"criterion_count" => length(linked), "verified_count" => verified, "gap_count" => length(linked) - verified, "status" => status}}
      end)

    Map.put(projection, "tasks", tasks)
  end

  defp subject(task) do
    work = latest_work(task)
    result = work_subject(task, work)
    if Contract.valid_subject?(result), do: result
  end

  defp latest_work(task) do
    (get_in(task, [:ledger, "pr_work"]) || %{})
    |> Map.values()
    |> Enum.sort_by(&{&1["updated_at"] || "", &1["id"] || ""}, :desc)
    |> Enum.find(&(WorkEvidence.for_task(&1, task)["current"] == true))
  end

  defp work_subject(task, work) do
    publication = if work, do: work["publication"] || %{}, else: %{}
    number = publication["pr_number"]

    %{
      "kind" => if(is_integer(number), do: "pr", else: "source"),
      "repository" => String.replace_prefix(task[:project] || "", "github:", ""),
      "revision" => if(work, do: work["head_sha"]),
      "artifact_digest" => nil,
      "environment" => nil,
      "configuration_ref" => nil,
      "pr_number" => number
    }
  end

  defp link_evidence(link, tasks, timestamp) do
    case Enum.find(tasks, &(&1[:id] == link["task_id"])) do
      nil ->
        []

      task ->
        current = revision(task) == link["task_revision"] and subject(task) == link["subject"]
        if current, do: candidate_evidence(task, link["criterion_id"], timestamp), else: []
    end
  end

  defp candidate_evidence(task, criterion, timestamp) do
    current_subject = subject(task)

    if current_subject && is_binary(criterion) do
      native = (get_in(task, [:ledger, "pr_work"]) || %{}) |> Map.values() |> Enum.flat_map(&native_receipt(&1, task, criterion, current_subject, timestamp))
      native ++ github_evidence(task, criterion, current_subject, timestamp)
    else
      []
    end
  end

  defp native_receipt(work, task, criterion, subject, timestamp) do
    result = WorkEvidence.for_task(work, task)

    if result["current"] and result["status"] in ~w(ready reviewed) and work["head_sha"] == subject["revision"],
      do: [receipt(criterion, "independent-review", subject, "symphony:independent-review", work["id"] <> ":" <> result["run_id"], "passed", timestamp, "native")],
      else: []
  end

  defp github_evidence(task, criterion, subject, timestamp) do
    (task[:pull_requests] || [])
    |> Enum.filter(&matching_pr?(&1, subject))
    |> Enum.flat_map(&ci_receipts(&1, criterion, subject, timestamp))
  end

  defp matching_pr?(pr, subject), do: pr[:number] == subject["pr_number"] and pr[:head_sha] == subject["revision"] and pr[:check_details_status] == "available"

  defp ci_receipts(pr, criterion, subject, timestamp) do
    (pr[:check_runs] || [])
    |> Enum.filter(&(&1[:kind] == "check_run" and &1[:app_slug] == "github-actions" and is_binary(&1[:id])))
    |> Enum.map(&receipt(criterion, "ci:" <> &1[:name], subject, "github-app:github-actions", &1[:id], check_result(&1), timestamp, "github"))
    |> Enum.filter(&Contract.valid_evidence?/1)
  end

  defp check_result(%{status: "completed", conclusion: "success"}), do: "passed"
  defp check_result(%{status: "completed", conclusion: conclusion}) when conclusion in ~w(skipped neutral), do: "skipped"
  defp check_result(%{status: "completed"}), do: "failed"
  defp check_result(_), do: "pending"

  defp receipt(criterion, check, subject, producer, run, result, timestamp, origin) do
    %{
      "id" => Contract.ref([criterion, check, subject, producer, run, result]),
      "criterion_id" => criterion,
      "release_id" => nil,
      "check" => check,
      "subject" => subject,
      "producer" => producer,
      "run_id" => run,
      "result" => result,
      "observed_at" => timestamp,
      "origin" => origin
    }
  end

  defp fresh?(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, time, 0} -> DateTime.diff(DateTime.utc_now(), time) in 0..120
      _ -> false
    end
  end

  defp fresh?(_), do: false
end
