defmodule SymphonyElixir.BrowserControlsTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  alias Phoenix.Socket.Transport
  alias SymphonyElixirWeb.{BoardActions, BrowserAuth, Endpoint}
  @endpoint Endpoint

  setup do
    {:ok, temporary_root} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(temporary_root, "symphony-browser-controls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow = root <> "/WORKFLOW.md"

    config = %{
      tracker: %{kind: "memory", active_states: ["open"], terminal_states: ["closed"]},
      workspace: %{root: root <> "/workspaces"},
      polling: %{interval_ms: 60_000},
      observability: %{dashboard_enabled: false},
      control: %{enabled: true, state_path: root <> "/control.json", initial_mode: "paused", max_attempts: 2}
    }

    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(workflow)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    supervisor = start_supervised!({Task.Supervisor, []})
    name = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor})
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])
    previous_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)
    endpoint_config = Keyword.merge(previous_endpoint, server: false, secret_key_base: String.duplicate("b", 64), orchestrator: name)
    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous_endpoint)
      restore_env("SYMPHONY_CONTROL_TOKEN", previous_token)
      File.rm_rf(root)
    end)

    {:ok, marker} = BrowserAuth.authenticate(local_conn(), token)

    authorization = %{
      marker: marker,
      host: "localhost",
      peer_ip: {127, 0, 0, 1},
      tracker_fingerprint: Orchestrator.tracker_fingerprint()
    }

    %{pid: pid, token: token, marker: marker, authorization: authorization, workflow: workflow, config: config}
  end

  test "login accepts only a configured token with a loopback Host and actual peer", ctx do
    assert {:ok, _} = BrowserAuth.authenticate(local_conn(), ctx.token)
    assert {:error, :unauthorized} = BrowserAuth.authenticate(local_conn(), "wrong")
    assert {:error, :unauthorized} = BrowserAuth.authenticate(local_conn(), %{"token" => ctx.token})
    assert {:error, :local_browser_required} = BrowserAuth.authenticate(%{local_conn() | host: "evil.example"}, ctx.token)

    remote = local_conn() |> Plug.Test.put_peer_data(%{address: {192, 0, 2, 10}, port: 55, ssl_cert: nil})
    # Forged remote_ip and forwarded headers do not override the adapter's peer.
    remote = %{remote | remote_ip: {127, 0, 0, 1}} |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1")
    assert {:error, :local_browser_required} = BrowserAuth.authenticate(remote, ctx.token)

    ipv6_peer = %{address: {0, 0, 0, 0, 0, 0, 0, 1}, port: 55, ssl_cert: nil}
    ipv6 = %{local_conn() | host: "::1"} |> Plug.Test.put_peer_data(ipv6_peer)
    assert {:ok, _} = BrowserAuth.authenticate(ipv6, ctx.token)
    System.delete_env("SYMPHONY_CONTROL_TOKEN")
    assert {:error, :control_auth_unconfigured} = BrowserAuth.authenticate(local_conn(), ctx.token)
  end

  test "cross-origin browser posts are refused even with the right control token", ctx do
    for origin <- ["https://evil.example", "http://localhost:1234", "https://localhost", "null", "http://localhost@evil.example", "http://localhost/path"] do
      conn = Plug.Conn.put_req_header(local_conn(), "origin", origin)
      assert {:error, :local_browser_required} = BrowserAuth.authenticate(conn, ctx.token)
    end

    conn = Plug.Conn.put_req_header(local_conn(), "origin", "http://localhost")
    assert {:ok, _} = BrowserAuth.authenticate(conn, ctx.token)

    for origins <- [["http://localhost", "http://localhost"], ["http://localhost", "https://evil.example"]] do
      ambiguous = %{local_conn() | req_headers: Enum.map(origins, &{"origin", &1})}
      assert {:error, :local_browser_required} = BrowserAuth.authenticate(ambiguous, ctx.token)
    end
  end

  test "chat login returns to chat while untrusted return URLs cannot redirect", ctx do
    for {destination, expected} <- [
          {"/chat", "/chat"},
          {"/?assistant=1", "/?assistant=1"},
          {"https://evil.example", "/?panel=settings"},
          {"//evil.example", "/?panel=settings"},
          {"/chat?next=//evil.example", "/?panel=settings"}
        ] do
      {conn, csrf} = browser_page()
      logged_in = post(browser_recycle(conn), "/operator/session", %{"_csrf_token" => csrf, "operator_token" => ctx.token, "return_to" => destination})
      assert redirected_to(logged_in) == expected
    end

    {conn, csrf} = browser_page()
    rejected = post(browser_recycle(conn), "/operator/session", %{"_csrf_token" => csrf, "operator_token" => "wrong", "return_to" => "/chat"})
    assert redirected_to(rejected) == "/chat"
  end

  test "authorization rejects missing context, expiry, token rotation and unavailable token", ctx do
    assert BrowserAuth.authorized?(ctx.authorization)
    refute BrowserAuth.authorized?(%{})
    refute BrowserAuth.authorized?(%{ctx.authorization | host: "evil.example"})
    refute BrowserAuth.authorized?(%{ctx.authorization | peer_ip: {192, 0, 2, 10}})
    refute BrowserAuth.authorized?(%{ctx.authorization | marker: nil})
    refute BrowserAuth.authorized?(%{ctx.authorization | marker: %{ctx.marker | "issued_at" => System.system_time(:second) - 28_800}})
    refute BrowserAuth.authorized?(%{ctx.authorization | marker: %{ctx.marker | "issued_at" => System.system_time(:second) + 60}})
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("r", 40))
    refute BrowserAuth.authorized?(ctx.authorization)
    System.delete_env("SYMPHONY_CONTROL_TOKEN")
    refute BrowserAuth.authorized?(ctx.authorization)
  end

  test "a queued browser command rechecks authentication inside the native owner", ctx do
    :sys.suspend(ctx.pid)
    command = Task.async(fn -> BoardActions.command("resume", nil, 0, "queued-auth", ctx.authorization, ctx.pid) end)
    Process.sleep(20)
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("changed", 8))
    :sys.resume(ctx.pid)
    assert {:error, :unauthorized} = Task.await(command)
    assert %{"mode" => "paused", "revision" => 0} = Orchestrator.control_snapshot(ctx.pid)
  end

  test "both HTTP and socket mount derive authorization from verified connection information", ctx do
    session = %{BrowserAuth.session_key() => ctx.marker}
    conn = local_conn()
    socket = %Phoenix.LiveView.Socket{private: %{connect_info: conn}}
    assert BrowserAuth.authorized?(BrowserAuth.context(session, socket))

    connect_info = %{uri: %URI{host: "localhost"}, peer_data: %{address: {127, 0, 0, 1}}}
    connected = %Phoenix.LiveView.Socket{private: %{connect_info: connect_info}}
    assert BrowserAuth.authorized?(BrowserAuth.context(session, connected))
    missing = %Phoenix.LiveView.Socket{private: %{connect_info: %{}}}
    refute BrowserAuth.authorized?(BrowserAuth.context(session, missing))
  end

  test "routed login and logout require CSRF", ctx do
    for path <- ["/operator/session", "/operator/session/logout"] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        post(local_conn(), path, %{"operator_token" => ctx.token})
      end
    end
  end

  test "login stores a purpose-bound proof and logout removes it and disconnects live sessions", ctx do
    {conn, csrf} = browser_page()
    logged_in = post(browser_recycle(conn), "/operator/session", %{"_csrf_token" => csrf, "operator_token" => ctx.token})
    assert redirected_to(logged_in) == "/?panel=settings"
    marker = Plug.Conn.get_session(logged_in, BrowserAuth.session_key())
    assert %{"fingerprint" => _, "issued_at" => _} = marker
    refute inspect(Plug.Conn.get_session(logged_in)) =~ ctx.token
    refute logged_in.resp_body =~ ctx.token
    refute inspect(logged_in.resp_cookies) =~ ctx.token
    assert logged_in.resp_cookies["_symphony_elixir_key"].http_only
    assert logged_in.resp_cookies["_symphony_elixir_key"].same_site == "Strict"
    socket_id = Plug.Conn.get_session(logged_in, "live_socket_id")
    :ok = Endpoint.subscribe(socket_id)

    logged_out = post(browser_recycle(logged_in), "/operator/session/logout", %{"_csrf_token" => csrf})
    assert redirected_to(logged_out) == "/?panel=settings"
    assert Plug.Conn.get_session(logged_out, BrowserAuth.session_key()) == nil
    assert_receive %Phoenix.Socket.Broadcast{topic: ^socket_id, event: "disconnect"}
  end

  test "failed login never echoes or logs submitted token and leaves controls locked" do
    {conn, csrf} = browser_page()
    supplied = "incorrect-private-token-value"

    output =
      capture_log(fn ->
        response = post(browser_recycle(conn), "/operator/session", %{"_csrf_token" => csrf, "operator_token" => supplied})
        assert redirected_to(response) == "/?panel=settings"
        assert Plug.Conn.get_session(response, BrowserAuth.session_key()) == nil
        refute response.resp_body =~ supplied
        refute inspect(Plug.Conn.get_session(response)) =~ supplied
      end)

    refute output =~ supplied
    assert Phoenix.Logger.filter_values(%{"operator_token" => supplied}) == %{"operator_token" => "[FILTERED]"}
  end

  test "routed login rejects cross-origin and non-loopback peer despite valid CSRF", ctx do
    {conn, csrf} = browser_page()
    params = %{"_csrf_token" => csrf, "operator_token" => ctx.token}
    remote_origin = browser_recycle(conn) |> Plug.Conn.put_req_header("origin", "https://evil.example")
    assert response(post(remote_origin, "/operator/session", params), 403) =~ "loopback"
    remote_peer = browser_recycle(conn) |> Plug.Test.put_peer_data(%{address: {192, 0, 2, 10}, port: 55, ssl_cert: nil})
    assert response(post(remote_peer, "/operator/session", params), 403) =~ "loopback"
  end

  test "rejected logout cannot clear or disconnect a valid browser session", ctx do
    {conn, csrf} = browser_page()
    logged_in = post(browser_recycle(conn), "/operator/session", %{"_csrf_token" => csrf, "operator_token" => ctx.token})
    marker = Plug.Conn.get_session(logged_in, BrowserAuth.session_key())
    socket_id = Plug.Conn.get_session(logged_in, "live_socket_id")
    :ok = Endpoint.subscribe(socket_id)
    remote_origin = browser_recycle(logged_in) |> Plug.Conn.put_req_header("origin", "https://evil.example")
    peer = %{address: {192, 0, 2, 10}, port: 55, ssl_cert: nil}
    remote_peer = browser_recycle(logged_in) |> Plug.Test.put_peer_data(peer)

    for request <- [remote_origin, remote_peer] do
      rejected = post(request, "/operator/session/logout", %{"_csrf_token" => csrf})
      assert response(rejected, 403) =~ "loopback"
      assert Plug.Conn.get_session(rejected, BrowserAuth.session_key()) == marker
      assert Plug.Conn.get_session(rejected, "live_socket_id") == socket_id
    end

    refute_receive %Phoenix.Socket.Broadcast{topic: ^socket_id, event: "disconnect"}
  end

  test "unconfigured controls reject browser login without retaining the submitted credential", ctx do
    {conn, csrf} = browser_page()
    System.delete_env("SYMPHONY_CONTROL_TOKEN")
    rejected = post(browser_recycle(conn), "/operator/session", %{"_csrf_token" => csrf, "operator_token" => ctx.token})
    assert redirected_to(rejected) == "/?panel=settings"
    assert Plug.Conn.get_session(rejected, BrowserAuth.session_key()) == nil
    assert Phoenix.Flash.get(rejected.assigns.flash, :error) == "Operator controls are not configured."
    refute inspect(Plug.Conn.get_session(rejected)) =~ ctx.token
    refute rejected.resp_body =~ ctx.token
  end

  test "websocket transport rejects foreign origin and accepts exact scheme host and port" do
    conn = local_conn() |> Plug.Conn.put_req_header("origin", "https://evil.example")
    rejected = Transport.check_origin(conn, Phoenix.LiveView.Socket, Endpoint, check_origin: :conn)
    assert rejected.halted
    assert rejected.status == 403
    good = local_conn() |> Plug.Conn.put_req_header("origin", "http://localhost")
    refute Transport.check_origin(good, Phoenix.LiveView.Socket, Endpoint, check_origin: :conn).halted
    assert {"/live", Phoenix.LiveView.Socket, opts} = List.keyfind(Endpoint.__sockets__(), "/live", 0)
    assert opts[:websocket][:check_origin] == :conn
  end

  test "browser commands use native owner revision, replay and issue holds", ctx do
    assert {:ok, %{"revision" => 1, "replayed" => false}} = BoardActions.command("drain", nil, 0, "one", ctx.authorization, ctx.pid)
    assert {:ok, %{"revision" => 1, "replayed" => true}} = BoardActions.command("drain", nil, 0, "one", ctx.authorization, ctx.pid)
    assert {:error, :command_id_conflict} = BoardActions.command("pause", nil, 0, "one", ctx.authorization, ctx.pid)
    assert {:error, :revision_conflict} = BoardActions.command("pause", nil, 0, "two", ctx.authorization, ctx.pid)
    assert {:ok, %{"revision" => 2}} = BoardActions.command("cancel", "7", 1, "three", ctx.authorization, ctx.pid)
    assert %{"issues" => %{"7" => %{"hold" => "cancelled"}}} = Orchestrator.control_snapshot(ctx.pid)
    assert {:ok, %{"revision" => 3}} = BoardActions.command("retry", "7", 2, "four", ctx.authorization, ctx.pid)
    assert %{"issues" => %{"7" => %{"hold" => nil}}} = Orchestrator.control_snapshot(ctx.pid)
  end

  test "unauthorized, expired and unsupported browser actions cannot reach mutation", ctx do
    assert {:error, :unauthorized} = BoardActions.command("resume", nil, 0, "default-owner", %{})
    assert {:error, :unauthorized} = BoardActions.command("resume", nil, 0, "one", %{}, ctx.pid)
    assert {:error, :invalid_command} = BoardActions.command("deploy", nil, 0, "one", ctx.authorization, ctx.pid)
    assert {:error, :invalid_command} = BoardActions.command("cancel", nil, 0, "one", ctx.authorization, ctx.pid)
    assert {:error, :invalid_command} = BoardActions.command("pause", "7", 0, "one", ctx.authorization, ctx.pid)
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("n", 40))
    assert {:error, :unauthorized} = BoardActions.command("resume", nil, 0, "one", ctx.authorization, ctx.pid)
    assert %{"revision" => 0, "mode" => "paused"} = Orchestrator.control_snapshot(ctx.pid)
  end

  test "unavailable owner is an explicit error with no browser fallback", ctx do
    GenServer.stop(ctx.pid, :normal)
    assert {:error, :unavailable} = BoardActions.command("pause", nil, 0, "one", ctx.authorization, ctx.pid)
  end

  test "browser command refreshes changed control configuration and fails closed", ctx do
    config = put_in(ctx.config, [:control, :max_attempts], 3)
    File.write!(ctx.workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    WorkflowStore.force_reload()
    assert {:error, :control_unavailable} = BoardActions.command("resume", nil, 0, "one", ctx.authorization, ctx.pid)
    assert %{"revision" => 0, "mode" => "paused", "fault" => fault} = Orchestrator.control_snapshot(ctx.pid)
    assert is_binary(fault)
  end

  test "retained task scope cannot send an issue command into a different tracker configuration", ctx do
    command = %{"action" => "cancel", "issue_id" => "7", "expected_revision" => 0, "command_id" => "one"}
    config = put_in(ctx.config, [:tracker, :project_slug], "different-project")
    File.write!(ctx.workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    WorkflowStore.force_reload()

    refute BrowserAuth.authorized?(ctx.authorization)
    assert {:error, :unauthorized} = BoardActions.command("cancel", "7", 0, "one", ctx.authorization, ctx.pid)

    assert {:error, :tracker_changed} =
             Orchestrator.control_command_guarded(command, ctx.authorization.tracker_fingerprint, ctx.pid)

    assert %{"revision" => 0, "issues" => %{}} = Orchestrator.control_snapshot(ctx.pid)
    assert {:ok, %{"revision" => 1}} = Orchestrator.control_command_guarded(command, Orchestrator.tracker_fingerprint(), ctx.pid)
  end

  test "upstream mode has no browser mutation path", ctx do
    config = put_in(ctx.config, [:control, :enabled], false)
    File.write!(ctx.workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    WorkflowStore.force_reload()
    supervisor = start_supervised!({Task.Supervisor, []}, id: :upstream_tasks)
    name = Module.concat(__MODULE__, "Upstream#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor}, id: :upstream_owner)
    assert {:error, :control_disabled} = BoardActions.command("pause", nil, 0, "one", ctx.authorization, pid)
    assert %{"enabled" => false} = Orchestrator.control_snapshot(pid)
  end

  defp local_conn, do: %{build_conn() | host: "localhost"} |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)

  defp browser_recycle(conn), do: recycle(conn) |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)

  defp browser_page do
    conn = get(local_conn(), "/")
    [_, token] = Regex.run(~r/<meta[^>]+name="csrf-token"[^>]+content="([^"]+)"/, conn.resp_body)
    {conn, token}
  end
end
