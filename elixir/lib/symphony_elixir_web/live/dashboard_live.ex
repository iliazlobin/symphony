defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc "Live task board with browser preferences and authenticated native controls."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Chat.Sessions
  alias SymphonyElixir.Chat.ViewContext
  alias SymphonyElixir.Config
  alias SymphonyElixirWeb.{BoardActions, BrowserAuth, ChatPanel, Endpoint, Markdown, SettingsPanel, TaskIntakePanel}
  alias SymphonyElixirWeb.{BoardCache, ChatNavigation, ObservabilityPubSub, Presenter}
  alias SymphonyElixirWeb.{TaskBoard, TaskExecution, TaskRework}

  @lanes [{"backlog", "Backlog"}, {"work", "Work"}, {"review", "Review"}, {"done", "Done"}]
  @refresh_ms 30_000

  @impl true
  def mount(_params, session, socket) do
    {scope, board, payload} = initial_state()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:payload_revision, 0)
      |> assign(:board, board)
      |> assign(:board_scope, scope)
      |> assign(:loading, false)
      |> assign(:dialog, nil)
      |> assign(:selected, nil)
      |> assign(:intake_key, nil)
      |> assign(:intake_task, nil)
      |> assign(:intake_subscription, nil)
      |> assign(:pending_command, nil)
      |> assign(:acceptance_commands, %{})
      |> assign(:settings_tab, "execution")
      |> assign(:concurrency_draft, nil)
      |> assign(:chat_health, "Not checked")
      |> assign(:notice, nil)
      |> assign(:auth, BrowserAuth.context(session, socket))
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:lanes, @lanes)
      |> assign(:url_filters, %{})
      |> assign(:linked_task, nil)
      |> assign(:chat_task_id, nil)
      |> assign(:chat_session_id, nil)
      |> assign(:chat_activity, %{})
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
    socket = if socket.assigns.dialog in [:new_task, :queue_task], do: clear_intake_subscription(socket), else: socket
    dialog = if params["panel"] == "settings", do: :settings, else: nil
    filters = url_filters(params)
    project = selected_project(socket.assigns.board, filters)
    chat_task = params["task"] || params["chat_task"]
    chat_session = if Sessions.valid_id?(params["chat_session"]), do: params["chat_session"]
    previous_selection = {socket.assigns.chat_project, socket.assigns.chat_task_id, socket.assigns.chat_session_id}
    selection_changed = {project, chat_task, chat_session} != previous_selection
    focus_chat = focus_session_navigation?(socket, params)
    socket = if selection_changed || filters != socket.assigns.url_filters, do: clear_view_context(socket), else: socket

    socket =
      socket
      |> assign(:dialog, dialog)
      |> assign(:url_filters, filters)
      |> assign(:linked_task, params["task"])
      |> assign(:chat_task_id, chat_task)
      |> assign(:chat_session_id, chat_session)
      |> assign(:chat_project, project)
      |> assign(:chat_id, if(selection_changed, do: nil, else: socket.assigns.chat_id))

    socket = socket |> open_linked_task() |> sync_chat_selection() |> refresh_chat_activity()
    {:noreply, if(focus_chat, do: push_event(socket, "focus-chat-session", %{}), else: socket)}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, socket |> assign(:payload, load_payload()) |> update(:payload_revision, &(&1 + 1))}
  end

  def handle_info(:refresh_board, socket) do
    Process.send_after(self(), :refresh_board, @refresh_ms)
    refresh_intake_history(socket)
    {:noreply, refresh_board(socket)}
  end

  def handle_info({:chat_updated, id}, socket) do
    send_update(ChatPanel, id: "management-chat", refresh_chat: id)
    if socket.assigns.dialog in [:new_task, :queue_task], do: send_update(TaskIntakePanel, id: "task-intake", refresh_action: id)
    {:noreply, socket}
  end

  def handle_info({:chat_list_updated, project}, socket) do
    if project == socket.assigns.chat_project_subscription,
      do: send_update(ChatPanel, id: "management-chat", refresh_threads: project)

    refresh_intake_history(socket)
    {:noreply, refresh_chat_activity(socket)}
  end

  def handle_info({:chat_panel, :project_subscription, project}, socket) do
    {:noreply, assign(socket, :chat_project_subscription, project)}
  end

  # The board always owns an open chat dock. Retired close events cannot hide it.
  def handle_info({:chat_panel, :close}, socket), do: {:noreply, socket}

  def handle_info({:chat_panel, :main}, socket), do: main_chat(socket)

  def handle_info({:chat_panel, :select_issue, id}, socket), do: handle_event("select-task", %{"id" => id}, socket)
  def handle_info({:chat_panel, :session, id, session}, socket), do: focus_chat_session(socket, id, session)

  def handle_info({:chat_panel, :navigate, %{project_id: project, chat_id: id}}, socket) do
    if project == socket.assigns.chat_project do
      {:noreply, socket |> assign(:chat_id, bounded_chat_id(id)) |> refresh_chat_activity()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:chat_panel, :board_link, url}, socket) do
    case chat_board_link(url, socket.assigns.chat_project) do
      {:ok, params} ->
        {:noreply, push_patch(socket, to: board_path(params))}

      :error ->
        {:noreply, assign(socket, :notice, "That reference does not belong to this project board.")}
    end
  end

  def handle_info({:task_intake, :subscribed, id}, socket) do
    if id && socket.assigns.dialog not in [:new_task, :queue_task] do
      Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "chat:" <> id)
      {:noreply, assign(socket, :intake_subscription, nil)}
    else
      {:noreply, assign(socket, :intake_subscription, id)}
    end
  end

  def handle_info({:task_intake, :changed}, socket), do: {:noreply, refresh_board(socket)}

  @impl true
  def handle_async(:board, {:ok, {scope, payload_revision, result}}, socket) do
    if scope == BoardCache.scope(orchestrator()) do
      :ok = BoardCache.put(scope, result)
      {:noreply, apply_board(socket, result, payload_revision)}
    else
      # A completed read belongs to the configuration that started it, never to
      # a new project, credential, controller or data source.
      {:noreply, socket |> assign(:loading, false) |> refresh_board()}
    end
  end

  def handle_async(:board, {:exit, _reason}, socket) do
    if socket.assigns.board_scope == BoardCache.scope(orchestrator()) do
      board = Map.put(socket.assigns.board, :source_error, "Board refresh failed; showing last-known tasks.")
      {:noreply, socket |> assign(:board, board) |> assign(:loading, false)}
    else
      {:noreply, socket |> assign(:loading, false) |> refresh_board()}
    end
  end

  defp apply_board(socket, result, payload_revision) do
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
    socket = if socket.assigns.payload_revision == payload_revision, do: refresh_payload(socket, result), else: socket
    review_ids = for task <- result.tasks, task.stage == "review", do: task.id

    socket =
      socket
      |> assign(:board, result)
      |> assign(:selected, current)
      |> assign(:loading, false)
      |> update(:acceptance_commands, &Map.take(&1, review_ids))

    socket =
      if selected && is_nil(current) && socket.assigns.dialog == :task do
        socket = socket |> clear_card_context() |> assign(:notice, "Task no longer available in this board.")
        push_patch(socket, to: board_location(socket), replace: true)
      else
        socket
      end

    socket |> open_linked_task() |> sync_chat_selection() |> refresh_chat_activity()
  end

  @impl true
  def handle_event(action, params, socket)
      when action in ["new-task", "queue-task", "move-task", "prepare-rework", "prepare-command", "confirm-command", "save-concurrency", "reset-concurrency"] do
    if read_only?(socket.assigns.board) do
      dialog = if socket.assigns.dialog in [:confirm, :new_task, :queue_task, :rework], do: nil, else: socket.assigns.dialog
      {:noreply, socket |> assign(:pending_command, nil) |> assign(:dialog, dialog) |> assign(:notice, "This board is read-only. Execution and tracker changes are unavailable here.")}
    else
      handle_write_event(action, params, socket)
    end
  end

  def handle_event(action, %{"id" => id}, socket) when action in ["select-task", "open-task"] do
    case Enum.find(socket.assigns.board.tasks, &(&1.id == id)) do
      nil ->
        {:noreply, assign(socket, :notice, "That task is no longer in the current board. Refresh and try again.")}

      task ->
        details? = action == "open-task"
        chat_id = if socket.assigns.chat_task_id == id, do: socket.assigns.chat_id
        chat_session = if socket.assigns.chat_task_id == id, do: socket.assigns.chat_session_id

        socket =
          socket
          |> clear_card_context()
          |> assign(:selected, if(details?, do: task))
          |> assign(:dialog, if(details?, do: :task))
          |> assign(:linked_task, if(details?, do: id))
          |> assign(:pending_command, nil)
          |> assign(:chat_task_id, id)
          |> assign(:chat_session_id, chat_session)
          |> assign(:chat_id, chat_id)

        {:noreply, push_patch(socket, to: board_location(socket))}
    end
  end

  def handle_event("open-settings", params, socket) do
    tab = if params["tab"] == "execution", do: "execution", else: socket.assigns.settings_tab

    socket =
      socket
      |> clear_card_context()
      |> assign(:dialog, :settings)
      |> assign(:settings_tab, tab)
      |> assign(:concurrency_draft, nil)

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
      if selected_project(socket.assigns.board, filters) != socket.assigns.chat_project do
        socket
        |> assign(chat_id: nil, chat_task_id: nil, chat_session_id: nil, chat_activity: %{})
        |> clear_card_context()
      else
        socket
      end

    {:noreply, push_patch(socket, to: board_location(socket), replace: true)}
  end

  def handle_event("main-chat", _params, socket), do: main_chat(socket)

  def handle_event("board-view-context", params, socket) do
    context = validated_context(params, socket)
    {:noreply, assign(socket, :view_context, context)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, refresh_board(socket)}

  defp handle_write_event("new-task", _params, socket) do
    if BrowserAuth.authorized?(socket.assigns.auth) do
      socket =
        socket
        |> clear_card_context()
        |> assign(dialog: :new_task, intake_task: nil, intake_key: System.unique_integer([:positive]))

      {:noreply, assign(socket, :notice, nil)}
    else
      {:noreply, socket |> assign(:dialog, :settings) |> assign(:notice, "Sign in before creating a task.")}
    end
  end

  defp handle_write_event("queue-task", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.board.tasks, &(&1.id == id)) do
      %{stage: "backlog", hold: nil} = task -> prepare_queue(socket, task)
      _ -> {:noreply, assign(socket, :notice, "Refresh the board and select an idle Backlog task to queue.")}
    end
  end

  defp handle_write_event("move-task", %{"id" => id, "stage" => stage}, socket) do
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == id))

    move_task(socket, task, stage)
  end

  defp handle_write_event("prepare-command", %{"action" => action} = params, socket) do
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == params["id"]))

    if action in ["pause", "drain", "resume"] or (action in ["cancel", "retry", "accept_task"] and task) do
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

  defp handle_write_event("prepare-rework", %{"rework" => params}, socket) when is_map(params) do
    task = socket.assigns.selected
    id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    revision = socket.assigns.board.control["revision"]

    with true <- (controls_available?(socket.assigns) and is_map(task)) or {:error, :unauthorized},
         {:ok, command} <- TaskRework.prepare(task, params, revision, id, Config.control_settings().base_sha) do
      pending = %{
        action: command["action"],
        issue_id: task.issue_id,
        identifier: task.identifier,
        revision: revision,
        id: id,
        command: command
      }

      {:noreply, socket |> assign(:pending_command, pending) |> assign(:dialog, :confirm) |> assign(:notice, nil)}
    else
      {:error, reason} -> {:noreply, assign(socket, :notice, command_error(reason))}
    end
  end

  defp handle_write_event("prepare-rework", _params, socket), do: {:noreply, assign(socket, :notice, "Enter corrections before returning to Work.")}

  defp handle_write_event("save-concurrency", _params, socket), do: {:noreply, assign(socket, :notice, "Enter a whole number within the workflow ceiling.")}
  defp handle_write_event("reset-concurrency", _params, socket), do: prepare_concurrency(socket, nil)

  defp handle_write_event("confirm-command", _params, %{assigns: %{pending_command: nil}} = socket), do: {:noreply, socket}

  defp handle_write_event("confirm-command", _params, socket) do
    pending = socket.assigns.pending_command

    result =
      cond do
        pending.action == "set_concurrency" -> BoardActions.settings_command(pending.limit, pending.revision, pending.id, socket.assigns.auth, orchestrator())
        pending.action in ["create_pr_work", "continue_pr_work"] -> BoardActions.pr_work_command(pending.command, socket.assigns.auth, orchestrator())
        true -> BoardActions.command(pending.action, pending.issue_id, pending.revision, pending.id, socket.assigns.auth, orchestrator())
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

  defp move_task(socket, nil, _stage), do: {:noreply, assign(socket, :notice, "Task unavailable; refresh the board.")}
  defp move_task(socket, %{stage: stage} = task, "backlog") when stage in ["ready", "running"], do: prepare_command(socket, "cancel", task)

  defp move_task(socket, %{stage: "backlog"} = task, stage) when stage in ["work", "ready"] do
    if is_nil(task.hold), do: prepare_queue(socket, task), else: prepare_command(socket, "retry", task)
  end

  defp move_task(socket, %{stage: "review"} = task, "done"), do: prepare_command(socket, "accept_task", task)

  defp move_task(socket, %{stage: "review"} = task, "work") do
    if controls_available?(socket.assigns),
      do: {:noreply, socket |> assign(:selected, task) |> assign(:dialog, :rework) |> assign(:notice, nil)},
      else: {:noreply, socket |> assign(:dialog, :settings) |> assign(:notice, "Sign in before returning a task to Work.")}
  end

  defp move_task(socket, _task, _stage) do
    {:noreply, assign(socket, :notice, "Move Backlog to Work to start. The agent sends completed work to Review; accept it into Done or return it to Work with corrections.")}
  end

  defp prepare_queue(socket, task) do
    if BrowserAuth.authorized?(socket.assigns.auth) do
      {:noreply,
       socket
       |> clear_card_context()
       |> assign(dialog: :queue_task, intake_task: task, intake_key: System.unique_integer([:positive]), notice: nil)}
    else
      {:noreply, socket |> assign(:dialog, :settings) |> assign(:notice, "Sign in before queueing a task.")}
    end
  end

  defp prepare_command(socket, action, task) do
    control = socket.assigns.board.control

    cond do
      not controls_available?(socket.assigns) ->
        {:noreply, socket |> assign(:dialog, :settings) |> assign(:notice, "Sign in and refresh execution status in Settings before changing execution.")}

      not task_action_available?(action, task, socket.assigns) ->
        {:noreply, socket |> assign(:pending_command, nil) |> assign(:notice, "This action is not available for the task’s current state. Review its execution summary.")}

      true ->
        pending = %{
          action: action,
          issue_id: task && task.issue_id,
          identifier: task && task.identifier,
          revision: control["revision"],
          id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        }

        if action == "accept_task",
          do: accept_task(socket, task, pending),
          else: {:noreply, socket |> assign(:pending_command, pending) |> assign(:dialog, :confirm)}
    end
  end

  defp accept_task(socket, task, pending) do
    command = Map.get_lazy(socket.assigns.acceptance_commands, task.id, fn -> acceptance_command(pending, task) end)
    socket = update(socket, :acceptance_commands, &Map.put(&1, task.id, command))

    case BoardActions.accept_command(command, socket.assigns.auth, orchestrator()) do
      {:ok, _receipt} ->
        socket =
          socket
          |> clear_card_context()
          |> assign(:pending_command, nil)
          |> assign(:notice, command_receipt("accept_task"))
          |> refresh_board()

        {:noreply, push_patch(socket, to: board_location(socket))}

      {:error, reason} ->
        # A lost response may have committed; another deliberate click replays the
        # exact command. Rejected stale evidence requires a fresh human action.
        socket =
          if reason in [:unavailable, :control_unavailable],
            do: socket,
            else: update(socket, :acceptance_commands, &Map.delete(&1, task.id))

        {:noreply, socket |> assign(:notice, acceptance_error(reason)) |> refresh_board()}
    end
  end

  defp acceptance_error(reason) when reason in [:revision_conflict, :task_changed, :candidate_changed],
    do: "The task changed. Review its updated details before accepting it again."

  defp acceptance_error(reason) when reason in [:unavailable, :control_unavailable],
    do: "Acceptance could not be confirmed. Check the task status; accepting again safely checks the same request."

  defp acceptance_error(reason), do: command_error(reason)

  defp acceptance_command(pending, task) do
    %{
      "action" => "accept_task",
      "issue_id" => task.issue_id,
      "command_id" => pending.id,
      "expected_revision" => pending.revision,
      "expected_candidate_sha" => task.handoff && task.handoff["candidate_sha"],
      "expected_updated_at" => task.updated_at,
      "expected_tracker_state" => task.tracker_state
    }
  end

  defp task_action_available?(action, nil, _assigns), do: action in ["pause", "drain", "resume"]

  defp task_action_available?(action, task, assigns) do
    summary = execution_summary(task, assigns.board, assigns.payload)

    (action == "cancel" and summary.cancel?) or (action == "retry" and summary.retry?) or
      (action == "accept_task" and task.stage == "review" and is_nil(task.runtime) and is_nil(task.ledger["active"]))
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
    project_links = SymphonyElixir.ProjectDirectory.links()

    assigns =
      assign(assigns,
        authorized: BrowserAuth.authorized?(assigns.auth),
        chat_activity: if(BrowserAuth.authorized?(assigns.auth), do: assigns.chat_activity, else: %{}),
        read_only: read_only?(assigns.board),
        settings: reported_settings(assigns.board),
        settings_editable: settings_editable?(assigns),
        controls_available: controls_available?(assigns),
        dispatch_guidance: dispatch_guidance(assigns.board, assigns.payload),
        settings_projects: Enum.map(assigns.board.projects, &Map.put(&1, :url, safe_url(&1.url))),
        project_links: project_links,
        project_picker_label: project_picker_label(assigns.board, assigns.url_filters, project_links)
      )

    ~H"""
    <section id="task-board-app" class="dashboard-shell" phx-hook="TaskBoard" data-density="compact" data-theme="light"
      data-chat-open="true" data-chat-project={@chat_project} data-board-checked-at={@board.generated_at} data-context-revision={@context_revision}
      data-scope={scope(@board)} data-projects={Jason.encode!(@board.projects)} data-project-links={Jason.encode!(@project_links)} data-url-filters={Jason.encode!(@url_filters)} data-selected-task={@chat_task_id}>
      <div class="board-main">
      <header class="board-header">
        <div class="board-location">
          <a href="/" class="brand"><span class="brand-mark" aria-hidden="true">∿</span> Symphony</a>
          <span class="header-divider" aria-hidden="true">/</span>
          <div id="board-project-picker" class="filter-combo project-combo" data-filter="project" phx-update="ignore">
            <div class="combo-control"><input id="filter-project" role="combobox" aria-label="Select project"
              autocomplete="off" aria-autocomplete="list" aria-expanded="false" aria-controls="options-project"
              placeholder={@project_picker_label} title={@project_picker_label} /><button type="button" data-filter-toggle="project" aria-label="Open project selector">⌄</button></div>
            <div id="options-project" class="combo-options" role="listbox" aria-label="Project options" hidden></div>
          </div>
        </div>
        <span class="header-spacer"></span>
        <div id="board-search" phx-update="ignore"><input type="search" data-board-search aria-label="Search tasks" placeholder="Search tasks…" /></div>
        <button id="settings-button" class="button button-quiet" phx-click="open-settings">Settings</button>
        <button :if={!@read_only} id="new-task-button" class="button button-primary" phx-click="new-task">+ New task</button>
      </header>

      <div id="board-toolbar" class="board-toolbar" phx-update="ignore">
        <div class="toolbar-primary">
          <div id="board-filter-panel" class="filter-row">
            <div :for={{key, label} <- [{"status", "Status"}, {"priority", "Priority"}, {"milestone", "Milestone"}, {"label", "Tags"}, {"assignee", "Assignee"}]} class="filter-combo" data-filter={key}>
              <div class="combo-control"><input id={"filter-#{key}"} role="combobox" aria-label={"#{label} filter"}
                autocomplete="off" aria-autocomplete="list" aria-expanded="false" aria-controls={"options-#{key}"}
                placeholder={"#{label}: All"} /><button type="button" data-filter-toggle={key} aria-label={"Open #{label} filter"}>⌄</button></div>
              <div id={"options-#{key}"} class="combo-options" role="listbox" aria-label={"#{label} options"} aria-multiselectable="true" hidden></div>
            </div>
            <button type="button" class="button button-quiet" data-clear-filters>Clear filters</button>
          </div>
          <details class="board-menu display-menu">
            <summary><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h9m4 0h3M4 17h3m4 0h9M13 4v6M7 14v6" /></svg>Display</summary>
            <div class="board-menu-panel">
              <label class="display-field"><span>Sort by</span><select data-board-sort aria-label="Sort cards">
                <option value="manual">Manual order</option><option value="priority">Priority first</option>
                <option value="updated">Recently updated</option><option value="oldest">Oldest first</option><option value="title">Title A–Z</option>
              </select></label>
              <label class="display-field"><span>Cards</span><select data-board-density aria-label="Card details"><option value="compact">Compact</option><option value="details">Detailed</option></select></label>
              <label class="display-field"><span>Appearance</span><select data-board-theme aria-label="Board appearance"><option value="light">Light</option><option value="dark">Dark</option><option value="system">System</option></select></label>
            </div>
          </details>
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
        <div :if={@dispatch_guidance} id="board-dispatch-guidance" class="board-notice" role="status">
          <p>{@dispatch_guidance}</p>
          <button type="button" class="button button-small" phx-click="open-settings" phx-value-tab="execution">Execution settings</button>
        </div>
        <div class="board-summary"><span data-result-count>{length(@board.tasks)} tasks</span>
          <span class="summary-right"><span :if={@loading}>Updating…</span></span></div>
        <div id="mobile-lane-control" class="mobile-lane-control" phx-update="ignore"><label>Lane <select data-mobile-lane aria-label="Board lane">
          <option :for={{id, label} <- @lanes} value={id}>{label}</option>
        </select></label></div>
        <p id="card-selection-help" class="visually-hidden">Press Enter or Space to select this task's chat. Open the title for details.</p>
        <div class="kanban-board">
          <section :for={{stage, label} <- @lanes} id={"lane-#{stage}"} class="kanban-lane" data-stage={stage} aria-label={"#{label} lane"}>
            <div class="lane-heading"><h2><span class={"lane-dot lane-dot-#{stage}"} aria-hidden="true"></span>{label}<span class="lane-count" data-lane-count>{Enum.count(@board.tasks, &(task_lane(&1) == stage))}</span></h2>
              <button :if={!@read_only && stage == "backlog"} class="lane-add" phx-click="new-task" aria-label="Create a task in GitHub">+</button>
            </div>
            <div class="lane-cards" data-lane-cards>
              <article :for={task <- Enum.filter(@board.tasks, &(task_lane(&1) == stage))} id={card_id(task)} class="task-card" draggable={to_string(!@read_only)}
                tabindex="0" aria-label={"#{task.identifier}: #{task.title}"} aria-describedby="card-selection-help" aria-current={if @chat_task_id == task.id, do: "true"}
                data-status={task.stage} data-task-id={task.id} data-selected={to_string(@chat_task_id == task.id)} data-project={task.project} data-priority={priority(task.priority)} data-attention={to_string(not is_nil(task.attention))}
                data-labels={Jason.encode!(Map.get(task, :labels, []))} data-milestone={Jason.encode!(Map.get(task, :milestone))} data-assignees={Jason.encode!(Map.get(task, :assignees, []))}
                data-title={task.title} data-identifier={task.identifier} data-created={task.created_at || ""} data-updated={task.updated_at || ""}>
                <div class="card-top"><a :if={safe_url(task.url)} href={safe_url(task.url)} target="_blank" rel="noopener noreferrer"
                  aria-label={"Open #{task.identifier} in the issue tracker"}>{task.identifier}</a><span :if={!safe_url(task.url)}>{task.identifier}</span>
                  <span class="priority" data-priority={priority(task.priority)}>{priority(task.priority)}</span></div>
                <div class="card-title-row"><span class={"lane-dot lane-dot-#{stage}"} aria-hidden="true"></span>
                  <span class="card-title-text"><.link id={"open-#{card_id(task)}"} class="card-title" patch={task_detail_path(@url_filters, task.id, @chat_task_id, @chat_session_id)}>{task.title}</.link></span>
                </div>
                <div class="card-project">{task.project_label}</div>
                <.card_chat_status activity={Map.get(@chat_activity, task.id)} />
                <.feedback_summary task={task} />
                <.execution_summary summary={execution_summary(task, @board, @payload)} compact={true} />
                <span :if={blocker(task) && is_nil(task.hold)} class="attention-badge">{blocker(task)}</span>
                <div :if={pull_requests(task) != []} class="card-pr-summary"><span :for={pr <- Enum.take(pull_requests(task), 3)}>
                  <a :if={safe_url(field(pr, :url))} href={safe_url(field(pr, :url))} target="_blank" rel="noopener noreferrer">PR #{field(pr, :number)}</a>
                  <span class="pr-state" data-pr-state={String.downcase(pr_state(pr))}>{pr_state(pr)}</span>
                  <a :if={pr_checks_url(pr)} class="compact-ci" href={pr_checks_url(pr)} target="_blank" rel="noopener noreferrer"
                    title={ci_summary(pr)} aria-label={"PR ##{field(pr, :number)} checks: #{ci_status(pr)}"}>CI: {ci_status(pr)} ↗</a>
                  <span :if={!pr_checks_url(pr)} class="compact-ci" title={ci_summary(pr)}>CI: {ci_status(pr)}</span>
                  <span :if={field(pr, :check_details_status) in ["partial", "stale", "unavailable"]} class="compact-ci-note">Check details: {field(pr, :check_details_status)}</span>
                </span><.link :if={length(pull_requests(task)) > 3} class="card-pr-overflow" patch={board_path(Map.put(@url_filters, "task", task.id))} aria-label={"View all #{length(pull_requests(task))} pull requests"}>… +{length(pull_requests(task)) - 3}</.link></div>
                <div :if={pull_requests(task) != []} class="card-pull-requests">
                  <.pull_request :for={pr <- Enum.take(pull_requests(task), 3)} pr={pr} compact={true} />
                  <.link :if={length(pull_requests(task)) > 3} class="card-pr-overflow" patch={board_path(Map.put(@url_filters, "task", task.id))} aria-label={"View all #{length(pull_requests(task))} pull requests"}>… +{length(pull_requests(task)) - 3}</.link>
                </div>
                <div :if={task_links(task, ["repo", "candidate", "checks"]) != []} class="card-reference-links"><a :for={link <- task_links(task, ["repo", "candidate", "checks"])} href={link.url} target="_blank" rel="noopener noreferrer">{link.label} ↗</a></div>
                <p :if={current_activity(task, @payload)} class="card-activity">{current_activity(task, @payload)}</p>
                <div class="card-bottom"><time datetime={task.updated_at} title={updated_at(task.updated_at)}>{compact_updated_at(task.updated_at)}</time></div>
              </article>
            </div>
            <p class="lane-empty" data-lane-empty>No tasks</p>
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

      <dialog :if={@dialog} id="board-dialog" class="board-dialog" phx-hook="BoardDialog" data-kind={@dialog} data-nonmodal={to_string(@dialog == :task)} data-content-key={if @dialog == :task, do: @selected.id, else: @dialog} aria-labelledby="dialog-title">
        <div class="dialog-inner"><div class="dialog-heading"><h2 id="dialog-title" tabindex="-1" data-dialog-focus>{dialog_title(@dialog, @selected, @pending_command)}</h2>
          <button :if={@dialog != :task} id="close-dialog" class="button button-quiet" phx-click="close-dialog" aria-label="Close dialog">Close ×</button></div>
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
              <p class="muted">{@selected.project_label} · {@selected.identifier} · {lane_label(task_lane(@selected))}</p>
              <.execution_summary summary={execution_summary(@selected, @board, @payload)} />
              <.feedback_details task={@selected} />
              <div :if={!@read_only && @controls_available} class="dialog-actions execution-actions">
                <button :if={@selected.stage == "backlog" && is_nil(@selected.hold)} id="queue-task-button" class="button button-primary" phx-click="queue-task" phx-value-id={@selected.id}>Move to Work</button>
                <button :if={@selected.stage == "review"} class="button button-primary" phx-click="prepare-command" phx-value-action="accept_task" phx-value-id={@selected.id} phx-disable-with="Accepting…">Accept · Done</button>
                <button :if={@selected.stage == "review"} class="button" phx-click="move-task" phx-value-stage="work" phx-value-id={@selected.id}>Return to Work</button>
                <button :if={execution_summary(@selected, @board, @payload).cancel?} class="button" phx-click="prepare-command" phx-value-action="cancel" phx-value-id={@selected.id}>Cancel execution</button>
                <button :if={execution_summary(@selected, @board, @payload).retry?} class="button" phx-click="prepare-command" phx-value-action="retry" phx-value-id={@selected.id}>Retry</button>
              </div>
              <div :if={@selected.stage == "ready" && @dispatch_guidance} id="task-dispatch-guidance" class="board-notice" role="status">
                <p>{@dispatch_guidance}</p>
                <button type="button" class="button button-small" phx-click="open-settings" phx-value-tab="execution">Execution settings</button>
              </div>
              <div class="task-reference-links"><.link class="button button-small agent-chat-link" patch={session_path(@url_filters, @selected.id, nil)}><ChatPanel.agent_label name={@selected.title} role="task" /><span aria-hidden="true">→</span></.link><a :for={link <- task_links(@selected, if(pull_requests(@selected) == [], do: ["issue", "repo", "pr", "checks", "candidate"], else: ["issue", "repo", "candidate"]))} class="button button-small" href={link.url} target="_blank" rel="noopener noreferrer">{link.label} ↗</a></div>
              <p :if={blocker(@selected) && is_nil(@selected.hold)} class="attention-badge"><strong>Needs attention:</strong> {blocker(@selected)}</p>
              <p :if={Map.get(@selected, :completion_evidence)} class="muted">{Map.get(@selected, :completion_evidence)}</p>
              <section :if={pull_requests(@selected) != []} class="dialog-section"><h3>Pull requests <span class="section-count">{length(pull_requests(@selected))}</span></h3><.pull_request :for={pr <- pull_requests(@selected)} pr={pr} compact={false} chat_url={session_path(@url_filters, @selected.id, pr_session_id(@selected, pr))} /></section>
              <section :if={ChatNavigation.work_sessions(@selected) != []} class="dialog-section" aria-label="Feature agents">
                <h3>Feature agents</h3>
                <article :for={work <- ChatNavigation.work_sessions(@selected)} class="issue-work-session" data-work-id={work.id}>
                  <div class="widget-heading"><a :if={work.pr_url} href={work.pr_url} target="_blank" rel="noopener noreferrer">{work.title} ↗</a><span class="widget-label">{work.phase}</span><.link class="button button-small agent-chat-link" patch={session_path(@url_filters, @selected.id, "work:" <> work.id)}><ChatPanel.agent_label name={work.name} role="feature" /><span aria-hidden="true">→</span></.link></div>
                  <p class="issue-work-instruction">{work.instruction}</p>
                  <p :if={work.summary != ""}>{work.summary}</p>
                  <div class="issue-work-meta"><span :if={work.session_retained}>Session retained</span><span :if={work.review}>Review: {String.replace(work.review, "_", " ")}</span><code :if={work.head != ""}>{work.head}</code><time :if={work.updated_at} datetime={work.updated_at} title={updated_at(work.updated_at)}>{compact_updated_at(work.updated_at)}</time></div>
                </article>
              </section>
              <section class="dialog-section"><h3>Scope &amp; acceptance</h3><div class="markdown-content">{Markdown.render(@selected.description)}</div></section>
              <section :if={current_activity(@selected, @payload) || session_id(@selected)} class="dialog-section"><h3>Codex update</h3><p>{current_activity(@selected, @payload)}</p>
                <button :if={session_id(@selected)} class="button button-small" data-copy={session_id(@selected)}>Copy ID</button>
              </section>
              <.candidate_review :if={settled_handoff?(@selected)} task={@selected} />
            <% :rework -> %>
              <p>Describe the corrections or select GitHub feedback. The task returns to Work after confirmation.</p>
              <form id="task-rework-form" phx-submit="prepare-rework">
                <label class="display-field">Feature agent<select name="rework[work_id]" aria-label="Feature agent to continue">
                  <option :for={work <- TaskRework.options(@selected)} value={work.id}>{work.label}</option>
                  <option value="new">New feature agent</option>
                </select></label>
                <label class="rework-instruction">Corrections<textarea name="rework[instruction]" aria-label="Corrections" rows="4" maxlength="8000" placeholder="What needs to change?"></textarea></label>
                <fieldset :if={feedback_items(@selected) != []} class="feedback-selection"><legend>Include feedback</legend>
                  <label :for={item <- feedback_items(@selected)}>
                    <input type="checkbox" name="rework[feedback_ids][]" value={item["id"]} />
                    <span><a href={safe_url(item["url"])} target="_blank" rel="noopener noreferrer">@{item["author"]} · {feedback_status(item["status"])}</a><span class="feedback-body">{item["body"]}</span></span>
                  </label>
                </fieldset>
                <p :if={feedback_status_value(@selected) != "available"} class="muted">GitHub feedback is {feedback_status_value(@selected)}. You can enter corrections directly.</p>
                <button class="button button-primary" type="submit">Review return to Work</button>
              </form>
            <% :confirm -> %>
              <p>{command_description(@pending_command)}</p>
              <div :if={@pending_command.action in ["create_pr_work", "continue_pr_work"]} class="rework-preview">
                <p>{@pending_command.command["instruction"]}</p>
                <p>{length(@pending_command.command["feedback"])} selected comments · {if @pending_command.action == "create_pr_work", do: "New feature agent", else: "Continue feature agent"}</p>
                <ul><li :for={item <- @pending_command.command["feedback"]}><a href={safe_url(item["url"])} target="_blank" rel="noopener noreferrer">@{item["author"]}</a>: {item["body"]}</li></ul>
                <div :if={@pending_command.command["feedback"] != []} class="feedback-mirror-preview" aria-label="GitHub status reply preview">
                  <p>One status reply on this GitHub issue will be updated as work progresses. It contains source links and statuses, not copied comment text:</p>
                  <ul><li :for={item <- @pending_command.command["feedback"]}>Queued · <a href={safe_url(item["url"])} target="_blank" rel="noopener noreferrer">Feedback from @{item["author"]}</a></li></ul>
                  <p>👀 Working · ✅ Addressed · ❗ Blocked. Human review threads stay open until you resolve them.</p>
                </div>
              </div>
              <p class="muted">{@pending_command.identifier || "Configured project"} · operator revision {@pending_command.revision}</p>
              <div class="dialog-actions"><button :if={!@read_only} class="button button-primary" phx-click="confirm-command" phx-disable-with="Submitting…">Confirm {command_label(@pending_command.action)}</button><button class="button" phx-click="cancel-command">Cancel</button></div>
            <% kind when kind in [:new_task, :queue_task] -> %>
              <.live_component module={TaskIntakePanel} id="task-intake" auth={@auth} read_only={@read_only}
                project_id={if @intake_task, do: @intake_task.project, else: selected_project(@board, @url_filters)} form_key={@intake_key} task={@intake_task} />
          <% end %>
        </div>
      </dialog>
      </div>
      <aside id="management-chat-dock" class="management-chat-dock" aria-label="Project chat">
        <.live_component module={ChatPanel} id="management-chat" auth={@auth} csrf_token={@csrf_token}
          embedded={true} project_id={@chat_project} chat_id={@chat_id} task_id={@chat_task_id} session_id={@chat_session_id}
          task_title={chat_task_title(@board, @chat_task_id)} issue_tasks={@board.tasks} issue_activity={@chat_activity}
          view_context={@view_context} read_only={@read_only} />
      </aside>
    </section>
    """
  end

  defp refresh_intake_history(socket) do
    if socket.assigns.dialog in [:new_task, :queue_task],
      do: send_update(TaskIntakePanel, id: "task-intake", refresh_history: true)
  end

  defp refresh_board(%{assigns: %{loading: true}} = socket), do: socket

  defp refresh_board(socket) do
    server = orchestrator()
    scope = BoardCache.scope(server)
    loader = Endpoint.config(:board_loader) || (&TaskBoard.load/2)
    timeout = Endpoint.config(:board_timeout_ms) || 15_000

    socket =
      if scope == socket.assigns.board_scope do
        socket
      else
        socket
        |> clear_card_context()
        |> assign(:board, initial_board(%{}))
        |> assign(:payload, %{})
        |> assign(:board_scope, scope)
        |> assign(:chat_activity, %{})
        |> assign(:selected, nil)
        |> assign(:pending_command, nil)
        |> assign(:acceptance_commands, %{})
        |> sync_chat_selection()
      end

    payload_revision = socket.assigns.payload_revision

    socket
    |> assign(:loading, true)
    |> start_async(:board, fn -> {scope, payload_revision, loader.(server, timeout)} end)
  end

  # BrowserAccess checks Google identity before either mount. Reuse only a
  # bounded presentation snapshot; writes still revalidate native authority.
  defp initial_state do
    scope = BoardCache.scope(orchestrator())

    with {:ok, board} <- BoardCache.get(scope),
         true <- scope == BoardCache.scope(orchestrator()) do
      {scope, board, board.runtime}
    else
      _ ->
        payload = load_payload()
        current_scope = BoardCache.scope(orchestrator())
        payload = if current_scope == scope, do: payload, else: %{}
        {current_scope, initial_board(payload), payload}
    end
  end

  defp initial_board(payload), do: TaskBoard.from_runtime(payload)
  defp read_only?(board), do: Endpoint.config(:board_read_only, false) == true or Map.get(board, :read_only, false) == true

  defp refresh_payload(socket, board) do
    payload = if is_map(board[:runtime]), do: board.runtime, else: %{error: %{code: "snapshot_unavailable"}}
    assign(socket, :payload, payload)
  end

  defp source_status(board, loading) do
    provider = if Enum.any?(board.projects, &String.starts_with?(&1.id, "github:")), do: "GitHub", else: "Tracker"

    cond do
      board.source_error -> "#{provider} unavailable · last-known data"
      board.runtime_error -> "Last-known cards · controller unavailable"
      loading and board.generated_at -> "#{provider} checked #{age(board.generated_at)} · refreshing…"
      loading -> "#{provider} checking…"
      board.generated_at -> "#{provider} checked #{age(board.generated_at)}"
      true -> "#{provider} not checked"
    end
  end

  defp runtime_unavailable?(board, payload), do: not is_nil(board.runtime_error) or not is_nil(payload[:error])

  defp dispatch_guidance(board, payload) do
    control = board.control

    cond do
      runtime_unavailable?(board, payload) or not is_nil(board.source_error) ->
        nil

      not control_snapshot_available?(control) ->
        nil

      not Enum.any?(board.tasks, &(&1.stage == "ready")) ->
        nil

      control["mode"] == "paused" ->
        "Execution is paused. Ready tasks will not start until execution is resumed; existing holds and limits still apply."

      control["mode"] == "draining" ->
        "Execution is draining. Active work can finish, but Ready tasks will not start until execution is resumed."

      true ->
        nil
    end
  end

  defp control_snapshot_available?(control) do
    control["enabled"] == true and is_nil(control["fault"]) and is_integer(control["revision"]) and
      not Map.has_key?(control, "error") and not Map.has_key?(control, :error)
  end

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

  defp execution_summary(task, board, payload) do
    unavailable = runtime_unavailable?(board, payload) or not is_nil(board.source_error)
    TaskExecution.summary(task, board.control, unavailable)
  end

  attr(:summary, :map, required: true)
  attr(:compact, :boolean, default: false)

  defp execution_summary(assigns) do
    ~H"""
    <div class={["execution-summary", @compact && "compact"]} aria-label="Execution summary">
      <p class="execution-state">{@summary.status}</p>
      <dl :if={@summary.metrics != []} class="execution-metrics">
        <div :for={metric <- @summary.metrics}>
          <dt>{metric.label}</dt><dd title={metric.title}>{metric.value}</dd>
        </div>
      </dl>
      <p :if={@summary.note} class="execution-note">{@summary.note}</p>
    </div>
    """
  end

  defp feedback_items(task), do: get_in(task, [:feedback, :items]) || []
  defp feedback_status_value(task), do: get_in(task, [:feedback, :status]) || "unavailable"
  defp feedback_status("pending"), do: "not queued"
  defp feedback_status(status), do: status || "not queued"

  attr(:task, :map, required: true)

  defp feedback_summary(assigns) do
    items = feedback_items(assigns.task)
    counts = SymphonyElixir.Feedback.counts(items)
    assigns = assign(assigns, counts: counts, status: feedback_status_value(assigns.task), left: counts["pending"] + counts["queued"] + counts["blocked"])

    ~H"""
    <div :if={@counts["total"] > 0} class="card-feedback-summary" aria-label="Comment progress">
      <span>{@counts["total"]} comments{if @status == "partial", do: "+"}</span>
      <span :if={@counts["working"] > 0}>👀 {@counts["working"]} working</span>
      <span :if={@left > 0}>{@left} left</span>
      <span :if={@counts["addressed"] > 0}>{@counts["addressed"]} addressed</span>
      <span :if={@counts["blocked"] > 0} class="attention-badge">{@counts["blocked"]} blocked</span>
    </div>
    """
  end

  attr(:task, :map, required: true)

  defp feedback_details(assigns) do
    assigns = assign(assigns, items: feedback_items(assigns.task), status: feedback_status_value(assigns.task))

    ~H"""
    <section :if={@items != []} class="dialog-section feedback-details" aria-label="GitHub feedback">
      <h3>Feedback</h3>
      <.feedback_summary task={@task} />
      <p :if={@status != "available"} class="muted">Showing cached or partial feedback. Open GitHub for the complete conversation.</p>
      <article :for={item <- @items} class="feedback-item">
        <a href={safe_url(item["url"])} target="_blank" rel="noopener noreferrer">@{item["author"]} ↗</a>
        <span class="widget-label">{feedback_status(item["status"])}</span>
        <p class="feedback-body">{item["body"]}</p>
      </article>
    </section>
    """
  end

  defp blocker(task), do: Map.get(task, :blocker_reason) || task.attention
  defp display(value) when is_binary(value) and value != "", do: value |> String.downcase() |> String.replace("_", " ") |> String.capitalize()
  defp display(_), do: "Unknown"
  defp records(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp records(_), do: []
  defp field(record, key), do: Map.get(record, key, Map.get(record, Atom.to_string(key)))
  defp pull_requests(task), do: task |> Map.get(:pull_requests, []) |> records()
  defp handoff(task), do: if(is_map(task.handoff), do: task.handoff, else: %{})

  defp settled_handoff?(task) do
    is_map(task.handoff) and task.hold == "owner_review" and
      (is_nil(task.runtime) or task.runtime[:status] == "retrying") and is_nil(get_in(task.ledger, ["active"]))
  end

  defp candidate_review(assigns) do
    candidate = handoff(assigns.task)
    review = field(candidate, :review)
    review = if is_map(review), do: review, else: %{}
    sha = field(candidate, :candidate_sha)
    sha = if is_binary(sha) && Regex.match?(~r/\A[0-9a-f]{40}\z/, sha), do: sha

    commit =
      Enum.find_value(pull_requests(assigns.task), fn pr ->
        if sha && field(review, :candidate_sha) == sha && field(pr, :head_sha) == sha, do: pr_commit(pr)
      end)

    assigns =
      assign(assigns,
        sha: sha,
        commit: commit,
        verdict: review_verdict(field(review, :verdict)),
        summary: nonempty(field(review, :summary)) || nonempty(field(candidate, :summary)),
        findings: records(field(review, :findings))
      )

    ~H"""
    <section class="dialog-section candidate-review">
      <div class="candidate-review-heading"><h3>Agent review</h3><span class="evidence-badge">{@verdict}</span>
        <a :if={@commit} href={@commit.url} title={@sha} target="_blank" rel="noopener noreferrer">{String.slice(@sha, 0, 7)}</a>
        <code :if={@sha && !@commit} title={@sha}>{String.slice(@sha, 0, 7)}</code>
      </div>
      <p :if={@summary} class="candidate-summary">{@summary}</p>
      <ul :if={@findings != []} class="candidate-findings">
        <li :for={finding <- @findings}><strong>{display(field(finding, :severity))}</strong><code :if={nonempty(field(finding, :path))}>{field(finding, :path)}<span :if={field(finding, :line)}>:{field(finding, :line)}</span></code><span>{field(finding, :description)}</span></li>
      </ul>
    </section>
    """
  end

  defp review_verdict("approve"), do: "Approved"
  defp review_verdict("request_changes"), do: "Changes requested"
  defp review_verdict("blocked"), do: "Blocked"
  defp review_verdict(_), do: "Unknown"
  defp nonempty(value) when is_binary(value), do: if(String.trim(value) != "", do: value)
  defp nonempty(_), do: nil

  defp context_links(board), do: board |> Map.get(:context_links, []) |> records() |> valid_links()

  defp task_links(task, kinds) do
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
    url = safe_url(field(pr, :url))

    assigns =
      assign(assigns,
        url: url,
        chat_url: assigns[:chat_url],
        number: field(pr, :number),
        label: "PR ##{field(pr, :number)}",
        state: pr_state(pr),
        title: field(pr, :title),
        review: display(field(pr, :review)),
        commit: pr_commit(pr),
        changes: pr_changes(pr),
        mergeability: pr_mergeability(pr),
        revision: Enum.filter([field(pr, :head_ref), field(pr, :base_ref)], &is_binary/1) |> Enum.join(" → "),
        checks_url: pr_checks_url(pr),
        ci_status: ci_status(pr),
        ci_summary: ci_summary(pr),
        ci_note: ci_note(pr)
      )

    ~H"""
    <div class={"pull-request-evidence #{if @compact, do: "compact", else: ""}"} data-pr-number={@number}>
      <div class="pull-request-heading"><a :if={@url} href={@url} target="_blank" rel="noopener noreferrer" title={@title}>{@label}<span :if={!@compact && is_binary(@title)}> · {@title}</span></a><strong :if={!@url}>{@label}</strong><span class="pr-state" data-pr-state={String.downcase(@state)}>{@state}</span><.link :if={@chat_url} class="button button-small agent-chat-link" patch={@chat_url} aria-label={"Open #{@label} feature agent"}><ChatPanel.agent_label name={if is_binary(@title) && @title != "", do: @title, else: @label} role="feature" /><span aria-hidden="true">→</span></.link></div>
      <div class="pull-request-checks"><span>GitHub review: {@review}</span>
        <a :if={@checks_url} href={@checks_url} target="_blank" rel="noopener noreferrer" title={@ci_summary} aria-label={"#{@label} checks: #{@ci_status}"}>CI: {@ci_status} ↗</a>
        <span :if={!@checks_url} title={@ci_summary}>CI: {@ci_status}</span><span :if={@mergeability}>{@mergeability}</span>
      </div>
      <div :if={@commit || @changes} class="pull-request-metadata">
        <a :if={@commit} href={@commit.url} target="_blank" rel="noopener noreferrer" title={@revision <> " · " <> @commit.sha}>{String.slice(@commit.sha, 0, 7)}</a>
        <a :if={@changes && @url} href={@url <> "/files"} target="_blank" rel="noopener noreferrer">{@changes.files} {if @changes.files == 1, do: "file", else: "files"}<span class="diff-additions"> +{@changes.additions}</span><span> −{@changes.deletions}</span></a>
      </div>
      <p :if={@ci_note} class="ci-note">{@ci_note}</p>
    </div>
    """
  end

  defp ci_status(pr) do
    case {field(pr, :check_details_status), pr_jobs(pr)} do
      {"stale", _} -> ci_missing_details(pr, "Stale")
      {"unavailable", _} -> ci_missing_details(pr, "Unavailable")
      {"available", []} -> ci_missing_details(pr, "No checks")
      {_, [_ | _] = jobs} -> display(field(pr, :checks)) <> " · " <> check_counts(jobs)
      _ -> display(field(pr, :checks))
    end
  end

  defp pr_checks_url(pr) do
    url = safe_url(field(pr, :url))
    if is_binary(url) && Regex.match?(~r{\Ahttps://github\.com/[^/]+/[^/]+/pull/[1-9][0-9]*\z}, url), do: url <> "/checks"
  end

  defp ci_missing_details(pr, status) do
    detail = if status == "No checks", do: "no checks", else: "details " <> String.downcase(status)

    case field(pr, :checks) do
      result when result in ["success", "failure", "pending", "error", "expected"] -> display(result) <> " · " <> detail
      _ -> status
    end
  end

  defp ci_note(pr) do
    case field(pr, :check_details_status) do
      "partial" -> "Incomplete check details" <> if(pr_jobs(pr) == [], do: ".", else: ": " <> ci_summary(pr))
      status when status in ["stale", "unavailable"] -> ci_summary(pr)
      _ -> nil
    end
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

  defp ci_counts(jobs, total, status) do
    prefix = if status == "partial" && is_integer(total), do: "#{length(jobs)} of #{total} checks", else: "#{length(jobs)} checks"
    prefix <> " · " <> check_counts(jobs)
  end

  defp check_counts(jobs) do
    jobs
    |> Enum.frequencies_by(&check_result/1)
    |> Enum.sort_by(fn {result, _} -> {check_rank(result), result} end)
    |> Enum.map_join(", ", fn {result, count} -> "#{count} #{check_count_label(result)}" end)
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
    do:
      params
      |> Map.take(["project", "status", "priority", "milestone", "label", "assignee", "q", "sort"])
      |> Map.reject(fn {_key, value} -> not is_binary(value) or byte_size(value) > 2_000 or value == "" end)

  defp board_path(filters), do: if(filters == %{}, do: "/", else: "/?" <> URI.encode_query(filters))

  defp bounded_chat_id(id) when is_binary(id) and byte_size(id) <= 100, do: id
  defp bounded_chat_id(_), do: nil

  defp clear_view_context(socket) do
    socket |> assign(:view_context, nil) |> update(:context_revision, &(&1 + 1))
  end

  defp clear_intake_subscription(socket) do
    if socket.assigns.intake_subscription do
      Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "chat:" <> socket.assigns.intake_subscription)
    end

    assign(socket, :intake_subscription, nil)
  end

  defp clear_card_context(socket) do
    socket |> clear_intake_subscription() |> assign(:dialog, nil) |> assign(:linked_task, nil) |> clear_view_context()
  end

  defp focus_session_navigation?(socket, params) do
    is_binary(params["chat_task"]) and is_nil(params["task"]) and
      is_binary(socket.assigns.linked_task)
  end

  defp focus_chat_session(socket, task_id, session) do
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == task_id and &1.project == socket.assigns.chat_project))

    if (BrowserAuth.authorized?(socket.assigns.auth) and task) && (is_nil(session) or Enum.any?(Sessions.options(task, [session]), &(&1.id == session))) do
      socket =
        socket
        |> clear_card_context()
        |> assign(chat_task_id: task_id, chat_session_id: session, chat_id: nil, selected: nil)

      {:noreply, socket |> push_patch(to: board_location(socket)) |> push_event("focus-chat-session", %{})}
    else
      {:noreply, socket}
    end
  end

  defp session_path(filters, task_id, session) do
    params = Map.put(filters, "chat_task", task_id)
    board_path(if(session, do: Map.put(params, "chat_session", session), else: params))
  end

  defp task_detail_path(filters, task_id, selected, session) do
    params = Map.put(filters, "task", task_id)
    board_path(if(task_id == selected and session, do: Map.put(params, "chat_session", session), else: params))
  end

  defp pr_session_id(task, pr) do
    case Enum.find(Sessions.options(task), &(&1.pr && &1.pr.number == field(pr, :number))) do
      nil -> nil
      option -> option.id
    end
  end

  defp board_location(socket) do
    params = socket.assigns.url_filters
    params = if socket.assigns.chat_task_id, do: Map.put(params, "chat_task", socket.assigns.chat_task_id), else: params
    params = if socket.assigns.chat_session_id, do: Map.put(params, "chat_session", socket.assigns.chat_session_id), else: params
    params = if socket.assigns.dialog == :task && socket.assigns.linked_task, do: Map.put(params, "task", socket.assigns.linked_task), else: params
    params = if socket.assigns.dialog == :settings, do: Map.put(params, "panel", "settings"), else: params
    board_path(params)
  end

  defp main_chat(socket) do
    socket =
      socket
      |> clear_card_context()
      |> assign(chat_task_id: nil, chat_session_id: nil, chat_id: nil, selected: nil)

    {:noreply, push_patch(socket, to: board_location(socket))}
  end

  defp sync_chat_selection(socket) do
    id = socket.assigns.chat_task_id
    project = selected_project(socket.assigns.board, socket.assigns.url_filters)
    socket = assign(socket, :chat_project, project)
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == id and (is_nil(project) or &1.project == project)))

    cond do
      task ->
        session = if Enum.any?(Sessions.options(task, [socket.assigns.chat_session_id]), &(&1.id == socket.assigns.chat_session_id)), do: socket.assigns.chat_session_id
        assign(socket, chat_project: task.project, chat_session_id: session)

      id && socket.assigns.loading ->
        assign(socket, :chat_project, nil)

      id ->
        socket |> assign(chat_task_id: nil, chat_session_id: nil, chat_id: nil) |> clear_view_context()

      true ->
        socket
    end
  end

  defp chat_task_title(board, id) do
    case Enum.find(board.tasks, &(&1.id == id)) do
      nil -> nil
      task -> "#{task.identifier} · #{task.title}"
    end
  end

  defp refresh_chat_activity(socket) do
    project = socket.assigns.chat_project

    if connected?(socket) and is_binary(project) and BrowserAuth.authorized?(socket.assigns.auth) and not read_only?(socket.assigns.board) do
      store = Endpoint.config(:chat_store, SymphonyElixir.Chat.Store)

      case store.list(project, socket.assigns.auth) do
        {:ok, chats} ->
          activity = ChatNavigation.chat_activity(chats, project)
          assign(socket, :chat_activity, activity)

        _ ->
          assign(socket, :chat_activity, %{})
      end
    else
      assign(socket, :chat_activity, %{})
    end
  rescue
    _ -> assign(socket, :chat_activity, %{})
  catch
    :exit, _ -> assign(socket, :chat_activity, %{})
  end

  defp card_chat_status(assigns) do
    activity = assigns.activity || %{}

    assigns =
      assign(assigns,
        running: activity["status"] == "running" or activity["display_status"] == "action",
        queued: activity["queued_count"] || 0,
        paused: activity["queue_paused"] == true
      )

    ~H"""
    <div :if={@running or @queued > 0} class="card-chat-status" data-running={to_string(@running)} role="status">
      <span :if={@running} class="card-chat-processing"><span class="chat-status-spinner" aria-hidden="true"></span>Chat processing</span>
      <span :if={@queued > 0} class="card-chat-queued">{@queued} queued{if @paused, do: " · paused"}</span>
    </div>
    """
  end

  defp project_picker_label(board, filters, links) do
    case Enum.find(board.projects, &(&1.id == selected_project(board, filters))) do
      nil -> "All projects"
      project -> Enum.find_value(links, project.label, &if(&1["id"] == project.id, do: &1["label"]))
    end
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

    with true <- is_binary(project),
         {:ok, context} when is_map(context) <- ViewContext.validate(params, project),
         true <- Enum.all?(context["visible_task_ids"], &MapSet.member?(known, &1)) do
      context |> Map.put("selected_task_id", socket.assigns.chat_task_id) |> Map.put("board_checked_at", socket.assigns.board.generated_at)
    else
      _ -> nil
    end
  end

  defp chat_board_link(url, project) when is_binary(url) and is_binary(project) and byte_size(url) <= 4_000 do
    uri = URI.parse(url)
    params = URI.decode_query(uri.query || "")

    if uri.path == "/" && is_nil(uri.host) && is_nil(uri.scheme) && is_nil(uri.fragment) && params["project"] == project do
      {:ok, Map.take(params, ["project", "status", "priority", "milestone", "label", "assignee", "q", "sort", "task"])}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp chat_board_link(_url, _project), do: :error

  defp open_linked_task(%{assigns: %{dialog: dialog}} = socket) when dialog in [:settings, :new_task, :queue_task, :confirm],
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
  defp task_lane(task), do: Map.get(task, :lane) || if(task.stage in ["ready", "running"], do: "work", else: task.stage)
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
  defp dialog_title(:queue_task, _, _), do: "Move task to Work"
  defp dialog_title(:rework, task, _), do: "Return #{task.identifier} to Work"
  defp dialog_title(:new_task, _, _), do: "New task"
  defp dialog_title(:task, task, _), do: task.title
  defp dialog_title(:confirm, _, %{action: "set_concurrency"}), do: "Change concurrency?"
  defp dialog_title(:confirm, _, pending), do: "#{command_label(pending.action)} #{pending.identifier || "project"}?"

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

  defp command_description(action) when action in ["create_pr_work", "continue_pr_work"],
    do: "Return this issue to Work with the corrections below. Priority, concurrency and remaining token/time budgets still apply. Selected comments get an automatically updated GitHub status reply."

  defp command_description("retry"), do: "Clear this issue’s hold without resetting its budget. An eligible task can start again; this does not deliver an answer or automatically repair a candidate."
  defp command_label(action) when action in ["create_pr_work", "continue_pr_work"], do: "return to Work"
  defp command_label("set_concurrency"), do: "change"
  defp command_label(action), do: action
  defp command_receipt("accept_task"), do: "Accepted. This issue is Done."
  defp command_receipt(action) when action in ["create_pr_work", "continue_pr_work"], do: "Returned to Work with your corrections."
  defp command_receipt("set_concurrency"), do: "Concurrency saved. Refreshing the controller’s confirmed limit."
  defp command_receipt("cancel"), do: "Cancel accepted. The issue is held; verify worker cleanup before treating it as stopped."
  defp command_receipt(action), do: "#{String.capitalize(action)} accepted. Refreshing confirmed execution state."
  defp command_error(:corrections_required), do: "Enter corrections or select at least one feedback comment."
  defp command_error(:reopen_issue_required), do: "This GitHub issue is closed. Reopen it on GitHub before returning it to Work."
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
end
