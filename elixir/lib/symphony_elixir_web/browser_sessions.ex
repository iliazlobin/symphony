defmodule SymphonyElixirWeb.BrowserSessions do
  @moduledoc "Bounded, single-owner login attempts and revocable sessions. Restart signs browsers out."
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec issue(:flow | :session, map(), GenServer.server()) :: {:ok, String.t()} | {:error, atom()}
  def issue(kind, value, server \\ __MODULE__), do: call(server, {:issue, kind, value})

  @spec take_flow(term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def take_flow(id, server \\ __MODULE__), do: call(server, {:get, :flow, id})

  @spec complete_flow(term(), map(), GenServer.server()) :: {:ok, String.t()} | {:error, atom()}
  def complete_flow(id, value, server \\ __MODULE__), do: call(server, {:complete_flow, id, value})

  @spec session(term(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def session(id, server \\ __MODULE__), do: call(server, {:get, :session, id})

  @spec revoke(term(), GenServer.server()) :: :ok | {:error, atom()}
  def revoke(id, server \\ __MODULE__), do: call(server, {:revoke, id})

  @impl true
  def init(opts), do: {:ok, %{entries: %{}, capacity: Keyword.get(opts, :capacity, 1_000), clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:second) end)}}

  @impl true
  def handle_call(command, _from, state) do
    now = state.clock.()
    state = %{state | entries: Map.reject(state.entries, fn {_key, {_, _, until}} -> until <= now end)}
    execute(command, state, now)
  end

  defp execute({:issue, kind, value}, state, now) when kind in [:flow, :session] and is_map(value) do
    if map_size(state.entries) >= state.capacity do
      {:reply, {:error, :capacity}, state}
    else
      id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      ttl = if kind == :flow, do: 600, else: 28_800
      {:reply, {:ok, id}, %{state | entries: Map.put(state.entries, id, {kind, value, now + ttl})}}
    end
  end

  defp execute({:get, kind, id}, state, _now) do
    case state.entries[id] do
      {^kind, value, until} ->
        entries = if kind == :flow, do: Map.put(state.entries, id, {:completing, value, until}), else: state.entries
        {:reply, {:ok, value}, %{state | entries: entries}}

      _ ->
        {:reply, {:error, :expired}, state}
    end
  end

  defp execute({:complete_flow, id, value}, state, now) when is_map(value) do
    case state.entries[id] do
      {:completing, _flow, _until} ->
        # Keep the grant id across the transition: logout still carries the flow
        # cookie until the callback response arrives and must revoke that session.
        {:reply, {:ok, id}, %{state | entries: Map.put(state.entries, id, {:session, value, now + 28_800})}}

      _ ->
        {:reply, {:error, :expired}, state}
    end
  end

  defp execute({:revoke, id}, state, _now), do: {:reply, :ok, %{state | entries: Map.delete(state.entries, id)}}
  defp execute(_invalid, state, _now), do: {:reply, {:error, :invalid}, state}

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
