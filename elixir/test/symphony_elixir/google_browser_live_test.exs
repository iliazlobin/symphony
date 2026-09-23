defmodule SymphonyElixir.GoogleBrowserLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.{BoardCache, BrowserAccess, BrowserAuth, BrowserIdentity, BrowserOrigin, BrowserSessions}
  alias SymphonyElixirWeb.{Endpoint, TaskBoard}
  @endpoint Endpoint

  defmodule FixtureChatStore do
    def projects(_auth) do
      send(Endpoint.config(:browser_test_owner), :private_projects_read)
      {:ok, [%{"id" => "fixture", "label" => "Allowed project"}]}
    end

    def list(_project, _auth), do: {:ok, []}
  end

  setup context do
    origin = if context[:proxy], do: "https://symphony.example", else: "http://localhost"
    previous_secret = System.get_env("SYMPHONY_TEST_GOOGLE_LIVE_SECRET")
    System.put_env("SYMPHONY_TEST_GOOGLE_LIVE_SECRET", "fixture-secret")
    config = configuration(origin)
    put_config(config)
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])

    endpoint_config =
      Keyword.merge(previous_endpoint,
        server: false,
        secret_key_base: String.duplicate("g", 64),
        check_origin: [origin],
        chat_store: FixtureChatStore,
        browser_test_owner: self()
      )

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous_endpoint)
      restore_env("SYMPHONY_TEST_GOOGLE_LIVE_SECRET", previous_secret)
    end)

    %{config: config}
  end

  test "anonymous HTTP cannot render chat while the authorized connected view reads its project" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(local_conn(), "/chat")
    refute_received :private_projects_read

    marker = session_marker()
    {:ok, view, html} = live(authorized_conn(marker), "/chat")
    assert html =~ "Allowed project"
    assert has_element?(view, "#chat-composer")
    assert_received :private_projects_read
  end

  test "a warm board snapshot stays behind Google authentication on HTTP and websocket mounts" do
    issue = %Issue{id: "cached-private", identifier: "MEM-1", title: "Private cached task", state: "open"}
    board = TaskBoard.project([issue], %{}, %{}, Config.settings!())
    configured = Application.get_env(:symphony_elixir, Endpoint)
    updates = Keyword.merge(configured, board_loader: fn _, _ -> board end, snapshot_loader: fn -> flunk("warm mount must not read runtime") end)
    Endpoint.config_change([{Endpoint, updates}], [])
    :ok = BoardCache.put(BoardCache.scope(Orchestrator), board)

    anonymous = get(local_conn(), "/")
    assert redirected_to(anonymous) == "/login"
    refute anonymous.resp_body =~ "Private cached task"
    assert {:error, {:redirect, %{to: "/login"}}} = live(local_conn(), "/")

    marker = session_marker()
    authorized = get(authorized_conn(marker), "/")
    assert html_response(authorized, 200) =~ "Private cached task"
    assert Plug.Conn.get_resp_header(authorized, "cache-control") == ["no-store"]
    {:ok, view, html} = live(authorized_conn(marker), "/")
    assert html =~ "Private cached task"
    assert render_async(view) =~ "Private cached task"
    :ok = BrowserSessions.revoke(marker["id"])
    send(view.pid, :browser_session_check)
    assert_redirect(view, "/login")
    assert {:error, {:redirect, %{to: "/login"}}} = live(authorized_conn(marker), "/")
  end

  test "initialized browser gate blocks anonymous reads and permits an authorized uncached response" do
    mode = BrowserAccess.init(:browser)
    anonymous = BrowserAccess.call(init_test_session(local_conn(), %{}), mode)
    assert anonymous.halted
    assert redirected_to(anonymous) == "/login"

    authorized = BrowserAccess.call(authorized_conn(session_marker()), mode)
    refute authorized.halted
    assert Plug.Conn.get_resp_header(authorized, "cache-control") == ["no-store"]
  end

  test "revocation redirects an already connected view before it handles the next update" do
    marker = session_marker()
    {:ok, view, _html} = live(authorized_conn(marker), "/chat")
    assert_received :private_projects_read
    send(view.pid, :browser_session_check)
    assert render(view) =~ "Allowed project"
    assert :ok = BrowserSessions.revoke(marker["id"])
    send(view.pid, :browser_session_check)
    assert_redirect(view, "/login")
    refute_received :private_projects_read
  end

  test "an allowlist change revokes a mounted view on its next route callback", ctx do
    marker = session_marker()
    {:ok, view, _html} = live(authorized_conn(marker), "/chat")
    assert_received :private_projects_read
    # Drain mount-time subscription messages while the session is still valid.
    # Otherwise their handle_info guard can correctly redirect before this route test.
    assert render(view) =~ "Allowed project"
    put_config(put_in(ctx.config, [:browser_auth, :allowed_emails], ["different@gmail.com"]))
    assert {:error, {:redirect, %{to: "/login"}}} = render_patch(view, "/chat?project=fixture")
    refute_received :private_projects_read
  end

  test "enabling Google also gates sockets that mounted under the legacy provider", ctx do
    put_config(put_in(ctx.config, [:browser_auth, :provider], "local_token"))
    {:ok, view, html} = live(local_conn(), "/chat")
    assert html =~ "Unlock chat"
    put_config(ctx.config)
    send(view.pid, :browser_session_check)
    assert_redirect(view, "/login")
    refute_received :private_projects_read
  end

  @tag proxy: true
  test "initialized proxy normalization accepts only its configured peer and host" do
    options = BrowserOrigin.init([])
    normalized = BrowserOrigin.call(proxy_conn(), options)
    assert normalized.scheme == :https
    assert normalized.port == 443

    foreign = %{proxy_conn() | host: "attacker.example"}
    assert BrowserOrigin.call(foreign, options).scheme == :http
    untrusted = proxy_conn() |> Plug.Test.put_peer_data(%{address: {192, 0, 2, 11}, port: 12_345, ssl_cert: nil})
    assert BrowserOrigin.call(untrusted, options).scheme == :http
  end

  @tag proxy: true
  test "actual websocket routing accepts the fixed HTTPS origin over a trusted HTTP proxy" do
    conn = proxy_conn() |> socket_headers("https://symphony.example") |> get("/live/websocket?vsn=2.0.0")
    assert conn.state == :upgraded, inspect({conn.status, conn.resp_body})
    assert conn.scheme == :http

    rejected = proxy_conn() |> socket_headers("https://attacker.example") |> get("/live/websocket?vsn=2.0.0")
    assert rejected.status == 403
  end

  @tag proxy: true
  test "connected socket context normalizes only the exact proxy peer and matching host" do
    marker = session_marker()
    session = %{BrowserAuth.session_key() => marker}
    raw = %{uri: URI.parse("http://symphony.example:4000/live/websocket"), peer_data: %{address: {192, 0, 2, 10}}}
    socket = %Phoenix.LiveView.Socket{private: %{connect_info: raw}}
    auth = BrowserAuth.context(session, socket)
    assert auth.scheme == "https"
    assert auth.port == 443
    assert BrowserAuth.authorized?(auth)

    untrusted = put_in(socket.private.connect_info.peer_data.address, {192, 0, 2, 11})
    refute BrowserAuth.authorized?(BrowserAuth.context(session, untrusted))
    foreign = put_in(socket.private.connect_info.uri.host, "attacker.example")
    refute BrowserAuth.authorized?(BrowserAuth.context(session, foreign))
  end

  defp configuration(origin) do
    %{
      tracker: %{kind: "memory", active_states: ["open"], terminal_states: ["closed"]},
      browser_auth: %{
        provider: "google",
        public_origin: origin,
        client_id: "fixture-client.apps.googleusercontent.com",
        client_secret: "$SYMPHONY_TEST_GOOGLE_LIVE_SECRET",
        allowed_emails: ["owner@gmail.com"],
        trusted_proxy_ips: ["192.0.2.10"]
      },
      observability: %{dashboard_enabled: false}
    }
  end

  defp put_config(config) do
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nFixture")
    :ok = WorkflowStore.force_reload()
  end

  defp session_marker do
    {:ok, config} = BrowserIdentity.settings()
    identity = %{"iss" => "https://accounts.google.com", "sub" => "fixture-subject", "email" => "owner@gmail.com", "email_verified" => true}
    {:ok, id} = BrowserSessions.issue(:session, %{identity: identity, fingerprint: config.fingerprint, scope: Orchestrator.tracker_fingerprint()})
    %{"provider" => "google", "id" => id}
  end

  defp local_conn, do: %{build_conn() | host: "localhost"}
  defp authorized_conn(marker), do: init_test_session(local_conn(), %{BrowserAuth.session_key() => marker})

  defp proxy_conn do
    %{build_conn() | host: "symphony.example", port: 4000}
    |> Plug.Test.put_peer_data(%{address: {192, 0, 2, 10}, port: 12_345, ssl_cert: nil})
  end

  defp socket_headers(conn, origin) do
    %{conn | req_headers: [{"host", "symphony.example:4000"} | conn.req_headers]}
    |> Plug.Conn.put_req_header("origin", origin)
    |> Plug.Conn.put_req_header("connection", "upgrade")
    |> Plug.Conn.put_req_header("upgrade", "websocket")
    |> Plug.Conn.put_req_header("sec-websocket-version", "13")
    |> Plug.Conn.put_req_header("sec-websocket-key", Base.encode64("0123456789abcdef"))
  end
end
