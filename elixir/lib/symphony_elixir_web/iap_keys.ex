defmodule SymphonyElixirWeb.IAPKeys do
  @moduledoc "Bounded cache of Google's fixed IAP public signing keys; never serves expired keys."
  use GenServer

  @url "https://www.gstatic.com/iap/verify/public_key"
  @refresh_interval 30
  @maximum_age 3_600
  @p256 {1, 2, 840, 10045, 3, 1, 7}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec key(String.t(), GenServer.server()) :: {:ok, String.t()} | {:error, :identity_unavailable}
  def key(kid, server \\ __MODULE__) do
    GenServer.call(server, {:key, kid}, 5_000)
  catch
    :exit, _ -> {:error, :identity_unavailable}
  end

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:second) end)
    now = clock.()
    {:ok, %{keys: %{}, expires: now, refresh_at: now, clock: clock}}
  end

  @impl true
  def handle_call({:key, kid}, _from, state) do
    now = state.clock.()
    state = if state.expires > now and Map.has_key?(state.keys, kid), do: state, else: refresh(state, now)
    result = if state.expires > now, do: Map.fetch(state.keys, kid), else: :error

    {:reply,
     case result do
       {:ok, key} -> {:ok, key}
       :error -> {:error, :identity_unavailable}
     end, state}
  end

  defp refresh(%{refresh_at: refresh_at} = state, now) when refresh_at > now, do: state

  defp refresh(state, now) do
    state = %{state | refresh_at: now + @refresh_interval}

    case fetch_keys() do
      {:ok, keys, age} -> %{state | keys: keys, expires: now + age}
      _ -> state
    end
  end

  defp fetch_keys do
    options = [url: @url, redirect: false, retry: false, receive_timeout: 2_000, connect_options: [timeout: 1_000]]
    plug = Application.get_env(:symphony_elixir, :iap_http_plug)
    options = if plug, do: Keyword.put(options, :plug, plug), else: options

    with {:ok, %{status: 200, body: keys} = response} <- Req.get(options),
         true <- valid_keys?(keys) do
      {:ok, keys, cache_age(response)}
    else
      _ -> {:error, :identity_unavailable}
    end
  rescue
    # HTTP errors may contain request/response data. Never log or return them.
    _ -> {:error, :identity_unavailable}
  end

  defp valid_keys?(keys) when is_map(keys) and map_size(keys) in 1..20 do
    Enum.all?(keys, fn {kid, pem} ->
      is_binary(kid) and byte_size(kid) in 1..200 and is_binary(pem) and byte_size(pem) <= 4_096 and p256_public_key?(pem)
    end)
  end

  defp valid_keys?(_), do: false

  defp p256_public_key?(pem) do
    with [{:SubjectPublicKeyInfo, _, :not_encrypted} = entry] <- :public_key.pem_decode(pem),
         {{:ECPoint, <<4, _::binary-size(64)>>}, {:namedCurve, @p256}} <- :public_key.pem_entry_decode(entry) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp cache_age(response) do
    case Req.Response.get_header(response, "cache-control") do
      [value] ->
        case Regex.run(~r/(?:\A|[,\s])max-age=(\d+)(?:\z|[,\s])/, value) do
          [_, seconds] -> min(String.to_integer(seconds), @maximum_age)
          _ -> 300
        end

      _ ->
        300
    end
  end
end
