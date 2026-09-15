defmodule SymphonyElixir.ControlLedger do
  @moduledoc """
  Durable admission controls owned exclusively by the orchestrator.

  GitHub remains the work tracker. This ledger retains only operator decisions,
  execution budgets and handoff evidence. An advisory OS lock prevents two local
  services from sharing the ledger. Failed persistence always blocks admission.
  """
  alias SymphonyElixir.PathSafety
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
  def snapshot(ledger), do: ledger.data |> Map.drop(["commands"]) |> Map.put("enabled", true)

  @spec eligible?(t(), String.t()) :: boolean()
  def eligible?(ledger, issue_id) do
    issue = issue(ledger, issue_id)

    ledger.data["mode"] == "running" and is_nil(issue["hold"]) and is_nil(issue["active"]) and
      issue["attempts"] < ledger.settings.max_attempts and
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

      next = put_issue(ledger, issue_id, %{current | "attempts" => current["attempts"] + 1, "active" => active})
      with :ok <- persist(next), do: {:ok, next, run_id, remaining}
    else
      {:error, :not_admitted}
    end
  end

  @spec tokens(t(), String.t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def tokens(ledger, issue_id, run_id, total) do
    case issue(ledger, issue_id)["active"] do
      %{"run_id" => ^run_id, "tokens" => previous} when total <= previous ->
        {:ok, ledger}

      _ ->
        update_active(ledger, issue_id, run_id, fn current ->
          %{current | "active" => Map.put(current["active"], "tokens", max(total, current["active"]["tokens"]))}
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
    update_active(ledger, issue_id, run_id, fn current ->
      finished = settle(current, ledger.settings)
      finished = if is_nil(hold), do: finished, else: Map.put(finished, "hold", hold)
      if is_nil(evidence), do: finished, else: Map.put(finished, "handoff", evidence)
    end)
  end

  @spec hold(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def hold(ledger, issue_id, reason) do
    next = put_issue(ledger, issue_id, Map.put(issue(ledger, issue_id), "hold", reason))
    with :ok <- persist(next), do: {:ok, next}
  end

  @spec command(t(), map(), pos_integer() | nil) :: {:ok, t(), map(), boolean()} | {:error, term()}
  def command(ledger, params, concurrency_ceiling \\ nil) do
    with :ok <- validate_command(params) do
      fingerprint = command_fingerprint(params)
      command_id = params["command_id"]

      case ledger.data["commands"][command_id] do
        %{"fingerprint" => ^fingerprint, "result" => result} -> {:ok, ledger, result, true}
        %{} -> {:error, :command_id_conflict}
        nil -> apply_command(ledger, params, fingerprint, concurrency_ceiling)
      end
    end
  end

  defp apply_command(ledger, params, fingerprint, concurrency_ceiling) do
    cond do
      params["expected_revision"] != ledger.data["revision"] ->
        {:error, :revision_conflict}

      map_size(ledger.data["commands"]) >= 10_000 ->
        {:error, :command_history_full}

      true ->
        transition_command(ledger, params, fingerprint, concurrency_ceiling)
    end
  end

  defp transition_command(ledger, params, fingerprint, concurrency_ceiling) do
    with {:ok, next} <- transition_settings(ledger, params, concurrency_ceiling) do
      revision = ledger.data["revision"] + 1
      result = %{"command_id" => params["command_id"], "revision" => revision, "mode" => next.data["mode"], "action" => params["action"], "issue_id" => params["issue_id"]}
      result = if params["action"] == "set_concurrency", do: Map.put(result, "limit", params["limit"]), else: result
      entry = %{"fingerprint" => fingerprint, "result" => result}
      data = next.data |> Map.put("revision", revision) |> put_in(["commands", params["command_id"]], entry)
      next = %{next | data: data}
      with :ok <- persist(next), do: {:ok, next, result, false}
    end
  end

  @spec command_fingerprint(map()) :: String.t()
  def command_fingerprint(params), do: params |> Map.take(["action", "issue_id", "expected_revision", "limit"]) |> Jason.encode!()

  @spec effective_concurrency(t() | nil, pos_integer()) :: pos_integer()
  def effective_concurrency(nil, ceiling), do: ceiling
  def effective_concurrency(ledger, ceiling), do: min(ledger.data["concurrency_override"] || ceiling, ceiling)

  defp transition_settings(ledger, %{"action" => "set_concurrency", "limit" => limit}, ceiling) do
    if is_integer(ceiling) and (is_nil(limit) or limit <= ceiling),
      do: {:ok, %{ledger | data: Map.put(ledger.data, "concurrency_override", limit)}},
      else: {:error, :concurrency_limit_exceeded}
  end

  defp transition_settings(ledger, params, _ceiling), do: transition(ledger, params["action"], params["issue_id"])

  defp transition(ledger, action, nil) when action in ["pause", "drain", "resume"] do
    mode = %{"pause" => "paused", "drain" => "draining", "resume" => "running"}[action]
    {:ok, %{ledger | data: Map.put(ledger.data, "mode", mode)}}
  end

  defp transition(ledger, "cancel", issue_id) do
    {:ok, put_issue(ledger, issue_id, Map.put(issue(ledger, issue_id), "hold", "cancelled"))}
  end

  defp transition(ledger, "retry", issue_id) do
    current = issue(ledger, issue_id)

    cond do
      not is_nil(current["active"]) ->
        {:error, :issue_running}

      budget_exhausted?(current, ledger.settings) ->
        {:error, :budget_exhausted}

      true ->
        {:ok, put_issue(ledger, issue_id, Map.put(current, "hold", nil))}
    end
  end

  defp budget_exhausted?(issue, settings) do
    issue["attempts"] >= settings.max_attempts or issue["runtime_ms"] >= settings.max_total_runtime_ms or
      issue["tokens"] >= settings.max_total_tokens
  end

  defp validate_command(%{"command_id" => id, "expected_revision" => revision, "action" => action} = params)
       when is_binary(id) and byte_size(id) in 1..128 and is_integer(revision) and revision >= 0 do
    allowed_keys = ["command_id", "expected_revision", "action", "issue_id"] ++ if(action == "set_concurrency", do: ["limit"], else: [])
    valid_limit = valid_setting?(action, params)

    if valid_limit and valid_action?(action, params["issue_id"]) and Enum.all?(Map.keys(params), &(&1 in allowed_keys)),
      do: :ok,
      else: {:error, :invalid_command}
  end

  defp validate_command(_), do: {:error, :invalid_command}
  defp valid_setting?("set_concurrency", params), do: Map.has_key?(params, "limit") and valid_override?(params["limit"])
  defp valid_setting?(_action, _params), do: true

  defp valid_action?(action, nil) when action in ["pause", "drain", "resume", "set_concurrency"], do: true

  defp valid_action?(action, id) when action in ["cancel", "retry"] and is_binary(id),
    do: byte_size(id) in 1..128

  defp valid_action?(_, _), do: false

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
        if issue["active"], do: {id, issue |> settle(settings) |> Map.put("hold", "interrupted")}, else: {id, issue}
      end)

    data = Map.put(data, "issues", issues)
    if interrupted, do: Map.put(data, "mode", "paused"), else: data
  end

  defp load(path, initial_mode) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= 10_000_000 ->
        with {:ok, data} <- Jason.decode(bytes), true <- valid_data?(data), do: {:ok, data}, else: (_ -> {:error, :invalid_control_state})

      {:error, :enoent} ->
        {:ok, %{"version" => 1, "revision" => 0, "mode" => initial_mode, "issues" => %{}, "commands" => %{}, "concurrency_override" => nil}}

      _ ->
        {:error, :unreadable_control_state}
    end
  end

  defp valid_data?(%{"version" => 1, "revision" => revision, "mode" => mode, "issues" => issues, "commands" => commands} = data)
       when is_integer(revision) and revision >= 0 and mode in ["paused", "draining", "running"] and is_map(issues) and is_map(commands) do
    valid_override?(data["concurrency_override"]) and Enum.all?(issues, fn {id, item} -> is_binary(id) and valid_issue?(item) end) and
      Enum.all?(commands, &valid_command_entry?/1)
  end

  defp valid_data?(_), do: false
  defp valid_override?(nil), do: true
  defp valid_override?(limit), do: is_integer(limit) and limit > 0

  defp valid_command_entry?({id, %{"fingerprint" => fingerprint, "result" => result}}),
    do: is_binary(id) and is_binary(fingerprint) and is_map(result)

  defp valid_command_entry?(_), do: false

  defp valid_issue?(%{"attempts" => a, "runtime_ms" => r, "tokens" => t, "hold" => h, "active" => active}) do
    Enum.all?([a, r, t], &(is_integer(&1) and &1 >= 0)) and (is_nil(h) or is_binary(h)) and valid_active?(active)
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
        port = Port.open({:spawn_executable, python}, [:binary, :exit_status, :use_stdio, args: ["-u", "-c", @lock_script, path], line: 128])

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
    temp = ledger.path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    result =
      with {:ok, file} <- File.open(temp, [:write, :binary, :exclusive]) do
        result = with :ok <- File.chmod(temp, 0o600), :ok <- IO.binwrite(file, Jason.encode!(ledger.data)), do: :file.sync(file)
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
