defmodule SymphonyElixirWeb.ChatPanel do
  @moduledoc "Project-bound management conversations, streamed from the conversation owner."
  use Phoenix.LiveComponent

  alias SymphonyElixirWeb.{BrowserAuth, Endpoint}

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
       view_context: nil,
       initialized: false,
       projects: [],
       project: nil,
       chats: [],
       chat: nil,
       subscribed: nil,
       draft: "",
       client_id: nonce(),
       history_query: "",
       dialog: nil,
       inspector: false,
       inspector_tab: "context",
       notice: nil,
       loading: true,
       share_context: true,
       include_selected: true,
       unavailable: nil
     )}
  end

  @impl true
  def update(%{refresh_chat: id}, socket) do
    {:ok, if(chat_id(socket) == id, do: fetch_chat(socket, id), else: socket)}
  end

  def update(assigns, socket) do
    previous = {socket.assigns.project_id, socket.assigns.chat_id}
    socket = assign(socket, Map.take(assigns, [:id, :auth, :csrf_token, :embedded, :project_id, :chat_id, :view_context, :read_only]))
    location = {socket.assigns.project_id, socket.assigns.chat_id}
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

        not socket.assigns.initialized or previous != location or is_nil(socket.assigns.project) ->
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

  @impl true
  def handle_event("close-panel", _params, socket) do
    send(self(), {:chat_panel, :close})
    {:noreply, subscribe(socket, nil)}
  end

  def handle_event("open-chat", %{"id" => id}, socket) do
    case call(socket, :get, [project_id(socket), id]) do
      {:ok, chat} ->
        socket = socket |> clear_changed_draft(id) |> put_chat(chat) |> assign(:dialog, nil)
        {:noreply, navigate(socket, project_id(socket), id)}

      {:error, reason} ->
        {:noreply, show_error(socket, reason)}
    end
  end

  def handle_event("context-options", params, socket) do
    share = params["share_context"] == "true"
    selected = if share and Map.has_key?(params, "include_selected"), do: params["include_selected"] == "true", else: socket.assigns.include_selected
    {:noreply, assign(socket, share_context: share, include_selected: selected)}
  end

  def handle_event("context-preferences", %{"project_id" => project, "share_context" => share, "include_selected" => selected}, socket)
      when is_binary(project) and is_boolean(share) and is_boolean(selected) do
    if BrowserAuth.authorized?(socket.assigns.auth) and is_nil(socket.assigns.unavailable) and project == project_id(socket) do
      {:noreply, assign(socket, share_context: share, include_selected: selected)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("context-preferences", _params, socket), do: {:noreply, socket}

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

  def handle_event("open-history", _params, socket) do
    socket = refresh_list(socket)
    {:noreply, assign(socket, :dialog, if(BrowserAuth.authorized?(socket.assigns.auth), do: :history, else: nil))}
  end

  def handle_event("search-history", %{"query" => query}, socket), do: {:noreply, assign(socket, :history_query, String.slice(query, 0, 200))}
  def handle_event("open-rename", _params, socket), do: {:noreply, assign(socket, :dialog, :rename)}
  def handle_event("open-archive", _params, socket), do: {:noreply, assign(socket, :dialog, :archive)}
  def handle_event("close-dialog", _params, socket), do: {:noreply, assign(socket, :dialog, nil)}
  def handle_event("toggle-inspector", _params, socket), do: {:noreply, assign(socket, :inspector, not socket.assigns.inspector)}

  def handle_event("inspector-tab", %{"tab" => tab}, socket) when tab in ["context", "outputs"] do
    {:noreply, socket |> assign(:inspector_tab, tab) |> assign(:inspector, true)}
  end

  def handle_event("draft", %{"message" => text}, socket), do: {:noreply, assign(socket, :draft, String.slice(text, 0, 16_000))}

  def handle_event("send-message", %{"message" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" -> {:noreply, socket}
      byte_size(text) > 16_000 -> {:noreply, assign(socket, :notice, "Keep a message under 16,000 bytes.")}
      busy?(socket.assigns.chat) -> {:noreply, show_error(socket, :chat_busy)}
      true -> send_message(socket, text)
    end
  end

  def handle_event("stop-response", _params, socket) do
    mutate(socket, :stop, [project_id(socket), chat_id(socket)])
  end

  def handle_event("rename-chat", %{"title" => title}, socket) do
    mutate(socket, :rename, [project_id(socket), chat_id(socket), String.trim(title)])
  end

  def handle_event("archive-chat", _params, socket) do
    case call(socket, :archive, [project_id(socket), chat_id(socket)]) do
      {:ok, _chat} ->
        socket = socket |> clear_conversation() |> assign(:notice, "Conversation archived.")
        {:noreply, navigate(socket, project_id(socket), nil)}

      {:error, reason} ->
        {:noreply, show_error(socket, reason)}
    end
  end

  def handle_event("decide", %{"id" => id, "decision" => decision}, socket) when decision in ["confirm", "cancel", "reconcile"] do
    mutate(socket, :decide, [project_id(socket), chat_id(socket), id, decision])
  end

  defp send_message(socket, text) do
    case ensure_chat(socket) do
      {:ok, socket} ->
        args = [project_id(socket), chat_id(socket), text, socket.assigns.client_id, shared_context(socket)]

        case call(socket, :send_message_with_context, args) do
          {:ok, chat} ->
            {:noreply,
             socket
             |> put_chat(chat)
             |> assign(:draft, "")
             |> assign(:client_id, nonce())
             |> assign(:notice, nil)
             |> push_event("chat-message-sent", %{})
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

  defp shared_context(socket) do
    context = scoped_context(socket.assigns)

    cond do
      not socket.assigns.share_context or is_nil(context) -> nil
      socket.assigns.include_selected -> context
      true -> Map.put(context, "selected_task_id", nil)
    end
  end

  defp scoped_context(assigns) do
    project = assigns.project && assigns.project["id"]

    case assigns.view_context do
      %{"project_id" => ^project} = context when is_binary(project) -> context
      _ -> nil
    end
  end

  defp ensure_chat(%{assigns: %{chat: %{"id" => _id}}} = socket), do: {:ok, socket}

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
          |> assign(dialog: nil, notice: nil)

        {:noreply, navigate(socket, project_id(socket), chat["id"])}

      {:error, reason} ->
        {:noreply, show_error(socket, reason)}
    end
  end

  defp load_location(socket, params) do
    case call(socket, :projects, []) do
      {:ok, projects} ->
        selected = selected_project(projects, params["project"])
        socket = if selected != socket.assigns.project, do: clear_conversation(socket), else: socket
        socket = assign(socket, projects: projects, project: selected, loading: false)

        cond do
          is_nil(selected) -> assign(socket, :notice, unavailable_project(projects))
          params["chat"] -> socket |> assign(:dialog, nil) |> refresh_list() |> fetch_chat(params["chat"])
          true -> socket |> clear_conversation() |> refresh_list()
        end

      {:error, reason} ->
        socket |> assign(:loading, false) |> show_error(reason)
    end
  end

  defp selected_project(projects, nil), do: List.first(projects)
  defp selected_project(projects, id), do: Enum.find(projects, &(&1["id"] == id))
  defp unavailable_project([]), do: "No projects are available for chat."
  defp unavailable_project(_projects), do: "That project is not available. Select a project above."

  defp refresh_list(%{assigns: %{project: nil}} = socket), do: socket

  defp refresh_list(socket) do
    case call(socket, :list, [project_id(socket)]) do
      {:ok, chats} -> assign(socket, :chats, chats)
      {:error, reason} -> show_error(socket, reason)
    end
  end

  defp fetch_chat(socket, id) do
    case call(socket, :get, [project_id(socket), id]) do
      {:ok, chat} -> socket |> clear_changed_draft(id) |> put_chat(chat) |> refresh_list()
      {:error, reason} -> socket |> clear_conversation() |> show_error(reason)
    end
  end

  defp clear_changed_draft(%{assigns: %{chat: %{"id" => id}}} = socket, id), do: socket
  defp clear_changed_draft(socket, _id), do: assign(socket, draft: "", client_id: nonce())

  defp put_chat(socket, chat) do
    socket = subscribe(socket, chat["id"])
    assign(socket, :chat, chat)
  end

  defp clear_conversation(socket) do
    socket
    |> subscribe(nil)
    |> assign(chat: nil, chats: [], draft: "", history_query: "", client_id: nonce(), dialog: nil)
  end

  defp subscribe(%{assigns: %{subscribed: id}} = socket, id), do: socket

  defp subscribe(socket, id) do
    if socket.assigns.subscribed, do: Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "chat:" <> socket.assigns.subscribed)
    if id, do: Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat:" <> id)
    assign(socket, :subscribed, id)
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
  defp error_message(:unavailable), do: "Chat is temporarily unavailable. Your conversation has been retained; try again."
  defp error_message(:chat_disabled), do: "Chat is not enabled for this service yet."
  defp error_message(:chat_not_configured), do: "Chat is not configured for this service yet."
  defp error_message(reason) when reason in [:chat_storage_unavailable, :chat_storage_locked, :locked], do: "Conversation storage is unavailable or locked. Try again once the service is ready."
  defp error_message(:message_id_conflict), do: "This message could not be matched to its earlier submission. Reload the conversation before sending again."
  defp error_message(:invalid_view_context), do: "This board view could not be attached. Refresh the view, or turn off sharing before sending again."
  defp error_message(:invalid_message), do: "Enter a message of up to 16,000 bytes before sending."
  defp error_message(:chat_capacity), do: "The conversation service is at capacity. Wait for an active response to finish and try again."
  defp error_message(:start_new_chat), do: "This conversation has reached its current limit. Start a new chat to continue."
  defp error_message(:chat_runtime_changed), do: "The chat runtime changed. Start a new chat to use the current configuration."
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
  defp messages(nil), do: []
  defp messages(chat), do: list(chat["messages"])
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value), do: to_string(value)
  defp text(_value), do: ""
  defp widget_type(widget), do: map(widget)["type"]
  defp output_widgets(chat), do: Enum.flat_map(messages(chat), &list(&1["widgets"]))
  defp context_items(nil), do: []
  defp context_items(chat), do: list(chat["context"])
  defp matching_chats(chats, query), do: Enum.filter(chats, &(not &1["archived"] and String.contains?(String.downcase(chat_title(&1)), String.downcase(query))))

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
    assigns =
      assign(assigns,
        authorized: BrowserAuth.authorized?(assigns.auth),
        google_auth: BrowserAuth.google_enabled?(),
        running: running?(assigns.chat),
        executing: executing?(assigns.chat),
        busy: busy?(assigns.chat),
        current_context: scoped_context(assigns)
      )

    ~H"""
    <section id="chat-app" class={"chat-shell chat-panel #{if @embedded, do: "embedded-chat", else: ""}"} phx-hook="ChatWorkspace" data-chat-id={@chat && @chat["id"]} data-project={@project && @project["id"]} data-event-target={@myself} data-running={to_string(@running)}>
      <header class="board-header chat-header">
        <a :if={!@embedded} href="/" class="brand">∿ Symphony</a>
        <nav :if={!@embedded} class="workspace-tabs" aria-label="Workspace"><a href={board_path(@project && @project["id"])}>Board</a><a href={chat_path(@project && @project["id"])} aria-current="page">Chat</a></nav>
        <strong :if={@embedded}>Project chat</strong><span class="header-spacer"></span>
        <button :if={@authorized && is_nil(@unavailable)} id="chat-history-button" class="button button-quiet" phx-target={@myself} phx-click="open-history" disabled={is_nil(@project)}>History</button>
        <button :if={@authorized && is_nil(@unavailable)} id="new-chat-button" class="button button-primary" phx-target={@myself} phx-click="new-chat" disabled={is_nil(@project)}>+ New chat</button>
        <button :if={@embedded} class="button button-quiet" phx-target={@myself} phx-click="close-panel" aria-label="Close chat">×</button>
      </header>

      <div :if={@authorized && is_nil(@unavailable)} class="chat-toolbar">
        <form :if={!@embedded} phx-target={@myself} phx-change="select-project" class="chat-project-filter">
          <label for="chat-project">Project</label>
          <select id="chat-project" name="project" aria-label="Chat project">
            <option :if={is_nil(@project)} value="">Select a project</option>
            <option :for={project <- @projects} value={project["id"]} selected={@project && @project["id"] == project["id"]}>{project_label(project)}</option>
          </select>
        </form>
        <div class="chat-title"><strong>{chat_title(@chat)}</strong><span class="muted">{conversation_status(@chat)}</span></div>
        <button :if={@chat} class="button button-small button-quiet" phx-target={@myself} phx-click="open-rename" aria-label="Rename conversation">Rename</button>
        <button :if={@chat} class="button button-small button-quiet" phx-target={@myself} phx-click="open-archive" disabled={@busy}>Archive</button>
        <button id="chat-inspector-button" class="button button-small" phx-target={@myself} phx-click="toggle-inspector" aria-expanded={to_string(@inspector)} aria-controls="chat-inspector">Context & outputs</button>
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

      <div :if={!@loading && @authorized && is_nil(@unavailable)} class="chat-workspace" data-inspector={to_string(@inspector)}>
        <main class="chat-main">
          <div id="chat-scroll" class="chat-scroll" tabindex="0" aria-label="Conversation messages">
            <div :if={messages(@chat) == []} class="chat-empty">
              <span class="chat-orbit" aria-hidden="true">∿</span><h1>What’s next for {project_label(@project)}?</h1>
              <p>Review work, clarify a task, or plan the next step.<br />This conversation stays within this project.</p>
              <div class="chat-starters">
                <button type="button" data-chat-prompt="What is running and what is blocked?">What needs attention? <span aria-hidden="true">↗</span></button>
                <button type="button" data-chat-prompt="Show the current tasks and help me choose what to work on next.">Help me plan the next step <span aria-hidden="true">↗</span></button>
                <button type="button" data-chat-prompt="Help me write a clear new task with acceptance criteria.">Shape a new task <span aria-hidden="true">↗</span></button>
              </div>
            </div>

            <div id="chat-messages" class="chat-messages" aria-live="off">
              <article :for={message <- messages(@chat)} id={"message-#{message["id"]}"} class={"chat-message chat-message-#{if message["role"] == "user", do: "user", else: "assistant"}"}>
                <div class="message-meta"><strong>{if message["role"] == "user", do: "You", else: "Symphony"}</strong><span :if={message["status"] == "streaming"} class="streaming-mark">Responding</span></div>
                <div :if={text(message["text"]) != ""} class="message-text">{text(message["text"])}</div>
                <span :if={message["status"] in ["streaming", "pending"] && text(message["text"]) == ""} class="chat-thinking" role="status">Working<span aria-hidden="true"> ···</span></span>
                <div :if={list(message["widgets"]) != []} class="chat-widgets">
                  <.widget :for={widget <- list(message["widgets"])} widget={map(widget)} project={@project} busy={@busy} myself={@myself} embedded={@embedded} />
                </div>
              </article>
            </div>
            <p :if={@chat && @chat["status"] == "interrupted"} class="chat-response-status" role="status">Response stopped. Coding tasks continue independently.</p>
            <p :if={@chat && @chat["error"]} class="board-warning" role="alert">{text(@chat["error"])}</p>
          </div>

          <div class="chat-composer-wrap">
            <form :if={@embedded} id="chat-context-controls" class="chat-view-context" phx-target={@myself} phx-change="context-options">
              <label><input type="hidden" name="share_context" value="false" /><input type="checkbox" name="share_context" value="true" checked={@share_context} /> Share this view</label>
              <p :if={@current_context} class="chat-context-summary">{project_label(@project)} · {visible_tasks_label(@current_context)}<span :if={filter_summary(@current_context) != ""}> · {filter_summary(@current_context)}</span></p>
              <p :if={!@current_context} class="muted">No matching board context is available.</p>
              <p :if={@current_context && @current_context["truncated"]} class="muted">Only the first {length(list(@current_context["visible_task_ids"]))} matching cards are attached.</p>
              <label :if={@current_context && @current_context["selected_task_id"]}><input type="hidden" name="include_selected" value="false" /><input type="checkbox" name="include_selected" value="true" checked={@include_selected} disabled={!@share_context} /> Identify selected card: {text(@current_context["selected_task_id"])}</label>
              <p class="muted">{if @share_context, do: "The current snapshot accompanies your next message. Task information is data, not approval.", else: "This message will not share the current view. Earlier messages and retrieved sources remain in this conversation."}</p>
            </form>
            <p id="chat-live-status" class="visually-hidden" role="status" aria-live="polite">{if @busy, do: conversation_status(@chat), else: "Ready for your message."}</p>
            <form id="chat-composer" phx-target={@myself} phx-submit="send-message" phx-change="draft" class="chat-composer">
              <label for="chat-message-input" class="visually-hidden">Message {project_label(@project)}</label>
              <textarea id="chat-message-input" name="message" placeholder={"Message #{project_label(@project)}…"} rows="2" maxlength="16000" disabled={is_nil(@project) || @executing} phx-debounce="150">{@draft}</textarea>
              <div class="composer-bottom"><span class="composer-project">{project_label(@project)}</span>
                <button :if={@running} id="stop-response-button" type="button" class="button" phx-target={@myself} phx-click="stop-response" title="Stop this response; coding tasks keep running">■ Stop</button>
                <button :if={!@running} id="send-message-button" class="button button-primary" disabled={is_nil(@project) || @busy} phx-disable-with="Sending…" aria-label="Send message">{if @executing, do: "Applying action…", else: "Send ↑"}</button>
              </div>
            </form>
            <p class="composer-hint">Enter to send · Shift + Enter for a new line<span class="chat-connection"><span class="status-badge-offline">Disconnected · reconnecting</span></span></p>
          </div>
        </main>

        <aside :if={@inspector} id="chat-inspector" class="chat-inspector" aria-label="Conversation context and outputs">
          <div class="inspector-heading"><div class="workspace-tabs" role="tablist" aria-label="Conversation details">
            <button id="context-tab" role="tab" aria-selected={@inspector_tab == "context"} aria-controls="context-content" phx-target={@myself} phx-click="inspector-tab" phx-value-tab="context">Context</button>
            <button id="outputs-tab" role="tab" aria-selected={@inspector_tab == "outputs"} aria-controls="outputs-content" phx-target={@myself} phx-click="inspector-tab" phx-value-tab="outputs">Outputs</button>
          </div><button class="button button-quiet button-small" phx-target={@myself} phx-click="toggle-inspector" aria-label="Close context and outputs">×</button></div>
          <div :if={@inspector_tab == "context"} id="context-content" role="tabpanel" aria-labelledby="context-tab">
            <p class="inspector-label">Project boundary</p><strong>{project_label(@project)}</strong><p class="muted">Messages and retrieved information stay in this project.</p>
            <h3>Sources used</h3><p :if={context_items(@chat) == []} class="muted">Sources will appear here as the agent retrieves them.</p>
            <div :for={item <- context_items(@chat)} class="context-reference">
              <a :if={safe_url(map(item)["url"])} href={safe_url(map(item)["url"])}>{text(map(item)["title"] || map(item)["label"] || map(item)["url"])}</a>
              <strong :if={!safe_url(map(item)["url"])}>{text(map(item)["title"] || map(item)["label"] || map(item)["type"])}</strong>
              <p :if={map(item)["summary"]}>{text(map(item)["summary"])}</p><small>{text(map(item)["revision"] || map(item)["checked_at"])}</small>
            </div>
          </div>
          <div :if={@inspector_tab == "outputs"} id="outputs-content" role="tabpanel" aria-labelledby="outputs-tab">
            <p class="muted">Task references and confirmed action results from this conversation.</p>
            <p :if={output_widgets(@chat) == []} class="inspector-empty">No outputs yet.</p>
            <.widget :for={widget <- output_widgets(@chat)} widget={map(widget)} project={@project} busy={@busy} myself={@myself} embedded={@embedded} />
          </div>
        </aside>
      </div>

      <dialog :if={@dialog} id="chat-dialog" class="board-dialog chat-dialog" phx-hook="BoardDialog" data-close-selector="#chat-close-dialog" data-event-target={@myself} aria-labelledby="chat-dialog-title">
        <div class="dialog-inner"><div class="dialog-heading"><h2 id="chat-dialog-title">{dialog_title(@dialog)}</h2><button id="chat-close-dialog" class="button button-quiet" phx-target={@myself} phx-click="close-dialog" aria-label="Close dialog">Close ×</button></div>
          <div :if={@dialog == :history}>
            <p class="muted">{project_label(@project)} conversations</p>
            <form phx-target={@myself} phx-change="search-history"><label class="field"><span class="visually-hidden">Search conversations</span><input type="search" name="query" value={@history_query} placeholder="Search conversations…" phx-debounce="150" autofocus /></label></form>
            <div class="conversation-list"><button :for={chat <- matching_chats(@chats, @history_query)} type="button" phx-target={@myself} phx-click="open-chat" phx-value-id={chat["id"]} class="conversation-item" aria-current={if @chat && @chat["id"] == chat["id"], do: "page", else: nil}>
              <span><strong>{chat_title(chat)}</strong><small>{text(chat["updated_at"])}</small></span><span class="conversation-status">{if running?(chat), do: "Responding", else: "↗"}</span>
            </button></div>
            <p :if={matching_chats(@chats, @history_query) == []} class="inspector-empty">{if @history_query == "", do: "No conversations in this project yet.", else: "No conversations match your search."}</p>
          </div>
          <form :if={@dialog == :rename && @chat} phx-target={@myself} phx-submit="rename-chat"><label class="field">Conversation name<input name="title" value={chat_title(@chat)} maxlength="120" required /></label><button class="button button-primary" phx-disable-with="Saving…">Save name</button></form>
          <div :if={@dialog == :archive && @chat}><p>Archive “{chat_title(@chat)}”? It will leave the conversation picker. Its stored history will be retained.</p><div class="dialog-actions"><button class="button" phx-target={@myself} phx-click="close-dialog">Keep conversation</button><button class="button button-primary" phx-target={@myself} phx-click="archive-chat" disabled={@busy} phx-disable-with="Archiving…">Archive conversation</button></div></div>
        </div>
      </dialog>
    </section>
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

  defp dialog_title(:history), do: "Chat history"
  defp dialog_title(:rename), do: "Rename conversation"
  defp dialog_title(:archive), do: "Archive conversation"

  defp conversation_status(chat) do
    cond do
      running?(chat) -> "Responding…"
      executing?(chat) -> "Applying action…"
      true -> "Project conversation"
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
        <p class="message-text">{details_text(@widget["details"])}</p>
        <div :if={@widget["status"] in [nil, "pending"]} class="dialog-actions"><button class="button button-primary" phx-target={@myself} phx-click="decide" phx-value-id={@widget["id"]} phx-value-decision="confirm" disabled={@busy} phx-disable-with="Confirming…">Confirm action</button><button class="button" phx-target={@myself} phx-click="decide" phx-value-id={@widget["id"]} phx-value-decision="cancel" disabled={@busy} phx-disable-with="Cancelling…">Cancel</button></div>
        <p :if={@widget["status"] in [nil, "pending"]} class="muted widget-footnote">Nothing changes until you confirm this action.</p>
        <p :if={@widget["status"] == "executing"} class="muted" role="status">Applying action…</p>
        <p :if={@widget["status"] == "failed"} class="board-warning" role="alert">Action failed: {text(@widget["error"] || "The action could not be completed.")}</p>
        <div :if={@widget["status"] == "unknown"}><p class="muted">The outcome is uncertain. Check the recorded result before trying another action.</p><button class="button" phx-target={@myself} phx-click="decide" phx-value-id={@widget["id"]} phx-value-decision="reconcile" disabled={@busy} phx-disable-with="Checking…">Check outcome</button></div>
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
    <div class="widget-task"><div><span class="widget-task-id">{text(@task["identifier"])}</span><a :if={@url} href={@url} phx-target={@myself} phx-click={if @embedded && board_link?(@url, @project && @project["id"]), do: "board-link"} phx-value-url={@url}>{text(@task["title"] || "Open task")}</a><strong :if={!@url}>{text(@task["title"])}</strong><span :if={@task["attention"]} class="widget-task-attention">{text(@task["attention"])}</span></div><span class="widget-label">{text(@task["stage"] || @task["state"])}</span></div>
    """
  end
end
