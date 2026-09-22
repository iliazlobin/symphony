defmodule SymphonyElixirWeb.BoardCache do
  @moduledoc """
  Keeps one recent, complete board for fast browser reloads.

  This is a presentation cache, never an authority for tracker reads or execution.
  Callers fence asynchronous writes against the current scope and still refresh
  cached boards. Credentials contribute only to the opaque scope digest.
  """

  use GenServer

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixirWeb.Endpoint

  @ttl_ms 90_000
  @max_bytes 8_000_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Identifies the configured board sources without exposing their credentials."
  @spec scope(GenServer.server()) :: String.t() | nil
  def scope(orchestrator) do
    with endpoint when is_pid(endpoint) <- Process.whereis(Endpoint),
         {:ok, settings} <- Config.settings() do
      read_only = Endpoint.config(:board_read_only, false)

      identity = {
        Workflow.workflow_file_path(),
        settings.tracker,
        settings.control,
        source_environment(settings.tracker, settings.control),
        endpoint,
        {orchestrator, GenServer.whereis(orchestrator)},
        Endpoint.config(:board_loader),
        Endpoint.config(:snapshot_loader),
        read_only,
        if(read_only, do: {System.get_env("SYMPHONY_BOARD_API_URL"), System.get_env("SYMPHONY_BOARD_CONTROL_TOKEN")})
      }

      :crypto.hash(:sha256, :erlang.term_to_binary(identity)) |> Base.url_encode64(padding: false)
    else
      _ -> nil
    end
  end

  @spec get(String.t() | nil, GenServer.server()) :: {:ok, map()} | :miss
  def get(scope, server \\ __MODULE__), do: call(server, {:get, scope}, :miss)

  @spec put(String.t() | nil, map(), GenServer.server()) :: :ok
  def put(scope, board, server \\ __MODULE__), do: call(server, {:put, scope, board}, :ok)

  @impl true
  def init(opts), do: {:ok, %{entry: nil, clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)}}

  @impl true
  def handle_call({:get, scope}, _from, %{entry: {scope, board, stored_at}} = state) when is_binary(scope) do
    if state.clock.() - stored_at < @ttl_ms do
      {:reply, {:ok, board}, state}
    else
      {:reply, :miss, %{state | entry: nil}}
    end
  end

  def handle_call({:get, _scope}, _from, state), do: {:reply, :miss, state}

  def handle_call({:put, scope, board}, _from, state) do
    if is_binary(scope) and complete?(board) and :erlang.external_size(board) <= @max_bytes do
      {:reply, :ok, %{state | entry: {scope, board, state.clock.()}}}
    else
      {:reply, :ok, state}
    end
  end

  defp complete?(%{tasks: tasks, projects: projects, runtime: runtime, control: control, source_error: nil, runtime_error: nil}) do
    is_list(tasks) and is_list(projects) and is_map(runtime) and is_map(control)
  end

  defp complete?(_board), do: false

  defp call(server, message, unavailable) do
    GenServer.call(server, message, 1_000)
  catch
    :exit, _reason -> unavailable
  end

  defp source_environment(tracker, control) do
    references =
      (Map.values(tracker.provider) ++ Map.values(control) ++ [tracker.api_key, tracker.assignee, tracker.project_slug])
      |> Enum.flat_map(fn
        "$" <> name -> [name]
        _ -> []
      end)

    (references ++ tracker.secret_environment_names ++ ~w(GITHUB_TOKEN GITHUB_REPO LINEAR_API_KEY LINEAR_ASSIGNEE))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, System.get_env(&1)})
  end
end
