defmodule SymphonyElixirWeb.BrowserOrigin do
  @moduledoc "Fixed-origin browser navigation and trusted proxy normalization; ignores forwarded headers."
  alias SymphonyElixirWeb.BrowserIdentity

  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @spec loopback_login_url(Plug.Conn.t()) :: String.t() | nil
  def loopback_login_url(conn) do
    with {:ok, %{uri: %{scheme: "http"} = uri, origin: origin}} <- BrowserIdentity.settings(),
         true <- conn.scheme == :http and conn.port == uri.port,
         true <- uri.host in @loopback_hosts and conn.host in @loopback_hosts and conn.host != uri.host,
         true <- loopback_peer?(SymphonyElixirWeb.WorkspacePath.peer_ip(Plug.Conn.get_peer_data(conn).address)) do
      origin <> SymphonyElixirWeb.WorkspacePath.path("/login")
    else
      _ -> nil
    end
  end

  defp loopback_peer?({127, _, _, _}), do: true
  defp loopback_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_peer?(_), do: false

  @spec socket_uri(term(), term()) :: term()
  def socket_uri(%URI{} = uri, %{address: ip}) do
    ip = SymphonyElixirWeb.WorkspacePath.peer_ip(ip)

    case BrowserIdentity.settings() do
      {:ok, %{uri: %{scheme: "https"} = public} = config} ->
        if uri.host == public.host and (SymphonyElixirWeb.WorkspacePath.enabled?() or BrowserIdentity.trusted_peer?(ip, config)), do: %{uri | scheme: "https", port: public.port}, else: uri

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
        if conn.host == uri.host and (SymphonyElixirWeb.WorkspacePath.enabled?() or BrowserIdentity.trusted_peer?(Plug.Conn.get_peer_data(conn).address, config)),
          do: %{conn | scheme: :https, port: uri.port},
          else: conn

      _ ->
        conn
    end
  end
end
