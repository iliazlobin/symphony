defmodule SymphonyElixir.GoogleOIDCTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.{BrowserIdentity, BrowserSessions, GoogleOIDC}

  @client "test.apps.googleusercontent.com"
  @secret_env "TEST_GOOGLE_SECRET"
  @origin "http://localhost:8778"
  @email "owner@gmail.com"

  setup_all do
    %{key: :public_key.generate_key({:rsa, 2048, 65_537}), foreign_key: :public_key.generate_key({:rsa, 2048, 65_537})}
  end

  setup do
    previous = System.get_env(@secret_env)
    previous_plug = Application.get_env(:symphony_elixir, :google_http_plug)
    System.put_env(@secret_env, "fixture-google-secret")
    Application.put_env(:symphony_elixir, :google_http_plug, {Req.Test, __MODULE__})

    on_exit(fn ->
      restore_env(@secret_env, previous)

      if previous_plug do
        Application.put_env(:symphony_elixir, :google_http_plug, previous_plug)
      else
        Application.delete_env(:symphony_elixir, :google_http_plug)
      end
    end)

    config = %{
      "tracker" => %{"kind" => "memory"},
      "browser_auth" => %{"provider" => "google", "public_origin" => @origin, "client_id" => @client, "client_secret" => "$" <> @secret_env, "allowed_emails" => [@email]}
    }

    configure(config)
    %{config: config}
  end

  test "real signed Google response establishes a token-free identity session with state nonce and PKCE", ctx do
    {flow, query} = start()
    assert query["client_id"] == @client
    assert query["redirect_uri"] == @origin <> "/auth/google/callback"
    assert query["response_type"] == "code"
    assert query["scope"] == "openid email"
    assert query["code_challenge_method"] == "S256"
    assert query["prompt"] == "select_account"
    refute Map.has_key?(query, "login_hint")
    refute Map.has_key?(query, "access_type")
    assert byte_size(query["state"]) >= 32
    assert byte_size(query["nonce"]) >= 32
    refute query["nonce"] == "true"

    provider(ctx.key, query)
    assert {:ok, %{"provider" => "google", "id" => id} = marker, "/chat"} = GoogleOIDC.complete(flow, callback(query))
    assert id == flow
    assert {:ok, session} = BrowserSessions.session(id)
    assert session.identity == %{"iss" => "https://accounts.google.com", "sub" => "fixture-subject", "email" => @email, "email_verified" => true}
    assert_received :token_exchange
    assert_received :jwks_request

    for value <- [marker, session, :sys.get_state(BrowserSessions)] do
      serialized = inspect(value)
      refute serialized =~ "fixture-access-token"
      refute serialized =~ "fixture-refresh-token"
      refute serialized =~ "fixture-google-secret"
      refute serialized =~ "id_token"
    end

    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))
    refute_received :token_exchange

    # Logout can still carry the flow cookie if its request raced the callback's
    # response. That grant id must revoke the resulting session too.
    assert :ok = BrowserSessions.revoke(flow)
    assert {:error, :expired} = BrowserSessions.session(id)
  end

  test "logout during a provider exchange prevents the in-flight callback from creating a session", ctx do
    {flow, query} = start()
    owner = self()

    provider(ctx.key, query, %{}, nil, fn ->
      send(owner, {:provider_waiting, self()})

      receive do
        :release_provider -> :ok
      after
        5_000 -> flunk("Provider fixture was not released")
      end
    end)

    callback = Task.async(fn -> GoogleOIDC.complete(flow, callback(query)) end)
    assert_receive {:provider_waiting, provider}, 5_000
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))
    assert :ok = BrowserSessions.revoke(flow)
    send(provider, :release_provider)
    assert {:error, :sign_in_failed} = Task.await(callback)
    assert {:error, :expired} = BrowserSessions.session(flow)
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))
  end

  test "continuation requests existing Google sign-in and still validates a signed response", ctx do
    {flow, query} = start(:continuation)
    assert query["prompt"] == "none"
    assert query["login_hint"] == @email
    assert query["redirect_uri"] == @origin <> "/auth/google/callback"
    assert query["code_challenge_method"] == "S256"
    provider(ctx.key, query)

    assert {:ok, %{"provider" => "google", "id" => ^flow}, "/chat"} = GoogleOIDC.complete(flow, callback(query))
    assert {:ok, session} = BrowserSessions.session(flow)
    assert session.identity["email"] == @email
    assert session.scope == SymphonyElixir.Orchestrator.tracker_fingerprint()
    assert {:ok, config} = BrowserIdentity.settings()
    assert session.fingerprint == config.fingerprint
    assert_received :token_exchange
    assert_received :jwks_request
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))
  end

  test "continuation does not choose a login hint when several identities are allowed", ctx do
    configure(put_in(ctx.config, ["browser_auth", "allowed_emails"], [@email, "another@gmail.com"]))
    {_flow, query} = start(:continuation)
    assert query["prompt"] == "none"
    refute Map.has_key?(query, "login_hint")
  end

  test "only correlated continuation interaction errors allow an interactive retry and burn the flow", ctx do
    for reason <- ~w(login_required interaction_required account_selection_required consent_required) do
      {flow, query} = start(:continuation)
      provider(ctx.key, query)
      parameters = %{"state" => query["state"], "error" => reason, "error_description" => "fixture-google-secret"}

      log = capture_log(fn -> assert {:error, :interaction_required} = GoogleOIDC.complete(flow, parameters) end)
      refute log =~ "fixture-google-secret"
      assert {:error, :expired} = BrowserSessions.take_flow(flow)
      assert {:error, :expired} = BrowserSessions.session(flow)
      assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, parameters)
      refute_received :token_exchange
      refute_received :jwks_request
    end
  end

  test "interactive flows and uncorrelated or malformed provider errors fail without a retry signal", ctx do
    {interactive, query} = start()
    provider(ctx.key, query)
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(interactive, %{"state" => query["state"], "error" => "login_required"})

    invalid = [
      fn query -> %{"state" => query["state"], "error" => "access_denied"} end,
      fn query -> %{"state" => query["state"], "error" => "server_error"} end,
      fn query -> %{"state" => query["state"], "error" => ["login_required"]} end,
      fn query -> %{"state" => query["state"], "error" => "login_required", "code" => "unexpected-code"} end,
      fn _query -> %{"error" => "login_required"} end,
      fn _query -> %{"state" => [], "error" => "login_required"} end,
      fn _query -> %{"state" => "different", "error" => "login_required"} end,
      fn _query -> %{"state" => String.duplicate("x", 1_001), "error" => "login_required"} end
    ]

    for parameters <- invalid do
      {flow, query} = start(:continuation)
      provider(ctx.key, query)
      assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, parameters.(query))
      assert {:error, :expired} = BrowserSessions.take_flow(flow)
      assert {:error, :expired} = BrowserSessions.session(flow)
      refute_received :token_exchange
    end
  end

  test "continuation errors from revoked or configuration-stale flows cannot request a retry", ctx do
    changes = [
      put_in(ctx.config, ["browser_auth", "allowed_emails"], ["another@gmail.com"]),
      put_in(ctx.config, ["tracker", "active_states"], ["changed"])
    ]

    for changed <- changes do
      configure(ctx.config)
      {flow, query} = start(:continuation)
      provider(ctx.key, query)
      configure(changed)
      assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, %{"state" => query["state"], "error" => "login_required"})
      assert {:error, :expired} = BrowserSessions.take_flow(flow)
      refute_received :token_exchange
    end

    configure(ctx.config)
    {flow, query} = start(:continuation)
    assert :ok = BrowserSessions.revoke(flow)
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, %{"state" => query["state"], "error" => "login_required"})
  end

  test "continuation never bypasses the destination's allowed identity policy", ctx do
    {flow, query} = start(:continuation)
    provider(ctx.key, query, %{"email" => "unallowed@gmail.com"})
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))
    assert {:error, :expired} = BrowserSessions.session(flow)
  end

  test "each attempt generates independent state nonce and PKCE challenges" do
    {_first, one} = start()
    {_second, two} = start()
    for key <- ~w(state nonce code_challenge), do: refute(one[key] == two[key])
  end

  test "bad state consumes the login attempt without exchanging a code", ctx do
    {flow, query} = start()
    provider(ctx.key, query)
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, %{callback(query) | "state" => "incorrect-state"})
    refute_received :token_exchange
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))
    refute_received :token_exchange
  end

  test "configuration changes invalidate pending attempts before contacting Google", ctx do
    {flow, query} = start()
    provider(ctx.key, query)
    configure(put_in(ctx.config, ["browser_auth", "allowed_emails"], ["another@gmail.com"]))
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))
    refute_received :token_exchange
  end

  test "signature and every identity claim are validated before admission", ctx do
    now = System.system_time(:second)

    invalid = [
      {"issuer", %{"iss" => "https://attacker.invalid"}},
      {"audience", %{"aud" => "another.apps.googleusercontent.com"}},
      {"additional audience", %{"aud" => [@client, "foreign-client"]}},
      {"authorized party", %{"azp" => "foreign-client"}},
      {"nonce", %{"nonce" => "other-nonce"}},
      {"expired", %{"exp" => now - 1}},
      {"future issued", %{"iat" => now + 120}},
      {"old issued", %{"iat" => now - 700}},
      {"typed issue time", %{"iat" => Integer.to_string(now)}},
      {"typed expiry", %{"exp" => Integer.to_string(now + 300)}},
      {"expiry before issuance", %{"iat" => now + 30, "exp" => now + 10}},
      {"not before", %{"nbf" => now + 120}},
      {"typed not before", %{"nbf" => "0"}},
      {"unverified email", %{"email_verified" => false}},
      {"typed verification", %{"email_verified" => "true"}},
      {"unallowed email", %{"email" => "attacker@gmail.com"}},
      {"empty subject", %{"sub" => ""}},
      {"typed subject", %{"sub" => 42}}
    ]

    for {label, replacement} <- invalid do
      {flow, query} = start()
      provider(ctx.key, query, replacement)
      assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query)), label
    end

    {flow, query} = start()
    provider(ctx.key, query, %{}, ctx.foreign_key)
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))
  end

  test "required claims and ID tokens cannot be omitted or malformed", ctx do
    for field <- ~w(iss sub aud exp iat nonce email email_verified) do
      {flow, query} = start()
      provider(ctx.key, query, fn claims -> Map.delete(claims, field) end)
      assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query)), field
    end

    for token <- [nil, 12, %{}, String.duplicate("x", 32_769)] do
      assert {:error, :invalid_identity} = GoogleOIDC.fetch_user([], %{"id_token" => token})
    end

    assert {:error, :invalid_identity} = GoogleOIDC.fetch_user([], %{})
  end

  test "Google-verified third-party email does not grant operator admission", ctx do
    configure(put_in(ctx.config, ["browser_auth", "allowed_emails"], ["owner@example.com"]))
    {flow, query} = start()
    provider(ctx.key, query, %{"email" => "owner@example.com"})
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))

    {flow, query} = start()
    provider(ctx.key, query, %{"email" => "owner@example.com", "hd" => "example.com"})
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))

    configure(ctx.config |> put_in(["browser_auth", "allowed_emails"], ["owner@example.com"]) |> put_in(["browser_auth", "allowed_subjects"], ["fixture-subject"]))
    {flow, query} = start()
    provider(ctx.key, query, %{"email" => "owner@example.com", "hd" => "example.com"})
    assert {:ok, _, "/chat"} = GoogleOIDC.complete(flow, callback(query))
  end

  test "subject pinning restricts even an allowed verified Gmail email", ctx do
    configure(put_in(ctx.config, ["browser_auth", "allowed_subjects"], ["different-subject"]))
    {flow, query} = start()
    provider(ctx.key, query)
    assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query))
  end

  test "provider errors and malformed callback values never expose credentials", ctx do
    for parameters <- [
          %{},
          %{"code" => 2, "state" => "x"},
          %{"code" => "x", "state" => []},
          %{"code" => "", "state" => "x"},
          %{"code" => "x", "state" => String.duplicate("x", 1_001)},
          %{"code" => String.duplicate("x", 8_193), "state" => "x"},
          %{"code" => "x", "state" => "x", "error" => "fixture-google-secret"}
        ] do
      {flow, query} = start()
      provider(ctx.key, query)
      assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, parameters)
      refute_received :token_exchange
    end

    {flow, query} = start()
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(Plug.Conn.put_status(conn, 400), %{"error" => "fixture-google-secret"}) end)

    log = capture_log(fn -> assert {:error, :sign_in_failed} = GoogleOIDC.complete(flow, callback(query)) end)
    refute log =~ "fixture-google-secret"
  end

  test "unsafe origins unconfigured secrets and malformed references fail closed", ctx do
    for origin <- [
          "http://example.com",
          "https://user@example.com",
          "https://example.com/path",
          "https://example.com?next=1",
          "https://example.com#x",
          "https://example.com:0",
          "https://example.com:65536",
          "http://localhost/"
        ] do
      configure(put_in(ctx.config, ["browser_auth", "public_origin"], origin))
      assert {:error, :auth_unconfigured} = BrowserIdentity.settings(), origin
    end

    for secret <- ["literal-secret", "$BAD;NAME", "$", nil] do
      configure(put_in(ctx.config, ["browser_auth", "client_secret"], secret))
      assert {:error, :auth_unconfigured} = BrowserIdentity.settings()
      assert {:error, :sign_in_failed} = GoogleOIDC.start("/chat")
    end
  end

  test "environment-backed client configuration and proxy admission fail closed when input disappears", ctx do
    client_env = "TEST_GOOGLE_CLIENT_ID"
    previous = System.get_env(client_env)
    on_exit(fn -> restore_env(client_env, previous) end)
    System.put_env(client_env, @client)

    config =
      ctx.config
      |> put_in(["browser_auth", "client_id"], "$" <> client_env)
      |> put_in(["browser_auth", "trusted_proxy_ips"], ["127.0.0.1"])

    configure(config)
    assert {:ok, identity} = BrowserIdentity.settings()
    assert identity.client_id == @client
    assert BrowserIdentity.trusted_peer?({127, 0, 0, 1}, identity)
    refute BrowserIdentity.trusted_peer?({192, 0, 2, 1}, identity)
    refute BrowserIdentity.trusted_peer?("127.0.0.1", identity)
    refute BrowserIdentity.trusted_peer?(nil, identity)

    System.delete_env(client_env)
    assert {:error, :auth_unconfigured} = BrowserIdentity.settings()

    configure(put_in(config, ["browser_auth", "client_id"], "$BAD;NAME"))
    assert {:error, :auth_unconfigured} = BrowserIdentity.settings()
  end

  defp start(mode \\ nil) do
    result = if mode, do: GoogleOIDC.start("/chat", mode), else: GoogleOIDC.start("/chat")
    assert {:ok, flow, url} = result
    uri = URI.parse(url)
    assert uri.scheme == "https"
    assert uri.host == "accounts.google.com"
    assert uri.path == "/o/oauth2/v2/auth"
    {flow, URI.decode_query(uri.query)}
  end

  defp callback(query), do: %{"code" => "fixture-authorization-code", "state" => query["state"]}

  defp provider(key, query, replacements \\ %{}, signing_key \\ nil, before_token \\ fn -> :ok end) do
    now = System.system_time(:second)

    claims = %{
      "iss" => "https://accounts.google.com",
      "sub" => "fixture-subject",
      "aud" => @client,
      "azp" => @client,
      "iat" => now,
      "exp" => now + 300,
      "nonce" => query["nonce"],
      "email" => @email,
      "email_verified" => true
    }

    claims = if is_function(replacements, 1), do: replacements.(claims), else: Map.merge(claims, replacements)
    token = signed(claims, signing_key || key)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.host, conn.request_path} do
        {"POST", "oauth2.googleapis.com", "/token"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          form = URI.decode_query(body)
          assert form["client_id"] == @client
          assert form["client_secret"] == "fixture-google-secret"
          assert form["redirect_uri"] == @origin <> "/auth/google/callback"
          assert form["grant_type"] == "authorization_code"
          assert form["code"] == "fixture-authorization-code"
          assert byte_size(form["code_verifier"]) in 43..128
          assert Base.url_encode64(:crypto.hash(:sha256, form["code_verifier"]), padding: false) == query["code_challenge"]
          before_token.()
          send(owner, :token_exchange)
          Req.Test.json(conn, %{"access_token" => "fixture-access-token", "refresh_token" => "fixture-refresh-token", "token_type" => "Bearer", "id_token" => token})

        {"GET", "www.googleapis.com", "/oauth2/v3/certs"} ->
          send(owner, :jwks_request)
          Req.Test.json(conn, %{"keys" => [%{"kty" => "RSA", "kid" => "fixture-key", "alg" => "RS256", "use" => "sig", "n" => unsigned(elem(key, 2)), "e" => unsigned(elem(key, 3))}]})

        _ ->
          flunk("Unexpected provider request")
      end
    end)
  end

  defp signed(claims, key) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "kid" => "fixture-key"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    message = header <> "." <> payload
    message <> "." <> Base.url_encode64(:public_key.sign(message, :sha256, key), padding: false)
  end

  defp unsigned(integer), do: integer |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)

  defp configure(config) do
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    assert :ok = WorkflowStore.force_reload()
  end
end
