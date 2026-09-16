defmodule SymphonyElixir.ChatLiveTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.{BrowserAuth, Endpoint}
  @endpoint Endpoint

  # A real owner process and PubSub stream exercise UI state without model calls,
  # coding workers, GitHub writes, or the production conversation store.
  defmodule FixtureStore do
    import Phoenix.ConnTest, except: [get: 3]
    use GenServer
    def start_link(chats), do: GenServer.start_link(__MODULE__, chats, name: __MODULE__)
    def init(chats), do: {:ok, chats}

    def projects(_auth), do: {:ok, [%{"id" => "alpha", "label" => "Alpha project"}, %{"id" => "beta", "label" => "Beta project"}]}
    def list(project, _auth), do: {:ok, GenServer.call(__MODULE__, :all) |> Map.values() |> Enum.filter(&(&1["project_id"] == project))}

    def get(project, id, _auth) do
      case GenServer.call(__MODULE__, :all)[id] do
        %{"project_id" => ^project} = chat -> {:ok, chat}
        _ -> {:error, :project_mismatch}
      end
    end

    def create(project, title, _auth) do
      id = "new-#{System.unique_integer([:positive])}"
      chat = %{"id" => id, "title" => title, "project_id" => project, "messages" => [], "context" => [], "status" => "idle", "archived" => false, "updated_at" => "2026-09-15"}
      put(chat)
    end

    def rename(project, id, title, auth), do: update(project, id, auth, &Map.put(&1, "title", title))
    def archive(project, id, auth), do: update(project, id, auth, &Map.put(&1, "archived", true))
    def stop(project, id, auth), do: update(project, id, auth, &Map.put(&1, "status", "interrupted"))

    def decide(project, id, proposal, decision, auth) do
      update(project, id, auth, fn chat ->
        Map.update!(chat, "messages", &Enum.map(&1, fn message -> update_proposals(message, proposal, decision) end))
      end)
    end

    defp update_proposals(message, proposal, decision) do
      widgets = Enum.map(message["widgets"] || [], &decide_widget(&1, proposal, decision))
      Map.put(message, "widgets", widgets)
    end

    defp decide_widget(%{"id" => id} = widget, id, decision), do: Map.put(widget, "status", if(decision == "confirm", do: "confirmed", else: "cancelled"))
    defp decide_widget(widget, _id, _decision), do: widget

    def send_message_with_context(project, id, text, client_id, context, auth) do
      update(project, id, auth, fn chat ->
        user = %{"id" => client_id, "role" => "user", "text" => text, "widgets" => [], "view_context" => context}
        assistant = %{"id" => "response-" <> client_id, "role" => "assistant", "text" => "", "status" => "streaming", "widgets" => []}
        chat |> Map.put("status", "running") |> Map.update!("messages", &(&1 ++ [user, assistant]))
      end)
    end

    def update(project, id, auth, fun) do
      with {:ok, chat} <- get(project, id, auth), do: put(fun.(chat))
    end

    def put(chat) do
      :ok = GenServer.call(__MODULE__, {:put, chat})
      Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "chat:" <> chat["id"], {:chat_updated, chat["id"]})
      {:ok, chat}
    end

    def handle_call(:all, _from, state), do: {:reply, state, state}
    def handle_call({:put, chat}, _from, state), do: {:reply, :ok, Map.put(state, chat["id"], chat)}
  end

  defmodule EmbeddedHost do
    use Phoenix.LiveView
    alias SymphonyElixirWeb.{BrowserAuth, ChatPanel}

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         auth: BrowserAuth.context(session, socket),
         project_id: "alpha",
         chat_id: "a1",
         view_context: session["view_context"],
         read_only: session["read_only"] || false,
         board_link: nil,
         closed: false
       )}
    end

    def handle_info({:view_context, context}, socket), do: {:noreply, assign(socket, :view_context, context)}
    def handle_info({:project, project}, socket), do: {:noreply, assign(socket, project_id: project, chat_id: nil)}
    def handle_info({:read_only, value}, socket), do: {:noreply, assign(socket, :read_only, value)}

    def handle_info({:chat_updated, id}, socket) do
      send_update(ChatPanel, id: "management-chat", refresh_chat: id)
      {:noreply, socket}
    end

    def handle_info({:chat_panel, :navigate, location}, socket), do: {:noreply, assign(socket, Map.to_list(location))}
    def handle_info({:chat_panel, :board_link, url}, socket), do: {:noreply, assign(socket, :board_link, url)}
    def handle_info({:chat_panel, :close}, socket), do: {:noreply, assign(socket, :closed, true)}

    def render(assigns) do
      ~H"""
      <main id="board-host" data-board-link={@board_link} data-closed={to_string(@closed)}>
        <.live_component module={ChatPanel} id="management-chat" auth={@auth} csrf_token="fixture-only"
          embedded={true} project_id={@project_id} chat_id={@chat_id} view_context={@view_context} read_only={@read_only} />
      </main>
      """
    end
  end

  setup do
    config = %{
      tracker: %{kind: "memory", active_states: ["open"], terminal_states: ["closed"]},
      control: %{enabled: true, state_path: Workflow.workflow_file_path() <> ".control.json"},
      observability: %{dashboard_enabled: false}
    }

    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nFixture")
    :ok = WorkflowStore.force_reload()
    previous_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    token = String.duplicate("fixture-chat-token", 3)
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])
    Application.put_env(:symphony_elixir, Endpoint, Keyword.merge(previous_endpoint, server: false, secret_key_base: String.duplicate("c", 64), chat_store: FixtureStore))
    start_supervised!({FixtureStore, %{"a1" => chat("a1", "alpha", "Alpha plan"), "b1" => chat("b1", "beta", "Beta private plan")}})
    start_supervised!({Endpoint, []})
    {:ok, marker} = BrowserAuth.authenticate(local_conn(), token)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous_endpoint)
      if previous_token, do: System.put_env("SYMPHONY_CONTROL_TOKEN", previous_token), else: System.delete_env("SYMPHONY_CONTROL_TOKEN")
    end)

    %{marker: marker, token: token}
  end

  test "anonymous browsers cannot load messages or project history" do
    {:ok, view, html} = live(local_conn(), "/chat?project=alpha&chat=a1")
    assert html =~ "Unlock chat"
    refute html =~ "Alpha secret"
    refute html =~ "Beta private plan"
    render_click(with_target(view, "#chat-app"), "new-chat")
    refute render(view) =~ "Alpha secret"
    assert map_size(GenServer.call(FixtureStore, :all)) == 2
  end

  test "project routes isolate history and reject another project's thread", ctx do
    {view, html} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    assert html =~ "Alpha secret"
    refute html =~ "Beta secret"
    render_click(view, "open-history")
    assert has_element?(view, "#chat-dialog", "Alpha plan")
    refute has_element?(view, "#chat-dialog", "Beta private plan")
    render_change(view, "search-history", %{"query" => "missing"})
    assert has_element?(view, "#chat-dialog", "No conversations match")
    render_click(view, "close-dialog")
    render_patch(view, "/chat?project=alpha&chat=b1")
    refute render(view) =~ "Beta secret"
    refute render(view) =~ "Alpha secret"
    assert render(view) =~ "not available in the selected project"
  end

  test "project changes clear the conversation and draft without transferring history", ctx do
    {view, _} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    render_change(view, "search-history", %{"query" => "Alpha"})
    render_change(view, "draft", %{"message" => "Unsaved alpha details"})
    render_change(view, "select-project", %{"project" => "beta"})
    assert_patch(view, "/chat?project=beta")
    html = render(view)
    assert html =~ "What’s next for Beta project?"
    refute html =~ "Unsaved alpha details"
    refute html =~ "Alpha secret"
    render_click(view, "open-history")
    assert has_element?(view, "#chat-dialog", "Beta private plan")
    refute has_element?(view, "#chat-dialog", "Alpha plan")
  end

  test "new chats stream owner updates and resume after browser reconnect", ctx do
    {view, _} = chat_view(ctx, "/chat?project=alpha")
    render_submit(view, "send-message", %{"message" => "What is blocked?"})
    assert has_element?(view, "#stop-response-button")
    assert has_element?(view, "#chat-app[data-running=true]")
    assert render(view) =~ "What is blocked?"
    chat = GenServer.call(FixtureStore, :all) |> Map.values() |> Enum.find(&String.starts_with?(&1["id"], "new-"))
    messages = List.update_at(chat["messages"], -1, &Map.put(&1, "text", "One task is waiting"))
    FixtureStore.put(Map.put(chat, "messages", messages))
    assert eventually(fn -> render(view) =~ "One task is waiting" end)
    render_click(view, "stop-response")
    assert render(view) =~ "Response stopped"
    refute has_element?(view, "#stop-response-button")
    {resumed, _} = chat_view(ctx, "/chat?project=alpha&chat=" <> chat["id"])
    assert render(resumed) =~ "One task is waiting"
  end

  test "rename and archive preserve project ownership and stored history", ctx do
    {view, _} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    render_click(view, "open-rename")
    assert has_element?(view, "dialog#chat-dialog")
    render_submit(view, "rename-chat", %{"title" => "Release planning"})
    assert render(view) =~ "Release planning"
    refute has_element?(view, "#chat-dialog")
    render_click(view, "open-archive")
    render_click(view, "archive-chat")
    assert_patch(view, "/chat?project=alpha")
    {:ok, retained} = FixtureStore.get("alpha", "a1", nil)
    assert retained["archived"]
    assert retained["messages"] != []
    render_click(view, "open-history")
    refute has_element?(view, "#chat-dialog", "Release planning")
  end

  test "typed widgets link filters and tasks while proposals require explicit confirmation", ctx do
    widgets = [
      %{
        "type" => "tasks",
        "tasks" => [%{"id" => "alpha:7", "identifier" => "GH-7", "title" => "Pending task", "stage" => "ready"}],
        "url" => "/?project=alpha&status=ready",
        "filters" => %{"status" => "ready"}
      },
      %{"type" => "status", "summary" => "Two tasks", "counts" => %{"ready" => 2}},
      %{"type" => "proposal", "id" => "p1", "title" => "Create a task", "action" => "create_task", "details" => %{"title" => "Review setup"}, "status" => "pending"},
      %{"type" => "receipt", "summary" => "Task updated", "url" => "https://github.com/example/alpha/issues/7"}
    ]

    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    FixtureStore.put(Map.update!(chat, "messages", &Enum.map(&1, fn message -> Map.put(message, "widgets", widgets) end)))
    {view, _} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    assert has_element?(view, ".chat-widget-tasks a[href='/?project=alpha&status=ready']")
    assert has_element?(view, ".widget-task a[href='/?project=alpha&status=ready&task=alpha%3A7']")
    assert has_element?(view, ".status-counts dd", "2")
    assert has_element?(view, "button[phx-value-decision=confirm]")
    render_click(view, "decide", %{"id" => "p1", "decision" => "confirm"})
    refute has_element?(view, "button[phx-value-decision=confirm]")
    assert has_element?(view, ".chat-widget-proposal", "confirmed")
  end

  test "model text, malicious links and unknown widgets never execute as markup", ctx do
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    widgets = [%{"type" => "receipt", "summary" => "<img src=x onerror=alert(1)>", "url" => "javascript:alert(1)"}, %{"type" => "html", "html" => "<script>bad()</script>"}]
    message = %{"id" => "unsafe", "role" => "assistant", "text" => "<script>bad()</script>", "widgets" => widgets}
    FixtureStore.put(%{chat | "messages" => [message], "context" => [%{"title" => "Malicious source", "url" => "//evil.example"}]})
    {view, html} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    assert html =~ "&lt;script&gt;bad()&lt;/script&gt;"
    refute has_element?(view, ".chat-message script")
    refute has_element?(view, ".chat-widget img")
    refute has_element?(view, "a[href^='javascript:']")
    refute has_element?(view, ".chat-widget-html")
    render_click(view, "toggle-inspector")
    assert has_element?(view, ".chat-workspace[data-inspector=true]")
    assert has_element?(view, "#chat-inspector", "Malicious source")
    refute has_element?(view, "#chat-inspector a[href='//evil.example']")
  end

  test "conflicting controls wait for streaming or action completion without exposing action cancellation", ctx do
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)

    proposals = [
      %{"type" => "proposal", "id" => "pending", "title" => "Pending action", "status" => "pending"},
      %{"type" => "proposal", "id" => "unknown", "title" => "Uncertain action", "status" => "unknown"}
    ]

    messages = Enum.map(chat["messages"], &Map.put(&1, "widgets", proposals))
    chat = chat |> Map.put("messages", messages) |> Map.put("status", "running") |> Map.put("proposals", proposals)
    FixtureStore.put(chat)
    {view, _} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    assert has_element?(view, "button[phx-value-decision=confirm][disabled]")
    assert has_element?(view, "button[phx-value-decision=cancel][disabled]")
    assert has_element?(view, "button[phx-value-decision=reconcile][disabled]")
    assert has_element?(view, "#stop-response-button")

    executing = Map.put(hd(proposals), "status", "executing")
    chat = chat |> Map.put("status", "idle") |> Map.put("proposals", [executing | tl(proposals)])
    FixtureStore.put(chat)
    assert eventually(fn -> has_element?(view, "#send-message-button[disabled]", "Applying action") end)
    assert has_element?(view, "#chat-message-input[disabled]")
    assert has_element?(view, "button[phx-click=open-archive][disabled]")
    refute has_element?(view, "#stop-response-button")
    render_submit(view, "send-message", %{"message" => "A conflicting message"})
    assert render(view) =~ "Wait for the current response or action"
    assert {:ok, %{"messages" => ^messages}} = FixtureStore.get("alpha", "a1", nil)

    FixtureStore.put(Map.put(chat, "proposals", proposals))
    assert eventually(fn -> has_element?(view, "button[phx-value-decision=reconcile]:not([disabled])") end)
    assert has_element?(view, "#send-message-button:not([disabled])")
  end

  test "source failure and uncertain or failed actions remain visible instead of implying idle or success", ctx do
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)

    widgets = [
      %{
        "type" => "status",
        "counts" => %{"running" => 0},
        "source_error" => "Tracker unavailable",
        "control" => %{"mode" => "paused"},
        "generated_at" => "2026-09-15",
        "blockers" => [%{"id" => "task-7", "title" => "Review needed"}]
      },
      %{"type" => "proposal", "id" => "uncertain", "title" => "Uncertain update", "status" => "unknown"},
      %{"type" => "proposal", "id" => "failed", "title" => "Failed update", "status" => "failed", "error" => "The issue changed before this update."}
    ]

    FixtureStore.put(Map.update!(chat, "messages", &Enum.map(&1, fn message -> Map.put(message, "widgets", widgets) end)))
    {view, html} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    assert html =~ "Tracker unavailable"
    assert html =~ "Execution: paused"
    assert html =~ "Review needed"
    assert html =~ "Checked 2026-09-15"
    refute has_element?(view, ".status-counts")
    assert has_element?(view, "button[phx-value-decision=reconcile]", "Check outcome")
    refute has_element?(view, "button[phx-value-decision=confirm]")
    assert html =~ "The issue changed before this update."
  end

  test "expired authorization clears retained messages before another action", ctx do
    {view, _} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated", 8))
    render_click(view, "open-history")
    html = render(view)
    assert html =~ "Unlock chat"
    refute html =~ "Alpha secret"
  end

  test "embedded view updates retain draft and history while sending the latest IDs-only snapshot", ctx do
    first = view_context()
    view = embedded_view(ctx, first)
    assert has_element?(view, ".embedded-chat")
    refute has_element?(view, "#chat-project")
    assert has_element?(view, "#chat-context-controls", "2 visible tasks")
    render_change(view, "draft", %{"message" => "Help with these cards"})
    render_click(view, "open-history")
    render_change(view, "search-history", %{"query" => "Alpha"})
    updated = first |> Map.put("visible_task_ids", ["alpha:8"]) |> Map.put("viewport_task_ids", ["alpha:8"]) |> Map.put("selected_task_id", "alpha:8")
    send(view.pid, {:view_context, updated})
    assert has_element?(view, "#chat-message-input", "Help with these cards")
    assert has_element?(view, "#chat-dialog input[value=Alpha]")
    assert has_element?(view, "#chat-context-controls", "1 visible task")
    assert has_element?(view, "#chat-app[data-chat-id=a1]")
    render_click(view, "close-dialog")
    render_submit(view, "send-message", %{"message" => "Help with these cards"})
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    assert Enum.find(chat["messages"], &(&1["role"] == "user"))["view_context"] == updated
  end

  test "view sharing and selected-card identification are explicit per-message controls", ctx do
    context = view_context()
    view = embedded_view(ctx, context)
    render_change(view, "context-options", %{"share_context" => "true", "include_selected" => "false"})
    render_submit(view, "send-message", %{"message" => "Use the filter without identifying the selected card"})
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    sent = Enum.find(chat["messages"], &(&1["role"] == "user"))["view_context"]
    assert sent["selected_task_id"] == nil
    assert sent["visible_task_ids"] == context["visible_task_ids"]
    render_click(view, "stop-response")
    render_change(view, "context-options", %{"share_context" => "false", "include_selected" => "false"})
    render_submit(view, "send-message", %{"message" => "Do not attach this view"})
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    assert chat["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Map.fetch!("view_context") == nil
  end

  test "an embedded project switch clears drafts and never attaches another project's snapshot", ctx do
    view = embedded_view(ctx, view_context())
    render_change(view, "draft", %{"message" => "Private alpha draft"})
    send(view.pid, {:project, "beta"})
    html = render(view)
    refute html =~ "Private alpha draft"
    refute html =~ "Alpha secret"
    assert html =~ "No matching board context"
    render_submit(view, "send-message", %{"message" => "Discuss beta"})
    stored = GenServer.call(FixtureStore, :all) |> Map.values() |> Enum.find(&(&1["project_id"] == "beta" and String.starts_with?(&1["id"], "new-")))
    assert Enum.find(stored["messages"], &(&1["role"] == "user"))["view_context"] == nil
    assert render(view) =~ "Beta project"
  end

  test "saved chat preferences affect the next message without rewriting history or blocking composer overrides", ctx do
    context = view_context()
    view = embedded_view(ctx, context)
    assert has_element?(view, "#chat-app[data-project=alpha][data-event-target]")
    render_submit(view, "send-message", %{"message" => "First snapshot"})
    render_click(view, "stop-response")

    render_hook(view, "context-preferences", %{"project_id" => "alpha", "share_context" => false, "include_selected" => false})
    refute has_element?(view, "input[name=share_context][checked]")
    render_submit(view, "send-message", %{"message" => "Saved sharing preference"})
    render_click(view, "stop-response")

    render_change(view, "context-options", %{"share_context" => "true", "include_selected" => "false"})
    render_submit(view, "send-message", %{"message" => "Override for this message"})
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    [first, second, third] = Enum.filter(chat["messages"], &(&1["role"] == "user"))
    assert first["view_context"] == context
    assert second["view_context"] == nil
    assert third["view_context"] == Map.put(context, "selected_task_id", nil)
  end

  test "chat preferences reject stale project events and malformed boolean values", ctx do
    view = embedded_view(ctx, view_context())

    for params <- [
          %{"project_id" => "beta", "share_context" => false, "include_selected" => false},
          %{"project_id" => "alpha", "share_context" => "false", "include_selected" => false},
          %{"project_id" => "alpha", "share_context" => false}
        ] do
      render_hook(view, "context-preferences", params)
      assert has_element?(view, "input[name=share_context][checked]")
    end

    send(view.pid, {:project, "beta"})
    assert has_element?(view, "#chat-app[data-project=beta]")
    render_hook(view, "context-preferences", %{"project_id" => "alpha", "share_context" => false, "include_selected" => false})
    assert has_element?(view, "input[name=share_context][checked]")
    render_hook(view, "context-preferences", %{"project_id" => "beta", "share_context" => false, "include_selected" => true})
    refute has_element?(view, "input[name=share_context][checked]")
  end

  test "embedded typed links update the board without transferring conversation or accepting a foreign project", ctx do
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    widget = %{"type" => "tasks", "url" => "/?project=alpha&status=ready", "tasks" => [%{"id" => "alpha:7", "title" => "Linked card"}]}
    FixtureStore.put(Map.update!(chat, "messages", &Enum.map(&1, fn message -> Map.put(message, "widgets", [widget]) end)))
    view = embedded_view(ctx, view_context())
    view |> element(".widget-task a") |> render_click()
    assert has_element?(view, "#board-host[data-board-link='/?project=alpha&task=alpha%3A7']")
    assert has_element?(view, "#chat-app[data-chat-id=a1]")
    render_click(view, "board-link", %{"url" => "/?project=beta&task=beta%3A7"})
    assert render(view) =~ "outside this conversation"
    assert has_element?(view, "#board-host[data-board-link='/?project=alpha&task=alpha%3A7']")
    render_click(view, "open-history")
    assert has_element?(view, "#chat-dialog[data-close-selector='#chat-close-dialog']")
    refute has_element?(view, "#board-dialog")
    render_click(view, "close-panel")
    assert has_element?(view, "#board-host[data-closed=true]")
  end

  test "read-only embedded mode hides chat access and rejects forged mutations then recovers", ctx do
    view = embedded_view(ctx, view_context(), true)
    assert render(view) =~ "Chat is unavailable in this read-only view"
    refute has_element?(view, "#chat-composer")
    refute has_element?(view, ".chat-login")
    render_click(view, "new-chat")
    assert map_size(GenServer.call(FixtureStore, :all)) == 2
    send(view.pid, {:read_only, false})
    assert render(view) =~ "Alpha secret"
    assert has_element?(view, "#chat-composer")
  end

  test "authorization loss on component refresh clears all retained content", ctx do
    view = embedded_view(ctx, view_context())
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("changed", 8))
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    FixtureStore.put(chat)
    html = render(view)
    assert html =~ "Unlock chat"
    refute html =~ "Alpha secret"
    refute has_element?(view, "#chat-context-controls")
  end

  defp embedded_view(ctx, context, read_only \\ false) do
    session = %{BrowserAuth.session_key() => ctx.marker, "view_context" => context, "read_only" => read_only}
    {:ok, view, _html} = live_isolated(local_conn(), EmbeddedHost, session: session)
    with_target(view, "#chat-app")
  end

  defp view_context do
    %{
      "version" => 1,
      "project_id" => "alpha",
      "filters" => %{"project" => ["alpha"], "status" => ["ready"], "priority" => [], "q" => "", "sort" => "priority"},
      "selected_task_id" => "alpha:7",
      "visible_task_ids" => ["alpha:7", "alpha:8"],
      "viewport_task_ids" => ["alpha:7"],
      "hidden_columns" => [],
      "captured_at" => "2026-09-15T12:00:00Z",
      "board_checked_at" => "2026-09-15T11:59:50Z",
      "truncated" => false
    }
  end

  defp eventually(predicate, attempts \\ 50) do
    if predicate.() do
      true
    else
      if attempts > 0 do
        receive do
        after
          5 -> :ok
        end

        eventually(predicate, attempts - 1)
      else
        false
      end
    end
  end

  defp local_conn, do: %{build_conn() | host: "localhost"}

  defp chat_view(ctx, path) do
    conn = local_conn() |> Plug.Test.init_test_session(%{BrowserAuth.session_key() => ctx.marker})
    {:ok, view, html} = live(conn, path)
    {with_target(view, "#chat-app"), html}
  end

  defp chat(id, project, title) do
    %{
      "id" => id,
      "project_id" => project,
      "title" => title,
      "status" => "idle",
      "archived" => false,
      "updated_at" => "2026-09-15",
      "context" => [],
      "messages" => [%{"id" => "m1", "role" => "assistant", "text" => "#{String.capitalize(project)} secret", "widgets" => []}]
    }
  end
end
