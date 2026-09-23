defmodule SymphonyElixirWeb.ChatPanel do
  @moduledoc "Project-bound management conversations, streamed from the conversation owner."
  use Phoenix.LiveComponent

  alias SymphonyElixir.Chat.{Artifacts, Sessions}
  alias SymphonyElixir.ProjectDirectory
  alias SymphonyElixirWeb.{BrowserAuth, ChatNavigation, Endpoint}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       auth: nil,
       csrf_token: "",
       embedded: false,
       read_only: false,
       project_id: nil,
       chat_id: nil,
       task_id: nil,
       session_id: nil,
       task_title: nil,
       issue_tasks: [],
       issue_activity: %{},
       issue_query: "",
       pr_query: "",
       conversation_drafts: %{},
       view_context: nil,
       initialized: false,
       projects: [],
       project: nil,
       chats: [],
       list_error: nil,
       chat: nil,
       subscribed: nil,
       project_subscribed: nil,
       draft: "",
       client_id: nonce(),
       thread_query: "",
       session_tab: "chat",
       workspace_view: "list",
       notice: nil,
       loading: true,
       unavailable: nil
     )}
  end

  @impl true
  def update(%{refresh_chat: id}, socket) do
    {:ok, if(chat_id(socket) == id, do: fetch_chat(socket, id), else: socket)}
  end

  def update(%{refresh_threads: project}, socket) do
    socket = if project == project_id(socket), do: refresh_list(socket), else: socket
    {:ok, socket}
  end

  def update(assigns, socket) do
    previous = location(socket.assigns)

    socket =
      assign(socket, Map.take(assigns, [:id, :auth, :csrf_token, :embedded, :project_id, :chat_id, :task_id, :session_id, :task_title, :issue_tasks, :issue_activity, :view_context, :read_only]))

    location = location(socket.assigns)
    unavailable = availability(socket)
    socket = assign(socket, :unavailable, unavailable)

    socket =
      cond do
        not connected?(socket) ->
          assign(socket, :loading, true)

        unavailable ->
          socket |> clear_conversation() |> assign(projects: [], project: nil, loading: false)

        not BrowserAuth.authorized?(socket.assigns.auth) ->
          socket |> assign(:loading, false) |> show_error(:unauthorized)

        needs_location?(socket.assigns, previous, location) ->
          load_location(socket, %{"project" => socket.assigns.project_id, "chat" => socket.assigns.chat_id})

        true ->
          socket
      end

    {:ok, assign(socket, :initialized, connected?(socket))}
  end

  defp availability(socket) do
    store = Endpoint.config(:chat_store, SymphonyElixir.Chat.Store)

    cond do
      socket.assigns.read_only -> "Chat is unavailable in this read-only view."
      store == SymphonyElixir.Chat.Store and not SymphonyElixir.Config.chat_settings().enabled -> "Management chat is not enabled for this service."
      true -> nil
    end
  end

  defp needs_location?(assigns, previous, location) do
    not assigns.initialized or previous != location or is_nil(assigns.project) or (assigns.embedded and is_nil(assigns.chat))
  end

  defp location(assigns), do: {assigns.project_id, if(assigns.embedded, do: {assigns.task_id, assigns.session_id}, else: assigns.chat_id)}

  @impl true
  def handle_event(event, _params, %{assigns: %{embedded: true}} = socket)
      when event in ["close-panel", "new-chat", "open-chat", "back-to-chats", "search-threads", "pin-thread", "move-thread", "move-thread-step"] do
    {:noreply, socket}
  end

  def handle_event("main-chat", _params, socket) do
    if socket.assigns.embedded and BrowserAuth.authorized?(socket.assigns.auth), do: send(self(), {:chat_panel, :main})
    {:noreply, assign(socket, :issue_query, "")}
  end

  def handle_event("select-pr-session", %{"id" => id}, socket) do
    issue = Enum.find(socket.assigns.issue_tasks, &(&1.id == socket.assigns.task_id and &1.project == project_id(socket)))
    selected = if id == "", do: nil, else: id

    if socket.assigns.embedded and BrowserAuth.authorized?(socket.assigns.auth) and
         (is_nil(selected) or Enum.any?(Sessions.options(issue, [selected]), &(&1.id == selected))) do
      send(self(), {:chat_panel, :session, socket.assigns.task_id, selected})
      {:noreply, assign(socket, :pr_query, "")}
    else
      {:noreply, assign(socket, :notice, "That PR session is not available for this issue.")}
    end
  end

  def handle_event("search-issues", %{"query" => query}, socket) when is_binary(query) do
    {:noreply, assign(socket, :issue_query, String.slice(query, 0, 200))}
  end

  def handle_event("search-prs", %{"query" => query}, socket) when is_binary(query) do
    {:noreply, assign(socket, :pr_query, String.slice(query, 0, 200))}
  end

  def handle_event("select-issue", %{"id" => id}, socket) do
    if socket.assigns.embedded and BrowserAuth.authorized?(socket.assigns.auth) and
         Enum.any?(socket.assigns.issue_tasks, &(&1.id == id and &1.project == project_id(socket))) do
      send(self(), {:chat_panel, :select_issue, id})
      {:noreply, assign(socket, :issue_query, "")}
    else
      {:noreply, assign(socket, :notice, "That issue is not available in this project.")}
    end
  end

  def handle_event("close-panel", _params, socket) do
    send(self(), {:chat_panel, :close})
    {:noreply, socket |> subscribe(nil) |> subscribe_project(nil)}
  end

  def handle_event("open-chat", %{"id" => id}, socket) do
    case call(socket, :get, [project_id(socket), id]) do
      {:ok, chat} ->
        socket = socket |> clear_changed_draft(id) |> put_chat(chat) |> assign(session_tab: "chat", workspace_view: "conversation")
        {:noreply, navigate(socket, project_id(socket), id)}

      {:error, reason} ->
        {:noreply, show_error(socket, reason)}
    end
  end

  def handle_event("board-link", %{"url" => url}, socket) do
    if BrowserAuth.authorized?(socket.assigns.auth) and board_link?(url, project_id(socket)) do
      send(self(), {:chat_panel, :board_link, url})
      {:noreply, socket}
    else
      {:noreply, assign(socket, :notice, "That board link is outside this conversation's project.")}
    end
  end

  def handle_event("select-project", %{"project" => id}, socket) do
    # Switching projects changes the view, never a conversation's project binding.
    if Enum.any?(socket.assigns.projects, &(&1["id"] == id)) do
      {:noreply, socket |> clear_conversation() |> assign(:notice, nil) |> navigate(id, nil)}
    else
      {:noreply, assign(socket, :notice, "That project is not available.")}
    end
  end

  def handle_event("new-chat", _params, socket), do: mutate(socket, :create, [project_id(socket), "New chat"])

  def handle_event("search-threads", %{"query" => query}, socket), do: {:noreply, assign(socket, :thread_query, String.slice(query, 0, 200))}

  def handle_event("retry-chat-list", _params, socket), do: {:noreply, refresh_list(socket)}

  def handle_event("back-to-chats", _params, socket), do: {:noreply, socket |> refresh_list() |> assign(:workspace_view, "list")}

  def handle_event("pin-thread", %{"id" => id, "pinned" => pinned}, socket) when pinned in ["true", "false"] do
    update_list(socket, :pin, [project_id(socket), id, pinned == "true"])
  end

  def handle_event("move-thread", %{"id" => id, "before_id" => before, "project_id" => project, "pinned" => pinned}, socket) when is_boolean(pinned) do
    if project == project_id(socket) and socket.assigns.thread_query == "" do
      update_list(socket, :move, [project_id(socket), id, before, pinned])
    else
      {:noreply, socket}
    end
  end

  def handle_event("move-thread-step", %{"id" => id, "direction" => direction, "pinned" => pinned}, socket) when direction in ["up", "down"] and pinned in ["true", "false"] do
    socket = refresh_list(socket)

    case move_target(socket.assigns.chats, id, direction) do
      {:ok, before} when socket.assigns.thread_query == "" ->
        update_list(socket, :move, [project_id(socket), id, before, pinned == "true"])

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(event, _params, socket) when event in ["pin-thread", "move-thread", "move-thread-step"], do: {:noreply, socket}

  def handle_event("restore-workspace-view", %{"project_id" => project, "chat_id" => chat, "view" => view}, socket) when view in ["list", "conversation"] do
    if BrowserAuth.authorized?(socket.assigns.auth) and project == project_id(socket) and chat == chat_id(socket) and (not socket.assigns.embedded or view == "conversation") and
         (view == "list" or not is_nil(chat)) do
      {:noreply, assign(socket, :workspace_view, view)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore-workspace-view", _params, socket), do: {:noreply, socket}

  def handle_event(event, _params, %{assigns: %{embedded: true}} = socket) when event in ["session-tab", "restore-session-tab"] do
    {:noreply, assign(socket, :session_tab, "chat")}
  end

  def handle_event("session-tab", %{"tab" => tab}, socket) when tab in ["chat", "context", "outputs", "sources"] do
    {:noreply, assign(socket, :session_tab, tab)}
  end

  def handle_event("session-tab", _params, socket), do: {:noreply, socket}

  def handle_event("restore-session-tab", %{"project_id" => project, "chat_id" => chat, "tab" => tab}, socket)
      when tab in ["chat", "context", "outputs", "sources"] do
    if BrowserAuth.authorized?(socket.assigns.auth) and project == project_id(socket) and chat == chat_id(socket) do
      {:noreply, assign(socket, :session_tab, tab)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore-session-tab", _params, socket), do: {:noreply, socket}

  def handle_event("draft", %{"message" => text} = params, socket) do
    {:noreply, if(matching_conversation?(socket, params), do: assign(socket, :draft, String.slice(text, 0, 16_000)), else: socket)}
  end

  def handle_event("send-message", %{"message" => text} = params, socket) do
    text = String.trim(text)

    cond do
      not matching_conversation?(socket, params) -> {:noreply, socket}
      text == "" -> {:noreply, socket}
      byte_size(text) > 16_000 -> {:noreply, assign(socket, :notice, "Keep a message under 16,000 bytes.")}
      true -> send_message(socket, text)
    end
  end

  def handle_event(event, params, socket) when event in ["stop-response", "remove-queued", "prioritize-queued", "resume-queue"] do
    if matching_conversation?(socket, params) do
      case event do
        "stop-response" -> mutate(socket, :stop, [project_id(socket), chat_id(socket)])
        "remove-queued" -> mutate(socket, :remove_queued, [project_id(socket), chat_id(socket), params["id"]])
        "prioritize-queued" -> mutate(socket, :prioritize_queued, [project_id(socket), chat_id(socket), params["id"]])
        "resume-queue" -> mutate(socket, :resume_queue, [project_id(socket), chat_id(socket)])
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("decide", %{"id" => id, "decision" => decision} = params, socket) when decision in ["confirm", "cancel", "reconcile"] do
    if matching_conversation?(socket, params) do
      mutate(socket, :decide, [project_id(socket), chat_id(socket), id, decision])
    else
      {:noreply, socket}
    end
  end

  defp matching_conversation?(socket, params) do
    case params["chat_id"] do
      nil -> not socket.assigns.embedded
      id -> id == (chat_id(socket) || "")
    end
  end

  defp send_message(socket, text) do
    case ensure_chat(socket) do
      {:ok, socket} ->
        args = [project_id(socket), chat_id(socket), text, socket.assigns.client_id, scoped_context(socket.assigns)]

        case call(socket, :send_message_with_context, args) do
          {:ok, chat} ->
            {:noreply,
             socket
             |> put_chat(chat)
             |> assign(:draft, "")
             |> assign(session_tab: "chat", workspace_view: "conversation")
             |> assign(:client_id, nonce())
             |> assign(:notice, nil)
             |> push_event("chat-message-sent", %{chat_id: chat["id"], accepted_text: text})
             |> navigate(project_id(socket), chat["id"])}

          {:error, reason} ->
            {:noreply, show_error(socket, reason)}
        end

      {:error, reason} ->
        {:noreply, show_error(socket, reason)}
    end
  end

  defp navigate(socket, project, chat) do
    send(self(), {:chat_panel, :navigate, %{project_id: project, chat_id: chat}})
    socket
  end

  defp scoped_context(assigns) do
    project = assigns.project && assigns.project["id"]

    case assigns.view_context do
      %{"project_id" => ^project} = context when is_binary(project) -> context
      _ -> nil
    end
  end

  defp ensure_bound_conversation(%{assigns: %{session_id: session}} = socket) when is_binary(session),
    do: call(socket, :ensure_pr_conversation, [project_id(socket), socket.assigns.task_id, session])

  defp ensure_bound_conversation(socket), do: call(socket, :ensure_conversation, [project_id(socket), socket.assigns.task_id])

  defp ensure_chat(%{assigns: %{chat: %{"id" => _id}}} = socket), do: {:ok, socket}

  defp ensure_chat(%{assigns: %{embedded: true}} = socket) do
    case ensure_bound_conversation(socket) do
      {:ok, chat} -> {:ok, put_chat(socket, chat)}
      error -> error
    end
  end

  defp ensure_chat(socket) do
    case call(socket, :create, [project_id(socket), "New chat"]) do
      {:ok, chat} -> {:ok, put_chat(socket, chat)}
      error -> error
    end
  end

  defp mutate(socket, operation, args) do
    case call(socket, operation, args) do
      {:ok, chat} ->
        socket =
          socket
          |> clear_changed_draft(chat["id"])
          |> put_chat(chat)
          |> assign(notice: nil, workspace_view: "conversation")

        {:noreply, navigate(socket, project_id(socket), chat["id"])}

      {:error, reason} ->
        {:noreply, show_error(socket, reason)}
    end
  end

  defp update_list(socket, operation, args) do
    case call(socket, operation, args) do
      {:ok, chats} -> {:noreply, assign(socket, chats: chats, notice: nil, list_error: nil)}
      {:error, reason} -> {:noreply, show_error(socket, reason)}
    end
  end

  defp load_location(socket, params) do
    case call(socket, :projects, []) do
      {:ok, projects} ->
        selected = selected_project(projects, params["project"])
        socket = if selected != socket.assigns.project, do: clear_conversation(socket), else: socket

        socket =
          socket
          |> assign(projects: projects, project: selected, loading: false)
          |> subscribe_project(selected && selected["id"])

        load_selected(socket, params, selected, projects)

      {:error, reason} ->
        socket |> assign(:loading, false) |> show_error(reason)
    end
  end

  defp load_selected(socket, params, selected, projects) do
    cond do
      is_nil(selected) -> assign(socket, :notice, unavailable_project(projects))
      socket.assigns.embedded -> load_canonical(socket)
      params["chat"] -> socket |> refresh_list() |> fetch_chat(params["chat"]) |> assign(:workspace_view, "conversation")
      true -> socket |> clear_conversation(true) |> refresh_list()
    end
  end

  defp load_canonical(socket) do
    case ensure_bound_conversation(socket) do
      {:ok, chat} ->
        socket
        |> clear_changed_draft(chat["id"])
        |> put_chat(chat)
        |> assign(workspace_view: "conversation", session_tab: "chat", pr_query: "", notice: nil)
        |> navigate(project_id(socket), chat["id"])

      {:error, reason} ->
        socket |> clear_conversation(true) |> show_error(reason)
    end
  end

  defp selected_project(projects, nil), do: List.first(projects)
  defp selected_project(projects, id), do: Enum.find(projects, &(&1["id"] == id))
  defp unavailable_project([]), do: "No projects are available for chat."
  defp unavailable_project(_projects), do: "That project is not available. Select a project above."

  defp refresh_list(%{assigns: %{project: nil}} = socket), do: socket

  defp refresh_list(socket) do
    case call(socket, :list, [project_id(socket)]) do
      {:ok, chats} ->
        notice = if socket.assigns.notice == socket.assigns.list_error, do: nil, else: socket.assigns.notice
        assign(socket, chats: chats, list_error: nil, notice: notice)

      {:error, reason} ->
        socket |> show_error(reason) |> assign(:list_error, error_message(reason))
    end
  end

  defp fetch_chat(socket, id) do
    case call(socket, :get, [project_id(socket), id]) do
      {:ok, chat} -> socket |> clear_changed_draft(id) |> put_chat(chat) |> refresh_list()
      {:error, reason} -> socket |> clear_conversation(true) |> show_error(reason) |> refresh_list()
    end
  end

  defp clear_changed_draft(%{assigns: %{chat: %{"id" => id}}} = socket, id), do: socket

  defp clear_changed_draft(socket, id) do
    drafts = socket.assigns.conversation_drafts
    retained = %{draft: socket.assigns.draft, client_id: socket.assigns.client_id, session_tab: socket.assigns.session_tab}
    drafts = if chat_id(socket), do: Map.put(drafts, chat_id(socket), retained), else: drafts
    selected = Map.get(drafts, id, %{draft: "", client_id: nonce(), session_tab: "chat"})
    socket |> assign(:conversation_drafts, drafts) |> assign(selected)
  end

  defp put_chat(socket, chat) do
    socket = subscribe(socket, chat["id"])
    assign(socket, :chat, chat)
  end

  defp clear_conversation(socket, keep_project \\ false) do
    socket = if keep_project, do: socket, else: subscribe_project(socket, nil)

    socket
    |> subscribe(nil)
    |> assign(chat: nil, chats: [], list_error: nil, draft: "", thread_query: "", conversation_drafts: %{})
    |> assign(:pr_query, "")
    |> assign(client_id: nonce(), session_tab: "chat", workspace_view: "list")
  end

  defp subscribe(%{assigns: %{subscribed: id}} = socket, id), do: socket

  defp subscribe(socket, id) do
    if socket.assigns.subscribed, do: Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "chat:" <> socket.assigns.subscribed)
    if id, do: Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat:" <> id)
    assign(socket, :subscribed, id)
  end

  defp subscribe_project(%{assigns: %{project_subscribed: project}} = socket, project), do: socket

  defp subscribe_project(socket, project) do
    if socket.assigns.project_subscribed do
      Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "chat_project:" <> socket.assigns.project_subscribed)
    end

    if project, do: Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat_project:" <> project)
    send(self(), {:chat_panel, :project_subscription, project})
    assign(socket, :project_subscribed, project)
  end

  defp call(socket, operation, args) do
    if BrowserAuth.authorized?(socket.assigns.auth) and not socket.assigns.read_only and is_nil(socket.assigns.unavailable) do
      apply(Endpoint.config(:chat_store, SymphonyElixir.Chat.Store), operation, args ++ [socket.assigns.auth])
    else
      {:error, :unauthorized}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp show_error(socket, reason) do
    socket =
      if reason in [:unauthorized, :forbidden] do
        socket |> clear_conversation() |> assign(projects: [], project: nil)
      else
        socket
      end

    socket =
      if reason in [:unavailable, :chat_disabled, :chat_not_configured] do
        assign(socket, :unavailable, error_message(reason))
      else
        socket
      end

    assign(socket, :notice, error_message(reason))
  end

  defp error_message(reason) when reason in [:unauthorized, :forbidden] do
    if BrowserAuth.google_enabled?(), do: "Sign in with Google to continue.", else: "Your session is locked or has expired. Unlock chat to continue."
  end

  defp error_message(reason) when reason in [:not_found, :chat_not_found, :project_mismatch, :unknown_project, :project_not_found], do: "This conversation is not available in the selected project."
  defp error_message(reason) when reason in [:busy, :chat_busy, :already_running], do: "Wait for the current response or action to finish before continuing."
  defp error_message(reason) when reason in [:stale_revision, :stale_proposal], do: "The task changed since this action was prepared. Ask for a fresh proposal."
  defp error_message(:chat_order_changed), do: "This chat moved between pinned and unpinned. Refresh the list and try again."
  defp error_message(:invalid_chat_order), do: "The chat order changed. Refresh the list and try again within the same group."
  defp error_message(:chat_preferences_unavailable), do: "Chat list preferences are unavailable. We could not confirm saving pinning or ordering; your conversation is retained."
  defp error_message(:invalid_pin), do: "That pin change could not be saved. Refresh the list and try again."
  defp error_message(:unavailable), do: "Chat is temporarily unavailable. Your conversation has been retained; try again."
  defp error_message(:chat_disabled), do: "Chat is not enabled for this service yet."
  defp error_message(:chat_not_configured), do: "Chat is not configured for this service yet."
  defp error_message(reason) when reason in [:chat_storage_unavailable, :chat_storage_locked, :locked], do: "Conversation storage is unavailable or locked. Try again once the service is ready."
  defp error_message(:message_id_conflict), do: "This message could not be matched to its earlier submission. Reload the conversation before sending again."
  defp error_message(:invalid_view_context), do: "This board view could not be attached. Refresh the board before sending again."
  defp error_message(:invalid_message), do: "Enter a message of up to 16,000 bytes before sending."
  defp error_message(:chat_queue_full), do: "This conversation has 20 queued messages. Remove one or wait for a response before adding more."
  defp error_message(:chat_history_full), do: "This conversation has reached its storage limit. Existing messages and queued work are retained."
  defp error_message(:invalid_task_scope), do: "This task is not available in the selected project."
  defp error_message(:queued_message_not_found), do: "That message has already started or was removed. The queue is up to date."
  defp error_message(:chat_capacity), do: "The conversation service is at capacity. Wait for an active response to finish and try again."
  defp error_message(:start_new_chat), do: "This conversation has reached its current limit. Start a new chat to continue."
  defp error_message(:chat_runtime_changed), do: "The conversation runtime has changed. Restore its configured runtime before continuing."
  defp error_message(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp error_message(_reason), do: "The request could not be completed. Refresh the conversation and try again."

  defp project_id(socket), do: socket.assigns.project && socket.assigns.project["id"]
  defp chat_id(socket), do: socket.assigns.chat && socket.assigns.chat["id"]
  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp running?(chat), do: is_map(chat) and chat["status"] == "running"
  defp executing?(chat), do: is_map(chat) and Enum.any?(list(chat["proposals"]), &(&1["status"] == "executing"))
  defp busy?(chat), do: running?(chat) or executing?(chat)
  defp chat_title(nil), do: "New conversation"
  defp chat_title(chat), do: chat["title"] || "Untitled conversation"
  defp project_label(nil), do: "Select a project"
  defp project_label(project), do: project["label"] || project["id"]
  defp queued(nil), do: []
  defp queued(chat), do: list(chat["queue"])
  defp queue_paused?(chat), do: is_map(chat) and chat["queue_paused"] == true
  defp queueing?(chat), do: busy?(chat) or queued(chat) != []
  defp task_identifier(task_id), do: task_id |> String.split(":") |> List.last() |> then(&("#" <> &1))

  defp project_agent_title(project) do
    id = project && project["id"]
    directory = Enum.find(ProjectDirectory.links(), &(&1["id"] == id))
    name = (directory && directory["label"]) || (project && (project["label"] || id))
    if is_binary(name) and String.trim(name) != "", do: String.trim(name) <> " · Project agent", else: "Project agent"
  end

  defp matches_project_agent?(title, query) do
    String.contains?(String.downcase(title <> " project orchestration main chat"), String.downcase(query))
  end

  defp embedded_title(task_id, title), do: if(is_binary(title) and title != "", do: title, else: "Task " <> task_identifier(task_id))
  defp messages(nil), do: []
  defp messages(chat), do: list(chat["messages"])

  defp empty_response?(message) do
    message["role"] == "assistant" and message["status"] in [nil, "completed"] and
      String.trim(text(message["text"])) == "" and list(message["widgets"]) == []
  end

  defp message_timestamp(assigns) do
    assigns = assign(assigns, :time, message_time(assigns.value))

    ~H"""
    <time :if={@time} class={@class} datetime={@time.iso} title={@label <> ": " <> @time.full}
      aria-label={@label <> ": " <> @time.full} data-chat-timestamp data-time-label={@label}>{@time.short}</time>
    """
  end

  defp message_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        %{
          iso: DateTime.to_iso8601(datetime),
          short: Calendar.strftime(datetime, "%b %-d, %H:%M UTC"),
          full: Calendar.strftime(datetime, "%B %-d, %Y at %H:%M:%S UTC")
        }

      _ ->
        nil
    end
  end

  defp message_time(_value), do: nil
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value), do: to_string(value)
  defp text(_value), do: ""
  defp widget_type(widget), do: map(widget)["type"]
  defp output_widgets(chat), do: Enum.flat_map(messages(chat), &list(&1["widgets"]))
  defp retained_contexts(chat), do: messages(chat) |> Enum.filter(&is_map(&1["view_context"])) |> Enum.reverse()
  defp context_items(nil), do: []
  defp context_items(chat), do: list(chat["context"])

  defp matching_chats(chats, query) do
    Enum.filter(chats, &(not &1["archived"] and String.contains?(String.downcase(chat_title(&1) <> " " <> text(&1["snippet"])), String.downcase(query))))
  end

  defp thread_group(chats, pinned), do: Enum.filter(chats, &(not &1["archived"] and &1["pinned"] == true == pinned))

  defp move_target(chats, id, direction) do
    with %{} = chat <- Enum.find(chats, &(&1["id"] == id)),
         group = thread_group(chats, chat["pinned"] == true),
         index when is_integer(index) <- Enum.find_index(group, &(&1["id"] == id)) do
      case direction do
        "up" when index > 0 -> {:ok, Enum.at(group, index - 1)["id"]}
        "down" when index < length(group) - 1 -> {:ok, get_in(Enum.at(group, index + 2), ["id"])}
        _ -> :boundary
      end
    else
      _ -> :boundary
    end
  end

  defp selected_title(nil, _chats), do: "New conversation"
  defp selected_title(chat, chats), do: chat_title(Enum.find(chats, &(&1["id"] == chat["id"])) || chat)

  defp compact_updated_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> "Updated " <> Calendar.strftime(datetime, "%b %-d")
      _ -> "Updated time unknown"
    end
  end

  defp compact_updated_at(_), do: "Updated time unknown"
  defp thread_status(chat), do: text(chat["display_status"] || chat["status"] || "new")

  defp thread_status_label(chat) do
    Map.get(
      %{
        "running" => "Running",
        "action" => "Running action",
        "needs_reconciliation" => "Check outcome",
        "awaiting_confirmation" => "Awaiting confirmation",
        "error" => "Error",
        "interrupted" => "Interrupted",
        "queued" => "Queued",
        "queue_paused" => "Queue paused",
        "idle" => "Idle"
      },
      thread_status(chat),
      "New"
    )
  end

  defp chat_path(project, id \\ nil) do
    params = if project, do: %{"project" => project}, else: %{}
    params = if id, do: Map.put(params, "chat", id), else: params
    if params == %{}, do: "/chat", else: "/chat?" <> URI.encode_query(params)
  end

  defp board_path(project), do: if(project, do: "/?" <> URI.encode_query(%{"project" => project}), else: "/")

  defp safe_url(value) when is_binary(value) do
    if String.contains?(value, ["\\", "\n", "\r", "\t"]), do: nil, else: safe_uri(URI.parse(value), value)
  end

  defp safe_url(_value), do: nil
  defp safe_uri(%URI{scheme: scheme, host: host, userinfo: nil}, value) when scheme in ["http", "https"] and is_binary(host) and host != "", do: value
  defp safe_uri(%URI{scheme: nil, host: nil}, "/" <> rest = value), do: if(String.starts_with?(rest, "/"), do: nil, else: value)
  defp safe_uri(_uri, _value), do: nil

  defp board_link?(url, project) when is_binary(url) and is_binary(project) do
    case URI.parse(url) do
      %URI{scheme: nil, host: nil, path: "/", query: query, fragment: nil} when is_binary(query) ->
        params = URI.decode_query(query)

        safe_url(url) == url and params["project"] == project and Enum.all?(Map.keys(params), &(&1 in ~w(project status priority q sort task))) and
          (is_nil(params["task"]) or String.starts_with?(params["task"], project <> ":"))

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp board_link?(_url, _project), do: false

  defp reference_url(url, project) do
    safe = safe_url(url)

    if is_binary(safe) and String.starts_with?(safe, "/?") do
      if board_link?(safe, project && project["id"]), do: safe
    else
      safe
    end
  end

  @impl true
  def render(assigns) do
    project = assigns.project && assigns.project["id"]
    issue = Enum.find(assigns.issue_tasks, &(&1.id == assigns.task_id and &1.project == project))
    prs = if issue, do: ChatNavigation.pull_requests(issue), else: []
    retained = assigns.chats |> Enum.filter(&(&1["task_id"] == assigns.task_id)) |> Enum.map(& &1["session_id"])
    sessions = Sessions.options(issue, [assigns.session_id | retained])
    selected_session = Enum.find(sessions, &(&1.id == assigns.session_id))

    assigns =
      assign(assigns,
        issue: issue,
        project_agent_title: project_agent_title(assigns.project),
        issue_groups: ChatNavigation.issues(assigns.issue_tasks, assigns.issue_activity, project, assigns.issue_query),
        issue_sessions: matching_sessions(sessions, assigns.pr_query),
        selected_session: selected_session,
        pr_evidence: pr_evidence(issue && issue[:github_status], length(prs)),
        authorized: BrowserAuth.authorized?(assigns.auth),
        google_auth: BrowserAuth.google_enabled?(),
        running: running?(assigns.chat),
        executing: executing?(assigns.chat),
        busy: busy?(assigns.chat),
        queued: queued(assigns.chat),
        queue_paused: queue_paused?(assigns.chat),
        queueing: queueing?(assigns.chat),
        current_context: scoped_context(assigns),
        artifacts: Artifacts.entries(assigns.chat)
      )

    ~H"""
    <section id="chat-app" class={"chat-shell chat-panel #{if @embedded, do: "embedded-chat", else: ""}"} phx-hook="ChatWorkspace" data-embedded={to_string(@embedded)} data-chat-id={@chat && @chat["id"]} data-project={@project && @project["id"]} data-event-target={@myself} data-running={to_string(@running)} data-session-tab={@session_tab} data-workspace-view={@workspace_view}>
      <header class="board-header chat-header">
        <a :if={!@embedded} href="/" class="brand">∿ Symphony</a>
        <nav :if={!@embedded} class="workspace-tabs" aria-label="Workspace"><a href={board_path(@project && @project["id"])}>Board</a><a href={chat_path(@project && @project["id"])} aria-current="page">Chat</a></nav>
        <details :if={@embedded && @authorized && is_nil(@unavailable)} id="issue-switcher" class="issue-switcher" phx-hook="IssueSwitcher">
          <summary aria-label="Choose issue conversation"><span>{if @task_id, do: embedded_title(@task_id, @task_title), else: @project_agent_title}</span><span aria-hidden="true">⌄</span></summary>
          <div class="issue-switcher-menu">
            <form phx-change="search-issues" phx-target={@myself} role="search">
              <input id="issue-search" name="query" value={@issue_query} placeholder="Search issues, categories or activity…" autocomplete="off"
                role="combobox" aria-label="Search issue conversations" aria-autocomplete="list" aria-expanded="false" aria-controls="issue-options" phx-debounce="150" />
            </form>
            <div id="issue-options" class="issue-options" role="listbox" aria-label="Issues by category and activity">
              <button :if={matches_project_agent?(@project_agent_title, @issue_query)} id="issue-option-main" type="button" role="option" aria-selected={to_string(is_nil(@task_id))}
                phx-click="main-chat" phx-target={@myself} class="issue-option issue-option-main"><span class="issue-option-name">{@project_agent_title}</span><span>Create tasks, coordinate work, and report progress</span></button>
              <div :for={group <- @issue_groups} role="group" aria-label={group.label} class="issue-option-group" data-issue-category={group.id}>
                <div class="issue-group-label">{group.label}<span>{length(group.issues)}</span></div>
                <button :for={item <- group.issues} id={"issue-option-" <> Base.url_encode64(item.id, padding: false)} type="button" role="option" aria-selected={to_string(@task_id == item.id)}
                  phx-click="select-issue" phx-value-id={item.id} phx-target={@myself} class="issue-option" data-issue-id={item.id}>
                  <span class="issue-option-title"><span>{item.identifier}</span><span class="issue-option-name">{item.title}</span></span>
                  <span class="issue-option-meta">
                    <time :if={item.created_at} datetime={item.created_at} title={"Created " <> item.created_at}>{compact_created_at(item.created_at)}</time>
                    <span :if={is_nil(item.created_at)} title="Creation time unavailable">Created —</span>
                    <span class="issue-option-priority" data-priority={item.priority || "none"} title={if item.priority, do: "Priority P#{item.priority}", else: "Priority not set"}>{if item.priority, do: "P#{item.priority}", else: "Priority —"}</span>
                    <span class="issue-option-pr-count" title={pr_evidence(item.github_status, item.pull_request_count).message || "Pull requests attributed to this issue"}>{issue_pr_count(item)}</span>
                    <time :if={item.activity_at} class="issue-option-updated" datetime={item.activity_at} title={item.activity_label <> ": " <> item.activity_at}>{compact_updated_at(item.activity_at)}</time>
                  </span>
                  <span :if={item.preview not in [nil, ""]} class="issue-option-preview">{item.preview}</span>
                </button>
              </div>
              <p :if={@issue_groups == [] && @issue_query != ""} class="issue-options-empty">No matching issues. Try a category, issue number or recent activity.</p>
            </div>
          </div>
        </details>
        <span :if={@embedded && (!@authorized || !is_nil(@unavailable))}>{if @task_id, do: "Issue chat", else: @project_agent_title}</span><span class="header-spacer"></span>
        <button :if={!@embedded && @authorized && is_nil(@unavailable)} id="new-chat-button" class="button button-primary" phx-target={@myself} phx-click="new-chat" disabled={is_nil(@project)}>+ New chat</button>
      </header>

      <div :if={@authorized && is_nil(@unavailable)} class="chat-toolbar">
        <form :if={!@embedded} phx-target={@myself} phx-change="select-project" class="chat-project-filter">
          <label for="chat-project">Project</label>
          <select id="chat-project" name="project" aria-label="Chat project">
            <option :if={is_nil(@project)} value="">Select a project</option>
            <option :for={project <- @projects} value={project["id"]} selected={@project && @project["id"] == project["id"]}>{project_label(project)}</option>
          </select>
        </form>
        <button :if={!@embedded && @workspace_view == "conversation"} id="back-to-chats" class="button button-quiet" phx-target={@myself} phx-click="back-to-chats" aria-label="Back to chats">← Chats</button>
        <div :if={!@embedded} class="chat-title"><strong>{if @workspace_view == "list", do: "Chats", else: selected_title(@chat, @chats)}</strong><span class="muted">{if @workspace_view == "list", do: project_label(@project), else: conversation_status(@chat)}</span></div>
        <div :if={@embedded && @issue} class="issue-chat-identity">
          <details id="issue-pr-menu" class="issue-pr-menu" phx-hook="IssuePRMenu">
            <summary aria-label="Pull requests for this issue">
              <span class="issue-pr-selected">{if @selected_session, do: @selected_session.title, else: "Main thread"}</span><span :if={@selected_session} class="pr-state">{@selected_session.status}</span>
              <span class="issue-pr-count">{@pr_evidence.label}</span>
              <span :if={@chat && thread_status(@chat) not in ["idle", "new"]} class="issue-chat-activity" data-status={thread_status(@chat)}>{thread_status_label(@chat)}</span>
              <svg class="issue-pr-chevron" width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="m4 6 4 4 4-4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
            </summary>
            <div class="issue-pr-list">
              <form class="issue-pr-search" phx-change="search-prs" phx-submit="search-prs" phx-target={@myself} role="search">
                <input id="issue-pr-search" type="search" name="query" value={@pr_query} placeholder="Search pull requests or status…" aria-label="Search pull requests" autocomplete="off" phx-debounce="150" />
              </form>
              <div class="issue-pr-results">
              <button id="pr-session-main" type="button" class="issue-pr-select issue-pr-main" aria-pressed={to_string(is_nil(@session_id))}
                phx-click="select-pr-session" phx-value-id="" phx-target={@myself}><strong>Main thread</strong><span>Coordinate this issue and all its PRs</span></button>
              <p :if={@pr_evidence.message} class="issue-options-empty" role="status">{@pr_evidence.message}</p>
              <div :for={session <- @issue_sessions} class="issue-pr-option" data-pr-number={session.pr && session.pr.number} data-session-id={session.id}>
                <button type="button" class="issue-pr-select" aria-pressed={to_string(@session_id == session.id)}
                  phx-click="select-pr-session" phx-value-id={session.id} phx-target={@myself}>
                  <span>{session.title}</span><span class="pr-state" data-pr-state={session.pr && session.pr.state}>{session.status}</span>
                </button>
                <div :if={session.pr} class="issue-pr-meta">
                  <a :if={session.pr.url} href={session.pr.url} target="_blank" rel="noopener noreferrer">GitHub ↗</a>
                  <span>Review: {String.capitalize(String.replace(session.pr.review, "_", " "))}</span>
                  <a :if={session.pr.checks_url} href={session.pr.checks_url} target="_blank" rel="noopener noreferrer">CI: {String.capitalize(session.pr.ci)} ↗</a>
                  <span :if={session.work}>{session.work.phase}</span>
                </div>
              </div>
              <p :if={@pr_query != "" && @issue_sessions == []} class="issue-options-empty">No matching pull requests.</p>
              </div>
            </div>
          </details>
        </div>
        <div :if={@embedded && is_nil(@issue)} class="chat-title chat-bound-title"><span class="muted">{project_label(@project)} · {conversation_status(@chat)}</span></div>
      </div>

      <div :if={!@embedded && !@loading && @authorized && is_nil(@unavailable)} hidden={@workspace_view == "list"} class="chat-session-tabs workspace-tabs" role="tablist" aria-label="Conversation workspace">
        <button :for={{tab, label} <- [{"chat", "Chat"}, {"context", "Context"}, {"outputs", "Outputs"}, {"sources", "Sources"}]} id={"session-#{tab}-tab"} role="tab" aria-selected={to_string(@session_tab == tab)} aria-controls={"session-#{tab}-content"} tabindex={if @session_tab == tab, do: "0", else: "-1"} phx-target={@myself} phx-click="session-tab" phx-value-tab={tab}>{label}<span :if={tab == "outputs" && @artifacts != []} class="chat-tab-count">{length(@artifacts)}</span><span :if={tab == "sources" && context_items(@chat) != []} class="chat-tab-count">{length(context_items(@chat))}</span></button>
      </div>

      <p :if={@notice} class="board-warning chat-notice" role="status">{@notice}</p>

      <div :if={!@loading && @unavailable} class="chat-empty chat-unavailable" role="status"><h2>Chat unavailable</h2><p>{@unavailable}</p></div>

      <div :if={@loading} class="chat-empty" role="status"><span class="chat-orbit" aria-hidden="true">∿</span><h1>Opening your workspace</h1><p>Connecting to your project conversations…</p></div>

      <div :if={!@loading && !@authorized && is_nil(@unavailable)} class="chat-empty chat-login">
        <span class="chat-orbit" aria-hidden="true">∿</span><h1>Your project conversations</h1>
        <p>{if @google_auth, do: "Sign in to read chat history and manage work.", else: "Unlock this browser to read chat history and manage work."}</p>
        <form :if={@google_auth} action="/auth/google" method="post" class="chat-login-form">
          <input type="hidden" name="_csrf_token" value={@csrf_token} /><input type="hidden" name="return_to" value={if @embedded, do: "/?assistant=1", else: "/chat"} />
          <button class="button button-primary">Sign in with Google</button>
        </form>
        <form :if={!@google_auth} action="/operator/session" method="post" class="chat-login-form">
          <input type="hidden" name="_csrf_token" value={@csrf_token} /><input type="hidden" name="return_to" value={if @embedded, do: "/?assistant=1", else: "/chat"} />
          <label class="field">Operator token<input type="password" name="operator_token" autocomplete="off" required /></label>
          <button class="button button-primary">Unlock chat</button>
        </form>
        <p class="muted">{if @google_auth, do: "Use a Google account authorized for this Symphony service.", else: "Use the local operator token configured for this service."}</p>
      </div>

      <div :if={!@loading && @authorized && is_nil(@unavailable)} class="chat-workspace">
        <main class="chat-main">
          <section :if={!@embedded} id="chat-thread-list" class="chat-history-view" aria-label="Project chats" hidden={@workspace_view != "list"}>
            <p :if={@list_error} class="board-warning" role="alert">The chat list could not be loaded. Retained conversations have not been removed. <button type="button" class="button" phx-target={@myself} phx-click="retry-chat-list">Retry</button></p>
            <form id="chat-thread-search" phx-target={@myself} phx-change="search-threads"><label class="field"><span class="visually-hidden">Search chats</span><input type="search" name="query" value={@thread_query} placeholder="Search chats…" phx-debounce="150" /></label></form>
            <p :if={@thread_query != ""} class="chat-list-hint">Clear search to reorder chats.</p>
            <section :for={{pinned, label} <- [{true, "Pinned"}, {false, "Chats"}]} class="chat-list-group" data-pin-group={to_string(pinned)} aria-label={label}>
              <h2>{label}</h2>
              <div class="conversation-list">
                <div :for={chat <- thread_group(matching_chats(@chats, @thread_query), pinned)} id={"thread-#{chat["id"]}"} class="conversation-item" data-thread-id={chat["id"]} data-pinned={to_string(pinned)} data-selected={to_string(@chat && @chat["id"] == chat["id"] || false)}>
                  <button type="button" class="thread-drag-handle" data-thread-drag={chat["id"]} draggable={to_string(@thread_query == "")} disabled={@thread_query != ""} aria-label={"Drag to reorder #{chat_title(chat)}"} title="Drag to reorder; or use Move up and Move down">⠿</button>
                  <button type="button" phx-target={@myself} phx-click="open-chat" phx-value-id={chat["id"]} class="thread-open" aria-current={if @chat && @chat["id"] == chat["id"], do: "page", else: nil}>
                    <span class="thread-title-line"><strong>{chat_title(chat)}</strong><span class="thread-status" data-status={thread_status(chat)}>{thread_status_label(chat)}</span></span>
                    <span :if={text(chat["snippet"]) != ""} class="thread-snippet">{text(chat["snippet"])}</span>
                    <time :if={chat["updated_at"]} datetime={chat["updated_at"]} title={"Updated " <> text(chat["updated_at"])}>{compact_updated_at(chat["updated_at"])}</time>
                  </button>
                  <div class="thread-actions">
                    <button type="button" phx-target={@myself} phx-click="pin-thread" phx-value-id={chat["id"]} phx-value-pinned={to_string(!pinned)} aria-label={if pinned, do: "Unpin #{chat_title(chat)}", else: "Pin #{chat_title(chat)}"} title={if pinned, do: "Unpin chat", else: "Pin chat"}>{if pinned, do: "★", else: "☆"}</button>
                    <button type="button" phx-target={@myself} phx-click="move-thread-step" phx-value-id={chat["id"]} phx-value-direction="up" phx-value-pinned={to_string(pinned)} disabled={@thread_query != "" || move_target(@chats, chat["id"], "up") == :boundary} aria-label={"Move up #{chat_title(chat)}"} title="Move up">↑</button>
                    <button type="button" phx-target={@myself} phx-click="move-thread-step" phx-value-id={chat["id"]} phx-value-direction="down" phx-value-pinned={to_string(pinned)} disabled={@thread_query != "" || move_target(@chats, chat["id"], "down") == :boundary} aria-label={"Move down #{chat_title(chat)}"} title="Move down">↓</button>
                  </div>
                </div>
              </div>
              <p :if={is_nil(@list_error) && pinned && thread_group(matching_chats(@chats, @thread_query), true) == [] && @thread_query == ""} class="chat-list-hint">Pin a chat to keep it here.</p>
            </section>
            <p :if={is_nil(@list_error) && matching_chats(@chats, @thread_query) == []} class="chat-detail-empty">{if @thread_query == "", do: "No chats yet. Start a new chat for this project.", else: "No chats match your search."}</p>
          </section>
          <div id="chat-conversation-detail" class="chat-conversation-detail" hidden={@workspace_view != "conversation"}>
          <div id="session-chat-content" class="chat-scroll" role={if @embedded, do: "region", else: "tabpanel"} tabindex="0" aria-label={if @embedded, do: "Conversation"} aria-labelledby={if !@embedded, do: "session-chat-tab"} hidden={!@embedded && @session_tab != "chat"}>
            <div :if={messages(@chat) == []} class="chat-empty">
              <span class="chat-orbit" aria-hidden="true">∿</span><h1>{if @embedded && @task_id, do: "Let’s work on this task", else: "What’s next for #{project_label(@project)}?"}</h1>
              <p>{if @embedded && @task_id, do: "Discuss progress, clarify the scope, or plan the next step. This chat stays with the task.", else: "Plan work, create or update tasks, and review project progress."}</p>
              <div :if={!@embedded || is_nil(@task_id)} class="chat-starters">
                <button type="button" data-chat-prompt="What is running and what is blocked?">What needs attention? <span aria-hidden="true">↗</span></button>
                <button type="button" data-chat-prompt="Show the current tasks and help me choose what to work on next.">Help me plan the next step <span aria-hidden="true">↗</span></button>
                <button type="button" data-chat-prompt="Help me write a clear new task with acceptance criteria.">Shape a new task <span aria-hidden="true">↗</span></button>
              </div>
            </div>

            <div id="chat-messages" class="chat-messages" aria-live="off">
              <article :for={message <- messages(@chat)} id={"message-#{message["id"]}"} class={"chat-message chat-message-#{if message["role"] == "user", do: "user", else: "assistant"}"}>
                <div class="message-meta"><strong>{if(message["role"] == "user", do: "You", else: if(message["origin"] == "pr_update", do: "PR update", else: "Symphony"))}</strong><.message_timestamp value={message["created_at"]} label={if message["origin"] == "pr_update", do: "Observed", else: if(message["role"] == "user", do: "Sent", else: "Response started")} class="message-time" /><span :if={message["status"] == "streaming"} class="streaming-mark">Responding</span><span :if={message["role"] == "assistant" && message["status"] in ["interrupted", "error"]} class="message-outcome">{if message["status"] == "interrupted", do: "Stopped", else: "Failed"}</span></div>
                <div :if={String.trim(text(message["text"])) != ""} class="message-text">{text(message["text"])}</div>
                <span :if={empty_response?(message)} class="chat-empty-response">No text response.</span>
                <span :if={message["status"] in ["streaming", "pending"] && String.trim(text(message["text"])) == ""} class="chat-thinking" role="status">Working<span aria-hidden="true"> ···</span></span>
                <div :if={list(message["widgets"]) != []} class="chat-widgets">
                  <.widget :for={widget <- list(message["widgets"])} widget={map(widget)} project={@project} busy={@busy} myself={@myself} embedded={@embedded} chat_id={@chat && @chat["id"]} />
                </div>
              </article>
            </div>
            <p :if={@chat && @chat["status"] == "interrupted"} class="chat-response-status" role="status">Response stopped. Coding tasks continue independently.</p>
            <p :if={@chat && @chat["error"]} class="board-warning" role="alert">{text(@chat["error"])}</p>
          </div>

          <div :if={!@embedded} id="session-context-content" class="chat-detail-panel" role="tabpanel" tabindex="0" aria-labelledby="session-context-tab" hidden={@session_tab != "context"}>
            <h2>Context</h2><p class="muted">{project_label(@project)} · This conversation stays in this project.</p>
            <section class="chat-context-section"><h3>Next message</h3>
              <p class="muted">The current board view is attached automatically. Task information does not approve an action.</p>
              <.context_snapshot :if={@current_context} context={@current_context} />
              <p :if={!@current_context} class="muted">No matching board context is available. Messages and retrieved sources remain in this conversation.</p>
            </section>
            <section class="chat-context-section"><h3>Retained with messages</h3><p class="muted">Earlier snapshots are preserved with their messages; they do not describe the current screen.</p>
              <p :if={retained_contexts(@chat) == []} class="chat-detail-empty">No board snapshots yet.</p>
              <article :for={message <- retained_contexts(@chat)} class="retained-context"><p class="context-message">{text(message["text"])}</p><.context_snapshot context={message["view_context"]} /></article>
            </section>
          </div>
          <div :if={!@embedded} id="session-outputs-content" class="chat-detail-panel" role="tabpanel" tabindex="0" aria-labelledby="session-outputs-tab" hidden={@session_tab != "outputs"}>
            <h2>Outputs</h2><p class="muted">The latest 100 issues, pull requests and action results retained in this conversation. Status reflects the recorded observation; earlier tool results remain below.</p>
            <p :if={output_widgets(@chat) == []} class="chat-detail-empty">No outputs yet.</p>
            <div class="chat-artifacts"><.artifact :for={artifact <- @artifacts} artifact={artifact} /></div>
            <div :if={@session_tab == "outputs" && output_widgets(@chat) != []} class="chat-widgets"><h3>Tool results and actions</h3><.widget :for={widget <- output_widgets(@chat)} widget={map(widget)} project={@project} busy={@busy} myself={@myself} embedded={@embedded} chat_id={@chat && @chat["id"]} /></div>
          </div>
          <div :if={!@embedded} id="session-sources-content" class="chat-detail-panel" role="tabpanel" tabindex="0" aria-labelledby="session-sources-tab" hidden={@session_tab != "sources"}>
            <h2>Sources</h2><p class="muted">References retrieved for this conversation, with the recorded revision or observation time when available.</p>
            <p :if={context_items(@chat) == []} class="chat-detail-empty">Sources appear here as the agent retrieves them.</p>
            <div :for={item <- context_items(@chat)} class="context-reference">
              <a :if={reference_url(map(item)["url"], @project)} href={reference_url(map(item)["url"], @project)}>{text(map(item)["title"] || map(item)["label"] || map(item)["url"])}</a>
              <strong :if={!reference_url(map(item)["url"], @project)}>{text(map(item)["title"] || map(item)["label"] || map(item)["type"])}</strong>
              <p :if={map(item)["summary"]}>{text(map(item)["summary"])}</p><small>{text(map(item)["revision"] || map(item)["checked_at"])}</small>
            </div>
          </div>
          <div id={"chat-composer-wrap-#{@chat && @chat["id"] || "new"}"} class="chat-composer-wrap">
            <p :if={@session_tab != "chat" && @chat && @chat["error"]} class="board-warning" role="alert">{text(@chat["error"])}</p>
            <p :if={@session_tab != "chat" && @busy} class="chat-response-status" role="status">{conversation_status(@chat)} Open Chat to follow the response.</p>
            <p id="chat-live-status" class="visually-hidden" role="status" aria-live="polite">{if @busy, do: conversation_status(@chat), else: "Ready for your message."}</p>
            <section :if={@queued != []} id="chat-queue" class="chat-queue" aria-label="Queued messages">
              <div class="chat-queue-heading"><strong>{length(@queued)} queued</strong><span>{if @queue_paused, do: "Paused", else: if(@busy, do: "After the current response", else: "Waiting to send")}</span><button :if={@queue_paused && !@busy} id="resume-queue-button" type="button" class="button button-quiet" phx-target={@myself} phx-click="resume-queue" phx-value-chat_id={@chat["id"]}>Resume queue</button></div>
              <ol>
                <li :for={{message, index} <- Enum.with_index(@queued)} id={"queued-#{message["id"]}"} class="chat-queued-message">
                  <span class="chat-queue-position" aria-hidden="true">{index + 1}</span><div class="chat-queued-content"><p title={text(message["text"])}>{text(message["text"])}</p><.message_timestamp value={message["created_at"]} label="Queued" class="message-time queue-time" /></div>
                  <div class="chat-queue-actions"><button :if={index > 0} type="button" class="button button-quiet" phx-target={@myself} phx-click="prioritize-queued" phx-value-id={message["id"]} phx-value-chat_id={@chat["id"]} title="Send this message next without interrupting the current response">Send next</button><button type="button" class="button button-quiet" phx-target={@myself} phx-click="remove-queued" phx-value-id={message["id"]} phx-value-chat_id={@chat["id"]} aria-label={"Remove queued message #{index + 1}"} title="Remove queued message">×</button></div>
                </li>
              </ol>
            </section>
            <form id="chat-composer" phx-target={@myself} phx-submit="send-message" phx-change="draft" class="chat-composer">
              <input type="hidden" name="chat_id" value={@chat && @chat["id"] || ""} />
              <label for="chat-message-input" class="visually-hidden">Message {project_label(@project)}</label>
              <textarea id="chat-message-input" name="message" placeholder={"Message #{project_label(@project)}…"} rows="2" maxlength="16000" disabled={is_nil(@project)}>{@draft}</textarea>
              <div class="composer-bottom"><span class="composer-project">{project_label(@project)}</span>
                <button :if={@running} id="stop-response-button" type="button" class="button" phx-target={@myself} phx-click="stop-response" phx-value-chat_id={@chat["id"]} title="Stop this response; coding tasks keep running">■ Stop</button>
                <button id="send-message-button" class="button button-primary" disabled={is_nil(@project)} phx-disable-with="Sending…" aria-label={if @queueing, do: "Queue message", else: "Send message"}>{if @queueing, do: "Queue ↑", else: "Send ↑"}</button>
              </div>
            </form>
            <p class="composer-hint">Enter to send · Shift + Enter for a new line<span class="chat-connection"><span class="status-badge-offline">Disconnected · reconnecting</span></span></p>
          </div>
          </div>
        </main>

      </div>

    </section>
    """
  end

  defp context_snapshot(assigns) do
    ~H"""
    <div class="chat-context-snapshot">
      <p>{visible_tasks_label(@context)}<span :if={filter_summary(@context) != ""}> · {filter_summary(@context)}</span></p>
      <p :if={@context["selected_task_id"]} class="muted">Selected task: {text(@context["selected_task_id"])}</p>
      <p :if={list(@context["visible_task_ids"]) != []} class="context-task-ids">{Enum.join(list(@context["visible_task_ids"]), ", ")}</p>
      <p :if={@context["truncated"]} class="muted">Only the first {length(list(@context["visible_task_ids"]))} matching cards are included.</p>
      <small :if={@context["captured_at"]}>Captured {text(@context["captured_at"])}</small>
    </div>
    """
  end

  defp artifact(assigns) do
    ~H"""
    <article class="chat-artifact" data-artifact-kind={@artifact["kind"]}>
      <div class="widget-heading"><span class="artifact-kind">{String.replace(@artifact["kind"], "_", " ")}</span><span :if={@artifact["status"]} class="widget-label">{text(@artifact["status"])}</span></div>
      <a :if={safe_url(@artifact["url"])} href={safe_url(@artifact["url"])}>{text(@artifact["title"])}</a><strong :if={!safe_url(@artifact["url"])}>{text(@artifact["title"])}</strong>
      <dl :if={list(@artifact["metrics"]) != []} class="artifact-metrics"><div :for={metric <- list(@artifact["metrics"])}><dt>{text(metric["label"])}</dt><dd>{text(metric["value"])}</dd></div></dl>
      <div class="artifact-times"><small :if={@artifact["created_at"]}>Created {text(@artifact["created_at"])}</small><small :if={@artifact["updated_at"]}>Updated {text(@artifact["updated_at"])}</small><small :if={@artifact["checked_at"]}>Observed {text(@artifact["checked_at"])}</small></div>
    </article>
    """
  end

  defp visible_tasks_label(context) do
    count = length(list(context["visible_task_ids"]))
    "#{count} visible #{if count == 1, do: "task", else: "tasks"}"
  end

  defp filter_summary(context) do
    filters = map(context["filters"])

    [
      list(filters["status"]) |> Enum.map_join(", ", &text/1),
      list(filters["priority"]) |> Enum.map_join(", ", &text/1),
      if(text(filters["q"]) != "", do: "Search: #{text(filters["q"])}", else: ""),
      if(text(filters["sort"]) != "", do: "Sort: #{text(filters["sort"])}", else: "")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp conversation_status(chat) do
    cond do
      running?(chat) -> "Responding…"
      executing?(chat) -> "Applying action…"
      queue_paused?(chat) and queued(chat) != [] -> "Queue paused"
      queued(chat) != [] -> "Queued"
      true -> "Ready"
    end
  end

  defp widget(assigns) do
    assigns = assign(assigns, type: widget_type(assigns.widget), task: map(assigns.widget["task"]))

    ~H"""
    <section :if={@type in ["tasks", "task", "status", "proposal", "receipt"]} class={"chat-widget chat-widget-#{@type}"}>
      <div :if={@type == "tasks"}>
        <div class="widget-heading"><strong>{text(@widget["title"] || "Tasks")}</strong><a :if={reference_url(@widget["url"], @project)} href={reference_url(@widget["url"], @project)} phx-target={@myself} phx-click={if @embedded && board_link?(@widget["url"], @project && @project["id"]), do: "board-link"} phx-value-url={@widget["url"]}>Open filtered board ↗</a></div>
        <.source_state widget={@widget} />
        <p :if={list(@widget["tasks"]) == [] && !source_failed?(@widget)} class="muted">No tasks matched these filters.</p>
        <.task_reference :for={task <- list(@widget["tasks"])} task={map(task)} project={@project} myself={@myself} embedded={@embedded} filters={map(@widget["filters"])} />
      </div>
      <.task_reference :if={@type == "task"} task={Map.put_new(@task, "url", @widget["url"])} project={@project} myself={@myself} embedded={@embedded} filters={map(@widget["filters"])} />
      <div :if={@type == "status"}>
        <div class="widget-heading"><strong>Project status</strong><a :if={reference_url(@widget["url"], @project)} href={reference_url(@widget["url"], @project)} phx-target={@myself} phx-click={if @embedded && board_link?(@widget["url"], @project && @project["id"]), do: "board-link"} phx-value-url={@widget["url"]}>Open board ↗</a></div>
        <.source_state widget={@widget} />
        <p>{text(@widget["summary"])}</p>
        <p :if={map(@widget["control"])["mode"]} class="muted">Execution: {text(map(@widget["control"])["mode"])}</p>
        <dl :if={map(@widget["counts"]) != %{} && !source_failed?(@widget)} class="status-counts"><div :for={{label, value} <- Enum.sort(map(@widget["counts"]))}><dt>{text(label)}</dt><dd>{text(value)}</dd></div></dl>
        <div :if={list(@widget["blockers"]) != []} class="widget-blockers"><strong>Needs attention</strong><.task_reference :for={task <- list(@widget["blockers"])} task={map(task)} project={@project} myself={@myself} embedded={@embedded} filters={%{"status" => "attention"}} /></div>
      </div>
      <div :if={@type == "proposal"}>
        <div class="widget-heading"><strong>{text(@widget["title"] || "Proposed action")}</strong><span class="widget-label">{text(@widget["status"] || "pending")}</span></div>
        <p class="message-text">{proposal_details(@widget)}</p>
        <div :if={@widget["status"] in [nil, "pending"]} class="dialog-actions"><button class="button button-primary" phx-target={@myself} phx-click="decide" phx-value-chat_id={@chat_id} phx-value-id={@widget["id"]} phx-value-decision="confirm" disabled={@busy} phx-disable-with="Confirming…">Confirm action</button><button class="button" phx-target={@myself} phx-click="decide" phx-value-chat_id={@chat_id} phx-value-id={@widget["id"]} phx-value-decision="cancel" disabled={@busy} phx-disable-with="Cancelling…">Cancel</button></div>
        <p :if={@widget["status"] in [nil, "pending"]} class="muted widget-footnote">Nothing changes until you confirm this action.</p>
        <p :if={@widget["status"] == "executing"} class="muted" role="status">Applying action…</p>
        <p :if={@widget["status"] == "failed"} class="board-warning" role="alert">Action failed: {text(@widget["error"] || "The action could not be completed.")}</p>
        <div :if={@widget["status"] == "unknown"}><p class="muted">The outcome is uncertain. Check the recorded result before trying another action.</p><button class="button" phx-target={@myself} phx-click="decide" phx-value-chat_id={@chat_id} phx-value-id={@widget["id"]} phx-value-decision="reconcile" disabled={@busy} phx-disable-with="Checking…">Check outcome</button></div>
      </div>
      <div :if={@type == "receipt"} class="action-receipt"><span aria-hidden="true">✓</span><div><strong>Action result</strong><p>{text(@widget["summary"])}</p><a :if={reference_url(@widget["url"], @project)} href={reference_url(@widget["url"], @project)} phx-target={@myself} phx-click={if @embedded && board_link?(@widget["url"], @project && @project["id"]), do: "board-link"} phx-value-url={@widget["url"]}>View result ↗</a></div></div>
    </section>
    """
  end

  defp source_failed?(widget), do: not is_nil(widget["source_error"]) or not is_nil(widget["runtime_error"])

  defp source_state(assigns) do
    ~H"""
    <div :if={source_failed?(@widget)} class="widget-source-warning" role="alert"><strong>Current state is unavailable</strong><p :if={@widget["source_error"]}>{text(@widget["source_error"])}</p><p :if={@widget["runtime_error"]}>{text(@widget["runtime_error"])}</p><p>Any listed tasks are last-known information.</p></div>
    <p :if={@widget["generated_at"] || @widget["checked_at"]} class="widget-checked">Checked {text(@widget["generated_at"] || @widget["checked_at"])}</p>
    """
  end

  defp matching_sessions(sessions, query) do
    Enum.filter(sessions, fn session ->
      pr = session.pr || %{}
      matches_search?([session.title, session.status, pr[:review], pr[:ci]], query)
    end)
  end

  defp compact_created_at(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    "Created " <> Calendar.strftime(datetime, "%b %-d")
  end

  defp issue_pr_count(item) do
    count = item.pull_request_count
    label = if count == 1, do: "PR", else: "PRs"

    cond do
      item.github_status == "available" -> "#{count} #{label}"
      count > 0 -> "#{count}+ #{label}"
      true -> "PRs —"
    end
  end

  defp matches_search?(values, query) do
    haystack = values |> Enum.map_join(" ", &to_string/1) |> String.downcase()
    query |> String.downcase() |> String.split() |> Enum.all?(&String.contains?(haystack, &1))
  end

  defp pr_evidence("available", count),
    do: %{label: to_string(count), message: if(count == 0, do: "No linked pull requests yet.")}

  defp pr_evidence(status, count) do
    {label, message} =
      case status do
        "partial" -> {"Incomplete", "PR details are incomplete."}
        "unavailable" -> {"Unavailable", "PR details are unavailable."}
        "source_missing" -> {"Unavailable", "PR details are unavailable while the issue source is missing."}
        "not_applicable" -> {"Unavailable", "PR details are not available for this tracker."}
        _ -> {"Not loaded", "PR details have not loaded yet."}
      end

    %{label: if(count > 0, do: "#{count} shown", else: label), message: message}
  end

  defp proposal_details(%{"action" => action, "args" => args, "pr_work" => work})
       when action in ["create_pr_work", "continue_pr_work"] and is_map(args) and is_map(work) do
    verb = if action == "create_pr_work", do: "Create a PR work session", else: "Continue PR work #{String.slice(text(work["work_id"]), 0, 8)}"
    "#{verb} for issue ##{text(args["task_id"])}\n\n#{text(args["body"])}\n\nUses the issue's remaining budget and existing execution controls."
  end

  defp proposal_details(widget), do: details_text(widget["details"])

  defp details_text(value) when is_binary(value), do: value

  defp details_text(value) when is_map(value), do: Enum.map_join(value, "\n", fn {key, detail} -> "#{key}: #{detail_value(detail)}" end)
  defp details_text(_value), do: ""
  defp detail_value(value) when is_binary(value) or is_number(value), do: to_string(value)
  defp detail_value(value), do: Jason.encode!(value)

  defp task_reference(assigns) do
    # Prefer the canonical task ID, not a model-provided arbitrary board query.
    filters = assigns.filters |> Map.take(["status", "priority", "q", "sort"]) |> Map.reject(fn {_key, value} -> not is_binary(value) end)
    params = Map.merge(filters, %{"project" => assigns.project && assigns.project["id"], "task" => assigns.task["id"]})
    url = if is_binary(assigns.task["id"]), do: reference_url("/?" <> URI.encode_query(params), assigns.project), else: reference_url(assigns.task["url"], assigns.project)
    assigns = assign(assigns, :url, url)

    ~H"""
    <div class="widget-task"><div><span class="widget-task-id">{text(@task["identifier"])}</span><a :if={@url} href={@url} phx-target={@myself} phx-click={if @embedded && board_link?(@url, @project && @project["id"]), do: "board-link"} phx-value-url={@url}>{text(@task["title"] || "Open task")}</a><strong :if={!@url}>{text(@task["title"])}</strong><span :if={@task["attention"]} class="widget-task-attention">{text(@task["attention"])}</span></div><span class="widget-label">{display_lane(@task["lane"] || @task["stage"] || @task["state"])}</span></div>
    """
  end

  defp display_lane(stage) when stage in ["ready", "running"], do: "work"
  defp display_lane(stage), do: text(stage)
end
