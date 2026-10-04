defmodule SymphonyElixir.WorkspaceTransportTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixirWeb.{BrowserAuth, BrowserIdentity, BrowserSessions, Endpoint, StaticAssets}
  alias SymphonyElixirWeb.{WorkspacePath, WorkspaceSessions}

  defmodule Broker do
    def init(agent), do: agent

    def call(conn, agent) do
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))

      response =
        Agent.get_and_update(agent, fn {[reply | rest], commands} ->
          {reply, {rest, commands ++ [conn.body_params]}}
        end)

      Plug.Conn.send_resp(Plug.Conn.put_resp_content_type(conn, "application/json"), 200, Jason.encode!(response))
    end
  end

  setup do
    keys = ~w(SYMPHONY_WORKSPACE_PROJECT SYMPHONY_WORKSPACE_ORIGIN SYMPHONY_WORKSPACE_AUTH_SOCKET SYMPHONY_WORKSPACE_ENGINE_SOCKET SYMPHONY_WORKSPACE_SECRET TEST_WORKSPACE_GOOGLE_SECRET)
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
    :ok
  end

  test "paths preserve project scope and cannot confuse prefix boundaries" do
    System.delete_env("SYMPHONY_WORKSPACE_PROJECT")
    assert WorkspacePath.prefix() == ""
    assert WorkspacePath.path("/") == "/"
    assert WorkspacePath.relative("/") == "/"
    assert WorkspacePath.path("https://github.com/owner/repo") == "https://github.com/owner/repo"
    assert WorkspacePath.peer_ip(:unspec) == :unspec
    assert WorkspacePath.peer_ip({:local, "private"}) == {:local, "private"}
    refute WorkspacePath.enabled?()
    System.put_env("SYMPHONY_WORKSPACE_PROJECT", "../other")
    assert WorkspacePath.prefix() == ""
    enable_workspace("/private/broker.sock")
    assert WorkspacePath.path("/?task=one") == "/projects/symphony/?task=one"
    assert WorkspacePath.relative("/projects/symphony/?task=one") == "/?task=one"
    assert WorkspacePath.relative("/projects/symphony-other/") == "/projects/symphony-other/"
    assert WorkspacePath.path("/projects/events/") == "/projects/events/"
    assert WorkspacePath.peer_ip(:unspec) == {127, 0, 0, 1}
    assert WorkspacePath.peer_ip({:local, "private"}) == {127, 0, 0, 1}
    assert WorkspacePath.peer_ip({192, 0, 2, 1}) == {192, 0, 2, 1}
    assert StaticAssets.dashboard_css_url() =~ "/projects/symphony/dashboard.css"
    assert StaticAssets.dashboard_js_url() =~ "/projects/symphony/dashboard.js"
    assert StaticAssets.favicon_url() =~ "/projects/symphony/favicon.png"
    assert StaticAssets.browser_login_js_url() =~ "/projects/symphony/browser-login.js"
    assert StaticAssets.design_editor_js_url() =~ "/projects/symphony/design-editor/"
    assert StaticAssets.design_editor_css_url() =~ "/projects/symphony/design-editor/"
    assert StaticAssets.design_editor_asset_path() =~ "/projects/symphony/design-editor/"
    assert Endpoint.session_options()[:key] == "_symphony_workspace"
  end

  test "real private broker calls preserve values and fail closed for malformed replies or missing owner" do
    value = %{identity: %{"email" => "owner@gmail.com"}, fingerprint: <<0, 1, 2>>, scope: "selected-project"}
    packed = value |> :erlang.term_to_binary() |> Base.encode64()

    replies = [
      %{"id" => "grant"},
      %{"value" => packed},
      %{"id" => "grant"},
      %{"ok" => true},
      %{"error" => "expired"},
      %{"error" => "capacity"},
      %{},
      %{"value" => "bad"},
      %{"value" => Base.encode64(:erlang.term_to_binary(:not_a_map))}
    ]

    {path, agent} = broker(replies)
    enable_workspace(path)
    assert {:ok, "grant"} = BrowserSessions.issue(:flow, value)
    assert {:ok, ^value} = BrowserSessions.take_flow("grant")
    assert {:ok, "grant"} = BrowserSessions.complete_flow("grant", value)
    assert :ok = BrowserSessions.revoke("grant")
    assert {:error, :expired} = BrowserSessions.session("grant")
    assert {:error, :capacity} = WorkspaceSessions.call({:issue, :session, value})
    assert {:error, :unavailable} = WorkspaceSessions.call({:get, :session, "missing"})
    assert {:error, :unavailable} = WorkspaceSessions.call({:get, :session, "malformed"})
    assert {:error, :unavailable} = WorkspaceSessions.call({:get, :session, "not-map"})
    assert {:error, :unavailable} = WorkspaceSessions.call(:invalid)
    assert {[], commands} = Agent.get(agent, & &1)
    assert Enum.at(commands, 0)["value"] == packed
    stop_supervised!(:workspace_broker)
    assert {:error, :unavailable} = BrowserSessions.session("grant")
    System.delete_env("SYMPHONY_WORKSPACE_AUTH_SOCKET")
    assert {:error, :unavailable} = WorkspaceSessions.call({:get, :session, "grant"})
  end

  test "a shared identity grant crosses projects while tracker scope and origin fence requests" do
    auth = %{
      "provider" => "google",
      "public_origin" => "http://localhost:8779",
      "client_id" => "test.apps.googleusercontent.com",
      "client_secret" => "$TEST_WORKSPACE_GOOGLE_SECRET",
      "allowed_emails" => ["owner@gmail.com"]
    }

    File.write!(
      Workflow.workflow_file_path(),
      "---\n" <>
        Jason.encode!(%{
          tracker: %{kind: "memory", active_states: ["open"], terminal_states: ["closed"]},
          browser_auth: auth,
          polling: %{interval_ms: 60_000},
          observability: %{dashboard_enabled: false}
        }) <> "\n---\nTask"
    )

    :ok = WorkflowStore.force_reload()
    System.put_env("TEST_WORKSPACE_GOOGLE_SECRET", "fixture-secret")
    {socket_path, agent} = broker([])
    enable_workspace(socket_path)
    assert {:ok, settings} = BrowserIdentity.settings()
    assert settings.origin == "http://localhost:8778"
    identity = %{"iss" => "https://accounts.google.com", "sub" => "owner", "email" => "owner@gmail.com", "email_verified" => true}
    value = %{identity: identity, fingerprint: settings.fingerprint, scope: "other-project"}
    reply = %{"value" => value |> :erlang.term_to_binary() |> Base.encode64()}
    Agent.update(agent, fn _ -> {List.duplicate(reply, 4), []} end)

    context = %{
      marker: %{"provider" => "google", "id" => "shared"},
      host: "localhost",
      peer_ip: {127, 0, 0, 1},
      scheme: "http",
      port: 8778,
      tracker_fingerprint: Orchestrator.tracker_fingerprint()
    }

    workflow = Workflow.workflow_file_path()
    {:ok, current} = Workflow.load(workflow)
    links = [%{"id" => "github:owner/symphony", "label" => "Symphony", "url" => "http://localhost:8779"}]
    config = Map.put(current.config, "server", %{"project_links" => links})
    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    :ok = WorkflowStore.force_reload()
    assert [%{"url" => "http://localhost:8778/projects/symphony/"}] = SymphonyElixir.ProjectDirectory.links()
    assert BrowserAuth.authorized?(context)
    refute BrowserAuth.authorized?(%{context | tracker_fingerprint: "other-project"})
    refute BrowserAuth.authorized?(%{context | host: "evil.example"})
    refute BrowserAuth.authorized?(%{context | peer_ip: {192, 0, 2, 1}})
    System.put_env("SYMPHONY_WORKSPACE_PROJECT", "events")
    assert BrowserAuth.authorized?(context)
    stop_supervised!(:workspace_broker)
    refute BrowserAuth.authorized?(context)
  end

  test "engine listener is a private socket with explicit public paths and no TCP port" do
    socket_path = Path.join(System.tmp_dir!(), "engine-#{System.unique_integer([:positive])}.sock")
    System.put_env("SYMPHONY_WORKSPACE_PROJECT", "symphony")
    System.put_env("SYMPHONY_WORKSPACE_ORIGIN", "http://localhost:8778")
    System.put_env("SYMPHONY_WORKSPACE_AUTH_SOCKET", "/private/missing-broker.sock")
    System.put_env("SYMPHONY_WORKSPACE_ENGINE_SOCKET", socket_path)
    System.put_env("SYMPHONY_WORKSPACE_SECRET", String.duplicate("w", 64))
    previous = Application.get_env(:symphony_elixir, Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous)
      File.rm(socket_path)
    end)

    start_supervised!({HttpServer, port: 0, host: "127.0.0.1"})
    assert File.stat!(socket_path).mode |> Bitwise.band(0o777) == 0o600
    assert is_nil(HttpServer.bound_port())
    assert {:ok, %{status: 200, body: javascript}} = Req.get("http://localhost/dashboard.js", unix_socket: socket_path, headers: [{"host", "localhost:8778"}], retry: false)
    assert javascript =~ "SymphonyHooks"

    editor = StaticAssets.design_editor_js_url() |> WorkspacePath.relative()
    font = Enum.find(StaticAssets.design_editor_paths(), &String.ends_with?(&1, ".woff2"))

    for path <- [editor, font] do
      assert {:ok, _type, bytes} = StaticAssets.fetch(path)
      assert {:ok, %{status: 200, body: ^bytes}} = Req.get("http://localhost" <> path, unix_socket: socket_path, headers: [{"host", "localhost:8778"}], retry: false)
    end

    assert {:ok, %{status: 302, headers: headers}} = Req.get("http://localhost/login", unix_socket: socket_path, headers: [{"host", "localhost:8778"}], retry: false, redirect: false)
    assert headers["location"] == ["/projects/symphony/?panel=settings"]

    assert {:ok, %{status: 302, headers: scoped_headers}} =
             Req.get("http://localhost/projects/events/", unix_socket: socket_path, headers: [{"host", "localhost:8778"}], retry: false, redirect: false)

    assert scoped_headers["location"] == ["/projects/symphony/login"]
  end

  defp enable_workspace(path) do
    System.put_env("SYMPHONY_WORKSPACE_PROJECT", "symphony")
    System.put_env("SYMPHONY_WORKSPACE_ORIGIN", "http://localhost:8778")
    System.put_env("SYMPHONY_WORKSPACE_AUTH_SOCKET", path)
    System.put_env("SYMPHONY_WORKSPACE_ENGINE_SOCKET", "/private/engine.sock")
  end

  defp broker(replies) do
    path = Path.join(System.tmp_dir!(), "broker-#{System.unique_integer([:positive])}.sock")
    agent = start_supervised!({Agent, fn -> {replies, []} end})
    child = Supervisor.child_spec({Bandit, plug: {Broker, agent}, ip: {:local, path}, port: 0}, id: :workspace_broker)
    start_supervised!(child)
    on_exit(fn -> File.rm(path) end)
    {path, agent}
  end
end
