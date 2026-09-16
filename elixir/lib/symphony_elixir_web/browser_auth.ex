defmodule SymphonyElixirWeb.BrowserAuth do
  @moduledoc "Local browser authorization for bounded operator controls. Remote identity is not supported."

  alias Phoenix.LiveView
  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}

  @session_key "symphony_operator"
  @max_age_seconds 8 * 60 * 60
  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @type context :: %{marker: term(), host: term(), peer_ip: term(), tracker_fingerprint: term()}

  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @spec context(map(), Phoenix.LiveView.Socket.t()) :: context()
  def context(session, socket) do
    uri = LiveView.get_connect_info(socket, :uri)
    peer = LiveView.get_connect_info(socket, :peer_data)

    %{
      marker: session[@session_key],
      host: if(is_map(uri), do: Map.get(uri, :host)),
      peer_ip: if(is_map(peer), do: Map.get(peer, :address)),
      tracker_fingerprint: Orchestrator.tracker_fingerprint()
    }
  end

  @spec authorized?(term()) :: boolean()
  def authorized?(%{marker: marker, host: host, peer_ip: peer_ip, tracker_fingerprint: scope}) do
    local_address?(host, peer_ip) and valid_marker?(marker, Config.control_token()) and
      is_binary(scope) and scope == Orchestrator.tracker_fingerprint()
  end

  def authorized?(_context), do: false

  @spec authenticate(Conn.t(), term()) :: {:ok, map()} | {:error, atom()}
  def authenticate(conn, supplied) do
    token = Config.control_token()

    cond do
      not local_request?(conn) -> {:error, :local_browser_required}
      not configured_token?(token) -> {:error, :control_auth_unconfigured}
      not is_binary(supplied) or not Plug.Crypto.secure_compare(token, supplied) -> {:error, :unauthorized}
      true -> {:ok, %{"fingerprint" => fingerprint(token), "issued_at" => System.system_time(:second)}}
    end
  end

  @spec local_request?(Conn.t()) :: boolean()
  def local_request?(conn) do
    # Neither Host nor forwarded headers establish where the connection came from.
    local_address?(conn.host, Conn.get_peer_data(conn).address) and same_origin?(conn)
  end

  defp local_address?(host, ip), do: host in @loopback_hosts and loopback_ip?(ip)
  defp loopback_ip?({127, _, _, _}), do: true
  defp loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_ip?(_ip), do: false

  defp same_origin?(conn) do
    case Conn.get_req_header(conn, "origin") do
      [] -> true
      [origin] -> same_uri?(URI.parse(origin), conn)
      _ -> false
    end
  end

  defp same_uri?(uri, conn) do
    uri.scheme == Atom.to_string(conn.scheme) and uri.host == conn.host and uri.port == conn.port and
      is_nil(uri.userinfo) and uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp valid_marker?(%{"fingerprint" => supplied, "issued_at" => issued_at}, token)
       when is_binary(supplied) and is_integer(issued_at) do
    age = System.system_time(:second) - issued_at
    fresh? = age >= 0 and age < @max_age_seconds
    configured_token?(token) and fresh? and Plug.Crypto.secure_compare(fingerprint(token), supplied)
  end

  defp valid_marker?(_marker, _token), do: false
  defp configured_token?(token), do: is_binary(token) and byte_size(token) >= 32

  # This purpose-bound proof is stored only inside Phoenix's signed session.
  # It is never accepted as a bearer token and rotates with the configured token.
  defp fingerprint(token), do: :crypto.mac(:hmac, :sha256, token, "symphony-browser-operator-v1") |> Base.url_encode64(padding: false)
end
