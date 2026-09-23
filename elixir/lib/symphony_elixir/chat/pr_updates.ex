defmodule SymphonyElixir.Chat.PRUpdates do
  @moduledoc "Reads bounded PR/worker evidence for retained chats; owns no execution or model queue."
  use GenServer

  alias SymphonyElixir.Chat.Store
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.{BoardCache, TaskBoard}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc false
  @spec sync(GenServer.server()) :: :ok
  def sync(server), do: GenServer.call(server, :sync, 15_000)

  @impl true
  def init(opts) do
    state = %{reader: Keyword.get(opts, :reader, &read/0), store: Keyword.get(opts, :store, Store), interval: Keyword.get(opts, :interval_ms, 15_000)}
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, tick(state)}

  @impl true
  def handle_info(:tick, state) do
    state = tick(state)
    schedule(state)
    {:noreply, state}
  end

  defp schedule(%{interval: :manual}), do: :ok
  defp schedule(state), do: Process.send_after(self(), :tick, state.interval)

  defp tick(state) do
    if Store.tracking_prs?(state.store) do
      case state.reader.() do
        {:ok, project, fingerprint, board} -> Store.sync_pr_updates(project, fingerprint, board, state.store)
        _ -> :ok
      end
    end

    state
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  defp read do
    with true <- Config.chat_settings().enabled,
         {:ok, config} <- Config.settings(),
         true <- config.tracker.kind == "github",
         scope when is_binary(scope) <- BoardCache.scope(Orchestrator),
         fingerprint = Orchestrator.tracker_fingerprint(),
         board = board(scope),
         true <- scope == BoardCache.scope(Orchestrator) and fingerprint == Orchestrator.tracker_fingerprint(),
         true <- is_nil(board[:runtime_error]) and is_nil(board[:source_error]) do
      {:ok, "github:" <> config.tracker.provider["repo"], fingerprint, board}
    else
      _ -> :unavailable
    end
  end

  defp board(scope) do
    case BoardCache.get(scope) do
      {:ok, board} ->
        if fresh?(board[:generated_at]), do: board, else: load(scope)

      :miss ->
        load(scope)
    end
  end

  defp load(scope) do
    board_module = Application.get_env(:symphony_elixir, :chat_board_module, TaskBoard)
    board = board_module.load(Orchestrator, 5_000)
    if scope == BoardCache.scope(Orchestrator), do: BoardCache.put(scope, board)
    board
  end

  defp fresh?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.diff(DateTime.utc_now(), time, :second) in 0..10
      _ -> false
    end
  end

  defp fresh?(_), do: false
end
