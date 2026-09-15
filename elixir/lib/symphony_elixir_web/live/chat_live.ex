defmodule SymphonyElixirWeb.ChatLive do
  @moduledoc "Project-bound management conversations, streamed from the conversation owner."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{BrowserAuth, Endpoint}

  @impl true
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        auth: BrowserAuth.context(session, socket),
        csrf_token: Plug.CSRFProtection.get_csrf_token(),
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
        loading: not connected?(socket)
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket) and BrowserAuth.authorized?(socket.assigns.auth) do
      {:noreply, load_location(socket, params)}
    else
      {:noreply, assign(socket, :loading, not connected?(socket))}
    end
  end

  @impl true
  def handle_info({:chat_updated, id}, %{assigns: %{chat: %{"id" => id}}} = socket) do
    {:noreply, fetch_chat(socket, id)}
  end

  def handle_info({:chat_updated, _id}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select-project", %{"project" => id}, socket) do
    # Switching projects changes the view, never a conversation's project binding.
    if Enum.any?(socket.assigns.projects, &(&1["id"] == id)) do
      {:noreply, socket |> clear_conversation() |> assign(:notice, nil) |> push_patch(to: chat_path(id))}
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

  def handle_event("draft", %{"message" => text}, socket), do: {:noreply, assign(socket, :draft, String.slice(text, 0, 20_000))}

  def handle_event("send-message", %{"message" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" -> {:noreply, socket}
      byte_size(text) > 20_000 -> {:noreply, assign(socket, :notice, "Keep a message under 20,000 bytes.")}
      running?(socket.assigns.chat) -> {:noreply, assign(socket, :notice, "Wait for this response or stop it before sending another message.")}
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
        {:noreply, push_patch(socket, to: chat_path(project_id(socket)))}

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
        case call(socket, :send_message, [project_id(socket), chat_id(socket), text, socket.assigns.client_id]) do
          {:ok, chat} ->
            {:noreply,
             socket
             |> put_chat(chat)
             |> assign(:draft, "")
             |> assign(:client_id, nonce())
             |> assign(:notice, nil)
             |> push_event("chat-message-sent", %{})
             |> push_patch(to: chat_path(project_id(socket), chat["id"]))}

          {:error, reason} ->
            {:noreply, show_error(socket, reason)}
        end

      {:error, reason} ->
        {:noreply, show_error(socket, reason)}
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
        socket = socket |> put_chat(chat) |> assign(:dialog, nil) |> assign(:notice, nil)
        {:noreply, push_patch(socket, to: chat_path(project_id(socket), chat["id"]))}

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
    if BrowserAuth.authorized?(socket.assigns.auth) do
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

    assign(socket, :notice, error_message(reason))
  end

  defp error_message(reason) when reason in [:unauthorized, :forbidden], do: "Your session is locked or has expired. Unlock chat to continue."
  defp error_message(reason) when reason in [:not_found, :project_mismatch, :unknown_project], do: "This conversation is not available in the selected project."
  defp error_message(reason) when reason in [:busy, :already_running], do: "A response is already running in this conversation."
  defp error_message(reason) when reason in [:stale_revision, :stale_proposal], do: "The task changed since this action was prepared. Ask for a fresh proposal."
  defp error_message(:unavailable), do: "Chat is temporarily unavailable. Your conversation has been retained; try again."
  defp error_message(:chat_disabled), do: "Chat is not enabled for this service yet."
  defp error_message(:chat_not_configured), do: "Chat is not configured for this service yet."
  defp error_message(reason) when reason in [:chat_storage_unavailable, :locked], do: "Conversation storage is unavailable or locked. Try again once the service is ready."
  defp error_message(:chat_capacity), do: "The conversation service is at capacity. Wait for an active response to finish and try again."
  defp error_message(:start_new_chat), do: "This conversation has reached its current limit. Start a new chat to continue."
  defp error_message(:chat_runtime_changed), do: "The chat runtime changed. Start a new chat to use the current configuration."
  defp error_message(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp error_message(_reason), do: "The request could not be completed. Refresh the conversation and try again."

  defp project_id(socket), do: socket.assigns.project && socket.assigns.project["id"]
  defp chat_id(socket), do: socket.assigns.chat && socket.assigns.chat["id"]
  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp running?(chat), do: is_map(chat) and chat["status"] == "running"
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

  @impl true
  def render(assigns) do
    assigns = assign(assigns, authorized: BrowserAuth.authorized?(assigns.auth), running: running?(assigns.chat))

    ~H"""
    <section id="chat-app" class="chat-shell" phx-hook="ChatWorkspace" data-chat-id={@chat && @chat["id"]} data-running={to_string(@running)}>
      <header class="board-header chat-header">
        <a href="/" class="brand">∿ Symphony</a>
        <nav class="workspace-tabs" aria-label="Workspace"><a href={board_path(@project && @project["id"])}>Board</a><a href={chat_path(@project && @project["id"])} aria-current="page">Chat</a></nav>
        <span class="header-spacer"></span>
        <button :if={@authorized} id="chat-history-button" class="button button-quiet" phx-click="open-history" disabled={is_nil(@project)}>History</button>
        <button :if={@authorized} id="new-chat-button" class="button button-primary" phx-click="new-chat" disabled={is_nil(@project)}>+ New chat</button>
      </header>

      <div :if={@authorized} class="chat-toolbar">
        <form phx-change="select-project" class="chat-project-filter">
          <label for="chat-project">Project</label>
          <select id="chat-project" name="project" aria-label="Chat project">
            <option :if={is_nil(@project)} value="">Select a project</option>
            <option :for={project <- @projects} value={project["id"]} selected={@project && @project["id"] == project["id"]}>{project_label(project)}</option>
          </select>
        </form>
        <div class="chat-title"><strong>{chat_title(@chat)}</strong><span class="muted">{if @running, do: "Responding…", else: "Project conversation"}</span></div>
        <button :if={@chat} class="button button-small button-quiet" phx-click="open-rename" aria-label="Rename conversation">Rename</button>
        <button :if={@chat} class="button button-small button-quiet" phx-click="open-archive" disabled={@running}>Archive</button>
        <button id="chat-inspector-button" class="button button-small" phx-click="toggle-inspector" aria-expanded={to_string(@inspector)} aria-controls="chat-inspector">Context & outputs</button>
      </div>

      <p :if={Phoenix.Flash.get(@flash, :error)} class="board-warning" role="alert">{Phoenix.Flash.get(@flash, :error)}</p>
      <p :if={@notice} class="board-warning chat-notice" role="status">{@notice}</p>

      <div :if={@loading} class="chat-empty" role="status"><span class="chat-orbit" aria-hidden="true">∿</span><h1>Opening your workspace</h1><p>Connecting to your project conversations…</p></div>

      <div :if={!@loading && !@authorized} class="chat-empty chat-login">
        <span class="chat-orbit" aria-hidden="true">∿</span><h1>Your project conversations</h1>
        <p>Unlock this browser to read chat history and manage work.</p>
        <form action="/operator/session" method="post" class="chat-login-form">
          <input type="hidden" name="_csrf_token" value={@csrf_token} /><input type="hidden" name="return_to" value="/chat" />
          <label class="field">Operator token<input type="password" name="operator_token" autocomplete="off" required /></label>
          <button class="button button-primary">Unlock chat</button>
        </form>
        <p class="muted">Use the local operator token configured for this service.</p>
      </div>

      <div :if={!@loading && @authorized} class="chat-workspace" data-inspector={to_string(@inspector)}>
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
                  <.widget :for={widget <- list(message["widgets"])} widget={map(widget)} project={@project} running={@running} />
                </div>
              </article>
            </div>
            <p :if={@chat && @chat["status"] == "interrupted"} class="chat-response-status" role="status">Response stopped. Coding tasks continue independently.</p>
            <p :if={@chat && @chat["error"]} class="board-warning" role="alert">{text(@chat["error"])}</p>
          </div>

          <div class="chat-composer-wrap">
            <p id="chat-live-status" class="visually-hidden" role="status" aria-live="polite">{if @running, do: "Response in progress.", else: "Ready for your message."}</p>
            <form id="chat-composer" phx-submit="send-message" phx-change="draft" class="chat-composer">
              <label for="chat-message-input" class="visually-hidden">Message {project_label(@project)}</label>
              <textarea id="chat-message-input" name="message" placeholder={"Message #{project_label(@project)}…"} rows="2" maxlength="20000" disabled={is_nil(@project)} phx-debounce="150">{@draft}</textarea>
              <div class="composer-bottom"><span class="composer-project">{project_label(@project)}</span>
                <button :if={@running} id="stop-response-button" type="button" class="button" phx-click="stop-response" title="Stop this response; coding tasks keep running">■ Stop</button>
                <button :if={!@running} id="send-message-button" class="button button-primary" disabled={is_nil(@project)} phx-disable-with="Sending…" aria-label="Send message">Send ↑</button>
              </div>
            </form>
            <p class="composer-hint">Enter to send · Shift + Enter for a new line<span class="chat-connection"><span class="status-badge-offline">Disconnected · reconnecting</span></span></p>
          </div>
        </main>

        <aside :if={@inspector} id="chat-inspector" class="chat-inspector" aria-label="Conversation context and outputs">
          <div class="inspector-heading"><div class="workspace-tabs" role="tablist" aria-label="Conversation details">
            <button id="context-tab" role="tab" aria-selected={@inspector_tab == "context"} aria-controls="context-content" phx-click="inspector-tab" phx-value-tab="context">Context</button>
            <button id="outputs-tab" role="tab" aria-selected={@inspector_tab == "outputs"} aria-controls="outputs-content" phx-click="inspector-tab" phx-value-tab="outputs">Outputs</button>
          </div><button class="button button-quiet button-small" phx-click="toggle-inspector" aria-label="Close context and outputs">×</button></div>
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
            <.widget :for={widget <- output_widgets(@chat)} widget={map(widget)} project={@project} running={@running} />
          </div>
        </aside>
      </div>

      <dialog :if={@dialog} id="chat-dialog" class="board-dialog chat-dialog" phx-hook="BoardDialog" aria-labelledby="dialog-title">
        <div class="dialog-inner"><div class="dialog-heading"><h2 id="dialog-title">{dialog_title(@dialog)}</h2><button id="close-dialog" class="button button-quiet" phx-click="close-dialog" aria-label="Close dialog">Close ×</button></div>
          <div :if={@dialog == :history}>
            <p class="muted">{project_label(@project)} conversations</p>
            <form phx-change="search-history"><label class="field"><span class="visually-hidden">Search conversations</span><input type="search" name="query" value={@history_query} placeholder="Search conversations…" phx-debounce="150" autofocus /></label></form>
            <div class="conversation-list"><.link :for={chat <- matching_chats(@chats, @history_query)} patch={chat_path(@project["id"], chat["id"])} class="conversation-item" aria-current={if @chat && @chat["id"] == chat["id"], do: "page", else: nil}>
              <span><strong>{chat_title(chat)}</strong><small>{text(chat["updated_at"])}</small></span><span class="conversation-status">{if running?(chat), do: "Responding", else: "↗"}</span>
            </.link></div>
            <p :if={matching_chats(@chats, @history_query) == []} class="inspector-empty">{if @history_query == "", do: "No conversations in this project yet.", else: "No conversations match your search."}</p>
          </div>
          <form :if={@dialog == :rename && @chat} phx-submit="rename-chat"><label class="field">Conversation name<input name="title" value={chat_title(@chat)} maxlength="120" required /></label><button class="button button-primary" phx-disable-with="Saving…">Save name</button></form>
          <div :if={@dialog == :archive && @chat}><p>Archive “{chat_title(@chat)}”? It will leave the conversation picker. Its stored history will be retained.</p><div class="dialog-actions"><button class="button" phx-click="close-dialog">Keep conversation</button><button class="button button-primary" phx-click="archive-chat" disabled={@running} phx-disable-with="Archiving…">Archive conversation</button></div></div>
        </div>
      </dialog>
    </section>
    """
  end

  defp dialog_title(:history), do: "Chat history"
  defp dialog_title(:rename), do: "Rename conversation"
  defp dialog_title(:archive), do: "Archive conversation"

  defp widget(assigns) do
    assigns = assign(assigns, type: widget_type(assigns.widget), task: map(assigns.widget["task"]))

    ~H"""
    <section :if={@type in ["tasks", "task", "status", "proposal", "receipt"]} class={"chat-widget chat-widget-#{@type}"}>
      <div :if={@type == "tasks"}>
        <div class="widget-heading"><strong>{text(@widget["title"] || "Tasks")}</strong><a :if={safe_url(@widget["url"])} href={safe_url(@widget["url"])}>Open filtered board ↗</a></div>
        <.source_state widget={@widget} />
        <p :if={list(@widget["tasks"]) == [] && !source_failed?(@widget)} class="muted">No tasks matched these filters.</p>
        <.task_reference :for={task <- list(@widget["tasks"])} task={map(task)} project={@project} filters={map(@widget["filters"])} />
      </div>
      <.task_reference :if={@type == "task"} task={Map.put_new(@task, "url", @widget["url"])} project={@project} filters={map(@widget["filters"])} />
      <div :if={@type == "status"}>
        <div class="widget-heading"><strong>Project status</strong><a :if={safe_url(@widget["url"])} href={safe_url(@widget["url"])}>Open board ↗</a></div>
        <.source_state widget={@widget} />
        <p>{text(@widget["summary"])}</p>
        <p :if={map(@widget["control"])["mode"]} class="muted">Execution: {text(map(@widget["control"])["mode"])}</p>
        <dl :if={map(@widget["counts"]) != %{} && !source_failed?(@widget)} class="status-counts"><div :for={{label, value} <- Enum.sort(map(@widget["counts"]))}><dt>{text(label)}</dt><dd>{text(value)}</dd></div></dl>
        <div :if={list(@widget["blockers"]) != []} class="widget-blockers"><strong>Needs attention</strong><.task_reference :for={task <- list(@widget["blockers"])} task={map(task)} project={@project} filters={%{"status" => "attention"}} /></div>
      </div>
      <div :if={@type == "proposal"}>
        <div class="widget-heading"><strong>{text(@widget["title"] || "Proposed action")}</strong><span class="widget-label">{text(@widget["status"] || "pending")}</span></div>
        <p class="proposal-action">{text(@widget["action"])}</p><p class="message-text">{details_text(@widget["details"])}</p>
        <div :if={@widget["status"] in [nil, "pending"]} class="dialog-actions"><button class="button button-primary" phx-click="decide" phx-value-id={@widget["id"]} phx-value-decision="confirm" phx-disable-with="Confirming…">Confirm action</button><button class="button" phx-click="decide" phx-value-id={@widget["id"]} phx-value-decision="cancel" phx-disable-with="Cancelling…">Cancel</button></div>
        <p :if={@widget["status"] in [nil, "pending"]} class="muted widget-footnote">Nothing changes until you confirm this action.</p>
        <p :if={@widget["status"] == "executing"} class="muted" role="status">Applying action…</p>
        <p :if={@widget["status"] == "failed"} class="board-warning" role="alert">Action failed: {text(@widget["error"] || "The action could not be completed.")}</p>
        <div :if={@widget["status"] == "unknown"}><p class="muted">The outcome is uncertain. Check the recorded result before trying another action.</p><button class="button" phx-click="decide" phx-value-id={@widget["id"]} phx-value-decision="reconcile" phx-disable-with="Checking…">Check outcome</button></div>
      </div>
      <div :if={@type == "receipt"} class="action-receipt"><span aria-hidden="true">✓</span><div><strong>Action result</strong><p>{text(@widget["summary"])}</p><a :if={safe_url(@widget["url"])} href={safe_url(@widget["url"])}>View result ↗</a></div></div>
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
    url = if is_binary(assigns.task["id"]), do: "/?" <> URI.encode_query(params), else: safe_url(assigns.task["url"])
    assigns = assign(assigns, :url, url)

    ~H"""
    <div class="widget-task"><div><span class="widget-task-id">{text(@task["identifier"])}</span><a :if={@url} href={@url}>{text(@task["title"] || "Open task")}</a><strong :if={!@url}>{text(@task["title"])}</strong><span :if={@task["attention"]} class="widget-task-attention">{text(@task["attention"])}</span></div><span class="widget-label">{text(@task["stage"] || @task["state"])}</span></div>
    """
  end
end
