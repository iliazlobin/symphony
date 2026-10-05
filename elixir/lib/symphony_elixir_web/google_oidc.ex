defmodule SymphonyElixirWeb.GoogleOIDC do
  @moduledoc "Google-only authorization code flow. Provider tokens never leave this module."
  alias Assent.Strategy.OIDC
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{BrowserIdentity, BrowserSessions}

  @metadata %{
    "issuer" => "https://accounts.google.com",
    "authorization_endpoint" => "https://accounts.google.com/o/oauth2/v2/auth",
    "token_endpoint" => "https://oauth2.googleapis.com/token",
    "jwks_uri" => "https://www.googleapis.com/oauth2/v3/certs"
  }

  @spec start(String.t(), :interactive | :continuation) :: {:ok, String.t(), String.t()} | {:error, atom()}
  def start(return_to, mode \\ :interactive) when mode in [:interactive, :continuation] do
    with {:ok, config} <- BrowserIdentity.settings(),
         {:ok, response} <- OIDC.authorize_url(strategy(config, mode)),
         {:ok, id} <- BrowserSessions.issue(:flow, %{params: response.session_params, mode: mode, fingerprint: config.fingerprint, scope: Orchestrator.tracker_fingerprint(), return_to: return_to}) do
      {:ok, id, response.url}
    else
      _ -> {:error, :sign_in_failed}
    end
  end

  @spec complete(term(), map()) :: {:ok, map(), String.t()} | {:error, atom()}
  def complete(flow_id, params) do
    case BrowserSessions.take_flow(flow_id) do
      {:ok, flow} -> complete_claimed(flow_id, flow, params)
      _ -> {:error, :sign_in_failed}
    end
  end

  defp complete_claimed(flow_id, flow, params) do
    with {:ok, config} <- BrowserIdentity.settings(),
         true <- flow.fingerprint == config.fingerprint and (SymphonyElixirWeb.WorkspacePath.enabled?() or flow.scope == Orchestrator.tracker_fingerprint()),
         :ok <- callback_params(flow, params),
         options = Keyword.put(strategy(config), :session_params, flow.params),
         {:ok, %{user: claims}} <- OIDC.callback(options, params, __MODULE__),
         true <- BrowserIdentity.admit(claims, config),
         identity = Map.take(claims, ["iss", "sub", "email", "email_verified", "hd"]),
         {:ok, id} <- BrowserSessions.complete_flow(flow_id, %{identity: identity, fingerprint: config.fingerprint, scope: flow.scope}) do
      {:ok, %{"provider" => "google", "id" => id}, flow.return_to}
    else
      {:error, :interaction_required} -> fail_flow(flow_id, :interaction_required)
      _ -> fail_flow(flow_id)
    end
  rescue
    # Provider errors can include codes, secrets or tokens; never format or log them.
    _ -> fail_flow(flow_id)
  end

  defp fail_flow(flow_id, reason \\ :sign_in_failed) do
    BrowserSessions.revoke(flow_id)
    {:error, reason}
  end

  defp callback_params(%{mode: :continuation, params: %{state: state}}, %{"state" => state, "error" => error} = params)
       when is_binary(state) and byte_size(state) in 1..1_000 and
              not is_map_key(params, "code") and
              error in ["login_required", "interaction_required", "account_selection_required", "consent_required"],
       do: {:error, :interaction_required}

  defp callback_params(_flow, params), do: if(valid_params?(params), do: :ok, else: {:error, :sign_in_failed})

  @doc false
  @spec fetch_user(keyword(), map()) :: {:ok, map()} | {:error, atom()}
  def fetch_user(config, %{"id_token" => token}) when is_binary(token) and byte_size(token) <= 32_768 do
    with {:ok, %{claims: claims}} <- OIDC.validate_id_token(config, token),
         true <- fresh_claims?(claims) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  def fetch_user(_config, _token), do: {:error, :invalid_identity}

  defp fresh_claims?(%{"iat" => issued, "exp" => expires} = claims) when is_integer(issued) and is_integer(expires) do
    now = System.system_time(:second)

    issued <= now + 60 and issued >= now - 600 and expires > now and expires > issued and
      (not Map.has_key?(claims, "nbf") or (is_integer(claims["nbf"]) and claims["nbf"] <= now))
  end

  defp fresh_claims?(_claims), do: false

  defp valid_params?(%{"state" => state, "code" => code} = params) do
    is_binary(state) and byte_size(state) in 1..1_000 and is_binary(code) and
      byte_size(code) in 1..8_192 and not Map.has_key?(params, "error")
  end

  defp valid_params?(_params), do: false

  defp strategy(config, mode \\ :interactive) do
    [
      client_id: config.client_id,
      client_secret: config.client_secret,
      base_url: "https://accounts.google.com",
      redirect_uri: config.origin <> "/auth/google/callback",
      openid_configuration: @metadata,
      client_authentication_method: "client_secret_post",
      authorization_params: authorization_params(config, mode),
      code_verifier: true,
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      id_token_signed_response_alg: "RS256",
      id_token_ttl_seconds: 600,
      http_adapter: {Assent.HTTPAdapter.Req, http_options()}
    ]
  end

  defp authorization_params(config, :continuation) do
    params = [scope: "email", prompt: "none"]

    case config.emails do
      [email] -> Keyword.put(params, :login_hint, email)
      _ -> params
    end
  end

  defp authorization_params(_config, :interactive), do: [scope: "email", prompt: "select_account"]

  defp http_options do
    # Test transport replaces only I/O; Assent signature/claim checks still execute.
    options = [redirect: false, retry: false, receive_timeout: 10_000, connect_options: [timeout: 5_000]]

    case Application.get_env(:symphony_elixir, :google_http_plug) do
      nil -> options
      plug -> Keyword.put(options, :plug, plug)
    end
  end
end
