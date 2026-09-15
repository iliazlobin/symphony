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

    def send_message(project, id, text, client_id, auth) do
      update(project, id, auth, fn chat ->
        user = %{"id" => client_id, "role" => "user", "text" => text, "widgets" => []}
        assistant = %{"id" => "response", "role" => "assistant", "text" => "", "status" => "streaming", "widgets" => []}
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
    render_click(view, "new-chat")
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
    assert render(view) =~ "One task is waiting"
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
        "tasks" => [%{"id" => "github:example/alpha:7", "identifier" => "GH-7", "title" => "Pending task", "stage" => "ready"}],
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
    assert has_element?(view, ".widget-task a[href='/?project=alpha&status=ready&task=github%3Aexample%2Falpha%3A7']")
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
    assert has_element?(view, "#send-message-button[disabled]", "Applying action")
    assert has_element?(view, "#chat-message-input[disabled]")
    assert has_element?(view, "button[phx-click=open-archive][disabled]")
    refute has_element?(view, "#stop-response-button")
    render_submit(view, "send-message", %{"message" => "A conflicting message"})
    assert render(view) =~ "Wait for the current response or action"
    assert {:ok, %{"messages" => ^messages}} = FixtureStore.get("alpha", "a1", nil)

    FixtureStore.put(Map.put(chat, "proposals", proposals))
    assert has_element?(view, "button[phx-value-decision=reconcile]:not([disabled])")
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

  defp local_conn, do: %{build_conn() | host: "localhost"}

  defp chat_view(ctx, path) do
    conn = local_conn() |> Plug.Test.init_test_session(%{BrowserAuth.session_key() => ctx.marker})
    {:ok, view, html} = live(conn, path)
    {view, html}
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
