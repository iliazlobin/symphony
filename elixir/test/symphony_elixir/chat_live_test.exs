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

    def list(project, _auth),
      do:
        {:ok,
         GenServer.call(__MODULE__, :all)
         |> Map.values()
         |> Enum.filter(&(&1["project_id"] == project))
         |> Enum.sort_by(&{!(&1["pinned"] == true), &1["order"] || 0, &1["id"]})
         |> Enum.map(&Map.take(&1, ~w(id project_id title snippet updated_at status display_status archived pinned)))}

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

    def pin(project, id, pinned, auth) do
      with {:ok, _} <- update(project, id, auth, &Map.put(&1, "pinned", pinned)), do: list(project, auth)
    end

    def move(project, id, before, pinned, auth) do
      with {:ok, chats} <- list(project, auth),
           %{} = source <- Enum.find(chats, &(&1["id"] == id)),
           true <- source["pinned"] == true == pinned,
           true <- is_nil(before) or Enum.any?(chats, &(&1["id"] == before and &1["pinned"] == true == (source["pinned"] == true))) do
        ids = chats |> Enum.filter(&(&1["pinned"] == true == (source["pinned"] == true))) |> Enum.map(& &1["id"]) |> List.delete(id)
        index = Enum.find_index(ids, &(&1 == before)) || length(ids)

        List.insert_at(ids, index, id)
        |> Enum.with_index()
        |> Enum.each(fn {chat_id, order} -> update(project, chat_id, auth, &Map.put(&1, "order", order)) end)

        list(project, auth)
      else
        _ -> {:error, :invalid_chat_order}
      end
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
      Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "chat_project:" <> chat["project_id"], {:chat_list_updated, chat["project_id"]})
      {:ok, chat}
    end

    def handle_call(:all, _from, state), do: {:reply, state, state}
    def handle_call({:put, chat}, _from, state), do: {:reply, :ok, Map.put(state, chat["id"], chat)}
  end

  defmodule UnavailablePreferences do
    defdelegate projects(auth), to: FixtureStore
    defdelegate get(project, id, auth), to: FixtureStore
    def list(_project, _auth), do: {:error, :chat_preferences_unavailable}
    def pin(_project, _id, _pinned, _auth), do: {:error, :chat_preferences_unavailable}
    def move(_project, _id, _before, _pinned, _auth), do: {:error, :chat_preferences_unavailable}
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

    def handle_info({:chat_list_updated, project}, socket) do
      send_update(ChatPanel, id: "management-chat", refresh_threads: project)
      {:noreply, socket}
    end

    def handle_info({:chat_panel, :project_subscription, _project}, socket), do: {:noreply, socket}

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
    render_click(view, "back-to-chats")
    assert has_element?(view, "#chat-thread-list", "Alpha plan")
    refute has_element?(view, "#chat-thread-list", "Beta private plan")
    render_change(view, "search-threads", %{"query" => "missing"})
    assert has_element?(view, "#chat-thread-list", "No chats match")
    render_click(view, "session-tab", %{"tab" => "chat"})
    render_patch(view, "/chat?project=alpha&chat=b1")
    refute render(view) =~ "Beta secret"
    refute render(view) =~ "Alpha secret"
    assert render(view) =~ "not available in the selected project"
  end

  test "project changes clear the conversation and draft without transferring history", ctx do
    {view, _} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    render_change(view, "search-threads", %{"query" => "Alpha"})
    render_change(view, "draft", %{"message" => "Unsaved alpha details"})
    render_change(view, "select-project", %{"project" => "beta"})
    assert_patch(view, "/chat?project=beta")
    html = render(view)
    assert html =~ "What’s next for Beta project?"
    refute html =~ "Unsaved alpha details"
    refute html =~ "Alpha secret"
    render_click(view, "back-to-chats")
    assert has_element?(view, "#chat-thread-list", "Beta private plan")
    refute has_element?(view, "#chat-thread-list", "Alpha plan")
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

  test "session tabs preserve drafts and streamed history without rename or archive controls", ctx do
    {view, _} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    render_change(view, "draft", %{"message" => "Keep this draft"})

    for tab <- ~w(context outputs sources chat) do
      render_click(view, "session-tab", %{"tab" => tab})
      assert has_element?(view, "#session-#{tab}-tab[aria-selected=true]")
      assert has_element?(view, "#session-#{tab}-content:not([hidden])")
      assert has_element?(view, "#chat-message-input", "Keep this draft")
    end

    refute has_element?(view, "button[phx-click=open-rename]")
    refute has_element?(view, "button[phx-click=open-archive]")
    refute has_element?(view, "#chat-inspector-button")
    assert render(view) =~ "Alpha secret"
    {:ok, retained} = FixtureStore.get("alpha", "a1", nil)
    refute retained["archived"]
    assert retained["messages"] != []
  end

  test "Chat list is default, searchable and opens a conversation view", ctx do
    {:ok, second} = FixtureStore.get("alpha", "a1", nil)

    FixtureStore.put(
      second
      |> Map.put("id", "a2")
      |> Map.put("title", "Review cloud rollout")
      |> Map.put("snippet", "Check subscription workers")
      |> Map.put("updated_at", "2026-09-16T13:14:15Z")
      |> Map.put("display_status", "awaiting_confirmation")
    )

    {view, _} = chat_view(ctx, "/chat?project=alpha")
    assert has_element?(view, "#chat-thread-list:not([hidden])")
    assert has_element?(view, "#chat-conversation-detail[hidden]")
    refute has_element?(view, "#chat-history-button")
    refute has_element?(view, "#chat-dialog")
    render_change(view, "search-threads", %{"query" => "subscription"})
    assert has_element?(view, "[data-thread-id=a2] .thread-status", "Awaiting confirmation")
    refute has_element?(view, "[data-thread-id=a1]")
    assert has_element?(view, "[data-thread-id=a2] time[datetime='2026-09-16T13:14:15Z'][title='Updated 2026-09-16T13:14:15Z']", "Updated Sep 16")
    view |> element("[data-thread-id=a2] .thread-open") |> render_click()
    assert has_element?(view, "#session-chat-tab[aria-selected=true]")
    assert has_element?(view, "#chat-conversation-detail:not([hidden])")
    assert has_element?(view, "#chat-app[data-chat-id=a2]")
    render_click(view, "new-chat")
    assert has_element?(view, "#session-chat-tab[aria-selected=true]")
    refute has_element?(view, "#chat-app[data-chat-id=a2]")
  end

  test "list and detail navigation preserves a draft and same-chat updates never force detail", ctx do
    {view, _} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    assert has_element?(view, "#chat-conversation-detail:not([hidden])")
    refute has_element?(view, "#session-threads-tab")
    render_change(view, "draft", %{"message" => "Keep my draft"})
    render_click(view, "back-to-chats")
    assert has_element?(view, "#chat-thread-list:not([hidden])")
    assert has_element?(view, ".chat-session-tabs[hidden]")
    {:ok, current} = FixtureStore.get("alpha", "a1", nil)
    FixtureStore.put(Map.put(current, "status", "running"))
    assert eventually(fn -> has_element?(view, "#stop-response-button") end)
    assert has_element?(view, "#chat-thread-list:not([hidden])")
    assert has_element?(view, "#chat-message-input", "Keep my draft")
    view |> element("[data-thread-id=a1] .thread-open") |> render_click()
    assert has_element?(view, "#chat-conversation-detail:not([hidden])")
    assert has_element?(view, "#chat-message-input", "Keep my draft")
    render_hook(view, "restore-workspace-view", %{"project_id" => "beta", "chat_id" => "a1", "view" => "list"})
    assert has_element?(view, "#chat-conversation-detail:not([hidden])")
    render_hook(view, "restore-workspace-view", %{"project_id" => "alpha", "chat_id" => "a1", "view" => "list"})
    assert has_element?(view, "#chat-thread-list:not([hidden])")
    render_hook(view, "restore-session-tab", %{"project_id" => "alpha", "chat_id" => "a1", "tab" => "threads"})
    refute has_element?(view, "#session-threads-tab")
  end

  test "pinning and keyboard ordering keep chat groups scoped and retain selected draft", ctx do
    {:ok, original} = FixtureStore.get("alpha", "a1", nil)
    FixtureStore.put(original |> Map.put("id", "a2") |> Map.put("title", "Second chat"))
    FixtureStore.put(original |> Map.put("id", "a3") |> Map.put("title", "Third chat"))
    {view, _} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    render_change(view, "draft", %{"message" => "Still selected"})
    render_click(view, "back-to-chats")
    refute has_element?(view, "[data-thread-id] button button")
    assert has_element?(view, "[data-thread-id=a1] [phx-value-direction=up][disabled]")
    view |> element("[data-thread-id=a2] [phx-click=pin-thread]") |> render_click()
    assert has_element?(view, "[data-pin-group=true] [data-thread-id=a2]")
    assert has_element?(view, "[data-thread-id=a2] [phx-click=pin-thread][aria-label='Unpin Second chat']")
    view |> element("[data-thread-id=a2] [phx-click=pin-thread]") |> render_click()
    view |> element("[data-thread-id=a3] [phx-value-direction=up]") |> render_click()
    assert has_element?(view, "[data-pin-group=false] [data-thread-id=a3] + [data-thread-id=a2]")
    render_change(view, "search-threads", %{"query" => "Third"})
    assert has_element?(view, "[data-thread-id=a3] [data-thread-drag][disabled]")
    assert has_element?(view, "[data-thread-id=a3] [phx-value-direction=down][disabled]")
    render_hook(view, "move-thread", %{"id" => "a3", "before_id" => "a1", "pinned" => false, "project_id" => "beta"})
    render_change(view, "search-threads", %{"query" => ""})
    assert has_element?(view, "[data-pin-group=false] [data-thread-id=a1] + [data-thread-id=a3]")
    assert has_element?(view, "#chat-message-input", "Still selected")
  end

  test "unavailable list preferences retain active detail and never claim an empty history", ctx do
    {view, _} = chat_view(ctx, "/chat?project=alpha&chat=a1")
    render_change(view, "draft", %{"message" => "Retained draft"})
    Endpoint.config_change([{Endpoint, Keyword.put(Application.get_env(:symphony_elixir, Endpoint), :chat_store, UnavailablePreferences)}], [])
    render_click(view, "pin-thread", %{"id" => "a1", "pinned" => "true"})
    assert render(view) =~ "could not confirm saving"
    assert has_element?(view, "#chat-message-input", "Retained draft")
    assert has_element?(view, "#chat-conversation-detail:not([hidden])")
    render_click(view, "back-to-chats")
    assert has_element?(view, "#chat-thread-list", "could not be loaded")
    assert has_element?(view, "[data-thread-id=a1]")
    refute render(view) =~ "No chats yet"
    {fresh, _} = chat_view(ctx, "/chat?project=alpha")
    assert has_element?(fresh, "#chat-thread-list", "could not be loaded")
    refute render(fresh) =~ "No chats yet"
    Endpoint.config_change([{Endpoint, Keyword.put(Application.get_env(:symphony_elixir, Endpoint), :chat_store, FixtureStore)}], [])
    render_click(view, "retry-chat-list")
    refute has_element?(view, "#chat-thread-list", "could not be loaded")
    refute render(view) =~ "could not confirm saving"
    assert has_element?(view, "#chat-message-input", "Retained draft")
  end

  test "thread activity refreshes in place and old project notifications cannot cross scope", ctx do
    view = embedded_view(ctx, view_context())
    render_change(view, "draft", %{"message" => "Keep alpha draft"})
    render_click(view, "back-to-chats")
    render_change(view, "search-threads", %{"query" => "Alpha"})
    {:ok, background} = FixtureStore.get("alpha", "a1", nil)
    FixtureStore.put(background |> Map.put("id", "a2") |> Map.put("title", "Alpha background") |> Map.put("display_status", "running"))
    assert eventually(fn -> has_element?(view, "[data-thread-id=a2] .thread-status", "Running") end)
    assert has_element?(view, "#chat-app[data-chat-id=a1]")
    assert has_element?(view, "#chat-message-input", "Keep alpha draft")
    assert has_element?(view, "#chat-thread-search input[value=Alpha]")
    assert Enum.any?(Registry.lookup(SymphonyElixir.PubSub, "chat_project:alpha"), &(elem(&1, 0) == view.pid))
    send(view.pid, {:project, "beta"})
    assert has_element?(view, "#chat-thread-list", "Beta private plan")
    refute has_element?(view, "[data-thread-id=a2]")
    refute Enum.any?(Registry.lookup(SymphonyElixir.PubSub, "chat_project:alpha"), &(elem(&1, 0) == view.pid))
    send(view.pid, {:chat_list_updated, "alpha"})
    refute render(view) =~ "Alpha background"
    assert Enum.any?(Registry.lookup(SymphonyElixir.PubSub, "chat_project:beta"), &(elem(&1, 0) == view.pid))
    render_click(view, "close-panel")
    assert has_element?(view, "#board-host[data-closed=true]")
    refute Enum.any?(Registry.lookup(SymphonyElixir.PubSub, "chat_project:beta"), &(elem(&1, 0) == view.pid))
  end

  test "all conversation statuses are clear and project refresh clears revoked content", ctx do
    {:ok, original} = FixtureStore.get("alpha", "a1", nil)

    for {status, label} <- [
          {"running", "Running"},
          {"action", "Running action"},
          {"needs_reconciliation", "Check outcome"},
          {"awaiting_confirmation", "Awaiting confirmation"},
          {"error", "Error"},
          {"interrupted", "Interrupted"},
          {"idle", "Idle"},
          {"new", "New"}
        ] do
      FixtureStore.put(original |> Map.put("id", status) |> Map.put("title", label) |> Map.put("display_status", status))
    end

    {view, _} = chat_view(ctx, "/chat?project=alpha")

    for status <- ~w(running action needs_reconciliation awaiting_confirmation error interrupted idle new) do
      assert has_element?(view, "[data-thread-id=#{status}] .thread-status[data-status=#{status}]")
    end

    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("revoked", 8))
    send(view.pid, {:chat_list_updated, "alpha"})
    assert eventually(fn -> render(view) =~ "Unlock chat" end)
    refute has_element?(view, "#chat-thread-list")
    refute Enum.any?(Registry.lookup(SymphonyElixir.PubSub, "chat_project:alpha"), &(elem(&1, 0) == view.pid))
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
    render_click(view, "session-tab", %{"tab" => "sources"})
    assert has_element?(view, "#session-sources-content:not([hidden])")
    assert has_element?(view, "#session-sources-content", "Malicious source")
    refute has_element?(view, "#session-sources-content a[href='//evil.example']")
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
    render_click(view, "back-to-chats")
    html = render(view)
    assert html =~ "Unlock chat"
    refute html =~ "Alpha secret"
  end

  test "embedded view updates retain draft and history while sending the latest IDs-only snapshot", ctx do
    first = view_context()
    view = embedded_view(ctx, first)
    assert has_element?(view, ".embedded-chat")
    refute has_element?(view, "#chat-project")
    assert has_element?(view, "#session-context-content", "2 visible tasks")
    render_change(view, "draft", %{"message" => "Help with these cards"})
    render_click(view, "back-to-chats")
    render_change(view, "search-threads", %{"query" => "Alpha"})
    updated = first |> Map.put("visible_task_ids", ["alpha:8"]) |> Map.put("viewport_task_ids", ["alpha:8"]) |> Map.put("selected_task_id", "alpha:8")
    send(view.pid, {:view_context, updated})
    assert has_element?(view, "#chat-message-input", "Help with these cards")
    assert has_element?(view, "#chat-thread-search input[value=Alpha]")
    assert has_element?(view, "#session-context-content", "1 visible task")
    assert has_element?(view, "#chat-app[data-chat-id=a1]")
    render_click(view, "session-tab", %{"tab" => "chat"})
    render_submit(view, "send-message", %{"message" => "Help with these cards"})
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    assert Enum.find(chat["messages"], &(&1["role"] == "user"))["view_context"] == updated
  end

  test "board context and selected task attach automatically and remain with their messages", ctx do
    context = view_context()
    view = embedded_view(ctx, context)
    refute has_element?(view, "input[name=share_context]")
    render_click(view, "session-tab", %{"tab" => "context"})
    render_submit(view, "send-message", %{"message" => "Use the current cards"})
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    assert Enum.find(chat["messages"], &(&1["role"] == "user"))["view_context"] == context
    assert has_element?(view, "#session-chat-tab[aria-selected=true]")
    render_click(view, "session-tab", %{"tab" => "context"})
    assert has_element?(view, ".retained-context", "Use the current cards")
    assert has_element?(view, ".retained-context", "Selected task: alpha:7")
    assert has_element?(view, "#stop-response-button")
    render_click(view, "stop-response")
    send(view.pid, {:view_context, nil})
    render_submit(view, "send-message", %{"message" => "No board is available now"})
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    assert chat["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Map.fetch!("view_context") == nil
    assert has_element?(view, ".retained-context", "Use the current cards")
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

  test "tab restoration rejects stale conversation, project and malformed preferences", ctx do
    view = embedded_view(ctx, view_context())

    for params <- [
          %{"project_id" => "beta", "chat_id" => "a1", "tab" => "sources"},
          %{"project_id" => "alpha", "chat_id" => "b1", "tab" => "sources"},
          %{"project_id" => "alpha", "chat_id" => "a1", "tab" => "unknown"}
        ] do
      render_hook(view, "restore-session-tab", params)
      assert has_element?(view, "#session-chat-tab[aria-selected=true]")
    end

    render_hook(view, "restore-session-tab", %{"project_id" => "alpha", "chat_id" => "a1", "tab" => "sources"})
    assert has_element?(view, "#session-sources-tab[aria-selected=true]")
    render_change(view, "draft", %{"message" => "Retain draft"})
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    FixtureStore.put(Map.put(chat, "status", "running"))
    assert eventually(fn -> has_element?(view, "#stop-response-button") end)
    assert has_element?(view, "#session-sources-tab[aria-selected=true]")
    assert has_element?(view, "#chat-message-input", "Retain draft")
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
    render_click(view, "back-to-chats")
    assert has_element?(view, "#chat-thread-list:not([hidden])")
    refute has_element?(view, "#chat-dialog")
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
    assert Enum.any?(Registry.lookup(SymphonyElixir.PubSub, "chat_project:alpha"), &(elem(&1, 0) == view.pid))
    send(view.pid, {:read_only, true})
    assert render(view) =~ "Chat is unavailable in this read-only view"
    refute Enum.any?(Registry.lookup(SymphonyElixir.PubSub, "chat_project:alpha"), &(elem(&1, 0) == view.pid))
  end

  test "authorization loss on component refresh clears all retained content", ctx do
    view = embedded_view(ctx, view_context())
    render_change(view, "draft", %{"message" => "Private alpha draft"})
    render_click(view, "session-tab", %{"tab" => "context"})
    assert has_element?(view, "#session-context-content")
    assert has_element?(view, "#chat-message-input", "Private alpha draft")
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("changed", 8))
    {:ok, chat} = FixtureStore.get("alpha", "a1", nil)
    FixtureStore.put(chat)

    # PubSub reaches the host before its queued component update; render alone
    # does not wait for that second message to clear the retained state.
    assert eventually(fn -> has_element?(view, ".chat-login", "Unlock chat") end)
    html = render(view)
    assert html =~ "Unlock chat"
    refute html =~ "Alpha secret"
    refute html =~ "Private alpha draft"
    refute has_element?(view, "#session-context-content")
    refute has_element?(view, "#chat-thread-list")
    refute has_element?(view, "#chat-composer")

    for topic <- ["chat:a1", "chat_project:alpha"] do
      refute Enum.any?(Registry.lookup(SymphonyElixir.PubSub, topic), &(elem(&1, 0) == view.pid))
    end
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
