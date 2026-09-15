defmodule SymphonyElixirWeb.ReadOnlyBoard do
  @moduledoc """
  Live GitHub board backed by GET-only reads of the configured Mac controller.

  This process owns no scheduler, control ledger, browser credential or chat runtime.
  The operator profile binds the controller address to the repository; the current
  controller API does not attest repository identity in its snapshot response.
  """

  alias SymphonyElixir.{Config, Tracker.Issue}
  alias SymphonyElixir.GitHub.{Board, Client}
  alias SymphonyElixirWeb.TaskBoard

  @entry_keys ~w(issue_id issue_identifier issue_url state worker_host workspace_path session_id turn_count last_event last_message started_at last_event_at tokens attempt due_at error blocked_at)a
  @total_keys ~w(input_tokens output_tokens total_tokens seconds_running)a

  @spec snapshot() :: map()
  def snapshot do
    case safe_read(fn -> read_remote("/api/v1/state", 3_000, &request/3) end) do
      {:ok, body} -> normalize_runtime(body)
      _ -> unavailable_runtime()
    end
  end

  @spec load(term(), pos_integer()) :: map()
  def load(_owner, timeout) do
    client = Application.get_env(:symphony_elixir, :github_client_module, Client)
    load_with(Config.settings!(), timeout, &client.fetch_issues_by_states/1, &request/3)
  end

  @doc false
  @spec load_with(map(), pos_integer(), function(), function()) :: map()
  def load_with(settings, timeout, issues_fun, request_fun) do
    started = System.monotonic_time(:millisecond)

    reads = [
      fn -> issues_fun.(["open", "closed"]) end,
      fn -> read_remote("/api/v1/state", timeout, request_fun) end,
      fn -> read_remote("/api/v1/control", timeout, request_fun) end
    ]

    pending = Enum.map(reads, &Task.async(fn -> safe_read(&1) end))

    [source, runtime_result, control_result] =
      pending
      |> Task.yield_many(timeout)
      |> Enum.map(fn {task, result} ->
        case result || Task.shutdown(task, :brutal_kill) do
          {:ok, value} -> value
          _ -> {:error, :unavailable}
        end
      end)

    repo = settings.tracker.provider["repo"]
    {issues, source_error} = scoped_issues(source, repo)

    runtime =
      case runtime_result do
        {:ok, body} -> normalize_runtime(body)
        _ -> unavailable_runtime()
      end

    {control, control_error} = control(control_result)
    runtime_error = if runtime[:error], do: "Controller activity unavailable; running work is unknown.", else: control_error

    issues
    |> TaskBoard.project(runtime, control, settings)
    |> Map.merge(%{
      source_error: source_error,
      runtime_error: runtime_error,
      read_only: true,
      data_mode: "Live GitHub",
      context_links: context_links(repo),
      source_note: "Read-only view of the configured controller. Chat is unavailable in this view."
    })
    |> Board.enrich(settings, max(timeout - (System.monotonic_time(:millisecond) - started), 1))
  end

  defp scoped_issues({:ok, issues}, repo) when is_list(issues) do
    if Enum.all?(issues, &(match?(%Issue{id: id} when is_binary(id), &1) and (&1.native_ref || %{})["repo"] == repo)),
      do: {issues, nil},
      else: {[], "GitHub returned invalid project data."}
  end

  defp scoped_issues(_, _repo), do: {[], "GitHub unavailable; showing last-known work when available."}

  defp control({:ok, %{"enabled" => false} = body}), do: {body, nil}

  defp control({:ok, %{"enabled" => true, "mode" => mode, "issues" => issues} = body}) when is_binary(mode) and is_map(issues) do
    error = if body["fault"], do: "Controller controls require recovery.", else: nil
    {body, error}
  end

  defp control(_), do: {%{"error" => "unavailable"}, "Controller holds unavailable; execution state is unknown."}

  defp normalize_runtime(%{"running" => running, "retrying" => retrying, "blocked" => blocked, "codex_totals" => totals} = body)
       when is_list(running) and is_list(retrying) and is_list(blocked) and is_map(totals) do
    if Enum.all?(running ++ retrying ++ blocked, &(is_map(&1) and is_binary(&1["issue_id"]))) do
      %{
        generated_at: body["generated_at"],
        running: Enum.map(running, &known_keys(&1, @entry_keys)),
        retrying: Enum.map(retrying, &known_keys(&1, @entry_keys)),
        blocked: Enum.map(blocked, &known_keys(&1, @entry_keys)),
        codex_totals: known_keys(totals, @total_keys),
        rate_limits: body["rate_limits"]
      }
    else
      unavailable_runtime()
    end
  end

  defp normalize_runtime(_), do: unavailable_runtime()
  defp known_keys(map, keys), do: Map.new(keys, &{&1, map[Atom.to_string(&1)]})
  defp unavailable_runtime, do: %{error: %{code: "controller_unavailable"}}

  defp read_remote(path, timeout, request_fun) do
    url = System.get_env("SYMPHONY_BOARD_API_URL", "")
    token = System.get_env("SYMPHONY_BOARD_CONTROL_TOKEN", "")

    case URI.parse(url) do
      %URI{scheme: "http", host: host, port: port, userinfo: nil, query: nil, fragment: nil, path: base}
      when host in ["127.0.0.1", "::1"] and is_integer(port) and base in [nil, "", "/"] and byte_size(token) >= 32 ->
        request_fun.(String.trim_trailing(url, "/") <> path, token, min(timeout, 3_000))

      _ ->
        {:error, :invalid_controller}
    end
  end

  defp request(url, token, timeout) do
    case Req.get(url,
           headers: [{"authorization", "Bearer " <> token}, {"accept", "application/json"}],
           redirect: false,
           retry: false,
           decode_body: false,
           receive_timeout: timeout,
           connect_options: [timeout: timeout]
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= 2_097_152 -> Jason.decode(body)
      _ -> {:error, :unavailable}
    end
  end

  defp safe_read(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp context_links(repo) do
    root = "https://github.com/" <> repo

    Enum.map([{"Repository", ""}, {"Issues", "/issues"}, {"Pull requests", "/pulls"}, {"Checks", "/actions"}], fn {label, path} ->
      %{label: label, url: root <> path}
    end)
  end
end
