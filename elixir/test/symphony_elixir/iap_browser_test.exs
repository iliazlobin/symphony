Code.require_file("../support/iap_support.exs", __DIR__)

defmodule SymphonyElixir.IAPBrowserTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixir.IAPFixture
  alias SymphonyElixirWeb.{BrowserAuth, BrowserSessions, Endpoint, IAPIdentity, IAPKeys, LiveSocket}
  @endpoint Endpoint
  @origin "https://symphony.example"

  defmodule ChatStore do
    def projects(_auth) do
      send(Endpoint.config(:iap_test_owner), :private_projects_read)
      {:ok, [%{"id" => "fixture", "label" => "Private IAP project"}]}
    end

    def list(_project, _auth), do: {:ok, []}
  end

  setup do
    {private, public} = IAPFixture.key_pair()
    previous_plug = Application.get_env(:symphony_elixir, :iap_http_plug)
    previous_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("t", 32))
    Application.put_env(:symphony_elixir, :iap_http_plug, {IAPFixture.Keys, owner: self(), keys: %{"fixture" => public}})
    :sys.replace_state(IAPKeys, fn state -> %{state | keys: %{}, expires: state.clock.(), refresh_at: state.clock.()} end)
    root = Path.dirname(Workflow.workflow_file_path())

    config = %{
      tracker: %{kind: "memory", active_states: ["open"], terminal_states: ["closed"]},
      browser_auth: %{provider: "iap", public_origin: @origin, audience: "/projects/123/global/backendServices/456", allowed_emails: ["iliazlobin91@gmail.com"]},
      workspace: %{root: root <> "/workspaces"},
      observability: %{dashboard_enabled: false},
      control: %{enabled: true, state_path: root <> "/control.json", initial_mode: "paused", token: String.duplicate("t", 32)}
    }

    put_config(config)
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])

    endpoint_options = [
      server: false,
      secret_key_base: String.duplicate("i", 64),
      check_origin: [@origin],
      chat_store: ChatStore,
      iap_test_owner: self()
    ]

    updates = Keyword.merge(previous_endpoint, endpoint_options)
    Application.put_env(:symphony_elixir, Endpoint, updates)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous_endpoint)
      restore_env("SYMPHONY_CONTROL_TOKEN", previous_token)

      if previous_plug do
        Application.put_env(:symphony_elixir, :iap_http_plug, previous_plug)
      else
        Application.delete_env(:symphony_elixir, :iap_http_plug)
      end
    end)

    %{private: private, token: IAPFixture.token(private), config: config}
  end

  test "real signed HTTP fetches its session before router dispatch and returns only an opaque grant", ctx do
    # Deliberately no init_test_session: exercise the actual Endpoint plug order.
    response = get(proxy_conn(ctx.token), "/login")
    assert redirected_to(response) == "/"
    marker = Plug.Conn.get_session(response, BrowserAuth.session_key())
    assert %{"provider" => "iap", "id" => id} = marker
    assert {:ok, record} = BrowserSessions.session(id)
    assert record.identity["email"] == "iliazlobin91@gmail.com"
    refute inspect(response.resp_cookies) =~ ctx.token
    assert response.scheme == :https
    assert response.resp_cookies["_symphony_elixir_key"].secure
    assert Plug.Conn.get_resp_header(response, "cache-control") == ["no-store"]
    assert BrowserAuth.authorized?(BrowserAuth.conn_context(response))
    assert_received :iap_keys_requested
  end

  test "missing, duplicate and forged assertions expose no private view even with unsigned identity headers", ctx do
    for path <- ["/", "/chat", "/dashboard.js", "/login"] do
      denied = proxy_conn(nil) |> Plug.Conn.put_req_header("x-goog-authenticated-user-email", "accounts.google.com:iliazlobin91@gmail.com") |> get(path)
      assert denied.status == 403
      refute denied.resp_body =~ "Private IAP project"
    end

    duplicate = %{proxy_conn(ctx.token) | req_headers: [{"x-goog-iap-jwt-assertion", ctx.token} | proxy_conn(ctx.token).req_headers]}
    assert get(duplicate, "/").status == 403
    {other_private, _} = IAPFixture.key_pair()
    assert get(proxy_conn(IAPFixture.token(other_private)), "/").status == 403
    assert get(proxy_conn(String.duplicate("x", 16_385)), "/").status == 403
    refute_received :private_projects_read
  end

  test "signed claims still require this exact audience, issuer, operator and bounded validity", ctx do
    now = System.system_time(:second)

    invalid = [
      %{"aud" => "/projects/123/global/backendServices/999"},
      %{"aud" => ["/projects/123/global/backendServices/456"]},
      %{"iss" => "https://accounts.google.com"},
      %{"email" => "other@gmail.com"},
      %{"email" => nil},
      %{"sub" => ""},
      %{"iat" => now + 100},
      %{"iat" => now - 1_000},
      %{"exp" => now - 1},
      %{"exp" => now + 700},
      %{"exp" => "future"},
      %{"nbf" => now + 100},
      %{"nbf" => "future"}
    ]

    {:ok, settings} = IAPIdentity.settings()
    for claims <- invalid, do: assert({:error, :invalid_identity} == IAPIdentity.verify(IAPFixture.token(ctx.private, claims), settings))
    assert {:ok, _} = IAPIdentity.verify(ctx.token, settings)
    assert {:error, :invalid_identity} = IAPIdentity.verify(IAPFixture.token("synthetic-key", %{}, "HS256"), settings)
    assert {:error, :invalid_identity} = IAPIdentity.verify("invalid", settings)
  end

  test "host and Origin cannot be selected by forwarded headers or valid cookies", ctx do
    foreign = %{proxy_conn(ctx.token) | host: "attacker.example"} |> Plug.Conn.put_req_header("x-forwarded-host", "symphony.example")
    assert get(foreign, "/").status == 403

    for origin <- ["https://attacker.example", "null", "https://symphony.example/"] do
      assert get(Plug.Conn.put_req_header(proxy_conn(ctx.token), "origin", origin), "/").status == 403
    end

    signed = get(proxy_conn(ctx.token), "/login")
    cookie_only = browser_recycle(signed) |> Plug.Conn.delete_req_header("x-goog-iap-jwt-assertion")
    assert get(cookie_only, "/chat").status == 403
    refute_received :private_projects_read
  end

  test "raw websocket upgrade requires a verified assertion and the fixed browser Origin", ctx do
    assert get(socket_headers(proxy_conn(nil), @origin), "/live/websocket?vsn=2.0.0").status == 403
    assert get(socket_headers(proxy_conn("forged"), @origin), "/live/websocket?vsn=2.0.0").status == 403
    assert get(socket_headers(proxy_conn(ctx.token), "https://attacker.example"), "/live/websocket?vsn=2.0.0").status == 403
    upgraded = get(socket_headers(proxy_conn(ctx.token), @origin), "/live/websocket?vsn=2.0.0")
    assert upgraded.state == :upgraded, inspect({upgraded.status, upgraded.resp_body})
    assert :error = LiveSocket.connect(%{"x-goog-iap-jwt-assertion" => ctx.token}, %Phoenix.Socket{}, %{uri: URI.parse(@origin), x_headers: []})
    put_config(put_in(ctx.config, [:browser_auth, :provider], "unknown"))
    assert :error = LiveSocket.connect(%{}, %Phoenix.Socket{}, %{})
  end

  test "a connected private chat revalidates grant revocation before the next callback", ctx do
    {:ok, view, html} = live(proxy_conn(ctx.token), "/chat")
    assert html =~ "Private IAP project"
    assert_received :private_projects_read
    %{browser_gate_auth: auth} = :sys.get_state(view.pid).socket.assigns
    :ok = BrowserSessions.revoke(auth.marker["id"])
    send(view.pid, :browser_session_check)
    assert_redirect(view, "/login")
  end

  test "a connected mount cannot replace its raw signed header with a valid HTTP cookie or connect params", ctx do
    for headers <- [[], [{"x-goog-iap-jwt-assertion", "forged"}]] do
      response = get(proxy_conn(ctx.token), "/chat")
      assert html_response(response, 200) =~ "Opening your workspace"
      assert %{"provider" => "iap", "id" => id} = Plug.Conn.get_session(response, BrowserAuth.session_key())
      assert {:ok, _record} = BrowserSessions.session(id)
      refute_received :private_projects_read

      conn =
        response
        |> Plug.Conn.put_private(:live_view_connect_info, %{uri: URI.parse("http://symphony.example:8080"), x_headers: headers})
        |> put_connect_params(%{"x-goog-iap-jwt-assertion" => ctx.token})

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn)
      refute_received :private_projects_read
    end
  end

  test "a connected chat cannot outlive its signed assertion or changed admission configuration", ctx do
    {:ok, view, _} = live(proxy_conn(ctx.token), "/chat")
    assert_received :private_projects_read
    put_config(put_in(ctx.config, [:browser_auth, :audience], "/projects/123/global/backendServices/789"))
    send(view.pid, :browser_session_check)
    assert_redirect(view, "/login")
    put_config(ctx.config)
    {:ok, expires_view, _} = live(proxy_conn(ctx.token), "/chat")

    :sys.replace_state(expires_view.pid, fn state ->
      auth = state.socket.assigns.browser_gate_auth
      verified = %{auth.iap_identity | identity: Map.put(auth.iap_identity.identity, "exp", System.system_time(:second) - 1)}
      %{state | socket: Phoenix.Component.assign(state.socket, :browser_gate_auth, %{auth | iap_identity: verified})}
    end)

    send(expires_view.pid, :browser_session_check)
    assert_redirect(expires_view, "/login")
  end

  test "sign-out clears IAP login and requires an explicit CSRF-protected continuation", ctx do
    response = get(proxy_conn(ctx.token), "/?panel=settings")
    csrf = csrf(response)
    old_marker = Plug.Conn.get_session(response, BrowserAuth.session_key())
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn -> post(proxy_conn(ctx.token), "/auth/iap", %{}) end
    logged_out = browser_recycle(response) |> post("/operator/session/logout", %{"_csrf_token" => csrf})
    assert redirected_to(logged_out) == @origin <> "/?gcp-iap-mode=CLEAR_LOGIN_COOKIE"
    assert {:error, :expired} = BrowserSessions.session(old_marker["id"])
    login = browser_recycle(logged_out) |> get("/login?continue=1")
    assert html_response(login, 200) =~ "Continue to Symphony"
    assert login.resp_body =~ "action=\"/auth/iap\""
    refute BrowserAuth.authorized?(BrowserAuth.conn_context(login))
    refute Plug.Conn.get_session(login, BrowserAuth.session_key())
    continued = browser_recycle(login) |> post("/auth/iap", %{"_csrf_token" => csrf(login), "return_to" => "https://attacker.example"})
    assert redirected_to(continued) == "/?panel=settings"
    assert BrowserAuth.authorized?(BrowserAuth.conn_context(continued))
    refute Plug.Conn.get_session(continued, "iap_signed_out")
  end

  test "only health bypasses IAP; signed browser identity never grants the API bearer authority", ctx do
    assert get(proxy_conn(nil), "/healthz").status == 200
    assert post(proxy_conn(nil), "/healthz", %{}).status == 403
    assert get(proxy_conn(ctx.token), "/api/v1/control").status == 403
    local = %{build_conn() | host: "localhost"}
    assert get(local, "/api/v1/control").status == 401
    local = Plug.Conn.put_req_header(local, "authorization", "Bearer " <> String.duplicate("t", 32))
    assert get(local, "/api/v1/control").status in [200, 503]
    refute_received :private_projects_read
  end

  test "configuration resolves explicit environment references and fails closed when incomplete", ctx do
    previous_origin = System.get_env("IAP_FIXTURE_ORIGIN")
    previous_audience = System.get_env("IAP_FIXTURE_AUDIENCE")
    System.put_env("IAP_FIXTURE_ORIGIN", @origin)
    System.put_env("IAP_FIXTURE_AUDIENCE", "/projects/123/global/backendServices/456")

    on_exit(fn ->
      restore_env("IAP_FIXTURE_ORIGIN", previous_origin)
      restore_env("IAP_FIXTURE_AUDIENCE", previous_audience)
    end)

    configured = ctx.config |> put_in([:browser_auth, :public_origin], "$IAP_FIXTURE_ORIGIN") |> put_in([:browser_auth, :audience], "$IAP_FIXTURE_AUDIENCE")
    put_config(configured)
    assert {:ok, %{origin: @origin}} = IAPIdentity.settings()

    for changes <- [
          %{public_origin: "http://symphony.example"},
          %{public_origin: @origin <> ":443"},
          %{audience: "other"},
          %{allowed_emails: []},
          %{allowed_emails: ["*"]},
          %{allowed_subjects: ["different"]}
        ] do
      changed = Map.update!(ctx.config, :browser_auth, &Map.merge(&1, changes))
      put_config(changed)
      assert get(proxy_conn(ctx.token), "/").status == 403
    end

    put_config(ctx.config)
    response = get(proxy_conn(ctx.token), "/login")
    scope = Orchestrator.tracker_fingerprint()
    auth = BrowserAuth.conn_context(response)
    refute BrowserAuth.authorized?(%{auth | tracker_fingerprint: "stale-" <> scope})
    refute BrowserAuth.authorized?(%{auth | tracker_fingerprint: nil})
    {:ok, record} = BrowserSessions.session(auth.marker["id"])
    refute IAPIdentity.valid_session?(record, auth.iap_identity, "stale")
    refute IAPIdentity.valid_session?(%{record | scope: nil}, auth.iap_identity, nil)
  end

  defp put_config(config) do
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nFixture")
    :ok = WorkflowStore.force_reload()
  end

  defp proxy_conn(token) do
    conn =
      %{build_conn() | host: "symphony.example", port: 8080}
      |> Plug.Test.put_peer_data(%{address: {192, 0, 2, 10}, port: 12_345, ssl_cert: nil})
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)

    if token, do: Plug.Conn.put_req_header(conn, "x-goog-iap-jwt-assertion", token), else: conn
  end

  defp browser_recycle(conn) do
    conn
    |> recycle(~w(accept accept-language authorization x-goog-iap-jwt-assertion))
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
    |> Plug.Conn.put_req_header("origin", @origin)
  end

  defp csrf(conn), do: conn.resp_body |> Floki.parse_document!() |> Floki.find("input[name=_csrf_token]") |> Floki.attribute("value") |> hd()

  defp socket_headers(conn, origin) do
    %{conn | req_headers: [{"host", conn.host} | conn.req_headers]}
    |> Plug.Conn.put_req_header("origin", origin)
    |> Plug.Conn.put_req_header("connection", "upgrade")
    |> Plug.Conn.put_req_header("upgrade", "websocket")
    |> Plug.Conn.put_req_header("sec-websocket-version", "13")
    |> Plug.Conn.put_req_header("sec-websocket-key", Base.encode64("0123456789abcdef"))
  end
end
