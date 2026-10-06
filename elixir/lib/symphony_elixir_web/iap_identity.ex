defmodule SymphonyElixirWeb.IAPIdentity do
  @moduledoc "Explicit IAP browser identity; signed assertions never authorize the machine control API."
  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.{BrowserAuth, BrowserSessions, IAPKeys}

  @issuer "https://cloud.google.com/iap"
  @header "x-goog-iap-jwt-assertion"
  @maximum_lifetime 660

  @spec enabled?() :: boolean()
  def enabled?, do: Config.browser_auth_settings()["provider"] == "iap"

  @spec settings() :: {:ok, map()} | {:error, :auth_unconfigured}
  def settings do
    raw = Config.browser_auth_settings()
    origin = resolve(raw["public_origin"])
    audience = resolve(raw["audience"])
    uri = URI.parse(if(is_binary(origin), do: origin, else: ""))
    emails = raw["allowed_emails"]
    subjects = raw["allowed_subjects"] || []

    if raw["provider"] == "iap" and valid_origin?(uri, origin) and valid_audience?(audience) and
         valid_strings?(emails, 320) and emails != [] and valid_strings?(subjects, 255) and
         length(Enum.uniq_by(emails, &String.downcase/1)) == length(emails) and
         Enum.all?(emails, &Regex.match?(~r/\A[^\s@]+@[^\s@]+\z/, &1)) do
      config = %{provider: "iap", origin: origin, uri: uri, audience: audience, emails: Enum.map(emails, &String.downcase/1), subjects: subjects, proxies: []}
      {:ok, Map.put(config, :fingerprint, :crypto.hash(:sha256, :erlang.term_to_binary(config)))}
    else
      {:error, :auth_unconfigured}
    end
  end

  @spec verify_headers(term(), term()) :: {:ok, map()} | {:error, :invalid_identity}
  def verify_headers(headers, %URI{} = uri) when is_list(headers) do
    with {:ok, config} <- settings(),
         true <- uri.host == config.uri.host,
         [token] <- for({@header, value} <- headers, do: value),
         {:ok, identity} <- verify(token, config) do
      {:ok, identity}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  def verify_headers(_, _), do: {:error, :invalid_identity}

  @spec verify(term(), map()) :: {:ok, map()} | {:error, :invalid_identity}
  def verify(token, config) when is_binary(token) and byte_size(token) <= 16_384 do
    with [header, _, signature] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(header, padding: false),
         {:ok, %{"alg" => "ES256", "kid" => kid} = fields} <- Jason.decode(decoded),
         true <- is_binary(kid) and byte_size(kid) in 1..200 and Enum.all?(Map.keys(fields), &(&1 in ["alg", "kid", "typ"])),
         {:ok, signature} <- Base.url_decode64(signature, padding: false),
         true <- byte_size(signature) == 64,
         {:ok, key} <- IAPKeys.key(kid),
         {:ok, %{verified?: true, claims: claims}} <- Assent.JWTAdapter.AssentJWT.verify(token, key, json_library: Jason),
         true <- fresh_claims?(claims, config) do
      {:ok, %{identity: Map.take(claims, ["iss", "aud", "sub", "email", "iat", "exp"]), fingerprint: config.fingerprint, origin: config.origin}}
    else
      _ -> {:error, :invalid_identity}
    end
  rescue
    _ -> {:error, :invalid_identity}
  end

  def verify(_, _), do: {:error, :invalid_identity}

  @spec fresh_claims?(term(), map()) :: boolean()
  def fresh_claims?(%{"iss" => @issuer, "aud" => audience, "sub" => subject, "email" => email, "iat" => issued, "exp" => expires} = claims, config)
      when is_binary(subject) and byte_size(subject) in 1..255 and is_binary(email) and is_integer(issued) and is_integer(expires) do
    now = System.system_time(:second)

    audience == config.audience and issued <= now + 30 and issued >= now - @maximum_lifetime and
      expires > now and expires > issued and expires - issued <= @maximum_lifetime and
      (not Map.has_key?(claims, "nbf") or (is_integer(claims["nbf"]) and claims["nbf"] <= now)) and
      String.downcase(email) in config.emails and (config.subjects == [] or subject in config.subjects)
  end

  def fresh_claims?(_, _), do: false

  @spec init(atom()) :: atom()
  def init(mode), do: mode

  @spec call(Conn.t(), atom()) :: Conn.t()
  def call(conn, :request) do
    cond do
      not enabled?() -> conn
      conn.method == "GET" and conn.request_path == "/healthz" -> conn |> Conn.send_resp(200, "ok") |> Conn.halt()
      String.starts_with?(conn.request_path, "/api/v1/") and BrowserAuth.local_request?(conn) -> conn
      true -> authenticate_request(conn)
    end
  end

  def call(conn, :session) do
    case conn.assigns[:iap_identity] do
      %{identity: _claims} = verified ->
        conn = Conn.fetch_session(conn)

        if Conn.get_session(conn, "iap_signed_out") == true do
          conn
        else
          case session_marker(conn, verified) do
            {:ok, marker} -> conn |> Conn.put_session(BrowserAuth.session_key(), marker) |> Conn.put_session("live_socket_id", "operator:" <> marker["id"])
            _ -> reject(conn)
          end
        end

      _ ->
        conn
    end
  end

  defp authenticate_request(conn) do
    uri = %URI{host: conn.host, scheme: Atom.to_string(conn.scheme), port: conn.port}

    with {:ok, config} <- settings(),
         true <- origin_matches?(conn, config.origin),
         {:ok, verified} <- verify_headers(conn.req_headers, uri) do
      conn |> Map.put(:scheme, :https) |> Map.put(:port, config.uri.port) |> Conn.assign(:iap_identity, verified) |> Conn.put_resp_header("cache-control", "no-store")
    else
      _ -> reject(conn)
    end
  end

  defp origin_matches?(conn, origin), do: Conn.get_req_header(conn, "origin") in [[], [origin]]
  defp reject(conn), do: conn |> Conn.send_resp(403, "Browser identity required.") |> Conn.halt()

  defp session_marker(conn, verified) do
    marker = Conn.get_session(conn, BrowserAuth.session_key())
    scope = Orchestrator.tracker_fingerprint()

    with %{"provider" => "iap", "id" => id} <- marker,
         {:ok, record} <- BrowserSessions.session(id),
         true <- valid_session?(record, verified, scope) do
      {:ok, marker}
    else
      _ ->
        BrowserAuth.revoke(marker)
        record = Map.merge(verified, %{provider: "iap", scope: scope})

        case BrowserSessions.issue(:session, record) do
          {:ok, id} -> {:ok, %{"provider" => "iap", "id" => id}}
          _ -> {:error, :identity_unavailable}
        end
    end
  end

  @spec valid_session?(term(), map(), term()) :: boolean()
  def valid_session?(%{provider: "iap", fingerprint: fingerprint, identity: identity, scope: scope}, verified, scope) when is_binary(scope) do
    with {:ok, config} <- settings() do
      fingerprint == config.fingerprint and verified.fingerprint == fingerprint and fresh_claims?(identity, config) and
        fresh_claims?(verified.identity, config) and identity["sub"] == verified.identity["sub"] and identity["email"] == verified.identity["email"]
    else
      _ -> false
    end
  end

  def valid_session?(_, _, _), do: false

  defp valid_origin?(uri, origin) do
    uri.scheme == "https" and is_binary(uri.host) and uri.host not in ["", "localhost", "127.0.0.1", "::1"] and
      uri.path in [nil, ""] and is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and origin == URI.to_string(uri)
  end

  defp valid_audience?(value), do: is_binary(value) and Regex.match?(~r/\A\/projects\/[0-9]+\/global\/backendServices\/[0-9]+\z/, value)
  defp valid_strings?(items, bytes), do: is_list(items) and length(items) <= 20 and length(Enum.uniq(items)) == length(items) and Enum.all?(items, &(is_binary(&1) and byte_size(&1) in 1..bytes))
  defp resolve("$" <> name), do: if(Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name), do: System.get_env(name), else: nil)
  defp resolve(value), do: value
end
