defmodule SymphonyElixir.ControlLedger do
  @moduledoc """
  Durable admission controls owned exclusively by the orchestrator.

  GitHub remains the work tracker. This ledger retains only operator decisions,
  execution budgets, local routing decisions and handoff evidence. An advisory OS lock prevents two local
  services from sharing the ledger. Failed persistence always blocks admission.
  """
  alias SymphonyElixir.{IssueAcceptance, PathSafety, PRWork, TaskRouting}
  defstruct [:path, :lock, :settings, :data]

  @lock_script """
  import fcntl, os, sys
  fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
  try:
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
  except BlockingIOError:
      print('LOCKED', flush=True)
      sys.exit(1)
  print('READY', flush=True)
  sys.stdin.buffer.read(1)
  """

  @spec open(map(), Path.t()) :: {:ok, t()} | {:error, term()}
  def open(settings, workspace_root) do
    with :ok <- validate_path(settings.state_path, workspace_root),
         {:ok, lock} <- acquire_lock(settings.state_path <> ".lock") do
      load_locked(settings, lock)
    end
  end

  @doc "Offline, explicitly scoped legacy acceptance recovery; never performs startup recovery or starts execution."
  @spec recover_legacy_acceptance(Path.t(), Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def recover_legacy_acceptance(path, workspace_root, request, opts \\ []) do
    with :ok <- validate_recovery_request(request, opts),
         :ok <- existing_recovery_path(path, workspace_root),
         {:ok, lock} <- acquire_lock(path <> ".lock") do
      try do
        recover_acceptance_locked(path, workspace_root, request, opts)
      after
        close(%__MODULE__{lock: lock})
      end
    end
  end

  defp validate_recovery_request(request, opts) do
    valid =
      recovery_ids?(request[:issue_ids]) and recovery_project?(request[:project_id]) and
        is_binary(request[:tracker_fingerprint]) and byte_size(request.tracker_fingerprint) in 1..256 and
        is_integer(request[:expected_revision]) and request.expected_revision >= 0 and
        recovery_options?(opts)

    if valid, do: :ok, else: {:error, :invalid_acceptance_recovery}
  end

  defp recovery_ids?(ids) when is_list(ids) do
    length(ids) in 1..20 and length(Enum.uniq(ids)) == length(ids) and
      Enum.all?(ids, &(is_binary(&1) and Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, &1)))
  end

  defp recovery_ids?(_), do: false

  defp recovery_project?(project),
    do: is_binary(project) and Regex.match?(~r/\Agithub:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, project)

  defp recovery_options?(opts), do: opts[:apply] in [nil, false, true] and (opts[:apply] != true or is_binary(opts[:backup_path]))

  defp existing_recovery_path(path, workspace_root) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> validate_path(path, workspace_root)
      _ -> {:error, :invalid_recovery_path}
    end
  end

  defp recover_acceptance_locked(path, workspace_root, request, opts) do
    with {:ok, bytes} <- File.read(path),
         {:ok, data} <- decode_control_state(bytes),
         :ok <- recovery_idle_revision(data, request),
         {:ok, next, report} <- upgrade_acceptance_records(data, request),
         :ok <- validate_control_state(next),
         :ok <- persist_recovered_acceptance(path, workspace_root, bytes, next, report, opts) do
      {:ok, report}
    end
  end

  defp persist_recovered_acceptance(path, workspace_root, bytes, next, report, opts) do
    if opts[:apply] == true and report.changed_ids != [] do
      with :ok <- existing_recovery_path(path, workspace_root),
           :ok <- unchanged_recovery_source(path, bytes),
           :ok <- recovery_backup(opts[:backup_path], workspace_root, bytes),
           :ok <- unchanged_recovery_source(path, bytes) do
        persist(%__MODULE__{path: path, data: next})
      end
    else
      :ok
    end
  end

  defp recovery_idle_revision(data, request) do
    cond do
      data["revision"] != request.expected_revision -> {:error, :revision_conflict}
      Enum.any?(data["issues"], fn {_id, item} -> not is_nil(item["active"]) end) -> {:error, :recovery_requires_idle_ledger}
      true -> :ok
    end
  end

  defp upgrade_acceptance_records(data, request) do
    initial = {:ok, data, %{changed_ids: [], already_upgraded_ids: []}}
    Enum.reduce_while(request.issue_ids, initial, &upgrade_acceptance_record(&1, &2, request))
  end

  defp upgrade_acceptance_record(id, {:ok, next, report}, request) do
    item = get_in(next, ["issues", id]) || %{}
    observed = get_in(next, ["tracker_issues", id]) || %{}
    project = get_in(item, ["acceptance", "project_id"])
    legacy = if project == request.project_id, do: update_in(item, ["acceptance"], &Map.delete(&1, "project_id")), else: item
    result = IssueAcceptance.upgrade_legacy(legacy, observed, request.project_id, request.tracker_fingerprint)

    case {observed["id"], result} do
      {^id, {:ok, upgraded}} ->
        key = if upgraded == item, do: :already_upgraded_ids, else: :changed_ids
        {:cont, {:ok, put_in(next, ["issues", id], upgraded), Map.update!(report, key, &(&1 ++ [id]))}}

      _ ->
        {:halt, {:error, :acceptance_migration_mismatch}}
    end
  end

  defp unchanged_recovery_source(path, expected) do
    if File.read(path) == {:ok, expected}, do: :ok, else: {:error, :recovery_source_changed}
  end

  defp recovery_backup(path, workspace_root, bytes) do
    with :ok <- validate_path(path, workspace_root),
         {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
      result = with :ok <- File.chmod(path, 0o600), :ok <- IO.binwrite(file, bytes), do: :file.sync(file)
      File.close(file)
      if result == :ok, do: sync_directory(Path.dirname(path)), else: result
    end
  end

  defp load_locked(settings, lock) do
    with {:ok, data} <- load(settings.state_path, settings.initial_mode),
         ledger = %__MODULE__{path: settings.state_path, lock: lock, settings: settings, data: recover(data, settings)},
         :ok <- persist(ledger) do
      {:ok, ledger}
    else
      error ->
        close(%__MODULE__{lock: lock})
        error
    end
  end

  @type t :: %__MODULE__{}
  @spec close(t()) :: :ok
  def close(%{lock: port}) when is_port(port) do
    try do
      Port.command(port, "q")

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        1_000 -> Port.close(port)
      end
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @spec snapshot(t()) :: map()
  def snapshot(ledger) do
    issues = Map.new(ledger.data["issues"], fn {id, item} -> {id, item |> Map.put_new("attempt_base", 0) |> Map.put("cycle_attempts", cycle_attempts(item))} end)
    ledger.data |> Map.drop(["commands"]) |> Map.put("issues", issues) |> Map.put("enabled", true)
  end

  @spec eligible?(t(), String.t()) :: boolean()
  def eligible?(ledger, issue_id) do
    issue = issue(ledger, issue_id)

    ledger.data["mode"] == "running" and not IssueAcceptance.accepted?(issue) and is_nil(issue["hold"]) and is_nil(issue["active"]) and get_in(issue, ["routing", "queued"]) != false and
      PRWork.dispatchable?(issue) and
      cycle_attempts(issue) < ledger.settings.max_attempts and
      issue["runtime_ms"] < ledger.settings.max_total_runtime_ms and
      issue["tokens"] < ledger.settings.max_total_tokens
  end

  @spec reserve(t(), String.t()) :: {:ok, t(), String.t(), pos_integer()} | {:error, term()}
  def reserve(ledger, issue_id) do
    if eligible?(ledger, issue_id) do
      run_id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      current = issue(ledger, issue_id)
      remaining = ledger.settings.max_total_runtime_ms - current["runtime_ms"]

      active = %{
        "run_id" => run_id,
        "started_at_ms" => now(),
        "started_monotonic_ms" => System.monotonic_time(:millisecond),
        "runtime_epoch" => runtime_epoch(),
        "reserved_runtime_ms" => remaining,
        "tokens" => 0
      }

      next = put_issue(ledger, issue_id, PRWork.reserve(%{current | "attempts" => current["attempts"] + 1, "active" => active}))
      with :ok <- persist(next), do: {:ok, next, run_id, remaining}
    else
      {:error, :not_admitted}
    end
  end

  @spec tokens(t(), String.t(), String.t(), non_neg_integer(), map() | nil) :: {:ok, t()} | {:error, term()}
  def tokens(ledger, issue_id, run_id, total, builder_usage \\ nil) do
    case issue(ledger, issue_id)["active"] do
      %{"run_id" => ^run_id, "tokens" => previous} when total <= previous and is_nil(builder_usage) ->
        {:ok, ledger}

      _ ->
        update_active(ledger, issue_id, run_id, fn current ->
          %{current | "active" => Map.put(current["active"], "tokens", max(total, current["active"]["tokens"]))} |> PRWork.usage(builder_usage)
        end)
    end
  end

  @spec exhausted?(t(), String.t()) :: boolean()
  def exhausted?(ledger, issue_id) do
    current = issue(ledger, issue_id)
    current["tokens"] + (get_in(current, ["active", "tokens"]) || 0) >= ledger.settings.max_total_tokens
  end

  @spec finish(t(), String.t(), String.t(), String.t() | nil, map() | nil) :: {:ok, t()} | {:error, term()}
  def finish(ledger, issue_id, run_id, hold \\ nil, evidence \\ nil) do
    current = issue(ledger, issue_id)

    with %{"run_id" => ^run_id} <- current["active"],
         {:ok, current} <- PRWork.finish(current, hold, evidence) do
      finished = settle(current, ledger.settings)
      finished = if is_nil(hold), do: finished, else: Map.put(finished, "hold", hold)
      finished = if is_nil(evidence), do: finished, else: Map.put(finished, "handoff", evidence)
      next = put_issue(ledger, issue_id, finished)
      with :ok <- persist(next), do: {:ok, next}
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_run}
    end
  end

  @spec selected_work(t(), String.t()) :: map() | nil
  def selected_work(ledger, issue_id), do: PRWork.selected(issue(ledger, issue_id))

  @spec checkpoint_pr_work(t(), String.t(), String.t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def checkpoint_pr_work(ledger, issue_id, run_id, work_id, attrs) do
    current = issue(ledger, issue_id)

    with %{"run_id" => ^run_id} <- current["active"],
         {:ok, updated} <- PRWork.checkpoint(current, work_id, attrs) do
      next = put_issue(ledger, issue_id, updated)
      with :ok <- persist(next), do: {:ok, next}
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_run}
    end
  end

  @spec record_pr_publication(t(), map(), map()) :: {:ok, t(), boolean()} | {:error, term()}
  def record_pr_publication(ledger, receipt, context) do
    with {:ok, updated, replayed} <- PRWork.publication(issue(ledger, receipt["issue_id"]), receipt, context) do
      next = put_issue(ledger, receipt["issue_id"], updated)
      with :ok <- persist(next), do: {:ok, next, replayed}
    end
  end

  @spec hold(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def hold(ledger, issue_id, reason) do
    current = issue(ledger, issue_id)
    next = if IssueAcceptance.accepted?(current), do: ledger, else: put_issue(ledger, issue_id, PRWork.hold(current, reason))
    with :ok <- persist(next), do: {:ok, next}
  end

  @spec command(t(), map(), pos_integer() | nil, map()) :: {:ok, t(), map(), boolean()} | {:error, term()}
  def command(ledger, params, concurrency_ceiling \\ nil, context \\ %{}) do
    with :ok <- validate_command(params) do
      fingerprint = command_fingerprint(params)
      command_id = params["command_id"]

      case ledger.data["commands"][command_id] do
        %{"fingerprint" => ^fingerprint, "result" => result} -> {:ok, ledger, result, true}
        %{} -> {:error, :command_id_conflict}
        nil -> apply_command(ledger, params, fingerprint, concurrency_ceiling, context)
      end
    end
  end

  defp apply_command(ledger, params, fingerprint, concurrency_ceiling, context) do
    cond do
      params["expected_revision"] != ledger.data["revision"] ->
        {:error, :revision_conflict}

      map_size(ledger.data["commands"]) >= 10_000 ->
        {:error, :command_history_full}

      true ->
        transition_command(ledger, params, fingerprint, concurrency_ceiling, context)
    end
  end

  defp transition_command(ledger, params, fingerprint, concurrency_ceiling, context) do
    revision = ledger.data["revision"] + 1

    with {:ok, next} <- transition_settings(ledger, params, concurrency_ceiling, context),
         {:ok, next} <- routing_intent(next, params, revision, context) do
      result = %{"command_id" => params["command_id"], "revision" => revision, "mode" => next.data["mode"], "action" => params["action"], "issue_id" => params["issue_id"]}
      result = if params["action"] == "set_concurrency", do: Map.put(result, "limit", params["limit"]), else: result
      result = if PRWork.command?(params), do: Map.put(result, "work_id", params["work_id"]), else: result
      entry = %{"fingerprint" => fingerprint, "result" => result}
      data = next.data |> Map.put("revision", revision) |> put_in(["commands", params["command_id"]], entry)
      next = %{next | data: data}
      with :ok <- persist(next), do: {:ok, next, result, false}
    end
  end

  @spec command_fingerprint(map()) :: String.t()
  def command_fingerprint(params), do: params |> Map.take(["action", "issue_id", "expected_revision", "limit"] ++ command_fields(params["action"])) |> Jason.encode!()

  @spec effective_concurrency(t() | nil, pos_integer()) :: pos_integer()
  def effective_concurrency(nil, ceiling), do: ceiling
  def effective_concurrency(ledger, ceiling), do: min(ledger.data["concurrency_override"] || ceiling, ceiling)

  defp transition_settings(ledger, %{"action" => "set_concurrency", "limit" => limit}, ceiling, _context) do
    if is_integer(ceiling) and (is_nil(limit) or limit <= ceiling),
      do: {:ok, %{ledger | data: Map.put(ledger.data, "concurrency_override", limit)}},
      else: {:error, :concurrency_limit_exceeded}
  end

  defp transition_settings(ledger, %{"action" => action, "issue_id" => id} = params, _ceiling, context) when action in ["create_pr_work", "continue_pr_work"] do
    current = issue(ledger, id)

    cond do
      IssueAcceptance.accepted?(current) ->
        {:error, :task_already_accepted}

      total_budget_exhausted?(current, ledger.settings) ->
        {:error, :budget_exhausted}

      action == "create_pr_work" and Enum.any?(ledger.data["issues"], fn {other_id, other} -> other_id != id and Map.has_key?(other["pr_work"] || %{}, params["work_id"]) end) ->
        {:error, :pr_work_exists}

      true ->
        with {:ok, next} <- PRWork.transition(current, params, context), do: {:ok, put_issue(ledger, id, Map.put(next, "attempt_base", current["attempts"]))}
    end
  end

  defp transition_settings(ledger, %{"action" => "accept_task", "issue_id" => id} = params, _ceiling, context) do
    with {:ok, current} <- IssueAcceptance.accept(issue(ledger, id), params, context), do: {:ok, put_issue(ledger, id, current)}
  end

  defp transition_settings(ledger, %{"action" => action, "issue_id" => id} = params, _ceiling, context) when action in ~w(queue_task unqueue_task) do
    current = issue(ledger, id)
    observed = get_in(ledger.data, ["tracker_issues", id]) || %{}

    with :ok <- routing_observation(observed, params, context), :ok <- routing_hold(current, action), do: {:ok, ledger}
  end

  defp transition_settings(ledger, params, _ceiling, _context), do: transition(ledger, params["action"], params["issue_id"])

  defp routing_observation(observed, params, context) do
    cond do
      context[:tracker_kind] != "github" or observed["tracker_fingerprint"] != context[:tracker_fingerprint] -> {:error, :task_not_found}
      observed["repository"] != context[:repository] -> {:error, :task_not_found}
      observed["updated_at"] != params["expected_updated_at"] -> {:error, :task_changed}
      observed["state"] != "open" or observed["dispatchable"] != true -> {:error, :task_not_queueable}
      true -> :ok
    end
  end

  defp routing_hold(current, action) do
    cond do
      IssueAcceptance.accepted?(current) -> {:error, :task_already_accepted}
      not is_nil(current["active"]) -> {:error, :issue_running}
      action == "unqueue_task" and current["hold"] != "cancelled" -> {:error, :task_must_be_cancelled}
      action == "queue_task" and current["hold"] not in [nil, "cancelled"] -> {:error, :task_not_queueable}
      true -> :ok
    end
  end

  defp transition(ledger, action, nil) when action in ["pause", "drain", "resume"] do
    mode = %{"pause" => "paused", "drain" => "draining", "resume" => "running"}[action]
    {:ok, %{ledger | data: Map.put(ledger.data, "mode", mode)}}
  end

  defp transition(ledger, "cancel", issue_id) do
    current = issue(ledger, issue_id)
    if IssueAcceptance.accepted?(current), do: {:error, :task_already_accepted}, else: {:ok, put_issue(ledger, issue_id, PRWork.hold(current, "cancelled"))}
  end

  defp transition(ledger, "retry", issue_id) do
    current = issue(ledger, issue_id)

    cond do
      IssueAcceptance.accepted?(current) ->
        {:error, :task_already_accepted}

      not is_nil(current["active"]) ->
        {:error, :issue_running}

      budget_exhausted?(current, ledger.settings) ->
        {:error, :budget_exhausted}

      true ->
        with {:ok, current} <- PRWork.retry(current), do: {:ok, put_issue(ledger, issue_id, Map.put(current, "hold", nil))}
    end
  end

  defp budget_exhausted?(issue, settings) do
    cycle_attempts(issue) >= settings.max_attempts or total_budget_exhausted?(issue, settings)
  end

  defp total_budget_exhausted?(issue, settings), do: issue["runtime_ms"] >= settings.max_total_runtime_ms or issue["tokens"] >= settings.max_total_tokens
  defp cycle_attempts(issue), do: issue["attempts"] - (issue["attempt_base"] || 0)

  defp validate_command(%{"command_id" => id, "expected_revision" => revision, "action" => action} = params)
       when is_binary(id) and byte_size(id) in 1..128 and is_integer(revision) and revision >= 0 do
    allowed_keys = ["command_id", "expected_revision", "action", "issue_id"] ++ if(action == "set_concurrency", do: ["limit"], else: command_fields(action))
    valid_limit = valid_setting?(action, params)

    if valid_limit and valid_action?(action, params["issue_id"]) and Enum.all?(Map.keys(params), &(&1 in allowed_keys)),
      do: :ok,
      else: {:error, :invalid_command}
  end

  defp validate_command(_), do: {:error, :invalid_command}
  defp valid_setting?("set_concurrency", params), do: Map.has_key?(params, "limit") and valid_override?(params["limit"])

  defp valid_setting?(action, params) when action in ~w(queue_task unqueue_task),
    do: is_binary(params["expected_updated_at"]) and match?({:ok, _, _}, DateTime.from_iso8601(params["expected_updated_at"]))

  defp valid_setting?("accept_task", params), do: IssueAcceptance.valid_command?(params)
  defp valid_setting?(action, params) when action in ["create_pr_work", "continue_pr_work"], do: PRWork.valid_command?(params)
  defp valid_setting?(_action, _params), do: true

  defp valid_action?(action, nil) when action in ["pause", "drain", "resume", "set_concurrency"], do: true

  defp valid_action?(action, id) when action in ["cancel", "retry", "accept_task", "create_pr_work", "continue_pr_work", "queue_task", "unqueue_task"] and is_binary(id),
    do: byte_size(id) in 1..128

  defp valid_action?(_, _), do: false
  defp command_fields(action) when action in ~w(queue_task unqueue_task), do: ["expected_updated_at"]
  defp command_fields(action), do: PRWork.command_fields(action) ++ IssueAcceptance.command_fields(action)

  defp routing_intent(ledger, %{"issue_id" => id, "action" => action}, revision, context) when is_binary(id) do
    current = issue(ledger, id)
    updated = TaskRouting.intent(current, action, revision, context)

    if TaskRouting.valid?(updated["routing"]),
      do: {:ok, if(updated == current, do: ledger, else: put_issue(ledger, id, updated))},
      else: {:error, :invalid_routing_configuration}
  end

  defp routing_intent(ledger, _params, _revision, _context), do: {:ok, ledger}

  @spec observe_issues(t(), [SymphonyElixir.Tracker.Issue.t()], map()) :: {:ok, t()} | {:error, term()}
  def observe_issues(ledger, issues, tracker) do
    current = ledger.data["tracker_issues"] || %{}
    observations = Enum.reduce(issues, current, &observe_issue(&1, &2, tracker))

    cond do
      observations == current ->
        {:ok, ledger}

      not valid_observations?(observations) ->
        {:error, :task_catalog_full}

      true ->
        next = %{ledger | data: Map.put(ledger.data, "tracker_issues", observations)}
        with :ok <- persist(next), do: {:ok, next}
    end
  end

  defp observe_issue(issue, observations, tracker) do
    case TaskRouting.observation(issue, tracker) do
      nil ->
        observations

      record ->
        if newer_observation?(observations[record["id"]], record), do: Map.put(observations, record["id"], record), else: observations
    end
  end

  defp newer_observation?(nil, _record), do: true
  defp newer_observation?(%{"tracker_fingerprint" => scope}, %{"tracker_fingerprint" => other}) when scope != other, do: true

  defp newer_observation?(previous, record) do
    {:ok, old, _} = DateTime.from_iso8601(previous["updated_at"])
    {:ok, new, _} = DateTime.from_iso8601(record["updated_at"])
    DateTime.compare(new, old) != :lt
  end

  @spec routing_sync_result(t(), String.t(), pos_integer(), String.t(), :ok | {:error, atom()}) ::
          {:ok, t()} | {:error, term()}
  def routing_sync_result(ledger, id, revision, scope, result) do
    current = issue(ledger, id)

    case current["routing"] do
      %{"revision" => ^revision, "tracker_fingerprint" => ^scope} = routing ->
        persist_routing_sync(ledger, id, current, routing, result)

      _ ->
        {:error, :stale_routing_intent}
    end
  end

  defp persist_routing_sync(ledger, id, current, routing, result) do
    with {:ok, routing} <- sync_result(routing, result), next = put_issue(ledger, id, Map.put(current, "routing", routing)), :ok <- persist(next), do: {:ok, next}
  end

  defp sync_result(routing, :ok), do: {:ok, %{routing | "status" => "synced", "error" => nil, "synced_at" => DateTime.utc_now() |> DateTime.to_iso8601()}}
  defp sync_result(routing, {:error, reason}) when is_atom(reason), do: {:ok, %{routing | "status" => "pending", "error" => reason |> Atom.to_string() |> String.slice(0, 128)}}
  defp sync_result(_routing, _result), do: {:error, :invalid_sync_result}

  defp update_active(ledger, issue_id, run_id, fun) do
    current = issue(ledger, issue_id)

    case current["active"] do
      %{"run_id" => ^run_id} ->
        next = put_issue(ledger, issue_id, fun.(current))
        with :ok <- persist(next), do: {:ok, next}

      _ ->
        {:error, :stale_run}
    end
  end

  defp issue(ledger, id), do: Map.get(ledger.data["issues"], id, %{"attempts" => 0, "runtime_ms" => 0, "tokens" => 0, "hold" => nil, "active" => nil})
  defp put_issue(ledger, id, current), do: %{ledger | data: put_in(ledger.data, ["issues", id], current)}
  defp now, do: System.system_time(:millisecond)

  defp runtime_epoch, do: System.pid() <> ":" <> Integer.to_string(:erlang.system_info(:start_time))

  defp settle(current, settings) do
    active = current["active"]

    elapsed =
      if active["runtime_epoch"] == runtime_epoch() and is_integer(active["started_monotonic_ms"]) do
        min(max(0, System.monotonic_time(:millisecond) - active["started_monotonic_ms"]), settings.max_total_runtime_ms)
      else
        # An unknown runtime epoch cannot prove unused time. Keep the reservation
        # consumed instead of letting restart or a clock adjustment refund budget.
        active["reserved_runtime_ms"] || max(0, settings.max_total_runtime_ms - current["runtime_ms"])
      end

    %{current | "runtime_ms" => current["runtime_ms"] + elapsed, "tokens" => current["tokens"] + active["tokens"], "active" => nil}
  end

  defp recover(data, settings) do
    interrupted = Enum.any?(data["issues"], fn {_id, issue} -> not is_nil(issue["active"]) end)

    issues =
      Map.new(data["issues"], fn {id, issue} ->
        if issue["active"], do: {id, issue |> PRWork.recover() |> settle(settings) |> Map.put("hold", "interrupted")}, else: {id, issue}
      end)

    data = Map.put(data, "issues", issues)
    if interrupted, do: Map.put(data, "mode", "paused"), else: data
  end

  defp load(path, initial_mode) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= 10_000_000 ->
        decode_control_state(bytes)

      {:error, :enoent} ->
        {:ok, %{"version" => 1, "revision" => 0, "mode" => initial_mode, "issues" => %{}, "commands" => %{}, "concurrency_override" => nil}}

      _ ->
        {:error, :unreadable_control_state}
    end
  end

  defp decode_control_state(bytes) when byte_size(bytes) <= 10_000_000 do
    with {:ok, data} <- Jason.decode(bytes), :ok <- validate_control_state(data), do: {:ok, data}, else: (_ -> {:error, :invalid_control_state})
  end

  defp decode_control_state(_), do: {:error, :unreadable_control_state}
  defp validate_control_state(data), do: if(valid_data?(data), do: :ok, else: {:error, :invalid_control_state})

  defp valid_data?(%{"version" => 1, "revision" => revision, "mode" => mode, "issues" => issues, "commands" => commands} = data)
       when is_integer(revision) and revision >= 0 and mode in ["paused", "draining", "running"] and is_map(issues) and is_map(commands) do
    valid_observations?(data["tracker_issues"] || %{}) and valid_override?(data["concurrency_override"]) and
      valid_records?(issues, commands)
  end

  defp valid_data?(_), do: false

  defp valid_records?(issues, commands), do: valid_issues?(issues) and Enum.all?(commands, &valid_command_entry?/1) and unique_pr_work_ids?(issues)

  defp valid_issues?(issues) do
    Enum.all?(issues, fn {id, item} ->
      is_binary(id) and valid_issue?(item) and PRWork.valid_issue?(id, item) and IssueAcceptance.valid_record?(item["acceptance"]) and TaskRouting.valid?(item["routing"])
    end)
  end

  defp valid_observations?(observations) when is_map(observations) do
    map_size(observations) <= 10_000 and Enum.all?(observations, fn {id, record} -> TaskRouting.valid_observation?(record) and record["id"] == id end)
  end

  defp valid_observations?(_), do: false

  defp unique_pr_work_ids?(issues) do
    ids = Enum.flat_map(issues, fn {_id, item} -> Map.keys(item["pr_work"] || %{}) end)
    length(ids) == MapSet.size(MapSet.new(ids))
  end

  defp valid_override?(nil), do: true
  defp valid_override?(limit), do: is_integer(limit) and limit > 0

  defp valid_command_entry?({id, %{"fingerprint" => fingerprint, "result" => result}}),
    do: is_binary(id) and is_binary(fingerprint) and is_map(result)

  defp valid_command_entry?(_), do: false

  defp valid_issue?(%{"attempts" => a, "runtime_ms" => r, "tokens" => t, "hold" => h, "active" => active} = issue) do
    base = Map.get(issue, "attempt_base", 0)
    Enum.all?([a, r, t, base], &(is_integer(&1) and &1 >= 0)) and base <= a and (is_nil(h) or is_binary(h)) and valid_active?(active)
  end

  defp valid_issue?(_), do: false
  defp valid_active?(nil), do: true
  defp valid_active?(%{"run_id" => id, "started_at_ms" => at, "tokens" => tokens}), do: is_binary(id) and is_integer(at) and is_integer(tokens) and tokens >= 0
  defp valid_active?(_), do: false

  defp validate_path(path, root) when is_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, parent} <- PathSafety.canonicalize(Path.dirname(path)),
         {:ok, canonical_root} <- PathSafety.canonicalize(root) do
      cond do
        path != Path.join(parent, Path.basename(path)) ->
          {:error, :control_path_symlink}

        path == canonical_root or String.starts_with?(path, canonical_root <> "/") ->
          {:error, :control_state_inside_workspace}

        symlink?(path) or symlink?(path <> ".lock") ->
          {:error, :control_path_symlink}

        true ->
          :ok
      end
    end
  end

  defp validate_path(_, _), do: {:error, :missing_control_state_path}
  defp symlink?(path), do: match?({:ok, %{type: :symlink}}, File.lstat(path))

  defp acquire_lock(path) do
    case System.find_executable("python3") do
      nil ->
        {:error, :python3_required_for_control_lock}

      python ->
        environment = Enum.map(System.get_env(), fn {name, _value} -> {String.to_charlist(name), false} end)

        options = [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["-I", "-u", "-c", @lock_script, path],
          env: environment,
          line: 128
        ]

        port = Port.open({:spawn_executable, python}, options)

        receive do
          {^port, {:data, {:eol, "READY"}}} ->
            {:ok, port}

          {^port, _} ->
            close(%__MODULE__{lock: port})
            {:error, :control_state_locked}
        after
          5_000 ->
            close(%__MODULE__{lock: port})
            {:error, :control_lock_timeout}
        end
    end
  end

  defp sync_directory(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      result = :file.sync(file)
      :file.close(file)
      result
    end
  end

  defp persist(ledger) do
    bytes = Jason.encode!(ledger.data)

    if byte_size(bytes) <= 10_000_000 do
      persist_bytes(ledger, bytes)
    else
      {:error, {:control_persistence, :state_too_large}}
    end
  end

  defp persist_bytes(ledger, bytes) do
    temp = ledger.path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    result =
      with {:ok, file} <- File.open(temp, [:write, :binary, :exclusive]) do
        result = with :ok <- File.chmod(temp, 0o600), :ok <- IO.binwrite(file, bytes), do: :file.sync(file)
        File.close(file)
        with :ok <- result, :ok <- File.rename(temp, ledger.path), do: sync_directory(Path.dirname(ledger.path))
      end

    if result != :ok, do: File.rm(temp)

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:control_persistence, reason}}
    end
  end
end
