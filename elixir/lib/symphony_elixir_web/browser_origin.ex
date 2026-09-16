defmodule SymphonyElixirWeb.BrowserOrigin do
  @moduledoc "Normalizes only explicitly trusted proxy peers to the fixed public origin; ignores forwarded headers."
  alias SymphonyElixirWeb.BrowserIdentity

  @spec socket_uri(term(), term()) :: term()
  def socket_uri(%URI{} = uri, %{address: ip}) do
    case BrowserIdentity.settings() do
      {:ok, %{uri: %{scheme: "https"} = public} = config} ->
        if uri.host == public.host and BrowserIdentity.trusted_peer?(ip, config), do: %{uri | scheme: "https", port: public.port}, else: uri

      _ ->
        uri
    end
  end

  def socket_uri(uri, _peer), do: uri

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case BrowserIdentity.settings() do
      {:ok, %{uri: %{scheme: "https"} = uri} = config} ->
        if conn.host == uri.host and BrowserIdentity.trusted_peer?(Plug.Conn.get_peer_data(conn).address, config), do: %{conn | scheme: :https, port: uri.port}, else: conn

      _ ->
        conn
    end
  end
end
