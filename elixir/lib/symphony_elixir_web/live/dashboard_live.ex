defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc "Live task board with browser preferences and authenticated native controls."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Chat.ViewContext
  alias SymphonyElixirWeb.{BoardActions, BrowserAuth, ChatPanel, Endpoint, Markdown, SettingsPanel}
  alias SymphonyElixirWeb.{ObservabilityPubSub, Presenter, TaskBoard}

  @lanes [{"backlog", "Backlog"}, {"ready", "Ready"}, {"running", "Running"}, {"review", "Review"}, {"done", "Done"}]
  @refresh_ms 30_000

  @impl true
  def mount(_params, session, socket) do
    payload = load_payload()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:board, initial_board(payload))
      |> assign(:loading, false)
      |> assign(:dialog, nil)
      |> assign(:selected, nil)
      |> assign(:pending_command, nil)
      |> assign(:settings_tab, "execution")
      |> assign(:concurrency_draft, nil)
      |> assign(:chat_health, "Not checked")
      |> assign(:notice, nil)
      |> assign(:auth, BrowserAuth.context(session, socket))
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:lanes, @lanes)
      |> assign(:url_filters, %{})
      |> assign(:linked_task, nil)
      |> assign(:chat_open, false)
      |> assign(:chat_project, nil)
      |> assign(:chat_project_subscription, nil)
      |> assign(:chat_id, nil)
      |> assign(:view_context, nil)
      |> assign(:context_revision, 0)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      Process.send_after(self(), :refresh_board, @refresh_ms)
      {:ok, refresh_board(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    dialog = if params["panel"] == "settings", do: :settings, else: nil
    filters = url_filters(params)
    project = selected_project(socket.assigns.board, filters)
    selection_changed = project != socket.assigns.chat_project || params["task"] != socket.assigns.linked_task
    socket = if selection_changed || filters != socket.assigns.url_filters, do: clear_view_context(socket), else: socket

    socket = if socket.assigns.chat_open && params["assistant"] != "1", do: unsubscribe_chat(socket), else: socket

    socket =
      socket
      |> assign(:dialog, dialog)
      |> assign(:url_filters, filters)
      |> assign(:linked_task, params["task"])
      |> assign(:chat_open, params["assistant"] == "1")
      |> assign(:chat_project, project)
      |> assign(:chat_id, bounded_chat_id(params["chat"]))

    {:noreply, open_linked_task(socket)}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload, load_payload())}
  end

  def handle_info(:refresh_board, socket) do
    Process.send_after(self(), :refresh_board, @refresh_ms)
    {:noreply, refresh_board(socket)}
  end

  def handle_info({:chat_updated, id}, socket) do
    if socket.assigns.chat_open, do: send_update(ChatPanel, id: "management-chat", refresh_chat: id)
    {:noreply, socket}
  end

  def handle_info({:chat_list_updated, project}, socket) do
    if socket.assigns.chat_open && project == socket.assigns.chat_project_subscription,
      do: send_update(ChatPanel, id: "management-chat", refresh_threads: project)

    {:noreply, socket}
  end

  def handle_info({:chat_panel, :project_subscription, project}, socket) do
    if project && not socket.assigns.chat_open do
      Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "chat_project:" <> project)
      {:noreply, assign(socket, :chat_project_subscription, nil)}
    else
      {:noreply, assign(socket, :chat_project_subscription, project)}
    end
  end

  def handle_info({:chat_panel, :close}, socket) do
    socket = socket |> unsubscribe_chat() |> assign(chat_open: false, chat_id: nil, view_context: nil)
    {:noreply, push_patch(socket, to: board_location(socket))}
  end

  def handle_info({:chat_panel, :navigate, %{project_id: project, chat_id: id}}, socket) do
    if Enum.any?(socket.assigns.board.projects, &(&1.id == project)) do
      filters = Map.put(socket.assigns.url_filters, "project", project)
      changed = project != socket.assigns.chat_project

      socket =
        socket
        |> assign(:url_filters, filters)
        |> assign(:chat_project, project)
        |> assign(:chat_id, bounded_chat_id(id))

      socket = if changed, do: clear_card_context(socket), else: socket
      {:noreply, push_patch(socket, to: board_location(socket))}
    else
      {:noreply, assign(socket, :notice, "Choose a project available in this board.")}
    end
  end

  def handle_info({:chat_panel, :board_link, url}, socket) do
    case chat_board_link(url, socket.assigns.chat_project) do
      {:ok, params} ->
        params = Map.merge(params, chat_params(socket))
        {:noreply, push_patch(socket, to: board_path(params))}

      :error ->
        {:noreply, assign(socket, :notice, "That reference does not belong to this project board.")}
    end
  end

  @impl true
  def handle_async(:board, {:ok, result}, socket) do
    # A failed source cannot turn last-known work into an empty successful board.
    previous = socket.assigns.board

    result =
      if result.source_error || result.runtime_error do
        previous_tasks = Map.new(previous.tasks, &{&1.id, &1})
        tasks = Map.merge(Map.new(result.tasks, &{&1.id, &1}), previous_tasks) |> Map.values()
        %{result | tasks: tasks, generated_at: previous.generated_at}
      else
        result
      end

    selected = socket.assigns.selected
    current = selected && Enum.find(result.tasks, &(&1.id == selected.id))
    socket = refresh_payload(socket, result)
    socket = socket |> assign(:board, result) |> assign(:selected, current) |> assign(:loading, false)

    socket =
      if selected && is_nil(current) && socket.assigns.dialog == :task do
        socket = socket |> clear_card_context() |> assign(:notice, "Task no longer available in this board.")
        push_patch(socket, to: board_location(socket), replace: true)
      else
        socket
      end

    {:noreply, open_linked_task(socket)}
  end

  def handle_async(:board, {:exit, _reason}, socket) do
    board = Map.put(socket.assigns.board, :source_error, "Board refresh failed; showing last-known tasks.")
    {:noreply, socket |> assign(:board, board) |> assign(:loading, false)}
  end

  @impl true
  def handle_event(action, params, socket)
      when action in ["new-task", "move-task", "prepare-command", "confirm-command", "save-concurrency", "reset-concurrency"] do
    if read_only?(socket.assigns.board) do
      dialog = if socket.assigns.dialog in [:confirm, :new_task], do: nil, else: socket.assigns.dialog
      {:noreply, socket |> assign(:pending_command, nil) |> assign(:dialog, dialog) |> assign(:notice, "This board is read-only. Execution and tracker changes are unavailable here.")}
    else
      handle_write_event(action, params, socket)
    end
  end

  def handle_event("open-task", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.board.tasks, &(&1.id == id)) do
      nil ->
        {:noreply, assign(socket, :notice, "That task is no longer in the current board. Refresh and try again.")}

      task ->
        socket =
          socket
          |> assign(:selected, task)
          |> assign(:dialog, :task)
          |> assign(:linked_task, id)
          |> clear_view_context()

        {:noreply, push_patch(socket, to: board_location(socket))}
    end
  end

  def handle_event("open-settings", _params, socket) do
    socket = socket |> clear_card_context() |> assign(:dialog, :settings) |> assign(:concurrency_draft, nil)
    {:noreply, refresh_chat_health(socket)}
  end

  def handle_event("settings-tab", %{"tab" => tab}, socket) when tab in ["execution", "ai", "connections"],
    do: {:noreply, assign(socket, :settings_tab, tab)}

  def handle_event("settings-tab", _params, socket), do: {:noreply, socket}

  def handle_event("edit-concurrency", %{"limit" => limit}, socket) when is_binary(limit) and byte_size(limit) <= 10,
    do: {:noreply, assign(socket, :concurrency_draft, limit)}

  def handle_event("edit-concurrency", _params, socket), do: {:noreply, socket}
  def handle_event("cancel-settings-edit", _params, socket), do: {:noreply, assign(socket, :concurrency_draft, nil)}
  def handle_event("refresh-settings", _params, socket), do: {:noreply, socket |> refresh_chat_health() |> refresh_board()}

  def handle_event("cancel-command", _params, socket) do
    if socket.assigns.pending_command && socket.assigns.pending_command.action == "set_concurrency" do
      {:noreply, socket |> assign(:pending_command, nil) |> assign(:dialog, :settings)}
    else
      handle_event("close-dialog", %{}, socket)
    end
  end

  def handle_event("close-dialog", _params, socket) do
    socket = socket |> clear_card_context() |> assign(:pending_command, nil)
    {:noreply, push_patch(socket, to: board_location(socket))}
  end

  def handle_event("board-filters", params, socket) do
    filters = url_filters(params)
    socket = socket |> assign(:url_filters, filters) |> clear_view_context()

    socket =
      if selected_project(socket.assigns.board, filters) != socket.assigns.chat_project,
        do: socket |> assign(:chat_id, nil) |> clear_card_context(),
        else: socket

    {:noreply, push_patch(socket, to: board_location(socket), replace: true)}
  end

  def handle_event("open-chat", _params, socket) do
    socket = assign(socket, :chat_open, true)
    {:noreply, push_patch(socket, to: board_location(socket))}
  end

  def handle_event("board-view-context", params, socket) do
    context = validated_context(params, socket)
    {:noreply, assign(socket, :view_context, context)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, refresh_board(socket)}

  defp handle_write_event("new-task", _params, socket), do: {:noreply, assign(socket, :dialog, :new_task)}

  defp handle_write_event("move-task", %{"id" => id, "stage" => stage}, socket) do
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == id))

    cond do
      is_nil(task) ->
        {:noreply, assign(socket, :notice, "Task unavailable; refresh the board.")}

      task.stage == "ready" and stage == "backlog" ->
        prepare_command(socket, "cancel", task)

      task.stage == "backlog" and stage == "ready" and not is_nil(task.hold) ->
        prepare_command(socket, "retry", task)

      true ->
        {:noreply,
         socket
         |> assign(:selected, task)
         |> assign(:dialog, :task)
         |> assign(:notice, "Stages follow confirmed work. Manage intake labels in the issue tracker; review and completion require their evidence.")}
    end
  end

  defp handle_write_event("prepare-command", %{"action" => action} = params, socket) do
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == params["id"]))

    if action in ["pause", "drain", "resume"] or (action in ["cancel", "retry"] and task) do
      prepare_command(socket, action, task)
    else
      {:noreply, assign(socket, :notice, "Unsupported action.")}
    end
  end

  defp handle_write_event("save-concurrency", %{"limit" => text}, socket) when is_binary(text) and byte_size(text) <= 10 do
    case Integer.parse(text) do
      {limit, ""} -> prepare_concurrency(socket, limit)
      _ -> {:noreply, assign(socket, :notice, "Enter a whole number within the workflow ceiling.")}
    end
  end

  defp handle_write_event("save-concurrency", _params, socket), do: {:noreply, assign(socket, :notice, "Enter a whole number within the workflow ceiling.")}
  defp handle_write_event("reset-concurrency", _params, socket), do: prepare_concurrency(socket, nil)

  defp handle_write_event("confirm-command", _params, %{assigns: %{pending_command: nil}} = socket), do: {:noreply, socket}

  defp handle_write_event("confirm-command", _params, socket) do
    pending = socket.assigns.pending_command

    result =
      if pending.action == "set_concurrency" do
        BoardActions.settings_command(pending.limit, pending.revision, pending.id, socket.assigns.auth, orchestrator())
      else
        BoardActions.command(pending.action, pending.issue_id, pending.revision, pending.id, socket.assigns.auth, orchestrator())
      end

    case result do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:dialog, if(pending.action == "set_concurrency", do: :settings))
         |> assign(:concurrency_draft, nil)
         |> assign(:pending_command, nil)
         |> assign(:notice, command_receipt(pending.action))
         |> refresh_board()}

      {:error, reason} ->
        # Keep the original command identity on an uncertain response so a retry is idempotent.
        {:noreply, socket |> assign(:notice, command_error(reason)) |> refresh_board()}
    end
  end

  defp prepare_command(socket, action, task) do
    control = socket.assigns.board.control

    if BrowserAuth.authorized?(socket.assigns.auth) and control["enabled"] == true and is_integer(control["revision"]) do
      pending = %{
        action: action,
        issue_id: task && task.issue_id,
        identifier: task && task.identifier,
        revision: control["revision"],
        id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      }

      {:noreply, socket |> assign(:pending_command, pending) |> assign(:dialog, :confirm)}
    else
      {:noreply, socket |> assign(:dialog, :settings) |> assign(:notice, "Unlock local operator controls in Settings before changing execution.")}
    end
  end

  defp prepare_concurrency(socket, limit) do
    board = socket.assigns.board
    settings = reported_settings(board)
    ceiling = get_in(settings, ["concurrency", "ceiling"])

    cond do
      not settings_editable?(socket.assigns) ->
        {:noreply, socket |> assign(:dialog, :settings) |> assign(:notice, "Settings unavailable. Refresh controller state and unlock local controls in Connections.")}

      not is_nil(limit) and (not is_integer(limit) or limit < 1 or limit > ceiling) ->
        {:noreply, assign(socket, :notice, "Choose a limit from 1 to #{ceiling}.")}

      true ->
        pending = %{
          action: "set_concurrency",
          limit: limit,
          issue_id: nil,
          identifier: nil,
          revision: board.control["revision"],
          id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        }

        socket = socket |> assign(:pending_command, pending) |> assign(:settings_tab, "execution")
        {:noreply, socket |> assign(:dialog, :confirm) |> assign(:notice, nil)}
    end
  end

  defp reported_settings(board), do: if(is_map(board.control["settings"]), do: board.control["settings"], else: %{})

  defp settings_available?(settings) do
    case settings["concurrency"] do
      %{"effective" => effective, "ceiling" => ceiling, "default" => default} ->
        is_integer(effective) and is_integer(ceiling) and is_integer(default) and
          effective > 0 and effective <= ceiling and default == ceiling

      _ ->
        false
    end
  end

  defp controls_available?(assigns) do
    board = assigns.board

    not read_only?(board) and BrowserAuth.authorized?(assigns.auth) and not runtime_unavailable?(board, assigns.payload) and
      board.control["enabled"] == true and is_nil(board.control["fault"]) and is_integer(board.control["revision"])
  end

  defp settings_editable?(assigns), do: controls_available?(assigns) and settings_available?(reported_settings(assigns.board))

  defp refresh_chat_health(socket) do
    health =
      cond do
        read_only?(socket.assigns.board) ->
          "Unavailable in read-only preview"

        not BrowserAuth.authorized?(socket.assigns.auth) ->
          "Unlock controls to inspect"

        true ->
          server = Endpoint.config(:chat_store) || SymphonyElixir.Chat.Store

          case chat_service_health(server, socket.assigns.auth) do
            {:ok, %{enabled: false}} -> "Disabled"
            {:ok, %{enabled: true, healthy: true}} -> "Service available · sign-in not checked"
            {:ok, %{enabled: true, healthy: false}} -> "Storage unavailable"
            _ -> "Service unavailable"
          end
      end

    assign(socket, :chat_health, health)
  end

  defp chat_service_health(module, auth) do
    if Code.ensure_loaded?(module) and function_exported?(module, :health, 1), do: module.health(auth), else: {:error, :unavailable}
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        authorized: BrowserAuth.authorized?(assigns.auth),
        read_only: read_only?(assigns.board),
        settings: reported_settings(assigns.board),
        settings_editable: settings_editable?(assigns),
        controls_available: controls_available?(assigns),
        settings_projects: Enum.map(assigns.board.projects, &Map.put(&1, :url, safe_url(&1.url)))
      )

    ~H"""
    <section id="task-board-app" class="dashboard-shell" phx-hook="TaskBoard" data-density="compact" data-theme="light"
      data-chat-open={to_string(@chat_open)} data-chat-project={@chat_project} data-board-checked-at={@board.generated_at} data-context-revision={@context_revision}
      data-scope={scope(@board)} data-projects={Jason.encode!(@board.projects)} data-url-filters={Jason.encode!(@url_filters)} data-selected-task={@dialog == :task && @selected && @selected.id}>
      <div class="board-main">
      <header class="board-header">
        <a href="/" class="brand"><span class="brand-mark" aria-hidden="true">∿</span> Symphony</a>
        <span class="header-divider" aria-hidden="true">/</span><span class="board-heading">Projects</span>
        <span class="header-spacer"></span>
        <div id="board-search" phx-update="ignore"><input type="search" data-board-search aria-label="Search tasks" placeholder="Search tasks…" /></div>
        <button id="settings-button" class="button button-quiet" phx-click="open-settings">Settings</button>
        <button :if={!@read_only} id="new-task-button" class="button button-primary" phx-click="new-task">+ New task</button>
        <button id="open-chat-button" class="button button-quiet" phx-click="open-chat" aria-expanded={to_string(@chat_open)} aria-controls="management-chat-dock">Chat</button>
      </header>

      <div id="board-toolbar" class="board-toolbar" phx-update="ignore">
        <div class="toolbar-primary">
          <div class="filter-combo project-combo" data-filter="project">
            <div class="combo-control"><input id="filter-project" role="combobox" aria-label="Project filter"
              autocomplete="off" aria-autocomplete="list" aria-expanded="false" aria-controls="options-project"
              placeholder="Project: All" /><button type="button" data-filter-toggle="project" aria-label="Open project filter">⌄</button></div>
            <div id="options-project" class="combo-options" role="listbox" aria-label="Project options" aria-multiselectable="true" hidden></div>
          </div>
          <span class="header-spacer"></span>
          <button type="button" class="button button-quiet toolbar-button" data-toggle-filters aria-expanded="false" aria-controls="board-filter-panel">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M7 12h10M10 17h4" /></svg>Filter</button>
          <details class="board-menu display-menu">
            <summary><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h9m4 0h3M4 17h3m4 0h9M13 4v6M7 14v6" /></svg>Display</summary>
            <div class="board-menu-panel">
              <label class="display-field"><span>Sort by</span><select data-board-sort aria-label="Sort cards">
                <option value="manual">Manual order</option><option value="priority">Priority first</option>
                <option value="updated">Recently updated</option><option value="oldest">Oldest first</option><option value="title">Title A–Z</option>
              </select></label>
              <label class="display-field"><span>Cards</span><select data-board-density aria-label="Card details"><option value="compact">Compact</option><option value="details">Detailed</option></select></label>
              <label class="display-field"><span>Appearance</span><select data-board-theme aria-label="Board appearance"><option value="light">Light</option><option value="dark">Dark</option><option value="system">System</option></select></label>
              <fieldset class="display-columns"><legend>Visible columns</legend><label :for={{id, label} <- @lanes}><input type="checkbox" data-visible-lane={id} checked={id != "done"} />{label}</label></fieldset>
            </div>
          </details>
        </div>
        <div id="board-filter-panel" class="filter-row" data-filter-panel hidden>
          <div :for={key <- ["status", "priority"]} class="filter-combo" data-filter={key}>
            <div class="combo-control"><input id={"filter-#{key}"} role="combobox" aria-label={"#{String.capitalize(key)} filter"}
              autocomplete="off" aria-autocomplete="list" aria-expanded="false" aria-controls={"options-#{key}"}
              placeholder={"#{String.capitalize(key)}: All"} /><button type="button" data-filter-toggle={key} aria-label={"Open #{key} filter"}>⌄</button></div>
            <div id={"options-#{key}"} class="combo-options" role="listbox" aria-label={"#{String.capitalize(key)} options"} aria-multiselectable="true" hidden></div>
          </div>
          <button type="button" class="button button-quiet" data-clear-filters>Clear filters</button>
        </div>
        <div data-filter-chips class="filter-chips" aria-label="Selected filters"></div>
      </div>

      <div class="board-content">
        <p :if={@notice} class="board-notice" role="status">{@notice}</p>
        <p :if={Phoenix.Flash.get(@flash, :error)} class="board-warning" role="alert">{Phoenix.Flash.get(@flash, :error)}</p>
        <p :if={Phoenix.Flash.get(@flash, :info)} class="board-notice" role="status">{Phoenix.Flash.get(@flash, :info)}</p>
        <p :if={@payload[:error]} class="board-warning" role="alert"><strong>Snapshot unavailable:</strong> {@payload.error.code}</p>
        <p :if={@board.source_error} class="board-warning" role="alert">{@board.source_error}</p>
        <p :if={@board.runtime_error} class="board-warning" role="alert">{@board.runtime_error}</p>
        <p :if={Map.get(@board, :enrichment_error)} class="board-warning" role="alert"><strong>Pull request details incomplete:</strong> {Map.get(@board, :enrichment_error)}</p>
        <div class="board-summary"><span data-result-count>{length(@board.tasks)} tasks</span>
          <span class="summary-right"><span :if={@loading}>Refreshing…</span>
          <button class="button button-small" phx-click="refresh" disabled={@loading}>Refresh</button></span></div>
        <div id="mobile-lane-control" class="mobile-lane-control" phx-update="ignore"><label>Lane <select data-mobile-lane aria-label="Board lane">
          <option :for={{id, label} <- @lanes} value={id}>{label}</option>
        </select></label></div>
        <div class="kanban-board">
          <section :for={{stage, label} <- @lanes} id={"lane-#{stage}"} class="kanban-lane" data-stage={stage} aria-label={"#{label} lane"}>
            <div class="lane-heading"><h2><span class={"lane-dot lane-dot-#{stage}"} aria-hidden="true"></span>{label}<span class="lane-count" data-lane-count>{Enum.count(@board.tasks, &(&1.stage == stage))}</span></h2>
              <details class="board-menu lane-menu"><summary aria-label={"#{label} column options"}>···</summary><div class="board-menu-panel"><button type="button" data-hide-lane={stage}>Hide column</button></div></details>
              <button :if={!@read_only && stage == "backlog"} class="lane-add" phx-click="new-task" aria-label="Create a task in GitHub">+</button>
            </div>
            <div class="lane-cards" data-lane-cards>
              <article :for={task <- Enum.filter(@board.tasks, &(&1.stage == stage))} id={card_id(task)} class="task-card" draggable={to_string(!@read_only)}
                data-task-id={task.id} data-project={task.project} data-priority={priority(task.priority)} data-attention={to_string(not is_nil(task.attention))}
                data-title={task.title} data-identifier={task.identifier} data-created={task.created_at || ""} data-updated={task.updated_at || ""}>
                <div class="card-top"><a :if={safe_url(task.url)} href={safe_url(task.url)} target="_blank" rel="noopener noreferrer"
                  aria-label={"Open #{task.identifier} in the issue tracker"}>{task.identifier}</a><span :if={!safe_url(task.url)}>{task.identifier}</span>
                  <span class="priority" data-priority={priority(task.priority)}>{priority(task.priority)}</span></div>
                <button id={"open-#{card_id(task)}"} class="card-title" phx-click="open-task" phx-value-id={task.id}><span class={"lane-dot lane-dot-#{stage}"} aria-hidden="true"></span><span>{task.title}</span></button>
                <div class="card-project">{task.project_label}</div>
                <div class="card-evidence"><span class="evidence-badge">Issue: {display(Map.get(task, :tracker_state))}</span><span>{task_execution(task)}</span></div>
                <span :if={blocker(task)} class="attention-badge">{blocker(task)}</span>
                <div :if={pull_requests(task) != []} class="card-pr-summary"><span :for={pr <- Enum.take(pull_requests(task), 2)}>
                  <a :if={safe_url(field(pr, :url))} href={safe_url(field(pr, :url))} target="_blank" rel="noopener noreferrer">PR #{field(pr, :number)}</a>
                  <span class="pr-state" data-pr-state={String.downcase(pr_state(pr))}>{pr_state(pr)}</span>
                  <span class="compact-ci" title={ci_summary(pr)}>CI: {display(field(pr, :checks))}</span>
                  <span :if={field(pr, :check_details_status) in ["partial", "stale", "unavailable"]} class="compact-ci-note">Check details: {field(pr, :check_details_status)}</span>
                </span><button :if={length(pull_requests(task)) > 2} class="card-more-links" phx-click="open-task" phx-value-id={task.id}>View all {length(pull_requests(task))} pull requests</button></div>
                <div :if={pull_requests(task) != []} class="card-pull-requests">
                  <.pull_request :for={pr <- Enum.take(pull_requests(task), 2)} pr={pr} compact={true} />
                  <button :if={length(pull_requests(task)) > 2} class="card-more-links" phx-click="open-task" phx-value-id={task.id}>View all {length(pull_requests(task))} pull requests</button>
                </div>
                <div :if={task_links(task, ["repo", "candidate", "checks"]) != []} class="card-reference-links"><a :for={link <- task_links(task, ["repo", "candidate", "checks"])} href={link.url} target="_blank" rel="noopener noreferrer">{link.label} ↗</a></div>
                <p :if={current_activity(task, @payload)} class="card-activity">{current_activity(task, @payload)}</p>
                <div class="card-bottom"><time datetime={task.updated_at} title={updated_at(task.updated_at)}>{compact_updated_at(task.updated_at)}</time>
                  <select :if={!@read_only} class="move-select" data-move-task={task.id} aria-label={"Move #{task.identifier}"}>
                    <option value="">Move…</option><option :for={{value, title} <- @lanes} :if={value != task.stage} value={value}>{title}</option>
                  </select></div>
              </article>
            </div>
            <p class="lane-empty" data-lane-empty>No tasks</p>
          </section>
          <section class="hidden-lanes" data-hidden-lanes aria-label="Hidden columns">
            <h2><span aria-hidden="true">▾</span> Hidden columns</h2>
            <button :for={{stage, label} <- @lanes} type="button" class="hidden-lane" data-show-lane={stage} aria-label={"Show #{label} column"} hidden={stage != "done"}>
              <span class={"lane-dot lane-dot-#{stage}"} aria-hidden="true"></span><span>{label}</span><span class="lane-count" data-hidden-count={stage}>{Enum.count(@board.tasks, &(&1.stage == stage))}</span>
            </button>
          </section>
        </div>
      </div>
      <div id="board-context" class="board-context" aria-label="Board data and execution status">
        <div class="board-context-state">
          <strong :if={Map.get(@board, :data_mode)}>{Map.get(@board, :data_mode)}</strong>
          <span class="board-source-state" data-unavailable={to_string(not is_nil(@board.source_error))}>{source_status(@board, @loading)}</span>
          <span class="board-runtime-state" data-unavailable={to_string(runtime_unavailable?(@board, @payload))}>{execution_status(@board, @payload)}</span>
          <span :if={@read_only} class="evidence-badge">Read-only</span>
        </div>
        <div :if={context_links(@board) != []} class="board-context-links">
          <a :for={link <- context_links(@board)} href={link.url} target="_blank" rel="noopener noreferrer">{link.label} ↗</a>
        </div>
        <p :if={Map.get(@board, :source_note)} class="board-source-note">{Map.get(@board, :source_note)}</p>
      </div>
      <footer class="board-footer"><span class="status-stack"><span class="status-badge-live">Live updates connected</span><span class="status-badge-offline">Disconnected · last-known state</span></span>
        <span>Manual order is a browser preference; scheduling follows repository policy.</span></footer>

      <dialog :if={@dialog} id="board-dialog" class="board-dialog" phx-hook="BoardDialog" data-nonmodal={to_string(@chat_open && @dialog == :task)} aria-labelledby="dialog-title">
        <div class="dialog-inner"><div class="dialog-heading"><h2 id="dialog-title">{dialog_title(@dialog, @selected, @pending_command)}</h2>
          <button id="close-dialog" class="button button-quiet" phx-click="close-dialog" aria-label="Close dialog">Close ×</button></div>
          <p :if={@notice} class="board-notice" role="status">{@notice}</p>
          <%= case @dialog do %>
            <% :settings -> %>
              <SettingsPanel.content board={%{@board | projects: @settings_projects}} read_only={@read_only} tab={@settings_tab}
                execution_status={execution_status(@board, @payload)} authorized={@authorized} can_control={@controls_available}
                can_edit={@settings_editable} settings={@settings} settings_available={settings_available?(@settings)} draft={@concurrency_draft}
                project_id={selected_project(@board, @url_filters)} chat_health={@chat_health} source_status={source_status(@board, @loading)}
                loading={@loading} csrf_token={@csrf_token} total_tokens={get_in(@payload, [:codex_totals, :total_tokens]) || "Unavailable"}
                runtime_duration={runtime_duration(@payload)} rate_limits={pretty(@payload[:rate_limits])} />
            <% :task -> %>
              <p class="muted">{@selected.project_label} · {@selected.identifier} · {lane_label(@selected.stage)}</p>
              <button :if={!@chat_open} class="button button-small" phx-click="open-chat">Discuss this task</button>
              <div class="task-evidence"><span class="evidence-badge">Issue: {display(Map.get(@selected, :tracker_state))}</span><span>{task_execution(@selected)}</span></div>
              <div class="task-reference-links"><a :for={link <- task_links(@selected)} class="button button-small" href={link.url} target="_blank" rel="noopener noreferrer">{link.label} ↗</a></div>
              <p :if={blocker(@selected)} class="attention-badge"><strong>Needs attention:</strong> {blocker(@selected)}</p>
              <p :if={Map.get(@selected, :completion_evidence)} class="muted">{Map.get(@selected, :completion_evidence)}</p>
              <section :if={pull_requests(@selected) != []} class="dialog-section"><h3>Pull requests</h3><.pull_request :for={pr <- pull_requests(@selected)} pr={pr} compact={false} /></section>
              <section class="dialog-section"><h3>Scope &amp; acceptance</h3><div class="markdown-content">{Markdown.render(@selected.description)}</div></section>
              <section class="dialog-section"><h3>Codex update</h3><p>{current_activity(@selected, @payload) || "No current worker activity."}</p>
                <button :if={session_id(@selected)} class="button button-small" data-copy={session_id(@selected)}>Copy ID</button>
              </section>
              <section :if={@selected.handoff} class="dialog-section"><h3>Candidate review</h3>
                <p :if={is_binary(field(handoff(@selected), :summary))}>{field(handoff(@selected), :summary)}</p>
                <p>Worker review: {worker_review(@selected)}</p>
                <p :if={is_binary(field(handoff(@selected), :candidate_sha))} class="task-description">Candidate: <code>{field(handoff(@selected), :candidate_sha)}</code></p>
                <p class="muted">Worker review is separate from GitHub review, checks, merge and deployment.</p>
                <details><summary>Handoff details</summary><pre>{pretty(@selected.handoff)}</pre></details>
              </section>
              <section :if={!@read_only} class="dialog-section"><h3>Execution</h3><p class="muted">Cancel requests a hold and worker cleanup. Retry clears a hold without resetting the budget; it does not answer a question or approve a candidate.</p>
                <div class="dialog-actions"><button :for={action <- ["cancel", "retry"]} class="button" phx-click="prepare-command" phx-value-action={action} phx-value-id={@selected.id}>{String.capitalize(action)}</button></div>
                <details><summary>Runtime details</summary><pre>{pretty(@selected.runtime)}</pre></details>
              </section>
            <% :confirm -> %>
              <p>{command_description(@pending_command)}</p>
              <p class="muted">{@pending_command.identifier || "Configured project"} · operator revision {@pending_command.revision}</p>
              <div class="dialog-actions"><button :if={!@read_only} class="button button-primary" phx-click="confirm-command" phx-disable-with="Submitting…">Confirm {if @pending_command.action == "set_concurrency", do: "change", else: @pending_command.action}</button><button class="button" phx-click="cancel-command">Cancel</button></div>
            <% :new_task -> %>
              <p>Create the canonical task in the configured issue tracker. Specify its outcome, scope, acceptance checks and dependencies before queueing.</p>
              <div :if={!@read_only} class="dialog-actions"><a :for={project <- @board.projects} :if={new_issue_url(project)} class="button button-primary" href={new_issue_url(project)} target="_blank" rel="noopener noreferrer">New issue · {project.label} ↗</a></div>
              <p class="muted">Return here and refresh after saving. Queue labels remain managed in GitHub; saving an issue alone does not start a worker.</p>
          <% end %>
        </div>
      </dialog>
      </div>
      <aside :if={@chat_open} id="management-chat-dock" class="management-chat-dock" aria-label="Project chat">
        <.live_component module={ChatPanel} id="management-chat" auth={@auth} csrf_token={@csrf_token}
          embedded={true} project_id={@chat_project} chat_id={@chat_id} view_context={@view_context} read_only={@read_only} />
      </aside>
    </section>
    """
  end

  defp refresh_board(%{assigns: %{loading: true}} = socket), do: socket

  defp refresh_board(socket) do
    server = orchestrator()
    loader = Endpoint.config(:board_loader) || (&TaskBoard.load/2)
    timeout = Endpoint.config(:board_timeout_ms) || 15_000
    socket |> assign(:loading, true) |> start_async(:board, fn -> loader.(server, timeout) end)
  end

  defp initial_board(payload), do: TaskBoard.from_runtime(payload)
  defp read_only?(board), do: Endpoint.config(:board_read_only, false) == true or Map.get(board, :read_only, false) == true

  defp refresh_payload(socket, board) do
    if is_function(Endpoint.config(:snapshot_loader), 0) do
      payload = if is_map(board[:runtime]), do: board.runtime, else: %{error: %{code: "snapshot_unavailable"}}
      assign(socket, :payload, payload)
    else
      socket
    end
  end

  defp source_status(board, loading) do
    provider = if Enum.any?(board.projects, &String.starts_with?(&1.id, "github:")), do: "GitHub", else: "Tracker"

    cond do
      board.source_error -> "#{provider} unavailable · last-known data"
      board.runtime_error -> "Last-known cards · controller unavailable"
      loading -> "#{provider} checking…"
      board.generated_at -> "#{provider} checked #{age(board.generated_at)}"
      true -> "#{provider} not checked"
    end
  end

  defp runtime_unavailable?(board, payload), do: not is_nil(board.runtime_error) or not is_nil(payload[:error])

  defp execution_status(board, payload) do
    cond do
      runtime_unavailable?(board, payload) -> "Execution unavailable"
      board.control["enabled"] == false -> "Execution controls disabled"
      is_binary(board.control["mode"]) -> "Controller: #{display(board.control["mode"])} · #{active_count(payload)}"
      true -> "Execution unavailable"
    end
  end

  defp active_count(payload) do
    case payload[:running] do
      running when is_list(running) -> if Enum.all?(running, &is_map/1), do: "#{length(running)} active", else: "active unknown"
      _ -> "active unknown"
    end
  end

  defp task_execution(task), do: "Execution: " <> display(Map.get(task, :execution_status))
  defp blocker(task), do: Map.get(task, :blocker_reason) || task.attention
  defp display(value) when is_binary(value) and value != "", do: value |> String.downcase() |> String.replace("_", " ") |> String.capitalize()
  defp display(_), do: "Unknown"
  defp records(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp records(_), do: []
  defp field(record, key), do: Map.get(record, key, Map.get(record, Atom.to_string(key)))
  defp pull_requests(task), do: task |> Map.get(:pull_requests, []) |> records()
  defp handoff(task), do: if(is_map(task.handoff), do: task.handoff, else: %{})

  defp worker_review(task) do
    case field(handoff(task), :review) do
      review when is_map(review) -> display(field(review, :verdict))
      _ -> "Unknown"
    end
  end

  defp context_links(board), do: board |> Map.get(:context_links, []) |> records() |> valid_links()

  defp task_links(task, kinds \\ ["issue", "repo", "pr", "checks", "candidate"]) do
    supplied = records(Map.get(task, :links, []))
    fallback = [%{kind: "issue", label: "Open issue in tracker", url: task.url}]

    (supplied ++ fallback)
    |> Enum.filter(&(link_kind(&1) in kinds))
    |> valid_links()
    |> Enum.uniq_by(& &1.url)
  end

  defp link_kind(link) do
    kind = field(link, :kind)
    kind = if is_atom(kind), do: Atom.to_string(kind), else: kind

    case kind do
      "repository" -> "repo"
      "pull_request" -> "pr"
      "commit" -> "candidate"
      other when is_binary(other) -> other
      _ -> nil
    end
  end

  defp valid_links(links) do
    links |> Enum.map(&valid_link/1) |> Enum.reject(&is_nil/1)
  end

  defp valid_link(link) do
    case {safe_url(field(link, :url)), field(link, :label)} do
      {url, label} when is_binary(url) and is_binary(label) and label != "" -> %{url: url, label: label}
      _ -> nil
    end
  end

  defp pr_state(pr) do
    state = display(field(pr, :state))
    if field(pr, :draft) == true and state not in ["Merged", "Closed"], do: "Draft", else: state
  end

  defp pull_request(assigns) do
    pr = assigns.pr
    label = "PR ##{field(pr, :number)}"

    assigns =
      assign(assigns,
        url: safe_url(field(pr, :url)),
        label: label,
        state: pr_state(pr),
        title: field(pr, :title),
        review: display(field(pr, :review)),
        checks: display(field(pr, :checks)),
        head_ref: field(pr, :head_ref),
        base_ref: field(pr, :base_ref),
        author: field(pr, :author),
        commit: pr_commit(pr),
        changes: pr_changes(pr),
        mergeability: pr_mergeability(pr),
        jobs: pr_jobs(pr),
        workflow_runs: workflow_runs(pr_jobs(pr)),
        check_details_status: field(pr, :check_details_status),
        ci_summary: ci_summary(pr)
      )

    ~H"""
    <div class={"pull-request-evidence #{if @compact, do: "compact", else: ""}"}>
      <div class="pull-request-heading"><a :if={@url} href={@url} target="_blank" rel="noopener noreferrer" title={@title}>{@label}<span :if={!@compact && is_binary(@title)}> · {@title}</span></a><strong :if={!@url}>{@label}</strong><span class="evidence-badge">{@state}</span></div>
      <div :if={@head_ref || @commit} class="pull-request-revision"><code :if={is_binary(@head_ref)}>{@head_ref}</code><span :if={!@compact && is_binary(@base_ref)}>→ <code>{@base_ref}</code></span><a :if={@commit} href={@commit.url} target="_blank" rel="noopener noreferrer" title={@commit.sha}>{String.slice(@commit.sha, 0, 7)}</a></div>
      <div :if={@changes || (!@compact && @author)} class="pull-request-metadata"><span :if={!@compact && is_binary(@author)}>By {@author}</span><a :if={@changes && @url} href={@url <> "/files"} target="_blank" rel="noopener noreferrer">{@changes.files} {if @changes.files == 1, do: "file", else: "files"}<span class="diff-additions"> +{@changes.additions}</span><span> −{@changes.deletions}</span></a></div>
      <div class="pull-request-checks"><span>GitHub review: {@review}</span><span>CI: {@checks}</span><span :if={!@compact && @mergeability}>{@mergeability}</span></div>
      <details :if={@jobs != []} class="ci-details" open={!@compact}>
        <summary>{@ci_summary}</summary>
        <p :if={@check_details_status == "partial"} class="ci-note">Some check details are unavailable; this list is incomplete.</p>
        <div :for={run <- @workflow_runs} class="ci-workflow"><a :if={run.url} href={run.url} target="_blank" rel="noopener noreferrer">{run.name || "Workflow"}<span :if={run.number}> #{run.number}</span> ↗</a><span :if={!run.url}>{run.name}</span><span :if={is_binary(run.event)}> · {String.replace(run.event, "_", " ")}</span></div>
        <ul class="ci-jobs"><.check_job :for={job <- @jobs} job={job} /></ul>
      </details>
      <p :if={@jobs == [] && @ci_summary} class="ci-note">{@ci_summary}</p>
    </div>
    """
  end

  defp pr_commit(pr) do
    url = safe_url(field(pr, :url))
    sha = field(pr, :head_sha)

    if is_binary(url) && Regex.match?(~r{\Ahttps://github\.com/[^/]+/[^/]+/pull/[1-9][0-9]*\z}, url) &&
         is_binary(sha) && Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      %{sha: sha, url: Regex.replace(~r{/pull/[0-9]+\z}, url, "/commit/" <> sha)}
    end
  end

  defp pr_changes(pr) do
    values = Enum.map([:changed_files, :additions, :deletions], &field(pr, &1))

    if Enum.all?(values, &(is_integer(&1) && &1 >= 0)) do
      [files, additions, deletions] = values
      %{files: files, additions: additions, deletions: deletions}
    end
  end

  defp pr_mergeability(pr) do
    case field(pr, :mergeable) do
      "mergeable" -> "No merge conflicts"
      "conflicting" -> "Merge conflicts"
      _ -> nil
    end
  end

  defp ci_summary(pr) do
    jobs = pr_jobs(pr)
    status = field(pr, :check_details_status)

    cond do
      status == "stale" -> "Check details belong to an older commit."
      status == "unavailable" -> "Individual check details unavailable."
      jobs != [] -> ci_counts(jobs, field(pr, :check_total), status)
      status == "available" -> "No checks reported for this commit."
      status == "partial" -> "Check details incomplete."
      true -> nil
    end
  end

  defp pr_jobs(pr) do
    if field(pr, :check_details_status) in ["available", "partial"], do: records(field(pr, :check_runs)), else: []
  end

  defp workflow_runs(jobs) do
    jobs
    |> Enum.map(fn job ->
      name = field(job, :workflow_name)
      url = safe_url(field(job, :run_url))
      %{name: name, url: url, number: field(job, :run_number), event: field(job, :run_event)}
    end)
    |> Enum.filter(&(&1.url || &1.name))
    |> Enum.uniq_by(&{&1.url, &1.name, &1.number})
  end

  defp ci_counts(jobs, total, status) do
    counts =
      jobs
      |> Enum.frequencies_by(&check_result/1)
      |> Enum.sort_by(fn {result, _} -> {check_rank(result), result} end)
      |> Enum.map_join(", ", fn {result, count} -> "#{count} #{check_count_label(result)}" end)

    prefix = if status == "partial" && is_integer(total), do: "#{length(jobs)} of #{total} checks", else: "#{length(jobs)} checks"
    prefix <> " · " <> counts
  end

  defp check_result(job) do
    status = field(job, :status)
    conclusion = field(job, :conclusion)
    if status == "completed", do: conclusion || "unknown", else: status || "unknown"
  end

  defp check_count_label("success"), do: "passed"
  defp check_count_label("failure"), do: "failed"
  defp check_count_label("in_progress"), do: "running"
  defp check_count_label(result), do: result |> display() |> String.downcase()
  defp check_rank(result) when result in ["failure", "error", "timed_out", "action_required", "startup_failure"], do: 0
  defp check_rank(result) when result in ["in_progress", "queued", "pending", "waiting", "requested"], do: 1
  defp check_rank("success"), do: 3
  defp check_rank(_), do: 2

  defp job_duration(job) do
    case field(job, :duration_ms) do
      ms when is_integer(ms) and ms >= 0 ->
        seconds = div(ms, 1_000)
        if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

      _ ->
        nil
    end
  end

  defp check_job(assigns) do
    job = assigns.job
    result = check_result(job)

    assigns =
      assign(assigns,
        name: field(job, :name) || "Unnamed check",
        url: safe_url(field(job, :url)),
        result: display(result),
        tone: if(result == "success", do: "success", else: if(check_rank(result) == 0, do: "failure", else: "pending")),
        duration: job_duration(job)
      )

    ~H"""
    <li class="ci-job">
      <div class="ci-job-heading"><span class={"ci-indicator #{@tone}"} aria-hidden="true"></span><a :if={@url} href={@url} target="_blank" rel="noopener noreferrer">{@name}</a><span :if={!@url}>{@name}</span></div>
      <div class="ci-job-status"><span>{@result}</span><span :if={@duration}>{@duration}</span></div>
    </li>
    """
  end

  defp current_activity(task, payload) do
    entries = Map.get(payload, :running, []) ++ Map.get(payload, :blocked, [])
    entry = Enum.find(entries, &(&1.issue_id == task.issue_id))
    runtime = task.runtime || %{}
    (entry && entry[:last_message]) || runtime[:last_message] || runtime[:error]
  end

  defp orchestrator, do: Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator

  defp load_payload do
    case Endpoint.config(:snapshot_loader) do
      loader when is_function(loader, 0) -> loader.()
      _ -> Presenter.state_payload(orchestrator(), Endpoint.config(:snapshot_timeout_ms) || 15_000)
    end
  end

  defp url_filters(params),
    do: params |> Map.take(["project", "status", "priority", "q", "sort"]) |> Map.reject(fn {_key, value} -> not is_binary(value) or byte_size(value) > 2_000 or value == "" end)

  defp board_path(filters), do: if(filters == %{}, do: "/", else: "/?" <> URI.encode_query(filters))

  defp unsubscribe_chat(socket) do
    if socket.assigns.chat_id, do: Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "chat:" <> socket.assigns.chat_id)

    if socket.assigns.chat_project_subscription do
      Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "chat_project:" <> socket.assigns.chat_project_subscription)
    end

    assign(socket, :chat_project_subscription, nil)
  end

  defp bounded_chat_id(id) when is_binary(id) and byte_size(id) <= 100, do: id
  defp bounded_chat_id(_), do: nil

  defp clear_view_context(socket) do
    socket |> assign(:view_context, nil) |> update(:context_revision, &(&1 + 1))
  end

  defp clear_card_context(socket) do
    socket |> assign(:dialog, nil) |> assign(:linked_task, nil) |> clear_view_context()
  end

  defp chat_params(%{assigns: %{chat_open: true, chat_id: id}}) do
    if id, do: %{"assistant" => "1", "chat" => id}, else: %{"assistant" => "1"}
  end

  defp chat_params(_socket), do: %{}

  defp board_location(socket) do
    params = Map.merge(socket.assigns.url_filters, chat_params(socket))
    params = if socket.assigns.dialog == :task && socket.assigns.linked_task, do: Map.put(params, "task", socket.assigns.linked_task), else: params
    params = if socket.assigns.dialog == :settings, do: Map.put(params, "panel", "settings"), else: params
    board_path(params)
  end

  defp selected_project(board, filters) do
    projects = Enum.map(board.projects, & &1.id)

    case String.split(filters["project"] || "", ",", trim: true) do
      [id] -> if id in projects, do: id
      [] -> if length(projects) == 1, do: hd(projects)
      _ -> nil
    end
  end

  defp validated_context(params, socket) do
    project = socket.assigns.chat_project
    known = socket.assigns.board.tasks |> Enum.filter(&(&1.project == project)) |> MapSet.new(& &1.id)

    with true <- socket.assigns.chat_open and is_binary(project),
         {:ok, context} when is_map(context) <- ViewContext.validate(params, project),
         true <- Enum.all?(context["visible_task_ids"], &MapSet.member?(known, &1)) do
      selected = socket.assigns.selected
      selected_id = if socket.assigns.dialog == :task && selected && selected.project == project, do: selected.id
      context |> Map.put("selected_task_id", selected_id) |> Map.put("board_checked_at", socket.assigns.board.generated_at)
    else
      _ -> nil
    end
  end

  defp chat_board_link(url, project) when is_binary(url) and is_binary(project) and byte_size(url) <= 4_000 do
    uri = URI.parse(url)
    params = URI.decode_query(uri.query || "")

    if uri.path == "/" && is_nil(uri.host) && is_nil(uri.scheme) && is_nil(uri.fragment) && params["project"] == project do
      {:ok, Map.take(params, ["project", "status", "priority", "q", "sort", "task"])}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp chat_board_link(_url, _project), do: :error

  defp open_linked_task(%{assigns: %{dialog: dialog}} = socket) when dialog in [:settings, :new_task, :confirm],
    do: socket

  defp open_linked_task(%{assigns: %{linked_task: id}} = socket) when is_binary(id) do
    projects = String.split(socket.assigns.url_filters["project"] || "", ",", trim: true)
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == id and (projects == [] or &1.project in projects)))

    cond do
      task -> socket |> assign(:selected, task) |> assign(:dialog, :task)
      socket.assigns.loading -> socket
      true -> socket |> assign(:selected, nil) |> assign(:dialog, nil) |> assign(:notice, "That task is not available in this project board.")
    end
  end

  defp open_linked_task(socket), do: socket
  defp scope(board), do: Enum.map_join(board.projects, ",", & &1.id)
  defp card_id(task), do: "task-" <> Base.url_encode64(task.id, padding: false)
  defp session_id(task), do: task.runtime && (task.runtime[:session_id] || task.runtime["session_id"])
  defp lane_label(stage), do: @lanes |> List.keyfind(stage, 0, {stage, stage}) |> elem(1)
  defp priority(value) when is_integer(value) and value > 0, do: "P#{value}"
  defp priority(_), do: "—"
  defp pretty(nil), do: "Unavailable"
  defp pretty(value), do: inspect(value, pretty: true, limit: 100, printable_limit: 10_000)

  defp runtime_duration(payload) do
    case get_in(payload, [:codex_totals, :seconds_running]) do
      seconds when is_number(seconds) -> "#{Float.round(seconds / 1, 1)} seconds recorded"
      _ -> "Unavailable"
    end
  end

  defp age(nil), do: "Updated time unknown"
  defp age(value), do: value |> to_string() |> String.replace("T", " ") |> String.replace("Z", " UTC")
  defp updated_at(nil), do: "Updated time unknown"
  defp updated_at(value), do: "Updated " <> age(value)

  defp compact_updated_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> "Updated " <> Calendar.strftime(datetime, "%b %-d")
      _ -> "Updated time unknown"
    end
  end

  defp compact_updated_at(_), do: "Updated time unknown"
  defp dialog_title(:settings, _, _), do: "Settings"
  defp dialog_title(:new_task, _, _), do: "New task"
  defp dialog_title(:task, task, _), do: task.title
  defp dialog_title(:confirm, _, %{action: "set_concurrency"}), do: "Change concurrency?"
  defp dialog_title(:confirm, _, pending), do: "#{String.capitalize(pending.action)} #{pending.identifier || "project"}?"

  defp command_description(%{action: "set_concurrency", limit: nil}),
    do: "Restore the workflow concurrency default. Active tasks keep running and cumulative budgets are unchanged. The controller rejects this change if its revision has changed."

  defp command_description(%{action: "set_concurrency", limit: limit}),
    do: "Allow at most #{limit} concurrent tasks. Active tasks keep running; new starts respect this limit and the workflow ceiling. Cumulative budgets are unchanged."

  defp command_description(%{action: action}), do: command_description(action)
  defp command_description("drain"), do: "Finish active work, then stop taking new tasks."
  defp command_description("pause"), do: "Interrupt active work and stop dispatch. Work may require recovery before continuing."
  defp command_description("resume"), do: "Allow eligible tasks to run within existing launch gates and budgets."

  defp command_description("cancel"),
    do: "Hold this issue and request cleanup of any active worker, including a worker claimed since the board was read. Cancellation is not complete until cleanup is confirmed."

  defp command_description("retry"), do: "Clear this issue’s hold without resetting its budget. An eligible task can start again; this does not deliver an answer or automatically repair a candidate."
  defp command_receipt("set_concurrency"), do: "Concurrency saved. Refreshing the controller’s confirmed limit."
  defp command_receipt("cancel"), do: "Cancel accepted. The issue is held; verify worker cleanup before treating it as stopped."
  defp command_receipt(action), do: "#{String.capitalize(action)} accepted. Refreshing confirmed execution state."
  defp command_error(:revision_conflict), do: "State changed. Close this dialog and review the refreshed board before trying again."
  defp command_error(:tracker_changed), do: "Project configuration changed. Reload the page and unlock controls again."
  defp command_error(:unauthorized), do: "Operator session unavailable or expired. Unlock controls in Settings."
  defp command_error(reason), do: "Command not confirmed (#{inspect(reason)}). A repeated confirmation uses the same command ID."

  defp safe_url(url) when is_binary(url) do
    if String.contains?(url, ["\\", "\n", "\r", "\t"]), do: nil, else: safe_uri(URI.parse(url), url)
  end

  defp safe_url(_), do: nil
  defp safe_uri(%URI{scheme: scheme, host: host, userinfo: nil}, url) when scheme in ["http", "https"] and is_binary(host) and host != "", do: url
  defp safe_uri(_uri, _url), do: nil

  defp new_issue_url(%{id: "github:" <> _, url: url}) do
    case safe_url(url) do
      nil -> nil
      safe -> String.trim_trailing(safe, "/") <> "/issues/new"
    end
  end

  defp new_issue_url(_), do: nil
end
