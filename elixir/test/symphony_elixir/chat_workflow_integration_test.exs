defmodule SymphonyElixir.ChatWorkflowIntegrationTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixir.Chat.{Store, Tools}
  alias SymphonyElixirWeb.{BrowserAuth, Endpoint, TaskBoard}
  @endpoint Endpoint
  @project "github:example/integration"

  # Only routes the optional server argument to this test's isolated real Store.
  # Conversation state, tool dispatch, persistence, previews and receipts are real.
  defmodule StoreClient do
    @operations [
      projects: 1,
      list: 2,
      create: 3,
      ensure_conversation: 3,
      remove_queued: 4,
      prioritize_queued: 4,
      resume_queue: 3,
      get: 3,
      rename: 4,
      archive: 3,
      pin: 4,
      move: 5,
      send_message: 5,
      send_message_with_context: 6,
      stop: 3,
      decide: 5
    ]
    for {operation, arity} <- @operations do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(operation)(unquote_splicing(args)) do
        server = Application.fetch_env!(:symphony_elixir, :chat_integration_store)
        apply(SymphonyElixir.Chat.Store, unquote(operation), [unquote_splicing(args)] ++ [server])
      end
    end
  end

  defmodule PanelHost do
    use Phoenix.LiveView
    alias SymphonyElixirWeb.{BrowserAuth, ChatPanel}

    def mount(_params, session, socket) do
      socket =
        assign(socket,
          auth: BrowserAuth.context(session, socket),
          project_id: session["project"],
          chat_id: nil,
          task_id: session["task_id"],
          task_title: session["task_title"],
          view_context: session["context"]
        )

      {:ok, socket}
    end

    def handle_info({:chat_updated, id}, socket) do
      send_update(ChatPanel, id: "management-chat", refresh_chat: id)
      {:noreply, socket}
    end

    def handle_info({:select_task, id, title}, socket), do: {:noreply, assign(socket, task_id: id, task_title: title)}
    def handle_info({:chat_panel, :main}, socket), do: {:noreply, assign(socket, task_id: nil, task_title: nil)}

    def handle_info({:view_context, context}, socket), do: {:noreply, assign(socket, :view_context, context)}

    def handle_info({:chat_list_updated, project}, socket) do
      send_update(ChatPanel, id: "management-chat", refresh_threads: project)
      {:noreply, socket}
    end

    def handle_info({:chat_panel, :project_subscription, _project}, socket), do: {:noreply, socket}

    def handle_info({:chat_panel, :navigate, location}, socket), do: {:noreply, assign(socket, Map.to_list(location))}

    def render(assigns) do
      ~H"""
      <.live_component module={ChatPanel} id="management-chat" auth={@auth} csrf_token="fixture-only"
        embedded={true} project_id={@project_id} chat_id={@chat_id} task_id={@task_id} task_title={@task_title} view_context={@view_context} read_only={false} />
      """
    end
  end

  defmodule Board do
    def load(_owner, _timeout), do: Agent.get(Application.fetch_env!(:symphony_elixir, :chat_integration_board), & &1)
  end

  defmodule Owner do
    def tracker_action_guarded(fingerprint, revision, issue_id, callback, _owner) do
      observer = Application.fetch_env!(:symphony_elixir, :chat_integration_test)
      send(observer, {:owner_guard, fingerprint, revision, issue_id})
      callback.()
    end
  end

  defmodule ModelRuntime do
    def run(opts, emit, tool) do
      send(opts.test_pid, {:model_started, self(), opts.thread_id, opts.text})
      emit.({:thread, opts.thread_id || "native-integration-thread"})
      emit.({:delta, "Reading this project. "})
      run_request(opts.text, opts, emit, tool)
    end

    defp run_request("Use this view", opts, emit, tool) do
      send(opts.test_pid, {:view_seen, opts.view_context, tool.("symphony_view_context", %{})})
      emit.({:delta, "View reviewed."})
      {:ok, %{status: :completed}}
    end

    defp run_request("Review work", opts, emit, tool) do
      read = tool.("symphony_project_status", %{})
      search = tool.("symphony_search_tasks", %{"q" => "retry", "status" => "attention", "priority" => "P2", "sort" => "priority"})
      details = tool.("symphony_task_details", %{"task_id" => "GH-2"})
      send(opts.test_pid, {:real_tool_results, [read, search, details]})
      emit.({:delta, "The retry task needs attention."})
      {:ok, %{status: :completed}}
    end

    defp run_request("Create a task", opts, emit, tool) do
      propose(opts, emit, tool, %{"action" => "create_task", "title" => "Clarify retry behavior", "body" => "Depends on: none\nVerify retry behavior."})
    end

    defp run_request("Queue task", opts, emit, tool), do: propose(opts, emit, tool, %{"action" => "queue_task", "task_id" => "GH-2"})
    defp run_request("Give feedback", opts, emit, tool), do: propose(opts, emit, tool, %{"action" => "feedback", "task_id" => "GH-2", "body" => "Please include the cancellation case."})

    defp run_request("Wait for thread status", opts, _emit, _tool) do
      send(opts.test_pid, {:waiting_for_thread_status, self()})

      receive do
        :finish_status -> {:ok, %{status: :completed}}
        :interrupt -> {:ok, %{status: :interrupted}}
      end
    end

    defp run_request("Wait for logout", opts, emit, tool) do
      send(opts.test_pid, {:awaiting_logout, self()})

      receive do
        :after_logout ->
          send(opts.test_pid, {:post_logout_tool, tool.("symphony_project_status", %{})})
          emit.({:delta, "AFTER_LOGOUT_MARKER"})
          {:ok, %{status: :completed}}

        :interrupt ->
          {:ok, %{status: :interrupted}}
      end
    end

    defp run_request("Fail this response", _opts, _emit, _tool), do: {:error, :model_unavailable}

    defp run_request(_text, _opts, emit, _tool) do
      emit.({:delta, "Conversation resumed."})
      {:ok, %{status: :completed}}
    end

    defp propose(opts, emit, tool, args) do
      result = tool.("symphony_propose_action", args)
      send(opts.test_pid, {:real_proposal, result})
      emit.({:delta, "Review the proposed action below."})
      {:ok, %{status: :completed}}
    end
  end

  setup do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.join(Path.dirname(Workflow.workflow_file_path()), "chat-integration"))

    config = %{
      tracker: %{
        kind: "github",
        provider: %{repo: "example/integration", token: "fixture-only"},
        required_labels: ["ready"],
        active_states: ["open"],
        terminal_states: ["closed"]
      },
      control: %{enabled: true, state_path: Path.join(root, "control.json"), initial_mode: "paused"},
      observability: %{dashboard_enabled: false}
    }

    configure(config)
    previous_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    token = String.duplicate("integration-only", 3)
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)

    keys = [
      :chat_board_module,
      :chat_tracker_owner,
      :chat_github_request,
      :chat_integration_store,
      :chat_integration_board,
      :chat_integration_test,
      Endpoint
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    board_agent = start_supervised!({Agent, fn -> board() end}, id: :board)
    Application.put_env(:symphony_elixir, :chat_board_module, Board)
    Application.put_env(:symphony_elixir, :chat_integration_board, board_agent)
    Application.put_env(:symphony_elixir, :chat_tracker_owner, Owner)
    Application.put_env(:symphony_elixir, :chat_integration_test, self())
    request_log = start_supervised!({Agent, fn -> [] end}, id: :requests)
    test_pid = self()

    Application.put_env(:symphony_elixir, :chat_github_request, fn method, path, params, body, _settings ->
      Agent.update(request_log, &(&1 ++ [{method, path, params, body}]))
      send(test_pid, {:github_request, method, path, body})
      github_response(method, path, body)
    end)

    settings = %{
      enabled: true,
      state_path: root <> "/state",
      codex_home: root <> "/runtime",
      executable: "/fixture/codex",
      timeout_ms: 3_000,
      max_concurrent: 2,
      test_pid: self()
    }

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    opts = [name: name, settings: settings, runtime: ModelRuntime, tools: Tools, orchestrator: :integration_owner]
    server = start_supervised!({Store, opts})
    Application.put_env(:symphony_elixir, :chat_integration_store, server)
    endpoint = Keyword.merge(previous[Endpoint] || [], server: false, secret_key_base: String.duplicate("i", 64), chat_store: StoreClient)
    Application.put_env(:symphony_elixir, Endpoint, endpoint)
    start_supervised!({Endpoint, []})
    {:ok, marker} = BrowserAuth.authenticate(local_conn(), token)
    auth = %{marker: marker, host: "localhost", peer_ip: {127, 0, 0, 1}, tracker_fingerprint: Orchestrator.tracker_fingerprint()}

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)

      restore_env("SYMPHONY_CONTROL_TOKEN", previous_token)
    end)

    %{server: server, opts: opts, marker: marker, auth: auth, requests: request_log, config: config, board: board_agent}
  end

  test "chat list pins and ordering update another browser and survive store restart", ctx do
    {:ok, first} = Store.create(@project, "First conversation", ctx.auth, ctx.server)
    {:ok, second} = Store.create(@project, "Second conversation", ctx.auth, ctx.server)
    {:ok, third} = Store.create(@project, "Third conversation", ctx.auth, ctx.server)
    {view, _} = chat_view(ctx, first["id"])
    {other, _} = chat_view(ctx)
    render_change(view, "draft", %{"message" => "Keep this draft while organizing"})
    render_click(view, "back-to-chats")
    render_click(view, "pin-thread", %{"id" => first["id"], "pinned" => "true"})
    pinned = "[data-pin-group=true] [data-thread-id='#{first["id"]}']"
    assert eventually(fn -> has_element?(other, pinned) end)
    render_hook(view, "move-thread", %{"id" => second["id"], "before_id" => third["id"], "pinned" => false, "project_id" => @project})
    reordered = "[data-pin-group=false] [data-thread-id='#{second["id"]}'] + [data-thread-id='#{third["id"]}']"
    assert eventually(fn -> has_element?(other, reordered) end)
    render_hook(view, "move-thread", %{"id" => first["id"], "before_id" => nil, "pinned" => false, "project_id" => @project})
    assert render(view) =~ "moved between pinned and unpinned"
    assert has_element?(view, "#chat-message-input", "Keep this draft while organizing")
    assert {:ok, before} = Store.get(@project, first["id"], ctx.auth, ctx.server)
    stop_supervised!(Store)
    server = start_supervised!({Store, ctx.opts})
    Application.put_env(:symphony_elixir, :chat_integration_store, server)
    assert {:ok, restored} = Store.get(@project, first["id"], ctx.auth, server)
    assert restored == before
    {reopened, _} = chat_view(ctx)
    assert has_element?(reopened, pinned)
    assert has_element?(reopened, reordered)
    render_click(view, "retry-chat-list")
    render_click(view, "open-chat", %{"id" => first["id"]})
    assert has_element?(view, "#chat-conversation-detail:not([hidden])")
    assert has_element?(view, "#chat-message-input", "Keep this draft while organizing")
    assert Agent.get(ctx.requests, & &1) == []
  end

  test "thread lists follow background conversation activity without changing the selected draft", ctx do
    assert {:ok, selected} = Store.create(@project, "Selected conversation", ctx.auth, ctx.server)
    assert {:ok, background} = Store.create(@project, "Background conversation", ctx.auth, ctx.server)
    {view, _} = chat_view(ctx, selected["id"])
    render_change(view, "draft", %{"message" => "Keep this unsent draft"})
    render_click(view, "back-to-chats")
    {index, _} = chat_view(ctx)
    selector = "#chat-thread-list [data-thread-id='#{background["id"]}'] .thread-status"
    assert has_element?(index, "#chat-thread-list:not([hidden])")

    assert {:ok, _} = Store.send_message(@project, background["id"], "Wait for thread status", "thread-status", ctx.auth, ctx.server)
    assert_receive {:waiting_for_thread_status, runtime}
    assert eventually(fn -> has_element?(view, selector, "Running") end)
    assert eventually(fn -> has_element?(index, selector, "Running") end)
    assert has_element?(view, "#chat-message-input", "Keep this unsent draft")

    send(runtime, :finish_status)
    assert eventually(fn -> has_element?(view, selector, "Idle") end)
    assert eventually(fn -> has_element?(index, selector, "Idle") end)
    assert has_element?(view, "#chat-message-input", "Keep this unsent draft")
    render_click(view, "open-chat", %{"id" => selected["id"]})
    assert has_element?(view, "#session-chat-content:not([hidden])")
    assert has_element?(view, "#chat-message-input", "Keep this unsent draft")
    assert Agent.get(ctx.requests, & &1) == []
  end

  test "output tabs retain issue and PR evidence, metrics and safe links across reconnect", ctx do
    pr = %{
      number: 9,
      title: "Handle interrupted retries",
      url: "https://github.com/example/integration/pull/9",
      state: "merged",
      review: "approved",
      checks: "success",
      check_total: 3,
      draft: false,
      additions: 12,
      deletions: 4,
      changed_files: 2
    }

    Agent.update(ctx.board, fn board -> %{board | tasks: Enum.map(board.tasks, &Map.put(&1, :pull_requests, [pr]))} end)
    {view, _} = chat_view(ctx)
    render_submit(view, "send-message", %{"message" => "Review work"})
    chat = wait_chat(ctx, &(&1["status"] == "idle"))
    render_click(view, "session-tab", %{"tab" => "outputs"})
    assert has_element?(view, "#session-outputs-content:not([hidden]) .chat-artifact[data-artifact-kind=issue]", "Clarify retry behavior")
    assert has_element?(view, ".chat-artifact[data-artifact-kind=pull_request] a[href='https://github.com/example/integration/pull/9']", "Handle interrupted retries")
    assert has_element?(view, ".chat-artifact[data-artifact-kind=pull_request]", "merged")
    assert has_element?(view, ".chat-artifact[data-artifact-kind=pull_request] .artifact-metrics", "approved")
    assert has_element?(view, ".chat-artifact[data-artifact-kind=pull_request] .artifact-metrics", "success")
    render_click(view, "session-tab", %{"tab" => "sources"})
    assert has_element?(view, "#session-sources-content:not([hidden]) .context-reference")
    {reopened, _} = chat_view(ctx, chat["id"])
    render_click(reopened, "session-tab", %{"tab" => "outputs"})
    assert has_element?(reopened, ".chat-artifact[data-artifact-kind=pull_request]", "Handle interrupted retries")
    assert Agent.get(ctx.requests, & &1) == []
  end

  test "real management tools stream linked widgets through Store and retain native thread history", ctx do
    {view, _conn} = chat_view(ctx)
    render_submit(view, "send-message", %{"message" => "Review work"})
    refute has_element?(view, ".chat-notice"), render(view) |> Floki.parse_document!() |> Floki.find(".chat-notice") |> Floki.text()
    assert_receive {:model_started, _, nil, "Review work"}
    assert_receive {:real_tool_results, [status, search, details]}
    assert [%{"type" => "status"}] = status["widgets"]
    assert [%{"type" => "tasks", "tasks" => [%{"issue_id" => "2"}]}] = search["widgets"]
    assert [%{"type" => "task", "task" => %{"description" => "Depends on: none"}}] = details["widgets"]
    chat = wait_chat(ctx, &(&1["status"] == "idle"))
    html = render(view)
    assert html =~ "The retry task needs attention."
    assert has_element?(view, ".chat-widget-status", "Execution: paused")
    assert has_element?(view, ".chat-widget-tasks a[href='/?priority=P2&project=github%3Aexample%2Fintegration&q=retry&sort=priority&status=attention']")

    assert has_element?(
             view,
             ".chat-widget-tasks .widget-task a[href='/?priority=P2&project=github%3Aexample%2Fintegration&q=retry&sort=priority&status=attention&task=github%3Aexample%2Fintegration%3A2']"
           )

    render_click(view, "session-tab", %{"tab" => "outputs"})
    refute has_element?(view, "#session-outputs-content", "No outputs yet.")
    assert Agent.get(ctx.requests, & &1) == []

    stop_supervised!(Store)
    server = start_supervised!({Store, ctx.opts})
    Application.put_env(:symphony_elixir, :chat_integration_store, server)
    assert {:ok, restored} = Store.get(@project, chat["id"], ctx.auth, server)
    assert restored["messages"] == chat["messages"]
    {resumed, _} = chat_view(ctx, chat["id"])
    assert render(resumed) =~ "The retry task needs attention."
    render_submit(resumed, "send-message", %{"message" => "Continue"})
    assert_receive {:model_started, _, "native-integration-thread", "Continue"}
  end

  test "create previews get durable IDs, execute only after confirmation and show real receipts", ctx do
    {view, _} = chat_view(ctx)
    render_submit(view, "send-message", %{"message" => "Create a task"})
    chat = wait_chat(ctx, &(&1["status"] == "idle"))
    assert_received {:real_proposal, %{"proposal" => proposal}}
    assert proposal["id"] == hd(chat["proposals"])["id"]
    assert String.match?(proposal["id"], ~r/^[a-f0-9]{32}$/)
    assert has_element?(view, ".chat-widget-proposal", "Clarify retry behavior")
    assert has_element?(view, ".chat-widget-proposal", "Verify retry behavior.")
    assert Agent.get(ctx.requests, & &1) == []
    render_click(view, "decide", %{"id" => proposal["id"], "decision" => "confirm"})
    assert_receive {:github_request, "POST", "/repos/example/integration/issues", body}
    assert body["labels"] == []
    assert body["body"] =~ "<!-- symphony-chat:#{proposal["id"]} -->"
    complete = wait_chat(ctx, &(hd(&1["proposals"])["status"] == "completed"))
    assert has_element?(view, ".chat-widget-receipt", "execution was not queued")
    assert List.last(complete["messages"])["widgets"] |> hd() |> Map.fetch!("type") == "receipt"
    render_click(view, "decide", %{"id" => proposal["id"], "decision" => "confirm"})
    refute_receive {:github_request, "POST", _, _}
  end

  test "queue preview retains routing labels and confirmation reaches the owner guard once", ctx do
    {view, _} = chat_view(ctx)
    render_submit(view, "send-message", %{"message" => "Queue task"})
    wait_chat(ctx, &(&1["status"] == "idle"))
    assert_received {:real_proposal, %{"proposal" => proposal}}
    assert proposal["queue_labels"] == ["ready"]
    assert has_element?(view, ".chat-widget-proposal", "ready")
    assert Agent.get(ctx.requests, & &1) == []
    render_click(view, "decide", %{"id" => proposal["id"], "decision" => "confirm"})
    assert_receive {:owner_guard, fingerprint, 3, "2"}
    assert fingerprint == ctx.auth.tracker_fingerprint
    assert_receive {:github_request, "PATCH", "/repos/example/integration/issues/2", body}
    assert body["labels"] == ["publish-approved", "ready"]
    wait_chat(ctx, &(hd(&1["proposals"])["status"] == "completed"))
    assert has_element?(view, ".chat-widget-receipt", "cancelled")
    render_click(view, "decide", %{"id" => proposal["id"], "decision" => "confirm"})
    refute_receive {:owner_guard, _, _, _}
  end

  test "board forms use the real durable tracker path without running a model", ctx do
    args = %{"action" => "create_task", "title" => "Create from the board", "body" => "## Outcome\nNative intake\n\nDepends on: none"}
    id = String.duplicate("a", 32)
    assert {:ok, preview} = Store.prepare_action(@project, id, args, ctx.auth, ctx.server)
    assert {:ok, ^preview} = Store.prepare_action(@project, id, args, ctx.auth, ctx.server)
    assert Agent.get(ctx.requests, & &1) == []
    assert {:ok, _} = Store.decide_action_record(@project, id, "confirm", ctx.auth, ctx.server)

    assert eventually(fn ->
             {:ok, record} = Store.get_action(@project, id, ctx.auth, ctx.server)
             hd(record["proposals"])["status"] == "completed"
           end)

    assert {:ok, _} = Store.decide_action_record(@project, id, "confirm", ctx.auth, ctx.server)
    posts = Agent.get(ctx.requests, &Enum.filter(&1, fn {method, _, _, _} -> method == "POST" end))
    assert [{"POST", "/repos/example/integration/issues", _, body}] = posts
    assert body["labels"] == []
    assert body["body"] =~ "Depends on: none"
    assert {:ok, []} = Store.list(@project, ctx.auth, ctx.server)
    refute_receive {:model_started, _, _, _}
  end

  test "Google operator revocation rejects a previously previewed board task", ctx do
    google = %{
      provider: "google",
      public_origin: "http://localhost",
      client_id: "fixture.apps.googleusercontent.com",
      client_secret: "$SYMPHONY_CONTROL_TOKEN",
      allowed_emails: ["owner@gmail.com"]
    }

    configure(Map.put(ctx.config, :browser_auth, google))
    {:ok, identity_config} = SymphonyElixirWeb.BrowserIdentity.settings()
    identity = %{"iss" => "https://accounts.google.com", "sub" => "task-operator", "email" => "owner@gmail.com", "email_verified" => true}
    {:ok, grant} = SymphonyElixirWeb.BrowserSessions.issue(:session, %{identity: identity, fingerprint: identity_config.fingerprint, scope: Orchestrator.tracker_fingerprint()})
    auth = %{ctx.auth | marker: %{"provider" => "google", "id" => grant}} |> Map.merge(%{scheme: "http", port: 80})
    args = %{"action" => "create_task", "title" => "Reviewed task", "body" => "Depends on: none"}
    id = String.duplicate("c", 32)
    assert {:ok, _} = Store.prepare_action(@project, id, args, auth, ctx.server)
    assert :ok = SymphonyElixirWeb.BrowserSessions.revoke(grant)
    assert {:error, :unauthorized} = Store.decide_action_record(@project, id, "confirm", auth, ctx.server)
    assert Agent.get(ctx.requests, & &1) == []
  end

  test "foreign chat routing and tracker reconfiguration never reveal retained history", ctx do
    {view, _} = chat_view(ctx)
    render_submit(view, "send-message", %{"message" => "Review work"})
    chat = wait_chat(ctx, &(&1["status"] == "idle"))
    render_patch(view, "/chat?project=github%3Aother%2Frepo&chat=" <> chat["id"])
    refute render(view) =~ "The retry task needs attention."
    assert {:error, :project_not_found} = Store.get("github:other/repo", chat["id"], ctx.auth, ctx.server)
    configure(put_in(ctx.config, [:tracker, :provider, :repo], "other/repo"))
    refute BrowserAuth.authorized?(ctx.auth)
    render_patch(view, "/chat?project=github%3Aexample%2Fintegration&chat=" <> chat["id"])
    refute render(view) =~ "The retry task needs attention."
    assert render(view) =~ "Unlock chat"
  end

  test "logout broadcasts socket disconnection and the resulting browser cannot read streamed history", ctx do
    {view, conn} = chat_view(ctx)
    render_submit(view, "send-message", %{"message" => "Wait for logout"})
    assert_receive {:awaiting_logout, runtime}
    socket_id = Plug.Conn.get_session(conn, "live_socket_id")
    :ok = Endpoint.subscribe(socket_id)
    csrf = Plug.CSRFProtection.get_csrf_token()
    logged_out = post(conn, "/operator/session/logout", %{"_csrf_token" => csrf})
    assert redirected_to(logged_out) == "/?panel=settings"
    assert_receive %Phoenix.Socket.Broadcast{topic: ^socket_id, event: "disconnect"}
    send(runtime, :after_logout)
    {:ok, anonymous, html} = live(recycle(logged_out), "/chat?project=" <> URI.encode_www_form(@project))
    assert html =~ "Unlock chat"
    refute render(anonymous) =~ "AFTER_LOGOUT_MARKER"
    assert Agent.get(ctx.requests, & &1) == []
  end

  test "expired authorization clears messages and context on a streamed owner update", ctx do
    {view, _} = chat_view(ctx)
    render_submit(view, "send-message", %{"message" => "Review work"})
    chat = wait_chat(ctx, &(&1["status"] == "idle"))
    render_click(view, "session-tab", %{"tab" => "outputs"})
    assert has_element?(view, "#session-outputs-content")
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("new-integration-token", 3))
    Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "chat:" <> chat["id"], {:chat_updated, chat["id"]})
    assert eventually(fn -> render(view) =~ "Unlock chat" end)
    html = render(view)
    assert html =~ "Unlock chat"
    refute html =~ "The retry task needs attention."
    refute has_element?(view, "#session-outputs-content")
    refute has_element?(view, "#chat-messages")
    assert {:error, :unauthorized} = Store.get(@project, chat["id"], ctx.auth, ctx.server)
  end

  test "composer rejects over-limit messages before storing or starting a model turn", ctx do
    {view, _} = chat_view(ctx)
    assert has_element?(view, "#chat-message-input[maxlength='16000']")
    render_submit(view, "send-message", %{"message" => String.duplicate("x", 16_001)})
    assert render(view) =~ "16,000 bytes"
    assert {:ok, []} = Store.list(@project, ctx.auth, ctx.server)
    refute_receive {:model_started, _, _, _}
  end

  test "automatic board context reaches real Store and tools without reusing a prior view", ctx do
    snapshot = %{
      "version" => 1,
      "project_id" => @project,
      "filters" => %{"project" => [@project], "status" => ["ready"], "priority" => [], "q" => "retry", "sort" => "priority"},
      "selected_task_id" => @project <> ":2",
      "visible_task_ids" => [@project <> ":2"],
      "viewport_task_ids" => [@project <> ":2"],
      "hidden_columns" => [],
      "captured_at" => "2026-09-15T12:00:00Z",
      "board_checked_at" => nil,
      "truncated" => false
    }

    session = %{BrowserAuth.session_key() => ctx.marker, "project" => @project, "context" => snapshot}
    {:ok, view, _html} = live_isolated(local_conn(), PanelHost, session: session)
    view = with_target(view, "#chat-app")
    view |> element("#chat-composer") |> render_submit(%{"message" => "Use this view"})
    expected = snapshot
    assert_receive {:view_seen, ^expected, %{"context_status" => "available", "snapshot" => ^expected, "current_tasks" => [%{"issue_id" => "2"}]}}
    chat = wait_chat(ctx, &(&1["status"] == "idle"))
    user = Enum.find(chat["messages"], &(&1["role"] == "user"))
    assert user["view_context"] == expected
    send(view.pid, {:view_context, nil})
    assert has_element?(view, "#session-context-content", "No matching board context")
    view |> element("#chat-composer") |> render_submit(%{"message" => "Use this view"})
    assert_receive {:view_seen, nil, %{"context_status" => "unavailable", "snapshot" => nil, "current_tasks" => []}}
    chat = wait_chat(ctx, &(&1["status"] == "idle" and length(&1["messages"]) == 4))
    assert chat["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Map.fetch!("view_context") == nil
    assert Agent.get(ctx.requests, & &1) == []
  end

  test "task chat queues through the real Store and completes followups while the main chat remains selected", ctx do
    task_id = @project <> ":2"
    session = %{BrowserAuth.session_key() => ctx.marker, "project" => @project, "task_id" => task_id, "task_title" => "Clarify retry behavior"}
    {:ok, view, _html} = live_isolated(local_conn(), PanelHost, session: session)
    view = with_target(view, "#chat-app")
    assert {:ok, task_chat} = Store.ensure_conversation(@project, task_id, ctx.auth, ctx.server)
    assert has_element?(view, "#chat-app[data-chat-id='#{task_chat["id"]}']")
    view |> element("#chat-composer") |> render_submit(%{"message" => "Wait for thread status"})
    assert_receive {:model_started, _, nil, "Wait for thread status"}
    assert_receive {:waiting_for_thread_status, runtime}
    assert eventually(fn -> has_element?(view, "#send-message-button", "Queue") end)
    view |> element("#chat-composer") |> render_submit(%{"message" => "Follow up on this task"})
    assert has_element?(view, "#chat-queue", "1 queued")
    assert has_element?(view, "#chat-queue", "Follow up on this task")
    refute has_element?(view, "#chat-messages", "Follow up on this task")
    assert {:ok, queued} = Store.get(@project, task_chat["id"], ctx.auth, ctx.server)
    assert queued["queued_count"] == 1
    refute_received {:model_started, _, _, "Follow up on this task"}
    view |> element("#main-chat-button") |> render_click()
    assert {:ok, main_chat} = Store.ensure_conversation(@project, nil, ctx.auth, ctx.server)
    assert has_element?(view, "#chat-app[data-chat-id='#{main_chat["id"]}']")
    refute has_element?(view, "#chat-queue")
    view |> element("#chat-composer") |> render_change(%{"message" => "Keep the orchestration draft"})
    send(runtime, :finish_status)
    assert_receive {:model_started, _, "native-integration-thread", "Follow up on this task"}

    assert eventually(fn ->
             {:ok, current} = Store.get(@project, task_chat["id"], ctx.auth, ctx.server)
             current["status"] == "idle" and current["queued_count"] == 0 and length(current["messages"]) == 4
           end)

    assert has_element?(view, "#chat-app[data-chat-id='#{main_chat["id"]}']")
    assert has_element?(view, "#chat-message-input", "Keep the orchestration draft")
    refute has_element?(view, "#chat-messages", "Follow up on this task")
    send(view.pid, {:select_task, task_id, "Clarify retry behavior"})
    assert has_element?(view, "#chat-app[data-chat-id='#{task_chat["id"]}']")
    assert has_element?(view, "#chat-messages", "Follow up on this task")
    assert has_element?(view, "#chat-messages", "Conversation resumed.")
    refute has_element?(view, "#chat-queue")
    assert {:ok, summaries} = Store.list(@project, ctx.auth, ctx.server)
    assert Enum.count(summaries, &(&1["task_id"] == task_id)) == 1
    assert Enum.count(summaries, &(&1["conversation_role"] == "main")) == 1
    assert Agent.get(ctx.requests, & &1) == []
  end

  test "stopped and failed assistant rows remain labelled after later responses complete", ctx do
    task_id = @project <> ":2"
    session = %{BrowserAuth.session_key() => ctx.marker, "project" => @project, "task_id" => task_id, "task_title" => "Clarify retry behavior"}
    {:ok, view, _html} = live_isolated(local_conn(), PanelHost, session: session)
    view = with_target(view, "#chat-app")
    assert {:ok, chat} = Store.ensure_conversation(@project, task_id, ctx.auth, ctx.server)
    view |> element("#chat-composer") |> render_submit(%{"message" => "Wait for thread status"})
    assert_receive {:waiting_for_thread_status, _runtime}
    assert {:ok, running} = Store.get(@project, chat["id"], ctx.auth, ctx.server)
    stopped_id = List.last(running["messages"])["id"]
    chat_id = chat["id"]
    assert_push_event(view, "chat-message-sent", %{chat_id: ^chat_id, accepted_text: "Wait for thread status"})
    view |> element("#chat-composer") |> render_submit(%{"message" => "Continue after stop"})
    view |> element("#stop-response-button") |> render_click()
    assert eventually(fn -> has_element?(view, "#resume-queue-button") end)
    assert has_element?(view, "#message-#{stopped_id} .message-outcome", "Stopped")
    view |> element("#resume-queue-button") |> render_click()
    assert_receive {:model_started, _, "native-integration-thread", "Continue after stop"}
    wait_chat(ctx, &(&1["status"] == "idle" and length(&1["messages"]) == 4))
    assert eventually(fn -> not has_element?(view, "#chat-queue") end)
    assert has_element?(view, "#message-#{stopped_id} .message-outcome", "Stopped")
    view |> element("#chat-composer") |> render_submit(%{"message" => "Fail this response"})
    failed = wait_chat(ctx, &(&1["status"] == "error"))
    failed_id = List.last(failed["messages"])["id"]
    assert eventually(fn -> has_element?(view, "#message-#{failed_id} .message-outcome", "Failed") end)
    view |> element("#chat-composer") |> render_submit(%{"message" => "Recover this response"})
    wait_chat(ctx, &(&1["status"] == "idle" and length(&1["messages"]) == 8))
    assert has_element?(view, "#message-#{failed_id} .message-outcome", "Failed")
    assert has_element?(view, "#message-#{stopped_id} .message-outcome", "Stopped")
    assert Agent.get(ctx.requests, & &1) == []
  end

  defp chat_view(ctx, id \\ nil) do
    session = %{BrowserAuth.session_key() => ctx.marker, "live_socket_id" => "operator:chat-integration-#{System.unique_integer([:positive])}"}
    conn = Plug.Test.init_test_session(local_conn(), session)
    params = if id, do: %{"project" => @project, "chat" => id}, else: %{"project" => @project}
    {:ok, view, _html} = live(conn, "/chat?" <> URI.encode_query(params))

    assert has_element?(view, "#chat-project option[value='github:example/integration']"),
           inspect({Store.projects(ctx.auth, ctx.server), render(view) |> Floki.parse_document!() |> Floki.find(".chat-notice") |> Floki.text()})

    {with_target(view, "#chat-app"), conn}
  end

  defp wait_chat(ctx, predicate, remaining \\ 100)
  defp wait_chat(_ctx, _predicate, 0), do: flunk("Conversation did not reach the expected state")

  defp wait_chat(ctx, predicate, remaining) do
    case Store.list(@project, ctx.auth, Application.fetch_env!(:symphony_elixir, :chat_integration_store)) do
      {:ok, [summary | _]} ->
        {:ok, chat} = Store.get(@project, summary["id"], ctx.auth, Application.fetch_env!(:symphony_elixir, :chat_integration_store))
        if predicate.(chat), do: chat, else: retry_chat(ctx, predicate, remaining)

      _ ->
        retry_chat(ctx, predicate, remaining)
    end
  end

  defp retry_chat(ctx, predicate, remaining) do
    receive do
      {:chat_updated, _} -> :ok
    after
      10 -> :ok
    end

    wait_chat(ctx, predicate, remaining - 1)
  end

  defp local_conn, do: %{build_conn() | host: "localhost"}

  defp eventually(predicate, attempts \\ 50) do
    cond do
      predicate.() ->
        true

      attempts == 0 ->
        false

      true ->
        receive do
        after
          5 -> :ok
        end

        eventually(predicate, attempts - 1)
    end
  end

  defp github_response("GET", path, _body) do
    if String.ends_with?(path, "/issues/2") do
      {:ok, %{status: 200, body: %{"number" => 2, "updated_at" => "2026-09-15T10:00:00Z", "body" => "Depends on: none", "labels" => ["publish-approved"]}}}
    else
      {:ok, %{status: 200, body: []}}
    end
  end

  defp github_response("POST", _path, body), do: {:ok, %{status: 201, body: Map.put(body, "number", 8)}}
  defp github_response("PATCH", _path, body), do: {:ok, %{status: 200, body: Map.put(body, "number", 2)}}

  defp board do
    issues =
      for {id, title, priority} <- [{"1", "Check source admission", 1}, {"2", "Clarify retry behavior", 2}],
          do: %Issue{
            id: id,
            identifier: "GH-#{id}",
            title: title,
            priority: priority,
            state: "open",
            description: "Depends on: none",
            dispatchable: true,
            native_ref: %{"repo" => "example/integration"},
            labels: [],
            updated_at: ~U[2026-09-15 10:00:00Z]
          }

    board = TaskBoard.project(issues, %{}, %{"enabled" => true, "revision" => 3, "mode" => "paused", "issues" => %{}}, Config.settings!())
    tasks = Enum.map(board.tasks, fn task -> if task.issue_id == "2", do: %{task | hold: "cancelled", attention: "Needs feedback"}, else: task end)
    %{board | tasks: tasks}
  end

  defp configure(config) do
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nFixture")
    assert :ok = WorkflowStore.force_reload()
  end
end
