defmodule SymphonyElixir.GoogleBrowserTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  alias SymphonyElixirWeb.{BrowserAuth, BrowserIdentity, BrowserOrigin, BrowserSessions, Endpoint}
  @endpoint Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "google-browser-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow = root <> "/WORKFLOW.md"

    auth = %{
      "provider" => "google",
      "public_origin" => "http://localhost",
      "client_id" => "test.apps.googleusercontent.com",
      "client_secret" => "$TEST_GOOGLE_BROWSER_SECRET",
      "allowed_emails" => ["owner@gmail.com"]
    }

    config = %{
      tracker: %{kind: "memory", active_states: ["open"], terminal_states: ["closed"]},
      browser_auth: auth,
      workspace: %{root: root <> "/workspaces"},
      polling: %{interval_ms: 60_000},
      observability: %{dashboard_enabled: false},
      control: %{enabled: true, state_path: root <> "/control.json", initial_mode: "paused"}
    }

    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(workflow)
    previous = Application.get_env(:symphony_elixir, Endpoint, [])
    previous_secret = System.get_env("TEST_GOOGLE_BROWSER_SECRET")
    System.put_env("TEST_GOOGLE_BROWSER_SECRET", "synthetic-client-secret")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, Endpoint, Keyword.merge(previous, server: false, secret_key_base: String.duplicate("g", 64)))
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous)
      restore_env("TEST_GOOGLE_BROWSER_SECRET", previous_secret)
      File.rm_rf(root)
    end)

    %{workflow: workflow, config: config}
  end

  test "whole board and chat require Google, API remains machine-only, login is CSRF protected" do
    for path <- ["/", "/chat"] do
      assert redirected_to(get(local_conn(), path)) == "/login"
    end

    assert get(local_conn(), "/api/v1/state").status in [401, 503]
    login = get(local_conn(), "/login")
    assert html_response(login, 200) =~ "Sign in with Google"
    refute login.resp_body =~ "Operator token"
    assert Plug.Conn.get_resp_header(login, "cache-control") == ["no-store"]
    assert Plug.Conn.get_resp_header(login, "referrer-policy") == ["same-origin"]
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn -> post(local_conn(), "/auth/google", %{}) end
    assert {:error, :google_required} = BrowserAuth.authenticate(local_conn(), String.duplicate("x", 32))
  end

  test "Google start uses fixed callback, encrypted Lax cookie and one-use server state" do
    login = get(local_conn(), "/login")
    csrf = csrf(login)
    browser = browser_recycle(login) |> Plug.Conn.put_req_header("origin", "http://localhost")
    started = post(browser, "/auth/google", %{"_csrf_token" => csrf, "return_to" => "https://evil.example"})
    assert Plug.Conn.get_resp_header(started, "referrer-policy") == ["no-referrer"]
    location = redirected_to(started)
    assert String.starts_with?(location, "https://accounts.google.com/o/oauth2/v2/auth?")
    query = URI.decode_query(URI.parse(location).query)
    assert query["redirect_uri"] == "http://localhost/auth/google/callback"
    assert query["scope"] == "openid email"
    assert query["code_challenge_method"] == "S256"
    refute Map.has_key?(query, "client_secret")
    assert is_binary(query["nonce"])
    cookie = started.resp_cookies["_symphony_elixir_key"]
    assert cookie.same_site == "Lax"
    refute cookie.value =~ "synthetic-client-secret"
    flow = Plug.Conn.get_session(started, "google_flow")
    assert {:ok, %{return_to: "/?panel=settings", params: params}} = BrowserSessions.take_flow(flow)
    refute cookie.value =~ params.code_verifier
    assert {:error, :expired} = BrowserSessions.take_flow(flow)
    rejected = get(browser_recycle(started), "/auth/google/callback?state=wrong&code=fake")
    assert redirected_to(rejected) == "/login"
    assert Plug.Conn.get_resp_header(rejected, "referrer-policy") == ["no-referrer"]
  end

  test "project continuation reuses a valid destination session without starting OAuth" do
    {conn, marker} = signed_in()
    result = get(browser_recycle(conn), "/login?continue=1")
    assert redirected_to(result) == "/"
    assert Plug.Conn.get_session(result, BrowserAuth.session_key()) == marker
    assert Plug.Conn.get_session(result, "google_flow") == nil
    assert Plug.Conn.get_resp_header(result, "cache-control") == ["no-store"]
    assert BrowserAuth.authorized?(BrowserAuth.conn_context(result))
  end

  test "project continuation submits destination CSRF and validates its own OAuth identity" do
    login = get(local_conn(), "/login?continue=1")
    html = html_response(login, 200)
    assert html =~ "Opening your project"
    assert html =~ ~s(data-continue="true")
    script = html |> Floki.parse_document!() |> Floki.attribute("script", "src") |> hd()
    assert get(local_conn(), script).resp_body =~ "form.requestSubmit()"

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(local_conn(), "/auth/google", %{"continue" => "1"})
    end

    started = post(browser_recycle(login), "/auth/google", %{"_csrf_token" => csrf(login), "continue" => "1", "return_to" => "/"})
    query = URI.decode_query(URI.parse(redirected_to(started)).query)
    assert query["prompt"] == "none"
    assert query["login_hint"] == "owner@gmail.com"
    assert query["redirect_uri"] == "http://localhost/auth/google/callback"
    assert Plug.Conn.get_session(started, "google_continue") == nil
    provider(query)
    callback = "/auth/google/callback?" <> URI.encode_query(%{"state" => query["state"], "code" => "fixture"})
    completed = get(browser_recycle(started), callback)
    assert redirected_to(completed) == "/"
    assert BrowserAuth.authorized?(BrowserAuth.conn_context(completed))
    assert get(browser_recycle(completed), "/").status == 200
    assert redirected_to(get(browser_recycle(completed), "/login?continue=1")) == "/"
  end

  test "Google interaction falls back once without automatically retrying" do
    login = get(local_conn(), "/login?continue=1")
    started = post(browser_recycle(login), "/auth/google", %{"_csrf_token" => csrf(login), "continue" => "1"})
    query = URI.decode_query(URI.parse(redirected_to(started)).query)
    callback = "/auth/google/callback?" <> URI.encode_query(%{"state" => query["state"], "error" => "login_required"})
    failed = get(browser_recycle(started), callback)
    assert redirected_to(failed) == "/login"
    assert Plug.Conn.get_session(failed, "google_continue") == nil
    fallback = get(browser_recycle(failed), "/login?continue=1")
    html = html_response(fallback, 200)
    assert html =~ "Choose your Google account"
    refute html =~ "data-continue"
    assert Floki.find(Floki.parse_document!(html), "script") == []
    retry = post(browser_recycle(fallback), "/auth/google", %{"_csrf_token" => csrf(fallback)})
    assert URI.decode_query(URI.parse(redirected_to(retry)).query)["prompt"] == "select_account"
  end

  test "continuation intent is issued by this project and is cleared on a normal login page" do
    for path <- ["/login", "/login?continue=unexpected"] do
      login = get(local_conn(), path)
      refute login.resp_body =~ "data-continue"
      started = post(browser_recycle(login), "/auth/google", %{"_csrf_token" => csrf(login), "continue" => "1"})
      assert redirected_to(started) == "/login"
    end

    continuation = get(local_conn(), "/login?continue=1")
    normal = get(browser_recycle(continuation), "/login")
    assert Plug.Conn.get_session(normal, "google_continue") == false
    refute normal.resp_body =~ "data-continue"
    foreign = get(%{local_conn() | host: "evil.example"}, "/login?continue=1")
    refute foreign.resp_body =~ "data-continue"
  end

  test "a delayed continuation form cannot replace an existing session" do
    {conn, marker} = signed_in()
    token = csrf(conn)
    conn = conn |> browser_recycle() |> Plug.Test.init_test_session(%{"google_continue" => true})
    result = post(conn, "/auth/google", %{"_csrf_token" => token, "continue" => "1"})
    assert redirected_to(result) == "/"
    assert Plug.Conn.get_session(result, BrowserAuth.session_key()) == marker
    assert Plug.Conn.get_session(result, "google_continue") == nil
    assert BrowserAuth.authorized?(BrowserAuth.conn_context(result))
  end

  test "explicit sign-out suppresses automatic continuation until manual sign-in" do
    {conn, _marker} = signed_in()
    logged_out = post(browser_recycle(conn), "/operator/session/logout", %{"_csrf_token" => csrf(conn)})
    assert Plug.Conn.get_session(logged_out, "google_signed_out") == true
    login = get(browser_recycle(logged_out), "/login?continue=1")
    refute login.resp_body =~ "data-continue"
    assert Plug.Conn.get_session(login, "google_continue") == false
    stale = post(browser_recycle(login), "/auth/google", %{"_csrf_token" => csrf(login), "continue" => "1"})
    assert redirected_to(stale) == "/login"
    assert Plug.Conn.get_session(stale, "google_signed_out") == true
    assert Plug.Conn.get_session(stale, "google_flow") == nil
    started = post(browser_recycle(login), "/auth/google", %{"_csrf_token" => csrf(login)})
    assert URI.decode_query(URI.parse(redirected_to(started)).query)["prompt"] == "select_account"
    assert Plug.Conn.get_session(started, "google_signed_out") == nil
  end

  test "expired destination grants can renew with Google but local-token projects stay local", ctx do
    {conn, marker} = signed_in()
    :ok = BrowserSessions.revoke(marker["id"])
    login = get(browser_recycle(conn), "/login?continue=1")
    assert login.resp_body =~ ~s(data-continue="true")
    refute BrowserAuth.authorized?(BrowserAuth.conn_context(login))
    update_auth(ctx, %{"provider" => "local_token"})
    assert redirected_to(get(local_conn(), "/login?continue=1")) == "/"
  end

  test "loopback login aliases navigate to the configured origin before rendering a form", ctx do
    update_auth(ctx, Map.put(ctx.config.browser_auth, "public_origin", "http://localhost:8778"))

    for {host, peer} <- [{"127.0.0.1", {127, 0, 0, 1}}, {"::1", {0, 0, 0, 0, 0, 0, 0, 1}}] do
      conn = %{local_conn() | host: host, port: 8778}
      conn = Plug.Test.put_peer_data(conn, %{address: peer, port: 55, ssl_cert: nil})
      login = get(conn, "/login?return_to=https%3A%2F%2Fevil.example&code=discard&state=discard")

      assert redirected_to(login) == "http://localhost:8778/login"
      assert Plug.Conn.get_resp_header(login, "cache-control") == ["no-store"]
      assert Plug.Conn.get_resp_header(login, "referrer-policy") == ["no-referrer"]
      assert Plug.Conn.get_session(login, "google_flow") == nil
      assert Floki.find(Floki.parse_document!(login.resp_body), "form") == []
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn -> post(conn, "/auth/google", %{}) end
    end

    canonical = get(%{local_conn() | port: 8778}, "/login")
    assert html_response(canonical, 200) =~ "Sign in with Google"
    assert Plug.Conn.get_resp_header(canonical, "location") == []

    alias_switch = get(%{local_conn() | host: "127.0.0.1", port: 8778}, "/login?continue=1&return_to=https://evil.example")
    assert redirected_to(alias_switch) == "http://localhost:8778/login?continue=1"
  end

  test "login alias navigation ignores spoofed peers and requires the same local endpoint" do
    alias_conn = %{local_conn() | host: "127.0.0.1"}

    remote =
      alias_conn
      |> Plug.Test.put_peer_data(%{address: {192, 0, 2, 1}, port: 55, ssl_cert: nil})
      |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1")
      |> Plug.Conn.put_req_header("x-forwarded-host", "localhost")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "http")

    for conn <- [remote, %{alias_conn | port: 8778}, %{alias_conn | host: "evil.example"}, %{alias_conn | scheme: :https}] do
      assert BrowserOrigin.loopback_login_url(conn) == nil
      url = URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port, path: "/login"})
      assert Plug.Conn.get_resp_header(get(conn, url), "location") == []
    end
  end

  test "login alias navigation is unavailable for HTTPS, invalid Google configuration and local tokens", ctx do
    alias_conn = %{local_conn() | host: "127.0.0.1"}

    for auth <- [
          Map.put(ctx.config.browser_auth, "public_origin", "https://localhost"),
          Map.put(ctx.config.browser_auth, "public_origin", "http://localhost/path"),
          Map.put(ctx.config.browser_auth, "client_secret", nil),
          %{"provider" => "local_token"}
        ] do
      update_auth(ctx, auth)
      assert BrowserOrigin.loopback_login_url(alias_conn) == nil
      refute Enum.any?(Plug.Conn.get_resp_header(get(alias_conn, "/login"), "location"), &String.starts_with?(&1, "http"))
    end
  end

  test "stale alias login POST offers recovery without changing grants or pending flows" do
    {conn, marker} = signed_in()
    {:ok, flow} = BrowserSessions.issue(:flow, %{pending: true})

    login =
      conn
      |> browser_recycle()
      |> Plug.Test.init_test_session(%{"google_flow" => flow})
      |> get("/login")

    alias_browser = %{browser_recycle(login) | host: "127.0.0.1"}
    alias_browser = Plug.Conn.put_req_header(alias_browser, "origin", "http://127.0.0.1")
    rejected = post(alias_browser, "/auth/google", %{"_csrf_token" => csrf(login), "return_to" => "https://evil.example"})
    document = rejected |> html_response(403) |> Floki.parse_document!()

    assert Floki.attribute(document, "a", "href") == ["http://localhost/login"]
    assert Floki.text(document) =~ "Continue to Symphony"
    assert Floki.find(document, "form") == []
    assert Plug.Conn.get_resp_header(rejected, "location") == []
    assert Plug.Conn.get_session(rejected, BrowserAuth.session_key()) == marker
    assert Plug.Conn.get_session(rejected, "google_flow") == flow
    assert {:ok, _} = BrowserSessions.session(marker["id"])

    callback = get(%{browser_recycle(rejected) | host: "127.0.0.1"}, "/auth/google/callback?code=foreign&state=foreign")
    assert callback.status == 403
    assert Plug.Conn.get_resp_header(callback, "location") == []
    assert {:ok, _} = BrowserSessions.session(marker["id"])
    assert {:ok, %{pending: true}} = BrowserSessions.take_flow(flow)
  end

  test "logout revokes session and pending flow before disconnect and old cookies cannot return" do
    {conn, marker} = signed_in()
    assert get(browser_recycle(conn), "/").status == 200
    login = get(browser_recycle(conn), "/login")
    {:ok, flow} = BrowserSessions.issue(:flow, %{})
    login = browser_recycle(login) |> Plug.Test.init_test_session(%{"google_flow" => flow}) |> get("/login")
    result = post(browser_recycle(login), "/operator/session/logout", %{"_csrf_token" => csrf(login)})
    assert redirected_to(result) == "/login"
    assert {:error, :expired} = BrowserSessions.session(marker["id"])
    assert {:error, :expired} = BrowserSessions.take_flow(flow)
    assert redirected_to(get(browser_recycle(conn), "/")) == "/login"
  end

  test "wrong origin login and logout preserve current authentication" do
    {conn, marker} = signed_in()
    login = get(browser_recycle(conn), "/login")

    for origin <- ["https://evil.example", "http://localhost:8778", "null"],
        path <- ["/auth/google", "/operator/session/logout"] do
      # CSRF token itself is valid; origin check is a separate invariant.
      foreign = browser_recycle(login) |> Plug.Conn.put_req_header("origin", origin)
      result = post(foreign, path, %{"_csrf_token" => csrf(login)})
      assert result.status == 403
      assert {:ok, _} = BrowserSessions.session(marker["id"])
    end
  end

  test "unsolicited callback GET cannot sign out an authenticated browser" do
    {conn, marker} = signed_in()

    for path <- ["/auth/google/callback", "/auth/google/callback?code=foreign&state=foreign"] do
      callback = get(browser_recycle(conn), path)
      assert redirected_to(callback) == "/"
      assert {:ok, _} = BrowserSessions.session(marker["id"])
      assert BrowserAuth.authorized?(BrowserAuth.conn_context(callback))
      assert get(browser_recycle(callback), "/").status == 200
    end
  end

  test "session current identity policy, tracker scope and provider mode are rechecked", ctx do
    {conn, marker} = signed_in()
    auth = BrowserAuth.conn_context(conn)
    assert BrowserAuth.authorized?(auth)
    refute BrowserAuth.authorized?(%{auth | tracker_fingerprint: "other"})
    refute BrowserAuth.authorized?(%{auth | host: "evil.example"})
    refute BrowserAuth.authorized?(%{auth | peer_ip: {192, 0, 2, 3}})
    update_auth(ctx, Map.put(ctx.config.browser_auth, "allowed_emails", ["other@gmail.com"]))
    refute BrowserAuth.authorized?(auth)
    update_auth(ctx, %{"provider" => "local_token"})
    refute BrowserAuth.authorized?(auth)
    BrowserSessions.revoke(marker["id"])
  end

  test "HTTPS proxy normalization requires configured real peer, never forwarded headers", ctx do
    auth = ctx.config.browser_auth |> Map.put("public_origin", "https://symphony.example.com") |> Map.put("trusted_proxy_ips", ["127.0.0.1"])
    update_auth(ctx, auth)
    conn = %{local_conn() | host: "symphony.example.com", port: 8080}
    trusted = BrowserOrigin.call(conn, [])
    assert trusted.scheme == :https and trusted.port == 443

    remote =
      Plug.Test.put_peer_data(conn, %{address: {192, 0, 2, 1}, port: 10, ssl_cert: nil})
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1")

    assert BrowserOrigin.call(remote, []).scheme == :http
    refute BrowserAuth.callback_request?(remote |> Plug.Test.init_test_session(%{}))
    assert BrowserAuth.callback_request?(trusted |> Plug.Test.init_test_session(%{}))
    login = get(conn, "/login")
    assert login.resp_cookies["_symphony_elixir_key"].secure
  end

  test "invalid identity settings fail closed and secrets never appear in log filtering", ctx do
    for value <- ["http://example.com", "https://example.com/path", "https://user@example.com", "https://example.com?x=1", "//example.com", "https://example.com/"] do
      update_auth(ctx, Map.put(ctx.config.browser_auth, "public_origin", value))
      assert {:error, :auth_unconfigured} = BrowserIdentity.settings()
    end

    update_auth(ctx, Map.put(ctx.config.browser_auth, "provider", "typo"))
    assert BrowserAuth.google_enabled?()
    assert redirected_to(get(local_conn(), "/")) == "/login"

    for key <- ~w(code state id_token access_token refresh_token client_secret code_verifier) do
      assert Phoenix.Logger.filter_values(%{key => "secret"}) == %{key => "[FILTERED]"}
    end
  end

  test "successful callback creates a revocable session without retaining Google tokens" do
    login = get(local_conn(), "/login")
    started = post(browser_recycle(login), "/auth/google", %{"_csrf_token" => csrf(login), "return_to" => "/"})
    query = URI.decode_query(URI.parse(redirected_to(started)).query)
    provider(query)
    callback = "/auth/google/callback?" <> URI.encode_query(%{"state" => query["state"], "code" => "fixture"})
    completed = get(browser_recycle(started), callback)
    assert redirected_to(completed) == "/"
    assert Plug.Conn.get_resp_header(completed, "referrer-policy") == ["no-referrer"]
    marker = Plug.Conn.get_session(completed, BrowserAuth.session_key())
    assert BrowserAuth.authorized?(BrowserAuth.conn_context(completed))
    assert {:ok, %{identity: %{"sub" => "subject123"}}} = BrowserSessions.session(marker["id"])
    refute inspect(Plug.Conn.get_session(completed)) =~ "provider-token"
    refute inspect(completed.resp_cookies) =~ "provider-token"
    assert get(browser_recycle(completed), "/").status == 200
    replayed = get(browser_recycle(started), callback)
    assert redirected_to(replayed) == "/login"
  end

  test "capacity failure shows generic recovery and never exposes provider configuration" do
    flows = fill_store([])

    try do
      login = get(local_conn(), "/login")
      failed = post(browser_recycle(login), "/auth/google", %{"_csrf_token" => csrf(login)})
      assert redirected_to(failed) == "/login"
      refute inspect(Plug.Conn.get_session(failed)) =~ "synthetic-client-secret"
      assert Plug.Conn.get_session(failed, "google_flow") == nil
    after
      Enum.each(flows, &BrowserSessions.revoke/1)
    end
  end

  test "bad origin callbacks and browser-token fallback are refused", ctx do
    foreign = %{local_conn() | host: "evil.example"}
    assert get(foreign, "/auth/google/callback?code=bad&state=bad").status == 403
    login = get(local_conn(), "/login")
    response = post(browser_recycle(login), "/operator/session", %{"_csrf_token" => csrf(login), "operator_token" => "unused"})
    assert redirected_to(response) == "/login"
    update_auth(ctx, Map.put(ctx.config.browser_auth, "client_secret", nil))
    conn = Plug.Test.init_test_session(local_conn(), %{})
    refute BrowserAuth.callback_request?(conn)
    refute BrowserAuth.browser_request?(conn)
    update_auth(ctx, %{"provider" => "local_token"})
    assert redirected_to(get(local_conn(), "/login")) == "/?panel=settings"
  end

  defp fill_store(ids) do
    case BrowserSessions.issue(:flow, %{}) do
      {:ok, id} -> fill_store([id | ids])
      {:error, :capacity} -> ids
    end
  end

  defp provider(query) do
    previous = Application.get_env(:symphony_elixir, :google_http_plug)
    Application.put_env(:symphony_elixir, :google_http_plug, {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :google_http_plug, previous),
        else: Application.delete_env(:symphony_elixir, :google_http_plug)
    end)

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    now = System.system_time(:second)

    claims = %{
      "iss" => "https://accounts.google.com",
      "sub" => "subject123",
      "aud" => "test.apps.googleusercontent.com",
      "iat" => now,
      "exp" => now + 300,
      "nonce" => query["nonce"],
      "email" => "owner@gmail.com",
      "email_verified" => true
    }

    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "kid" => "fixture"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    unsigned = header <> "." <> payload
    token = unsigned <> "." <> Base.url_encode64(:public_key.sign(unsigned, :sha256, key), padding: false)

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.host, conn.request_path} do
        {"POST", "oauth2.googleapis.com", "/token"} ->
          Req.Test.json(conn, %{"token_type" => "Bearer", "access_token" => "provider-token", "id_token" => token})

        {"GET", "www.googleapis.com", "/oauth2/v3/certs"} ->
          Req.Test.json(conn, %{"keys" => [%{"kty" => "RSA", "kid" => "fixture", "n" => encode_unsigned(elem(key, 2)), "e" => encode_unsigned(elem(key, 3))}]})
      end
    end)
  end

  defp encode_unsigned(x), do: x |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)

  defp signed_in do
    {:ok, config} = BrowserIdentity.settings()
    identity = %{"iss" => "https://accounts.google.com", "sub" => "123", "email" => "owner@gmail.com", "email_verified" => true}
    {:ok, id} = BrowserSessions.issue(:session, %{identity: identity, fingerprint: config.fingerprint, scope: Orchestrator.tracker_fingerprint()})
    marker = %{"provider" => "google", "id" => id}
    conn = local_conn() |> Plug.Test.init_test_session(%{BrowserAuth.session_key() => marker, "live_socket_id" => "operator:" <> id})
    {get(conn, "/login"), marker}
  end

  defp update_auth(ctx, auth) do
    File.write!(ctx.workflow, "---\n" <> Jason.encode!(%{ctx.config | browser_auth: auth}) <> "\n---\nTask")
    WorkflowStore.force_reload()
  end

  defp csrf(conn), do: conn.resp_body |> Floki.parse_document!() |> Floki.find("input[name=_csrf_token]") |> Floki.attribute("value") |> hd()
  defp browser_recycle(conn), do: recycle(conn) |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)

  defp local_conn do
    build_conn()
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Plug.Test.put_peer_data(%{address: {127, 0, 0, 1}, port: 55, ssl_cert: nil})
  end
end
