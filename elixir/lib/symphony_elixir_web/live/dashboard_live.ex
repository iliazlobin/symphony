defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc "Live task board with browser preferences and authenticated native controls."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Chat.Sessions
  alias SymphonyElixir.Chat.ViewContext
  alias SymphonyElixir.Config
  alias SymphonyElixir.Specification.Document, as: SpecificationDocument
  alias SymphonyElixir.Specification.TaskLinks
  alias SymphonyElixir.TaskKind
  alias SymphonyElixir.WorkerFailure
  alias SymphonyElixirWeb.{BoardActions, BrowserAuth, ChatPanel, Endpoint, Markdown, SettingsPanel, TaskIntakePanel}
  alias SymphonyElixirWeb.{BoardCache, ChatNavigation, ObservabilityPubSub, Presenter}
  alias SymphonyElixirWeb.SpecificationActions
  alias SymphonyElixirWeb.SpecificationEditor
  alias SymphonyElixirWeb.StatusIndicator
  alias SymphonyElixirWeb.{TaskBoard, TaskExecution, TaskFilters, TaskOperator, TaskPresentation, TaskRework}

  alias SymphonyElixir.Assurance.{GraphSnapshot, Store}
  alias SymphonyElixirWeb.{AssuranceWorkspace, GraphNavigation, GraphProjection}

  @lanes [{"backlog", "Backlog"}, {"work", "Work"}, {"in_progress", "In progress"}, {"review", "Review"}, {"done", "Done"}]
  @refresh_ms 30_000

  @impl true
  def mount(_params, session, socket) do
    {scope, board, payload} = initial_state()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:payload_revision, 0)
      |> assign(:board_refresh_pending, false)
      |> assign(:board, board)
      |> assign(:board_scope, scope)
      |> assign(:loading, false)
      |> assign(:dialog, nil)
      |> assign(:selected, nil)
      |> assign(:intake_key, nil)
      |> assign(:intake_record_id, nil)
      |> assign(:intake_task, nil)
      |> assign(:intake_subscription, nil)
      |> assign(:pending_command, nil)
      |> assign(:acceptance_commands, %{})
      |> assign(:routing_commands, %{})
      |> assign(:settings_tab, "execution")
      |> assign(:concurrency_draft, nil)
      |> assign(:chat_health, "Not checked")
      |> assign(:notice, nil)
      |> assign(:auth, BrowserAuth.context(session, socket))
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:lanes, @lanes)
      |> assign(:url_filters, %{})
      |> assign(:design_source_context, %{})
      |> assign(:specification_source_context, %{})
      |> assign(:specification_state, %{})
      |> assign(:specification_project, nil)
      |> assign(:specification_draft, nil)
      |> assign(:specification_section, "brief")
      |> assign(:specification_notice, nil)
      |> assign(:specification_available, false)
      |> assign(:specification_history, nil)
      |> assign(:specification_review_open, false)
      |> assign(:specification_coverage, %{})
      |> assign(:specification_records, {:error, :task_links_unavailable})
      |> assign(:specification_focus, nil)
      |> assign(:specification_task_url, nil)
      |> assign(:board_view, "kanban")
      |> assign(:graph_options, %{})
      |> assign(:graph_index, nil)
      |> assign(:graph_index_key, nil)
      |> assign(:graph_board, board)
      |> assign(:graph_baseline, nil)
      |> assign(:graph_requested_baseline, nil)
      |> assign(:graph_history_task, nil)
      |> assign(:assurance_project, nil)
      |> assign(:assurance_snapshot, %{})
      |> assign(:assurance_projection, %{})
      |> assign(:assurance_error, nil)
      |> assign(:assurance_tab, "requirements")
      |> assign(:assurance_baseline_ref, nil)
      |> assign(:assurance_difference, %{})
      |> assign(:assurance_gaps, false)
      |> assign(:assurance_page, 0)
      |> assign(:calendar_plan, %{"anchor_on" => nil, "durations" => %{}})
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
    dialog = navigation_dialog(params["panel"])
    filters = params |> url_filters() |> legacy_idea_filters(params)
    board_view = filters["view"] || "kanban"
    view_changed = board_view != socket.assigns.board_view
    project = selected_project(socket.assigns.board, filters)
    chat_task = params["task"] || params["chat_task"]
    chat_session = valid_chat_session(params["chat_session"])
    previous_selection = {socket.assigns.chat_project, socket.assigns.chat_task_id, socket.assigns.chat_session_id}
    selection_changed = {project, chat_task, chat_session} != previous_selection
    project_changed = project != socket.assigns.chat_project
    focus_chat = focus_session_navigation?(socket, params)
    socket = if selection_changed || filters != socket.assigns.url_filters, do: clear_view_context(socket), else: socket

    socket =
      socket
      |> assign(:dialog, dialog)
      |> assign(:url_filters, filters)
      |> assign(:design_source_context, design_source_context(params, filters, project))
      |> assign(:specification_source_context, specification_source_context(params, filters, project))
      |> assign(:board_view, board_view)
      |> assign(:graph_options, GraphNavigation.read(params))
      |> assign(:linked_task, params["task"])
      |> assign(:chat_task_id, chat_task)
      |> assign(:chat_session_id, chat_session)
      |> assign(:chat_project, project)
      |> assign(:chat_id, if(selection_changed, do: nil, else: socket.assigns.chat_id))

    socket =
      socket
      |> open_linked_task()
      |> sync_chat_selection()
      |> navigation_focus(focus_chat, view_changed, chat_task, board_view)

    socket =
      socket
      |> maybe_load_specification()
      |> open_specification_source(params)
      |> refresh_specification_coverage()

    # Task/view navigation uses the already projected board and activity. The
    # project subscription and periodic refresh supply fresh activity without
    # serializing every selection behind a conversation-store list read.
    socket =
      socket
      |> refresh_chat_activity(project_changed)
      |> navigation_assurance(project_changed or dialog == :assurance)
      |> select_graph_baseline(if(board_view == "graph", do: params["baseline"]))
      |> refresh_graph_index()
      |> initialize_graph_anchor()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    socket = socket |> assign(:payload, load_payload()) |> update(:payload_revision, &(&1 + 1))
    {:noreply, refresh_local_board(socket)}
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
    {:noreply, socket |> refresh_local_board() |> refresh_chat_activity()}
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
      {:noreply, assign(socket, :chat_id, bounded_chat_id(id))}
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
      runtime =
        if socket.assigns.payload_revision == payload_revision,
          do: result[:runtime],
          else: socket.assigns.payload

      result = refresh_control(result, scope, runtime)
      :ok = BoardCache.put(scope, result)
      {:noreply, socket |> apply_board(result, payload_revision) |> continue_board_refresh()}
    else
      # A completed read belongs to the configuration that started it, never to
      # a new project, credential, controller or data source.
      {:noreply, socket |> assign(:loading, false) |> refresh_board()}
    end
  end

  def handle_async(:board, {:exit, _reason}, socket) do
    if socket.assigns.board_scope == BoardCache.scope(orchestrator()) do
      board = Map.put(socket.assigns.board, :source_error, "Board refresh failed; showing last-known tasks.")

      socket =
        socket
        |> assign(:board, board)
        |> assign(:loading, false)
        |> refresh_specification_coverage()
        |> continue_board_refresh()

      {:noreply, socket}
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

    socket =
      socket
      |> open_linked_task()
      |> sync_chat_selection()
      |> refresh_chat_activity()
      |> refresh_specification_coverage()

    socket |> refresh_assurance(true) |> refresh_graph_index()
  end

  @impl true
  def handle_event(action, params, socket)
      when action in ["new-task", "queue-task", "move-task", "prepare-rework", "prepare-command", "confirm-command", "save-concurrency", "reset-concurrency"] do
    if read_only?(socket.assigns.board) or historical_graph?(socket.assigns) do
      dialog = if socket.assigns.dialog in [:confirm, :new_task, :queue_task, :rework], do: nil, else: socket.assigns.dialog
      {:noreply, socket |> assign(:pending_command, nil) |> assign(:dialog, dialog) |> assign(:notice, "This board is read-only. Execution and tracker changes are unavailable here.")}
    else
      handle_write_event(action, params, socket)
    end
  end

  def handle_event(event, %{"project" => project} = params, socket)
      when event in ~w(design-load design-save design-review design-reviewed prepare-design-task) do
    case design_request(event, project, params, socket.assigns) do
      {:ok, record} when event == "prepare-design-task" ->
        socket =
          socket
          |> clear_intake_subscription()
          |> assign(dialog: :new_task, intake_task: nil, notice: nil)
          |> assign(intake_key: record["id"], intake_record_id: record["id"])

        {:reply, %{ok: true}, socket}

      {:ok, data} ->
        {:reply, %{ok: true, data: data}, socket}

      {:error, reason} ->
        {:reply, %{ok: false, error: if(is_atom(reason), do: Atom.to_string(reason), else: "design_action_unavailable")}, socket}
    end
  end

  def handle_event(event, _params, socket)
      when event in ~w(design-load design-save design-review design-reviewed prepare-design-task),
      do: {:reply, %{ok: false, error: "invalid_design_request"}, socket}

  def handle_event(event, params, socket)
      when event in ~w(spec-section spec-edit spec-save spec-review spec-confirm-review spec-cancel-review spec-add-item spec-remove-item spec-add-diagram spec-remove-diagram spec-add-criterion spec-remove-criterion spec-prepare-task spec-open-task-preview spec-open-version spec-return-draft spec-reload) do
    if specification_request?(event, params, socket.assigns),
      do: {:noreply, specification_event(event, params, socket)},
      else: {:noreply, assign(socket, :specification_notice, "Open this project’s Design and sign in to edit its specification.")}
  end

  def handle_event("open-assurance", _params, socket) do
    socket = socket |> clear_card_context() |> assign(:dialog, :assurance) |> refresh_assurance(true)
    {:noreply, push_patch(socket, to: board_location(socket))}
  end

  def handle_event("graph-options", params, socket) do
    params = if params["group_by"] && params["group_by"] != socket.assigns.graph_options["group_by"], do: Map.merge(params, %{"group" => "", "page" => 0}), else: params
    params = if params["mode"] == "focus", do: Map.put(params, "anchor", socket.assigns.graph_history_task || socket.assigns.chat_task_id), else: params
    options = GraphNavigation.update(socket.assigns.graph_options, params)
    socket = assign(socket, :graph_options, options)
    {:noreply, push_patch(socket, to: board_location(socket), replace: true)}
  end

  def handle_event("graph-search", params, socket) do
    options = GraphNavigation.update(socket.assigns.graph_options, %{"query" => params["query"] || "", "search_page" => 0})
    socket = assign(socket, :graph_options, options)
    {:noreply, push_patch(socket, to: board_location(socket), replace: true)}
  end

  def handle_event("live-graph", _params, socket) do
    socket = socket |> select_graph_baseline(nil) |> refresh_graph_index()
    {:noreply, push_patch(socket, to: board_location(socket), replace: true)}
  end

  def handle_event("assurance-tab", %{"tab" => tab}, socket) when tab in ~w(requirements versions releases),
    do: {:noreply, assign(socket, assurance_tab: tab, assurance_page: 0)}

  def handle_event("assurance-select-baseline", %{"ref" => ref}, socket) do
    ref = if ref == "", do: nil, else: ref
    exists = is_nil(ref) or Enum.any?(socket.assigns.assurance_snapshot["baselines"] || [], &(&1["ref"] == ref))

    if exists,
      do: {:noreply, assign(socket, assurance_baseline_ref: ref, assurance_difference: %{}, assurance_page: 0)},
      else: {:noreply, assign(socket, :assurance_error, :assurance_baseline_not_found)}
  end

  def handle_event("assurance-compare", %{"ref" => ref}, socket) do
    case Store.diff(socket.assigns.chat_project, ref, socket.assigns.auth, assurance_server()) do
      {:ok, difference} ->
        baseline = Enum.find(socket.assigns.assurance_snapshot["baselines"] || [], &(&1["ref"] == ref))

        graph_difference = current_graph_difference(socket, baseline)
        difference = difference |> Map.merge(graph_difference) |> Map.put("compared_ref", ref)
        {:noreply, assign(socket, assurance_difference: difference, assurance_page: 0)}

      {:error, reason} ->
        {:noreply, assign(socket, :assurance_error, reason)}
    end
  end

  def handle_event("assurance-view-baseline", %{"ref" => ref}, socket) do
    filters = view_filters(socket.assigns.url_filters, "graph")
    socket = socket |> select_graph_baseline(ref) |> clear_card_context() |> assign(:url_filters, filters)
    socket = refresh_graph_index(socket)
    {:noreply, push_patch(socket, to: board_location(socket))}
  end

  def handle_event("assurance-gaps", params, socket), do: {:noreply, assign(socket, assurance_gaps: (params["gaps_only"] || params["only"]) in ~w(true on), assurance_page: 0)}

  def handle_event("assurance-page", %{"page" => page}, socket) do
    number = GraphNavigation.read(%{"graph_page" => page})["page"] || 0
    {:noreply, assign(socket, :assurance_page, number)}
  end

  def handle_event("assurance-" <> action, params, socket)
      when action in ~w(save-requirement save-criterion link-task unlink-task remove-requirement remove-criterion save-dependency remove-dependency save-baseline record-release) do
    result = assurance_mutation(socket, action, params)

    socket =
      case result do
        {:ok, _snapshot} -> assurance_saved(socket)
        {:error, reason} -> socket |> refresh_assurance(true) |> assign(:assurance_error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("select-plan-task", %{"id" => id} = params, %{assigns: %{graph_baseline: %{} = baseline}} = socket) do
    exists = Enum.any?(baseline["graph_snapshot"]["graph"]["nodes"], &(&1["task_id"] == id))

    socket =
      if exists do
        socket
        |> assign(:graph_history_task, id)
        |> focus_graph_options(params)
        |> plan_selection_focus(id, params)
      else
        socket
      end

    {:reply, %{selected_task_id: socket.assigns.graph_history_task}, socket}
  end

  def handle_event("select-plan-task", %{"id" => id, "work_id" => work}, socket) when is_binary(work),
    do: socket |> focus_chat_session(id, "work:" <> work, false) |> reply_plan_selection()

  def handle_event("select-plan-task", %{"id" => id} = params, socket) when is_binary(id) do
    if Enum.any?(socket.assigns.board.tasks, &(&1.id == id)) do
      socket = socket |> focus_graph_options(params) |> plan_selection_focus(id, params)
      same_thread = socket.assigns.chat_task_id == id and is_nil(socket.assigns.chat_session_id)
      chat_id = if same_thread, do: socket.assigns.chat_id

      "select-task"
      |> handle_event(params, assign(socket, chat_session_id: nil, chat_id: chat_id))
      |> reply_plan_selection()
    else
      reply_plan_selection({:noreply, socket})
    end
  end

  def handle_event("select-plan-task", _params, socket), do: reply_plan_selection({:noreply, socket})

  def handle_event("open-card", _params, %{assigns: %{graph_requested_baseline: ref}} = socket) when is_binary(ref),
    do: {:noreply, assign(socket, :notice, "This is a reviewed snapshot. Return to the live graph to open current task controls.")}

  def handle_event("open-card", %{"id" => id} = params, socket) when is_binary(id),
    do: handle_event("open-task", params, socket)

  def handle_event("open-card", _params, socket), do: {:noreply, socket}

  def handle_event("switch-view", %{"view" => view} = params, socket) when view in ["idea", "design", "kanban", "graph", "gantt"] do
    id = params["id"] || socket.assigns.chat_task_id
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == id and &1.project == socket.assigns.chat_project))
    filters = if is_map(params["filters"]), do: url_filters(params["filters"]), else: socket.assigns.url_filters
    socket = socket |> clear_card_context() |> assign(:url_filters, view_filters(filters, view))

    socket =
      if task && task.id != socket.assigns.chat_task_id,
        do: assign(socket, chat_task_id: task.id, chat_session_id: nil, chat_id: nil),
        else: socket

    socket = if (view == "graph" and task) && params["id"], do: focus_graph_options(socket, %{"focus" => "true", "id" => task.id}), else: socket

    {:noreply, push_patch(socket, to: board_location(socket))}
  end

  def handle_event("switch-view", _params, socket), do: {:noreply, socket}

  def handle_event("change-calendar-plan", params, socket) when is_map(params) do
    anchor = calendar_anchor(params["anchor_on"])

    known = MapSet.new(socket.assigns.board.tasks, & &1.id)
    durations = if is_map(params["durations"]), do: params["durations"], else: %{}

    durations =
      durations
      |> Enum.take(1000)
      |> Map.new()
      |> Map.filter(fn {id, days} ->
        MapSet.member?(known, id) and is_integer(days) and days >= 1 and days <= 365
      end)

    {:noreply, assign(socket, :calendar_plan, %{"anchor_on" => anchor, "durations" => durations})}
  end

  def handle_event("change-calendar-plan", _params, socket), do: {:noreply, socket}

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

  def handle_event("operator-question", %{"id" => id}, socket) do
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == id and &1.project == socket.assigns.chat_project))

    if task && socket.assigns.board_view not in ["idea", "design"] do
      prompt = TaskOperator.summary(task, socket.assigns.board, socket.assigns.payload).question_prompt
      chat_id = if is_nil(socket.assigns.chat_session_id), do: socket.assigns.chat_id
      socket = assign(socket, chat_session_id: nil, chat_id: chat_id)
      {:noreply, socket} = handle_event("select-task", %{"id" => id}, socket)
      {:noreply, push_event(socket, "task-chat-prompt", %{task_id: id, project_id: task.project, prompt: prompt})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("operator-question", _params, socket), do: {:noreply, socket}

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
    filters = params |> url_filters() |> view_filters(socket.assigns.board_view)
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

  def handle_event("open-graph", _params, socket), do: handle_event("switch-view", %{"view" => "graph"}, socket)

  def handle_event("main-chat", _params, socket), do: main_chat(socket)

  def handle_event("board-view-context", params, socket) do
    context = validated_context(params, socket)
    {:noreply, assign(socket, :view_context, context)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, refresh_board(socket)}

  defp calendar_anchor(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> if abs(Date.diff(date, Date.utc_today())) <= 365, do: Date.to_iso8601(date)
      _ -> nil
    end
  end

  defp calendar_anchor(_value), do: nil

  defp handle_write_event("new-task", _params, socket) do
    if BrowserAuth.authorized?(socket.assigns.auth) do
      key = System.unique_integer([:positive])

      socket =
        socket
        |> clear_card_context()
        |> assign(dialog: :new_task, intake_task: nil, intake_key: key, intake_record_id: nil)

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

    with {:ok, renew_attempts} <- renewal_flag(params),
         true <- not renew_attempts or action == "retry",
         true <- action in ["pause", "drain", "resume"] or (action in ["cancel", "retry", "accept_task"] and not is_nil(task)) do
      prepare_command(socket, action, task, renew_attempts)
    else
      _ -> {:noreply, assign(socket, :notice, "Unsupported action or retry-cycle option.")}
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
    {result, socket} = forward_pending_command(pending, socket)

    case result do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:dialog, if(pending.action == "set_concurrency", do: :settings))
         |> assign(:concurrency_draft, nil)
         |> assign(:pending_command, nil)
         |> assign(:notice, command_receipt(pending))
         |> refresh_board()}

      {:error, reason} ->
        # Keep the original command identity on an uncertain response so a retry is idempotent.
        {:noreply, socket |> assign(:notice, command_error(reason)) |> refresh_board()}
    end
  end

  defp forward_pending_command(%{renew_attempts: true} = pending, socket) do
    if pending[:submitted] == true or retry_renewal_available?(pending, socket.assigns) do
      socket = assign(socket, :pending_command, Map.put(pending, :submitted, true))
      {BoardActions.retry_command(pending.command, socket.assigns.auth, orchestrator()), socket}
    else
      {{:error, :task_not_retryable}, socket}
    end
  end

  defp forward_pending_command(pending, socket), do: {forward_command(pending, socket.assigns.auth), socket}

  defp forward_command(%{action: "set_concurrency"} = pending, auth),
    do: BoardActions.settings_command(pending.limit, pending.revision, pending.id, auth, orchestrator())

  defp forward_command(%{action: action} = pending, auth) when action in ["create_pr_work", "continue_pr_work"],
    do: BoardActions.pr_work_command(pending.command, auth, orchestrator())

  defp forward_command(pending, auth),
    do: BoardActions.command(pending.action, pending.issue_id, pending.revision, pending.id, auth, orchestrator())

  defp move_task(socket, nil, _stage), do: {:noreply, assign(socket, :notice, "Task unavailable; refresh the board.")}

  defp move_task(socket, _task, "in_progress") do
    {:noreply, assign(socket, :notice, "In progress shows active workers. Move the task to Work; the scheduler starts it when dependencies and capacity allow.")}
  end

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
    if controls_available?(socket.assigns) do
      command =
        Map.get_lazy(socket.assigns.routing_commands, task.id, fn ->
          %{
            "action" => "queue_task",
            "issue_id" => task.issue_id,
            "command_id" => Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
            "expected_revision" => socket.assigns.board.control["revision"],
            "expected_updated_at" => task.updated_at
          }
        end)

      socket = update(socket, :routing_commands, &Map.put(&1, task.id, command))

      queue_result(socket, task, BoardActions.routing_command(command, socket.assigns.auth, orchestrator()))
    else
      {:noreply, socket |> assign(:dialog, :settings) |> assign(:notice, "Sign in before moving a task to Work.")}
    end
  end

  defp queue_result(socket, task, {:ok, _receipt}) do
    {:noreply,
     socket
     |> update(:routing_commands, &Map.delete(&1, task.id))
     |> clear_card_context()
     |> assign(:notice, "Moved to Work.")
     |> refresh_local_board()
     |> refresh_board()}
  end

  defp queue_result(socket, task, {:error, reason}) do
    socket =
      if reason in [:unavailable, :control_unavailable],
        do: socket,
        else: update(socket, :routing_commands, &Map.delete(&1, task.id))

    {:noreply, socket |> assign(:notice, routing_error(reason)) |> refresh_board()}
  end

  defp routing_error(reason) when reason in [:revision_conflict, :task_changed],
    do: "The task changed. Check its updated status and move it again."

  defp routing_error(reason) when reason in [:unavailable, :control_unavailable],
    do: "The move could not be confirmed. Try again to safely check the same request."

  defp routing_error(reason), do: "Task could not move to Work (#{reason})."

  defp prepare_command(socket, action, task, renew_attempts \\ false) do
    control = socket.assigns.board.control

    cond do
      not controls_available?(socket.assigns) ->
        {:noreply, socket |> assign(:dialog, :settings) |> assign(:notice, "Sign in and refresh execution status in Settings before changing execution.")}

      not task_action_available?(action, task, socket.assigns, renew_attempts) ->
        {:noreply, assign(socket, :notice, "This action is not available for the task’s current state. Review its execution summary.")}

      true ->
        pending = %{
          action: action,
          issue_id: task && task.issue_id,
          identifier: task && task.identifier,
          revision: control["revision"],
          id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        }

        pending =
          if renew_attempts do
            command = %{"action" => "retry", "issue_id" => task.issue_id, "command_id" => pending.id, "expected_revision" => pending.revision, "renew_attempts" => true}
            Map.merge(pending, %{renew_attempts: true, submitted: false, command: command, cycle_limit: get_in(control, ["settings", "budgets", "max_attempts"])})
          else
            pending
          end

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

  defp task_action_available?(action, nil, _assigns, false), do: action in ["pause", "drain", "resume"]
  defp task_action_available?(_action, nil, _assigns, true), do: false

  defp task_action_available?("retry", task, assigns, true), do: execution_summary(task, assigns.board, assigns.payload).renew_attempts?
  defp task_action_available?(_action, _task, _assigns, true), do: false

  defp task_action_available?(action, task, assigns, false) do
    summary = execution_summary(task, assigns.board, assigns.payload)

    (action == "cancel" and summary.cancel?) or (action == "retry" and summary.retry?) or
      (action == "accept_task" and task.stage == "review" and is_nil(task.runtime) and is_nil(task.ledger["active"]))
  end

  defp renewal_flag(params) do
    case Map.get(params, "renew_attempts", false) do
      value when value in [true, "true"] -> {:ok, true}
      value when value in [false, "false"] -> {:ok, false}
      _ -> {:error, :invalid_command}
    end
  end

  defp retry_renewal_available?(pending, assigns) do
    case Enum.find(assigns.board.tasks, &(&1.issue_id == pending.issue_id)) do
      nil -> false
      task -> task_action_available?("retry", task, assigns, true)
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

    not historical_graph?(assigns) and not read_only?(board) and BrowserAuth.authorized?(assigns.auth) and not runtime_unavailable?(board, assigns.payload) and
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
    visible_task_ids = TaskFilters.visible_ids(assigns.board, assigns.url_filters, selected_project(assigns.board, assigns.url_filters))
    graph_nodes = get_in(assigns.board, [:workflow_graph, "nodes"]) || []

    assigns =
      assign(assigns,
        authorized: BrowserAuth.authorized?(assigns.auth),
        chat_activity: if(BrowserAuth.authorized?(assigns.auth), do: assigns.chat_activity, else: %{}),
        read_only: read_only?(assigns.board) or (historical_graph?(assigns) and BrowserAuth.authorized?(assigns.auth)),
        settings: reported_settings(assigns.board),
        settings_editable: settings_editable?(assigns),
        controls_available: controls_available?(assigns),
        dispatch_guidance: dispatch_guidance(assigns.board, assigns.payload),
        settings_projects: Enum.map(assigns.board.projects, &Map.put(&1, :url, safe_url(&1.url))),
        settings_return_to: board_path(Map.put(board_location_params(assigns), "panel", "settings")),
        chat_return_to: board_path(board_location_params(assigns)),
        project_links: project_links,
        visible_task_ids: visible_task_ids,
        task_catalog: task_catalog(assigns.board),
        selected_plan_id: selected_plan_id(assigns.board, assigns.chat_task_id, assigns.chat_session_id),
        navigation_task: Enum.find(assigns.board.tasks, &(&1.id == assigns.chat_task_id)),
        project_overview: project_overview(assigns.board, assigns.payload, selected_project(assigns.board, assigns.url_filters)),
        dependency_nodes: Map.new(Enum.filter(graph_nodes, &(&1["type"] == "task")), &{&1["task_id"], &1}),
        project_picker_label: project_picker_label(assigns.board, assigns.url_filters, project_links)
      )

    ~H"""
    <section id="task-board-app" class="dashboard-shell" phx-hook="TaskBoard" data-density="compact" data-theme="light"
      data-chat-open="true" data-board-view={@board_view} data-chat-project={@chat_project} data-board-checked-at={@board.generated_at} data-context-revision={@context_revision} data-specification-dirty={to_string(specification_dirty?(assigns))}
      data-task-catalog={Jason.encode!(@task_catalog)} data-task-kinds={Jason.encode!(TaskKind.values() ++ ["invalid"])} data-scope={scope(@board)} data-projects={Jason.encode!(@board.projects)} data-project-links={Jason.encode!(@project_links)} data-url-filters={Jason.encode!(@url_filters)} data-selected-task={@chat_task_id}>
      <div class="board-main">
      <header class="board-header">
        <div class="board-location">
          <a href={SymphonyElixirWeb.WorkspacePath.path("/")} class="brand"><span class="brand-mark" aria-hidden="true">∿</span> Symphony</a>
          <span class="header-divider" aria-hidden="true">/</span>
          <div id="board-project-picker" class="filter-combo project-combo" data-filter="project" phx-update="ignore">
            <div class="combo-control"><input id="filter-project" role="combobox" aria-label="Select project"
              autocomplete="off" aria-autocomplete="list" aria-expanded="false" aria-controls="options-project"
              placeholder={@project_picker_label} title={@project_picker_label} /><button type="button" data-filter-toggle="project" aria-label="Open project selector">⌄</button></div>
            <div id="options-project" class="combo-options" role="listbox" aria-label="Project options" hidden></div>
          </div>
          <nav id="board-view-picker" class="board-view-picker" aria-label="Project views">
            <.link :for={{view, label} <- [{"idea", "Idea"}, {"design", "Design"}, {"kanban", "Kanban"}, {"graph", "Graph"}, {"gantt", "Gantt"}]} id={"view-#{view}"}
              patch={view_path(Map.merge(@url_filters, GraphNavigation.params(@graph_options)), view, @chat_task_id, @chat_session_id)} aria-current={if @board_view == view, do: "page"}
              title={"#{label} view"} data-board-view-link={view}>
              <svg viewBox="0 0 20 20" aria-hidden="true">
                <path :if={view == "idea"} d="M7 13c0-2-3-3-3-6a6 6 0 0 1 12 0c0 3-3 4-3 6M7 13h6M8 16h4M9 18h2" />
                <path :if={view == "design"} d="M4 3h8l4 4v10H4zM12 3v4h4M7 10h6M7 13h4" />
                <path :if={view == "kanban"} d="M3 4h4v12H3zM9 4h3v8H9zM14 4h3v10h-3z" />
                <path :if={view == "graph"} d="M10 7v3M4 13v-3h12v3M8 3h4v4H8zM2 13h4v4H2zM14 13h4v4h-4z" />
                <path :if={view == "gantt"} d="M3 3v14h14M5 5h6M8 9h7M11 13h6" />
              </svg><span>{label}</span>
            </.link>
          </nav>
        </div>
        <span class="header-spacer"></span>
        <div id="board-search" phx-update="ignore"><input type="search" data-board-search aria-label="Search tasks" placeholder="Search tasks…" /></div>
        <button :if={@chat_project && @authorized} id="coverage-button" class="button button-quiet" phx-click="open-assurance" title="Requirements, reviewed versions and release evidence">Coverage</button>
        <button id="settings-button" class="button button-quiet" phx-click="open-settings">Settings</button>
      </header>

      <div id="board-toolbar" class="board-toolbar" phx-update="ignore">
        <div class="toolbar-primary">
          <button type="button" class="button button-quiet mobile-filter-toggle" data-task-filters data-mobile-filter-toggle aria-expanded="false" aria-controls="board-filter-panel">Filters</button>
          <div id="board-filter-panel" class="filter-row" data-task-filters>
            <div :for={{key, label} <- [{"status", "Status"}, {"priority", "Priority"}, {"kind", "Kind"}, {"milestone", "Milestone"}, {"label", "Tags"}, {"assignee", "Assignee"}]} class="filter-combo" data-filter={key}>
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
              <label class="display-field" data-kanban-display><span>Sort by</span><select data-board-sort aria-label="Sort cards">
                <option value="manual">Manual order</option><option value="priority">Priority first</option>
                <option value="updated">Recently updated</option><option value="oldest">Oldest first</option><option value="title">Title A–Z</option>
              </select></label>
              <label class="display-field" data-kanban-display><span>Cards</span><select data-board-density aria-label="Card details"><option value="compact">Compact</option><option value="details">Detailed</option></select></label>
              <label class="display-field"><span>Appearance</span><select data-board-theme aria-label="Board appearance"><option value="light">Light</option><option value="dark">Dark</option><option value="system">System</option></select></label>
            </div>
          </details>
        </div>
        <div data-filter-chips data-task-filters class="filter-chips" aria-label="Selected filters"></div>
      </div>

      <div class="board-content">
        <.project_state_overview :if={@board_view not in ["idea", "design"]} counts={@project_overview} />
        <div :if={@board_view == "idea"} id="idea-view" class="board-view-panel" aria-label="Idea view">
          <p :if={is_nil(@chat_project)} class="design-empty">Choose a project to start brainstorming.</p>
          <SymphonyElixirWeb.DesignView.content :if={@chat_project} project={@chat_project} project_label={@project_picker_label} notion_url={design_link(@chat_project)} />
        </div>
        <div :if={@board_view == "design"} id="design-view" class="board-view-panel" aria-label="Design specification">
          <p :if={is_nil(@chat_project)} class="design-empty">Choose a project to write its specification.</p>
          <SymphonyElixirWeb.SpecificationView.content :if={@chat_project} project={@chat_project} project_label={@project_picker_label}
            state={@specification_state} draft={if @specification_history, do: @specification_history["specification"], else: @specification_draft}
            section={@specification_section} available={@specification_available} read_only={@read_only} dirty={specification_dirty?(assigns)} notice={@specification_notice}
            history={not is_nil(@specification_history)} viewed_ref={@specification_history && @specification_history["ref"]} review_open={@specification_review_open}
            coverage={@specification_coverage} focus_item={@specification_focus} task_url={@specification_task_url}
            idea_url={view_path(@url_filters, "idea", @chat_task_id, @chat_session_id)} />
        </div>
        <p :if={@notice} class="board-notice" role="status">{@notice}</p>
        <p :if={Phoenix.Flash.get(@flash, :error)} class="board-warning" role="alert">{Phoenix.Flash.get(@flash, :error)}</p>
        <p :if={Phoenix.Flash.get(@flash, :info)} class="board-notice" role="status">{Phoenix.Flash.get(@flash, :info)}</p>
        <p :if={@payload[:error]} class="board-warning" role="alert"><strong>Snapshot unavailable:</strong> {@payload.error.code}</p>
        <p :if={@board.source_error} class="board-warning" role="alert">{@board.source_error}</p>
        <p :if={@board.runtime_error} class="board-warning" role="alert">{@board.runtime_error}</p>
        <div :if={@dispatch_guidance} id="board-dispatch-guidance" class="board-notice" role="status">
          <p>{@dispatch_guidance}</p>
          <button type="button" class="button button-small" phx-click="open-settings" phx-value-tab="execution">Execution settings</button>
        </div>
        <div class="board-summary" hidden={@board_view in ["idea", "design"]}><span data-result-count>{length(@board.tasks)} tasks</span>
          <div class="summary-right"><span :if={@loading}>Updating…</span>
            <.task_view_navigation :if={@navigation_task && @board_view in ["kanban", "graph", "gantt"]} task={@navigation_task} task_id={@chat_task_id} view={@board_view} filters={@url_filters} session={@chat_session_id} />
          </div>
        </div>
        <div :if={@board_view == "kanban"} id="kanban-view" class="board-view-panel" aria-label="Kanban view">
        <div id="mobile-lane-control" class="mobile-lane-control" phx-update="ignore"><label>Lane <select data-mobile-lane aria-label="Board lane">
          <option :for={{id, label} <- @lanes} value={id}>{label}</option>
        </select></label></div>
        <p id="card-selection-help" class="visually-hidden">Press Enter or Space to select this task's chat. Open the title for details.</p>
        <div class="kanban-board">
          <section :for={{stage, label} <- @lanes} id={"lane-#{stage}"} class="kanban-lane" data-stage={stage} aria-label={"#{label} lane"}>
            <div class="lane-heading"><h2><span class={"lane-dot lane-dot-#{stage}"} aria-hidden="true"></span>{label}<span class="lane-count" data-lane-count>{Enum.count(@board.tasks, &(task_lane(&1) == stage))}</span></h2>

            </div>
            <div class="lane-cards" data-lane-cards>
              <article :for={task <- Enum.filter(@board.tasks, &(task_lane(&1) == stage))} id={card_id(task)} class="task-card" draggable={to_string(!@read_only)}
                tabindex="0" aria-label={"#{task.identifier}: #{task.title}"} aria-describedby="card-selection-help" aria-current={if @chat_task_id == task.id, do: "true"}
                data-status={task.stage} data-lane={task_lane(task)} data-task-id={task.id} data-selected={to_string(@chat_task_id == task.id)} data-project={task.project} data-priority={priority(task.priority)} data-attention={to_string(not is_nil(task.attention))}
                data-labels={Jason.encode!(subject_tags(Map.get(task, :labels, [])))} data-milestone={Jason.encode!(Map.get(task, :milestone))} data-assignees={Jason.encode!(Map.get(task, :assignees, []))}
                data-kind={task_kind(task)} data-title={task.title} data-identifier={task.identifier} data-created={task.created_at || ""} data-updated={task.updated_at || ""}>
                <TaskPresentation.identity class="card-top" identifier={task.identifier} url={task.url} kind={task_kind(task)} priority={task.priority} />
                <div class="card-title-row"><span class={"lane-dot lane-dot-#{stage}"} aria-hidden="true"></span>
                  <span class="card-title-text"><.link id={"open-#{card_id(task)}"} class="card-title" patch={task_detail_path(@url_filters, task.id, @chat_task_id, @chat_session_id)}>{task.title}</.link></span>
                </div>
                <div class="card-project">{task.project_label}</div>
                <.card_chat_status activity={Map.get(@chat_activity, task.id)} />
                <span class="card-filter-context">Outside filters</span>
                <.feedback_summary task={task} />
                <.execution_summary id={card_id(task) <> "-execution"} summary={execution_summary(task, @board, @payload)} routing={task[:routing]} compact={true} />
                <.card_work_status task={task} filters={@url_filters} />
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
                <div class="card-bottom"><time datetime={task.updated_at} title={updated_at(task.updated_at)}>{compact_updated_at(task.updated_at)}</time>
                  <.dependency_links task={task} node={@dependency_nodes[task.id]} filters={@url_filters} session={if task.id == @chat_task_id, do: @chat_session_id} />
                </div>
              </article>
            </div>
            <p class="lane-empty" data-lane-empty>No tasks</p>
          </section>
        </div>
        </div>
        <div :if={@board_view == "graph"} id="graph-view" class="board-view-panel" aria-label="Graph view">
          <p :if={@graph_baseline} class="board-notice graph-version-notice">Reviewed graph <code>{String.slice(@graph_baseline["ref"], 0, 12)}</code> · captured {@graph_baseline["graph_snapshot"]["captured_at"]}. Status is from this snapshot.
            <button type="button" class="button button-small" phx-click="live-graph">Live graph</button>
          </p>
          <p :if={@graph_requested_baseline && !@graph_baseline} class="board-notice graph-version-notice">Reviewed graph unavailable. Sign in to load this version, or return to the live graph.
            <button type="button" class="button button-small" phx-click="live-graph">Live graph</button>
          </p>
          <SymphonyElixirWeb.WorkflowGraphView.content :if={!@graph_requested_baseline || @graph_baseline} board={@graph_board} project={@chat_project} filters={@url_filters} selected_id={@graph_history_task || @selected_plan_id} visible_task_ids={@visible_task_ids} graph_index={@graph_index} graph_options={@graph_options} baseline_ref={@graph_baseline && @graph_baseline["ref"]} chat_task_id={@chat_task_id} chat_session_id={@chat_session_id} />
        </div>
        <div :if={@board_view == "gantt"} id="gantt-view" class="board-view-panel" aria-label="Gantt view">
          <SymphonyElixirWeb.WorkflowGanttView.content board={@board} project={@chat_project} filters={@url_filters} selected_id={@chat_task_id} session={@chat_session_id} visible_task_ids={@visible_task_ids} plan_options={@calendar_plan} />
        </div>
      </div>
      <div id="board-context" class="board-context" aria-label="Board data and execution status">
        <div class="board-context-state">
          <strong :if={Map.get(@board, :data_mode)}>{Map.get(@board, :data_mode)}</strong>
          <span class="board-source-state" data-unavailable={to_string(not is_nil(@board.source_error))}>{source_status(@board, @loading)}</span>
          <span class="board-runtime-state" data-unavailable={to_string(runtime_unavailable?(@board, @payload))}>{execution_status(@board, @payload)}</span>
          <span :if={Map.get(@board, :enrichment_error)} class="board-sync-note" title={Map.get(@board, :enrichment_error)}>{if @board[:enrichment_reason] == "history_truncated", do: "Older PR history not loaded", else: "Some PR details unavailable"}</span>
          <span :if={@read_only} class="evidence-badge">Read-only</span>
        </div>
        <div :if={context_links(@board) != []} class="board-context-links">
          <a :for={link <- context_links(@board)} href={link.url} target="_blank" rel="noopener noreferrer">{link.label} ↗</a>
        </div>
        <p :if={Map.get(@board, :source_note)} class="board-source-note">{Map.get(@board, :source_note)}</p>
      </div>
      <footer class="board-footer"><span class="status-stack"><span class="status-badge-live">Live updates connected</span><span class="status-badge-offline">Disconnected · last-known state</span></span>
        <span>Manual order is a browser preference; scheduling follows repository policy.</span></footer>

      <dialog :if={@dialog} id="board-dialog" class="board-dialog" phx-hook="BoardDialog" data-kind={@dialog} aria-modal={to_string(@dialog != :task)} data-nonmodal={to_string(@dialog == :task)} data-content-key={if @dialog == :task, do: @selected.id, else: @dialog} aria-labelledby="dialog-title">
        <header class="dialog-heading"><h2 id="dialog-title" tabindex="-1" data-dialog-focus title={dialog_title(@dialog, @selected, @pending_command)}>{dialog_title(@dialog, @selected, @pending_command)}</h2>
          <button type="button" id="close-dialog" class="button button-quiet" phx-click="close-dialog" aria-label="Close dialog">Close ×</button></header>
        <div class="dialog-inner" data-dialog-scroll>
          <p :if={@notice} class="board-notice" role="status">{@notice}</p>
          <%= case @dialog do %>
            <% :assurance -> %>
              <SymphonyElixirWeb.AssuranceView.content snapshot={@assurance_snapshot} projection={@assurance_projection} board={@board} tab={@assurance_tab}
                baseline_ref={@assurance_baseline_ref} selected_task_id={@chat_task_id} difference={@assurance_difference}
                read_only={@read_only || !@authorized || !is_nil(@assurance_error) && @assurance_snapshot == %{}}
                error={@assurance_error} gaps_only={@assurance_gaps} page={@assurance_page} />
            <% :settings -> %>
              <SettingsPanel.content board={%{@board | projects: @settings_projects}} read_only={@read_only} tab={@settings_tab}
                execution_status={execution_status(@board, @payload)} authorized={@authorized} can_control={@controls_available}
                can_edit={@settings_editable} settings={@settings} settings_available={settings_available?(@settings)} draft={@concurrency_draft}
                project_id={selected_project(@board, @url_filters)} chat_health={@chat_health} source_status={source_status(@board, @loading)}
                loading={@loading} csrf_token={@csrf_token} return_to={@settings_return_to} total_tokens={get_in(@payload, [:codex_totals, :total_tokens]) || "Unavailable"}
                runtime_duration={runtime_duration(@payload)} rate_limits={pretty(@payload[:rate_limits])} />
            <% :task -> %>
              <p class="muted task-resource-context"><a :if={repository_url(@selected)} href={repository_url(@selected)} target="_blank" rel="noopener noreferrer" aria-label={"Open #{@selected.project_label} repository"}>{@selected.project_label}</a><span :if={!repository_url(@selected)}>{@selected.project_label}</span> · <a :if={safe_url(@selected.url)} href={safe_url(@selected.url)} target="_blank" rel="noopener noreferrer" aria-label={"Open #{@selected.identifier} in the issue tracker"}>{@selected.identifier}</a><span :if={!safe_url(@selected.url)}>{@selected.identifier}</span> · {lane_label(task_lane(@selected))}</p>
              <TaskOperator.panel id="task-detail-operator" task={@selected} board={@board} payload={@payload} controls_available={!@read_only && @controls_available} />
              <.feedback_details task={@selected} />
              <details class="dialog-section task-execution-details"><summary>Usage &amp; limits</summary>
                <.execution_summary id="task-detail-usage" summary={execution_summary(@selected, @board, @payload)} routing={@selected[:routing]} hide_unused={@selected.stage == "backlog"} />
                <p :if={blocker(@selected) && is_nil(@selected.hold)} class="attention-badge">{blocker(@selected)}</p>
                <p :if={Map.get(@selected, :completion_evidence)} class="muted">{Map.get(@selected, :completion_evidence)}</p>
              </details>
              <div :if={@selected.stage == "ready" && @dispatch_guidance} id="task-dispatch-guidance" class="board-notice" role="status">
                <p>{@dispatch_guidance}</p>
                <button type="button" class="button button-small" phx-click="open-settings" phx-value-tab="execution">Execution settings</button>
              </div>
              <div class="task-reference-links"><.link :if={specification_source_path(@selected)} class="button button-small" patch={specification_source_path(@selected)}>Specification source →</.link><.link :if={design_source_path(@url_filters, @selected)} class="button button-small" patch={design_source_path(@url_filters, @selected)}>Idea source →</.link><.link class="button button-small agent-chat-link" patch={session_path(@url_filters, @selected.id, nil)}><ChatPanel.agent_label name={@selected.title} role="task" /><span aria-hidden="true">→</span></.link><a :for={link <- task_links(@selected, if(pull_requests(@selected) == [], do: ["issue", "repo", "pr", "checks", "candidate"], else: ["issue", "repo", "candidate"]))} class="button button-small" href={link.url} target="_blank" rel="noopener noreferrer">{link.label} ↗</a></div>
              <section :if={pull_requests(@selected) != []} class="dialog-section"><h3>Pull requests <span class="section-count">{length(pull_requests(@selected))}</span></h3><.pull_request :for={pr <- pull_requests(@selected)} pr={pr} compact={false} chat_url={session_path(@url_filters, @selected.id, pr_session_id(@selected, pr))} /></section>
              <section :if={ChatNavigation.work_sessions(@selected) != []} class="dialog-section" aria-label="Work sessions">
                <h3>Work sessions <span class="section-count">{ChatNavigation.work_counts(@selected).total}</span></h3>
                <article :for={work <- ChatNavigation.work_sessions(@selected)} class="issue-work-session" data-work-id={work.id}>
                  <div class="widget-heading"><.link class="agent-chat-link" patch={session_path(@url_filters, @selected.id, "work:" <> work.id)}><ChatPanel.agent_label name={work.name} role="work" /><span aria-hidden="true">→</span></.link><span class="widget-label">{work.phase}</span></div>
                  <a :if={work.pr_url} class="work-resource-link" href={work.pr_url} target="_blank" rel="noopener noreferrer">PR #{work.pr_number} ↗</a>
                  <p class="issue-work-instruction">{work.instruction}</p>
                  <p :if={work.summary != ""}>{work.summary}</p>
                  <div class="issue-work-meta"><span :if={work.session_retained}>Session retained</span><span :if={work.review}>Review: {String.replace(work.review, "_", " ")}</span><code :if={work.head != ""}>{work.head}</code><time :if={work.updated_at} datetime={work.updated_at} title={updated_at(work.updated_at)}>{compact_updated_at(work.updated_at)}</time></div>
                </article>
              </section>
              <section class="dialog-section"><h3>Scope &amp; acceptance</h3><div class="markdown-content">{Markdown.render(@selected.description |> SymphonyElixirWeb.DesignActions.display_body() |> TaskLinks.display_body())}</div></section>
              <section :if={current_activity(@selected, @payload) || session_id(@selected)} class="dialog-section"><h3>Codex update</h3><p>{current_activity(@selected, @payload)}</p>
                <button :if={session_id(@selected)} class="button button-small" data-copy={session_id(@selected)}>Copy ID</button>
              </section>
              <.candidate_review :if={settled_handoff?(@selected)} task={@selected} />
            <% :rework -> %>
              <p>Describe the corrections or select GitHub feedback. The task returns to Work after confirmation.</p>
              <form id="task-rework-form" phx-submit="prepare-rework">
                <label class="display-field">Work agent<select name="rework[work_id]" aria-label="Work agent to continue">
                  <option :for={work <- TaskRework.options(@selected)} value={work.id}>{work.label}</option>
                  <option value="new">New work agent</option>
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
                <p>{length(@pending_command.command["feedback"])} selected comments · {if @pending_command.action == "create_pr_work", do: "New work agent", else: "Continue work agent"}</p>
                <ul><li :for={item <- @pending_command.command["feedback"]}><a href={safe_url(item["url"])} target="_blank" rel="noopener noreferrer">@{item["author"]}</a>: {item["body"]}</li></ul>
                <div :if={@pending_command.command["feedback"] != []} class="feedback-mirror-preview" aria-label="GitHub status reply preview">
                  <p>One status reply on this GitHub issue will be updated as work progresses. It contains source links and statuses, not copied comment text:</p>
                  <ul><li :for={item <- @pending_command.command["feedback"]}>Queued · <a href={safe_url(item["url"])} target="_blank" rel="noopener noreferrer">Feedback from @{item["author"]}</a></li></ul>
                  <p>👀 Working · ✅ Addressed · ❗ Blocked. Human review threads stay open until you resolve them.</p>
                </div>
              </div>
              <p class="muted">{@pending_command.identifier || "Configured project"} · operator revision {@pending_command.revision}</p>
              <div class="dialog-actions"><button :if={!@read_only} class="button button-primary" phx-click="confirm-command" phx-disable-with="Submitting…">Confirm {command_label(@pending_command)}</button><button class="button" phx-click="cancel-command">Cancel</button></div>
            <% kind when kind in [:new_task, :queue_task] -> %>
              <.live_component module={TaskIntakePanel} id="task-intake" auth={@auth} read_only={@read_only}
                project_id={if @intake_task, do: @intake_task.project, else: selected_project(@board, @url_filters)} form_key={@intake_key} record_id={@intake_record_id} task={@intake_task} />
          <% end %>
        </div>
      </dialog>
      </div>
      <aside :if={@board_view != "design"} id="management-chat-dock" class="management-chat-dock" aria-label="Project chat">
        <.live_component module={ChatPanel} id="management-chat" auth={@auth} csrf_token={@csrf_token} return_to={@chat_return_to}
          embedded={true} project_id={@chat_project} chat_id={@chat_id} task_id={if @board_view != "idea", do: @chat_task_id} session_id={if @board_view != "idea", do: @chat_session_id}
          task_title={if @board_view != "idea", do: chat_task_title(@board, @chat_task_id)} issue_tasks={@board.tasks} issue_activity={@chat_activity}
          view_context={@view_context} design_mode={@board_view == "idea"} read_only={@read_only}
          operator_design_url={design_source_path(@url_filters, @navigation_task)} operator_board={@board} operator_payload={@payload} controls_available={!@read_only && @controls_available} />
      </aside>
    </section>
    """
  end

  defp refresh_intake_history(socket) do
    if socket.assigns.dialog in [:new_task, :queue_task],
      do: send_update(TaskIntakePanel, id: "task-intake", refresh_history: true)
  end

  defp task_catalog(board) do
    Enum.map(board.tasks, fn task ->
      %{
        taskId: task.id,
        project: task.project,
        title: task.title,
        identifier: task.identifier,
        kind: task_kind(task),
        priority: priority(task.priority),
        status: task.stage,
        stage: task_lane(task),
        lane: task_lane(task),
        attention: to_string(not is_nil(task.attention)),
        labels: Jason.encode!(subject_tags(Map.get(task, :labels, []))),
        milestone: Jason.encode!(Map.get(task, :milestone)),
        assignees: Jason.encode!(Map.get(task, :assignees, []))
      }
    end)
  end

  defp valid_chat_session(session), do: if(Sessions.valid_id?(session), do: session)

  defp assurance_saved(socket) do
    socket = assign(socket, assurance_error: nil, assurance_difference: %{})
    socket |> refresh_assurance(true) |> refresh_graph_index()
  end

  defp assurance_server, do: Endpoint.config(:assurance_store) || Store

  defp refresh_assurance(socket, reload \\ false) do
    project = socket.assigns.chat_project
    changed = project != socket.assigns.assurance_project

    socket =
      if changed,
        do:
          assign(socket,
            assurance_project: project,
            assurance_snapshot: %{},
            assurance_projection: %{},
            assurance_error: nil,
            assurance_baseline_ref: nil,
            assurance_difference: %{},
            graph_baseline: nil
          ),
        else: socket

    if assurance_readable?(socket) do
      case AssuranceWorkspace.load(socket.assigns.board, project, socket.assigns.auth, socket.assigns.assurance_snapshot, reload or changed, assurance_server()) do
        {:ok, value, projection, board} ->
          socket = assign(socket, board: board, assurance_snapshot: value)
          assign(socket, assurance_projection: projection, assurance_error: nil)

        {:error, reason} ->
          clear_assurance(socket, reason)
      end
    else
      clear_assurance(socket, :assurance_unavailable)
    end
  end

  defp clear_assurance(socket, reason) do
    board = Map.drop(socket.assigns.board, [:assurance, :assurance_observations, :assurance_evidence, :assurance_baselines])

    assign(socket,
      board: board,
      assurance_snapshot: %{},
      assurance_projection: %{},
      assurance_error: reason,
      assurance_baseline_ref: nil,
      assurance_difference: %{},
      graph_baseline: nil,
      graph_history_task: nil
    )
  end

  defp current_graph_difference(socket, baseline) do
    board = socket.assigns.board

    if not socket.assigns.loading and SymphonyElixirWeb.AssuranceObservations.source_current?(board) do
      case GraphSnapshot.capture(board[:workflow_graph], socket.assigns.chat_project) do
        {:ok, current} -> %{"graph" => GraphSnapshot.diff(baseline && baseline["graph_snapshot"], current)}
        _ -> %{"graph" => %{}, "graph_unavailable" => true}
      end
    else
      %{"graph" => %{}, "graph_unavailable" => true}
    end
  end

  defp focus_graph_options(socket, params) do
    if params["focus"] == "true" or socket.assigns.graph_options["mode"] == "overview",
      do: assign(socket, :graph_options, GraphNavigation.update(socket.assigns.graph_options, %{"mode" => "focus", "anchor" => params["id"], "page" => 0, "query" => ""})),
      else: socket
  end

  defp initialize_graph_anchor(socket) do
    options = socket.assigns.graph_options
    task_id = socket.assigns.graph_history_task || socket.assigns.chat_task_id

    group? = is_binary(options["group"]) and options["group"] != ""
    focus? = is_binary(task_id) and options["mode"] not in ["overview", "tasks"]

    if socket.assigns.board_view == "graph" and is_nil(options["anchor"]) and (group? or focus?) do
      anchor = task_id || first_graph_task(socket.assigns.graph_index, options)
      assign(socket, :graph_options, GraphNavigation.update(options, %{"anchor" => anchor}))
    else
      socket
    end
  end

  defp first_graph_task(index, options) do
    projection = GraphProjection.project(index, nil, options)
    Enum.find_value(projection["nodes"], & &1["task_id"])
  end

  defp assurance_readable?(socket), do: is_binary(socket.assigns.chat_project) and BrowserAuth.authorized?(socket.assigns.auth) and not read_only?(socket.assigns.board)
  defp navigation_assurance(socket, true), do: refresh_assurance(socket, true)
  defp navigation_assurance(socket, false), do: socket
  defp navigation_dialog("settings"), do: :settings
  defp navigation_dialog("coverage"), do: :assurance
  defp navigation_dialog(_), do: nil

  defp refresh_graph_index(socket) do
    board = if socket.assigns.graph_baseline, do: historical_graph_board(socket.assigns.board, socket.assigns.graph_baseline), else: socket.assigns.board

    project = socket.assigns.chat_project

    visible =
      if socket.assigns.graph_baseline do
        :all
      else
        TaskFilters.visible_ids(board, socket.assigns.url_filters, project)
      end

    key = :crypto.hash(:sha256, :erlang.term_to_binary({board[:workflow_graph], board[:source_error], board[:runtime_error], visible, get_in(board, [:assurance, "tasks"])}))
    index = if key == socket.assigns.graph_index_key, do: socket.assigns.graph_index, else: GraphProjection.index(board, visible)
    assign(socket, graph_board: board, graph_index: index, graph_index_key: key)
  end

  defp historical_graph_board(board, baseline) do
    graph = baseline["graph_snapshot"]["graph"]
    tasks = for node <- graph["nodes"], node["type"] == "task", do: %{id: node["task_id"]}

    board
    |> Map.put(:workflow_graph, graph)
    |> Map.put(:tasks, tasks)
    |> Map.put(:assurance, %{})
    |> Map.put(:graph_version, baseline["ref"])
    |> Map.put(:source_error, nil)
    |> Map.put(:runtime_error, nil)
  end

  defp plan_selection_focus(socket, id, %{"focus" => "true"}), do: push_event(socket, "focus-plan-task", %{id: id, view: "graph"})
  defp plan_selection_focus(socket, _id, _params), do: socket

  defp select_graph_baseline(socket, nil) do
    socket
    |> clear_graph_pending(nil)
    |> assign(graph_requested_baseline: nil, graph_baseline: nil, graph_history_task: nil)
  end

  defp select_graph_baseline(socket, ref) do
    ref = if is_binary(ref) and Regex.match?(~r/\A[a-f0-9]{64}\z/, ref), do: ref
    select_requested_graph_baseline(socket, ref)
  end

  defp select_requested_graph_baseline(socket, nil), do: select_graph_baseline(socket, nil)

  defp select_requested_graph_baseline(socket, ref) do
    baseline = Enum.find(socket.assigns.assurance_snapshot["baselines"] || [], &(&1["ref"] == ref and is_map(&1["graph_snapshot"])))
    socket = socket |> clear_graph_pending(ref) |> assign(:graph_requested_baseline, ref)

    case baseline do
      nil ->
        assign(socket, :graph_baseline, nil)

      baseline ->
        options = GraphNavigation.update(socket.assigns.graph_options, %{"gaps_only" => false})
        assign(socket, graph_baseline: baseline, graph_options: options)
    end
  end

  defp historical_graph?(assigns), do: is_binary(assigns.graph_requested_baseline)

  defp clear_graph_pending(socket, ref) do
    if socket.assigns.graph_requested_baseline != ref do
      current_dialog = socket.assigns.dialog
      dialog = if current_dialog in [:confirm, :new_task, :queue_task, :rework], do: nil, else: current_dialog
      assign(socket, pending_command: nil, dialog: dialog)
    else
      socket
    end
  end

  defp assurance_mutation(socket, action, params) do
    context = %{
      project: socket.assigns.chat_project,
      auth: socket.assigns.auth,
      server: assurance_server(),
      board: socket.assigns.board,
      loading: socket.assigns.loading,
      read_only: read_only?(socket.assigns.board) or not is_nil(socket.assigns.assurance_baseline_ref) or historical_graph?(socket.assigns)
    }

    AssuranceWorkspace.mutate(context, action, params)
  end

  defp refresh_board(socket), do: socket |> refresh_local_board() |> refresh_source_board()

  defp refresh_local_board(socket) do
    board = refresh_control(socket.assigns.board, socket.assigns.board_scope, socket.assigns.payload)
    selected = socket.assigns.selected
    current = selected && Enum.find(board.tasks, &(&1.id == selected.id))
    :ok = BoardCache.put(socket.assigns.board_scope, board)

    socket
    |> assign(:board, board)
    |> assign(:selected, current)
    |> project_specification_coverage()
    |> refresh_assurance()
    |> refresh_graph_index()
  end

  defp refresh_control(board, scope, payload) do
    if scope == BoardCache.scope(orchestrator()) and not read_only?(board) and board.control["enabled"] == true do
      refresh_control_snapshot(board, SymphonyElixir.Orchestrator.control_snapshot(orchestrator()), payload)
    else
      board
    end
  end

  defp refresh_control_snapshot(board, %{"enabled" => true, "revision" => revision} = control, payload)
       when is_integer(revision) do
    if is_nil(control["fault"]) and control == board.control,
      do: board,
      else: TaskBoard.refresh_control(board, control, payload)
  end

  defp refresh_control_snapshot(board, unavailable, payload),
    do: TaskBoard.refresh_control(board, unavailable, payload)

  defp refresh_source_board(%{assigns: %{loading: true}} = socket), do: assign(socket, :board_refresh_pending, true)

  defp refresh_source_board(socket) do
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
        |> assign(:routing_commands, %{})
        |> sync_chat_selection()
      end

    payload_revision = socket.assigns.payload_revision

    socket
    |> assign(:loading, true)
    |> assign(:board_refresh_pending, false)
    |> start_async(:board, fn -> {scope, payload_revision, loader.(server, timeout)} end)
  end

  defp continue_board_refresh(%{assigns: %{board_refresh_pending: true}} = socket), do: refresh_source_board(socket)
  defp continue_board_refresh(socket), do: socket

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

  attr(:id, :string, required: true)
  attr(:summary, :map, required: true)
  attr(:compact, :boolean, default: false)
  attr(:hide_unused, :boolean, default: false)
  attr(:routing, :map, default: nil)

  defp execution_summary(assigns) do
    assigns =
      assign(assigns,
        sync_label: routing_sync_label(assigns.routing),
        metrics: if(assigns.compact, do: [], else: Enum.reject(assigns.summary.metrics, &(assigns.hide_unused && (&1.used || 0) == 0)))
      )

    ~H"""
    <div class={["execution-summary", @compact && "compact"]} aria-label="Execution summary">
      <p class="execution-state">{@summary.status}<StatusIndicator.indicator :if={@summary.note} id={@id <> "-note"} title="Execution details" detail={@summary.note} detail_class="execution-note" /><small :if={@sync_label} class="routing-sync muted" title="Saved locally. GitHub routing labels synchronize automatically; failed attempts retry."> · {@sync_label}</small></p>
      <dl :if={@metrics != []} class="execution-metrics">
        <div :for={metric <- @metrics}>
          <dt>{metric.label}</dt><dd title={metric.title}>{metric.value}</dd>
        </div>
      </dl>
    </div>
    """
  end

  defp routing_sync_label(%{"status" => "pending", "error" => error}) when not is_nil(error), do: "GitHub sync retrying"
  defp routing_sync_label(%{"status" => "pending"}), do: "Syncing GitHub"
  defp routing_sync_label(_routing), do: nil

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
      <span>{@counts["total"]} {if @counts["total"] == 1, do: "comment", else: "comments"}{if @status == "partial", do: "+"}</span>
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

  defp blocker(task) do
    case get_in(task, [:runtime, :error]) do
      error when is_binary(error) and error != "" -> WorkerFailure.summary(error)
      _ -> Map.get(task, :blocker_reason) || task.attention
    end
  end

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

  defp repository_url(task) do
    case task_links(task, ["repo"]) do
      [%{url: url} | _] -> url
      _ -> nil
    end
  end

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
      <div class="pull-request-heading"><a :if={@url} href={@url} target="_blank" rel="noopener noreferrer" title={@title}>{@label}<span :if={!@compact && is_binary(@title)}> · {@title}</span></a><strong :if={!@url}>{@label}</strong><span class="pr-state" data-pr-state={String.downcase(@state)}>{@state}</span><.link :if={@chat_url} class="button button-small agent-chat-link" patch={@chat_url} aria-label={"Open #{@label} work agent"}><ChatPanel.agent_label name={if is_binary(@title) && @title != "", do: @title, else: @label} role="work" /><span aria-hidden="true">→</span></.link></div>
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
    if is_nil(runtime[:error]), do: (entry && entry[:last_message]) || runtime[:last_message]
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
      |> Map.take(["project", "status", "priority", "kind", "milestone", "label", "assignee", "q", "sort", "view"])
      |> Map.reject(fn {_key, value} -> not is_binary(value) or byte_size(value) > 2_000 or value == "" end)
      |> Map.reject(fn {key, value} -> key == "view" and value not in ["idea", "design", "graph", "gantt"] end)

  defp legacy_idea_filters(%{"view" => "design"} = filters, params) do
    if design_reference?(params["design_ref"]) and design_item?(params["design_item"]) and
         params["design_section"] in ~w(brief requirements data architecture decisions),
       do: Map.put(filters, "view", "idea"),
       else: filters
  end

  defp legacy_idea_filters(filters, _params), do: filters

  defp design_source_context(params, %{"view" => "idea"} = filters, project) do
    project = filters["project"] || project

    with true <- is_binary(project),
         true <- design_reference?(params["design_ref"]),
         true <- design_item?(params["design_item"]),
         true <- params["design_section"] in ~w(brief requirements data architecture decisions) do
      source = Map.take(params, ~w(design_ref design_section design_item))
      task = params["design_task"]
      source = if scoped_design_task?(task, project), do: Map.put(source, "design_task", task), else: source
      %{project: project, params: source}
    else
      _ -> %{}
    end
  end

  defp design_source_context(_params, _filters, _project), do: %{}

  defp specification_source_context(params, %{"view" => "design"} = filters, project) do
    with true <- is_binary(project) and (filters["project"] || project) == project,
         true <- design_reference?(params["spec_ref"]),
         true <- SpecificationDocument.identifier?(params["spec_document"]),
         true <- SpecificationDocument.identifier?(params["spec_item"]) do
      source = Map.take(params, ~w(spec_ref spec_document spec_item))
      task = params["spec_task"]
      source = if scoped_design_task?(task, project), do: Map.put(source, "spec_task", task), else: source
      %{project: project, params: source}
    else
      _ -> %{}
    end
  end

  defp specification_source_context(_params, _filters, _project), do: %{}
  defp design_reference?(ref) when is_binary(ref), do: Regex.match?(~r/\A[a-f0-9]{64}\z/, ref)
  defp design_reference?(_ref), do: false
  defp design_item?(item) when is_binary(item), do: Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/, item)
  defp design_item?(_item), do: false

  defp scoped_design_task?(task, project) when is_binary(task) and byte_size(task) <= 240,
    do: String.starts_with?(task, project <> ":") and not Regex.match?(~r/[\x00-\x1f\x7f]/, task)

  defp scoped_design_task?(_task, _project), do: false

  defp design_link("github:iliazlobin/symphony"), do: "https://app.notion.com/p/3ebd865005a881acbbc1cc9799077ef4"
  defp design_link("github:iliazlobin/events-concierge"), do: "https://app.notion.com/p/3cfd865005a88162aa6bd4624b6a4af4"
  defp design_link(_project), do: nil

  defp design_source_path(filters, %{description: body, project: project, id: task_id}) do
    if source = SymphonyElixirWeb.DesignActions.reference(body) do
      filters
      |> Map.drop(~w(task chat_task chat_session panel))
      |> Map.merge(%{"project" => project, "view" => "idea", "design_ref" => source.ref, "design_section" => source.section, "design_item" => source.item, "design_task" => task_id})
      |> board_path()
    end
  end

  defp design_source_path(_filters, _task), do: nil

  defp design_request(event, project, params, assigns) do
    cond do
      project != assigns.chat_project or assigns.board_view != "idea" -> {:error, :design_project_mismatch}
      read_only?(assigns.board) or historical_graph?(assigns) -> {:error, :read_only}
      not BrowserAuth.authorized?(assigns.auth) -> {:error, :unauthorized}
      true -> design_action(event, project, params, assigns.auth)
    end
  end

  defp design_action("design-load", project, _params, auth), do: SymphonyElixirWeb.DesignActions.store().read(project, auth)
  defp design_action("design-save", project, params, auth), do: SymphonyElixirWeb.DesignActions.store().save(project, params["storage_revision"], params["scene"], auth)
  defp design_action("design-review", project, params, auth), do: SymphonyElixirWeb.DesignActions.store().review(project, params["storage_revision"], auth)
  defp design_action("design-reviewed", project, params, auth), do: SymphonyElixirWeb.DesignActions.store().reviewed(project, params["ref"], auth)
  defp design_action("prepare-design-task", project, params, auth), do: SymphonyElixirWeb.DesignActions.prepare(project, params, auth)

  defp specification_source_path(task) do
    if url = SpecificationActions.source_url(task.project, task.description), do: url <> "&" <> URI.encode_query(%{"spec_task" => task.id})
  end

  defp specification_store, do: Endpoint.config(:specification_store) || SymphonyElixir.Specification.Store

  defp refresh_specification_coverage(%{assigns: %{board_view: "design", chat_project: project}} = socket) when is_binary(project) do
    document = displayed_specification(socket.assigns)
    records = if document && document["sections"]["requirements"]["items"] != [], do: SpecificationActions.records(project, socket.assigns.auth), else: {:ok, []}
    socket |> assign(:specification_records, records) |> project_specification_coverage()
  end

  defp refresh_specification_coverage(socket), do: socket

  defp project_specification_coverage(socket) do
    document = displayed_specification(socket.assigns)
    ref = if document, do: SpecificationDocument.content_ref(document)
    available = is_nil(socket.assigns.board.source_error) and is_nil(socket.assigns.board.runtime_error)
    assign(socket, :specification_coverage, TaskLinks.coverage(document, ref, socket.assigns.specification_records, socket.assigns.board.tasks, available))
  end

  defp displayed_specification(%{specification_history: nil, specification_draft: draft}), do: draft
  defp displayed_specification(%{specification_history: history}), do: history["specification"]

  defp open_specification_source(socket, %{"spec_ref" => ref, "spec_document" => document, "spec_item" => item} = params) do
    if socket.assigns.board_view == "design" and not specification_dirty?(socket.assigns) do
      with true <- is_binary(ref) and String.match?(ref, ~r/\A[a-f0-9]{64}\z/) and SpecificationDocument.identifier?(document) and SpecificationDocument.identifier?(item),
           {:ok, record} <- specification_store().reviewed(socket.assigns.chat_project, ref, socket.assigns.auth),
           true <- record["document_id"] == document,
           node when is_map(node) <- TaskLinks.requirement(record["specification"], item) do
        task = Enum.find(socket.assigns.board.tasks, &(&1.id == params["spec_task"] and &1.project == socket.assigns.chat_project))

        assign(socket,
          specification_history: record,
          specification_focus: item,
          specification_section: "requirements",
          specification_task_url: if(task, do: SpecificationActions.task_url(task.project, task.id))
        )
      else
        _ -> assign(socket, :specification_notice, "This specification source is unavailable in the selected project.")
      end
    else
      assign(socket, :specification_notice, "Your draft has unsaved changes. Save it before opening a task’s reviewed source.")
    end
  end

  defp open_specification_source(socket, _params), do: assign(socket, specification_focus: nil, specification_task_url: nil)

  defp specification_request?(event, params, assigns) do
    is_map(params) and assigns.board_view == "design" and params["project"] == assigns.chat_project and
      BrowserAuth.authorized?(assigns.auth) and (not specification_read_only?(assigns) or event in ~w(spec-section spec-open-version spec-return-draft spec-reload spec-cancel-review))
  end

  defp specification_read_only?(assigns), do: read_only?(assigns.board) or historical_graph?(assigns)

  defp maybe_load_specification(%{assigns: %{board_view: "design", chat_project: project, specification_project: opened}} = socket) when project != opened,
    do: load_specification(socket)

  defp maybe_load_specification(socket), do: socket

  defp load_specification(socket) do
    same_project = socket.assigns.specification_project == socket.assigns.chat_project

    case specification_store().read(socket.assigns.chat_project, socket.assigns.auth) do
      {:ok, state} ->
        socket
        |> assign(specification_project: socket.assigns.chat_project, specification_history: nil)
        |> specification_saved(state)

      {:error, reason} ->
        socket = if same_project, do: socket, else: clear_specification(socket)

        socket
        |> assign(:specification_project, socket.assigns.chat_project)
        |> assign(:specification_available, false)
        |> assign(:specification_review_open, false)
        |> assign(:specification_notice, specification_error(reason))
    end
  end

  defp specification_saved(socket, state) do
    draft = state["draft"] || SpecificationDocument.new(socket.assigns.chat_project)

    socket
    |> assign(:specification_state, state)
    |> assign(:specification_draft, draft)
    |> assign(:specification_available, true)
    |> assign(:specification_notice, nil)
    |> assign(:specification_review_open, false)
    |> refresh_specification_coverage()
  end

  defp clear_specification(socket) do
    assign(socket,
      specification_state: %{},
      specification_draft: nil,
      specification_history: nil,
      specification_coverage: %{},
      specification_records: {:error, :task_links_unavailable},
      specification_focus: nil,
      specification_task_url: nil
    )
  end

  defp specification_dirty?(%{specification_draft: nil}), do: false

  defp specification_dirty?(%{specification_state: %{"draft" => nil}, specification_draft: draft}) do
    Enum.any?(draft["sections"], fn {_name, section} -> section["items"] != [] or section["diagrams"] != [] end)
  end

  defp specification_dirty?(assigns), do: assigns.specification_draft != assigns.specification_state["draft"]

  defp specification_event("spec-section", %{"section" => section}, socket) do
    if section in SpecificationDocument.sections(),
      do: assign(socket, specification_section: section, specification_review_open: false),
      else: assign(socket, :specification_notice, "Choose a specification section.")
  end

  defp specification_event("spec-reload", _params, socket), do: load_specification(socket)

  defp specification_event("spec-return-draft", _params, socket),
    do:
      socket
      |> assign(specification_history: nil, specification_focus: nil)
      |> assign(specification_task_url: nil, specification_notice: nil)
      |> refresh_specification_coverage()
      |> push_patch(to: board_path(socket.assigns.url_filters), replace: true)

  defp specification_event("spec-cancel-review", _params, socket), do: assign(socket, :specification_review_open, false)

  defp specification_event("spec-open-version", %{"ref" => ref}, socket) when is_binary(ref) do
    case specification_store().reviewed(socket.assigns.chat_project, ref, socket.assigns.auth) do
      {:ok, record} ->
        socket
        |> assign(:specification_history, record)
        |> assign(:specification_review_open, false)
        |> assign(:specification_notice, nil)
        |> refresh_specification_coverage()

      {:error, reason} ->
        assign(socket, :specification_notice, specification_error(reason))
    end
  end

  defp specification_event(event, params, socket)
       when event in ~w(spec-edit spec-save spec-review spec-confirm-review spec-add-item spec-remove-item spec-add-diagram spec-remove-diagram spec-add-criterion spec-remove-criterion spec-prepare-task spec-open-task-preview) do
    if socket.assigns.specification_available and is_nil(socket.assigns.specification_history),
      do: specification_write(event, params, socket),
      else: assign(socket, :specification_notice, "Return to the saved draft to make changes.")
  end

  defp specification_event(_event, _params, socket), do: assign(socket, :specification_notice, "The specification action is incomplete.")

  defp specification_write(event, params, socket) when event in ["spec-edit", "spec-save"] do
    assigns = socket.assigns

    case SpecificationEditor.edit(assigns.specification_draft, assigns.specification_state, params, assigns.specification_section) do
      {:ok, draft} ->
        socket =
          socket
          |> assign(specification_draft: draft, specification_review_open: false, specification_notice: nil)
          |> project_specification_coverage()

        if event == "spec-save", do: save_specification(socket), else: socket

      {:error, reason} ->
        assign(socket, :specification_notice, specification_error(reason))
    end
  end

  defp specification_write("spec-review", params, socket) do
    if not specification_dirty?(socket.assigns) and specification_current_revision?(params, socket),
      do: assign(socket, :specification_review_open, true),
      else: assign(socket, :specification_notice, "Save the draft before reviewing this exact version.")
  end

  defp specification_write("spec-open-task-preview", params, socket) do
    case SpecificationActions.get(socket.assigns.chat_project, params["id"], socket.assigns.auth) do
      {:ok, record} -> open_specification_task_preview(socket, record)
      {:error, reason} -> assign(socket, :specification_notice, SymphonyElixirWeb.TaskIntake.error_message(reason))
    end
  end

  defp specification_write("spec-prepare-task", params, socket) do
    if not specification_dirty?(socket.assigns) and specification_current_revision?(params, socket) do
      case SpecificationActions.prepare(socket.assigns.chat_project, params, socket.assigns.auth) do
        {:ok, record} ->
          open_specification_task_preview(socket, record)

        {:error, reason} ->
          assign(socket, :specification_notice, specification_error(reason))
      end
    else
      assign(socket, :specification_notice, "Save and review the requirement before preparing its task.")
    end
  end

  defp specification_write("spec-confirm-review", params, socket) do
    ready = not specification_dirty?(socket.assigns) and specification_current_revision?(params, socket)

    if socket.assigns.specification_review_open and ready do
      case specification_store().review(socket.assigns.chat_project, socket.assigns.specification_state["storage_revision"], socket.assigns.auth) do
        {:ok, state} -> socket |> specification_saved(state) |> assign(:specification_notice, "Reviewed version saved.")
        {:error, reason} -> assign(socket, :specification_notice, specification_error(reason))
      end
    else
      assign(socket, :specification_notice, "Review the saved version before confirming.")
    end
  end

  defp specification_write(event, params, socket) do
    section = socket.assigns.specification_section

    result =
      if params["section"] == section do
        id = if event == "spec-remove-criterion", do: Map.take(params, ~w(item criterion)), else: params["id"]
        SpecificationEditor.change(socket.assigns.specification_draft, section, event, id)
      else
        {:error, :invalid_specification_edit}
      end

    case result do
      {:ok, draft} ->
        socket
        |> assign(:specification_draft, draft)
        |> assign(:specification_review_open, false)
        |> assign(:specification_notice, nil)
        |> project_specification_coverage()

      {:error, reason} ->
        assign(socket, :specification_notice, specification_error(reason))
    end
  end

  defp specification_current_revision?(params, socket), do: SpecificationEditor.revision(params["storage_revision"]) == socket.assigns.specification_state["storage_revision"]

  defp open_specification_task_preview(socket, record) do
    socket
    |> clear_intake_subscription()
    |> assign(dialog: :new_task, intake_task: nil, notice: nil, intake_key: record["id"], intake_record_id: record["id"])
  end

  defp save_specification(socket) do
    case specification_store().save(socket.assigns.chat_project, socket.assigns.specification_state["storage_revision"], socket.assigns.specification_draft, socket.assigns.auth) do
      {:ok, state} -> socket |> specification_saved(state) |> assign(:specification_notice, "Draft saved.")
      {:error, reason} -> assign(socket, :specification_notice, specification_error(reason))
    end
  end

  defp specification_error(:unauthorized), do: "Sign in through Settings to open this project’s specification."
  defp specification_error(:stale_specification_revision), do: "The saved specification changed elsewhere. Your edits are retained here; compare them before reloading the saved draft."
  defp specification_error(:specification_empty), do: "Add specification content before saving a reviewed version."
  defp specification_error(:invalid_specification_edit), do: "This edit no longer matches the open section. Your draft is retained."
  defp specification_error(:specification_item_not_reviewed), do: "Save and review this requirement before preparing a task."
  defp specification_error(:specification_criteria_required), do: "Add a title, details and complete acceptance criteria before preparing a task."
  defp specification_error(:specification_task_too_large), do: "This requirement exceeds the task preview limits. Split it into smaller requirements; the text has not been truncated."
  defp specification_error(:specification_task_pending), do: "Finish or reconcile the existing task preview before preparing another."
  defp specification_error(_reason), do: "Specification storage is unavailable. Your open draft is retained; try reloading when storage recovers."

  defp reply_plan_selection({:noreply, socket}), do: {:reply, %{selected_task_id: socket.assigns.chat_task_id}, socket}

  defp navigation_focus(socket, focus_chat, view_changed, task_id, view) do
    socket = if view_changed, do: push_event(socket, "focus-plan-task", %{id: task_id, view: view}), else: socket
    if focus_chat, do: push_event(socket, "focus-chat-session", %{}), else: socket
  end

  defp project_overview(board, payload, project) do
    tasks = if project, do: Enum.filter(board.tasks, &(&1.project == project)), else: board.tasks
    counts = Enum.frequencies_by(tasks, &task_lane/1)
    attention = Enum.count(tasks, &TaskOperator.summary(&1, board, payload).attention?)
    Map.merge(counts, %{"all" => length(tasks), "attention" => attention})
  end

  attr(:counts, :map, required: true)

  defp project_state_overview(assigns) do
    ~H"""
    <nav id="project-state-overview" class="project-state-overview" aria-label="Project task states">
      <button :for={{status, label} <- [{"", "All"}, {"in_progress", "Running"}, {"review", "Review"}, {"attention", "Needs attention"}, {"backlog", "Backlog"}, {"work", "Work"}, {"done", "Done"}]}
        type="button" data-status-filter={status} aria-pressed="false" title={"Filter project tasks: #{label}"}>
        <span :if={status not in ["", "attention"]} class={"lane-dot lane-dot-#{status}"} aria-hidden="true"></span>
        <span>{label}</span><strong>{Map.get(@counts, if(status == "", do: "all", else: status), 0)}</strong>
      </button>
    </nav>
    """
  end

  attr(:task, :map, default: nil)
  attr(:task_id, :string, default: nil)
  attr(:view, :string, required: true)
  attr(:filters, :map, required: true)
  attr(:session, :string, default: nil)

  defp task_view_navigation(assigns) do
    ~H"""
    <nav id="selected-task-navigation" class="selected-task-navigation" aria-label="Task views" data-selected-task-id={@task_id}>
      <span data-task-navigation-label hidden={is_nil(@task)} title={@task && @task.title}>{@task && @task.identifier}</span>
      <.link :if={@task} class="button button-small" patch={task_detail_path(@filters, @task_id, @task_id, @session)} aria-label={"Details: #{@task.identifier}"}>Details</.link>
      <.link :for={{view, label} <- [{"kanban", "Show on board"}, {"graph", "Show graph"}, {"gantt", "Show timeline"}]} :if={view != @view}
        class="button button-small" patch={view_path(@filters, view, @task_id, @session)} data-board-view-link={view} data-board-view-task={@task_id}
        aria-label={if @task, do: "#{label}: #{@task.identifier}", else: label}>{label}</.link>
    </nav>
    """
  end

  defp selected_plan_id(board, task_id, "work:" <> work_id) do
    node = Enum.find(get_in(board, [:workflow_graph, "nodes"]) || [], &(&1["type"] == "work" and &1["work_id"] == work_id and &1["task_id"] == task_id))
    if node, do: node["id"], else: task_id
  end

  defp selected_plan_id(_board, task_id, _session), do: task_id

  defp view_filters(filters, "kanban"), do: Map.delete(filters, "view")
  defp view_filters(filters, view), do: Map.put(filters, "view", view)

  defp view_path(filters, view, task_id, session) do
    params = view_filters(filters, view)
    params = if task_id, do: Map.put(params, "chat_task", task_id), else: params
    params = if session, do: Map.put(params, "chat_session", session), else: params
    board_path(params)
  end

  attr(:task, :map, required: true)
  attr(:node, :map, default: nil)
  attr(:filters, :map, required: true)
  attr(:session, :string, default: nil)

  defp dependency_links(assigns) do
    ~H"""
    <TaskPresentation.dependencies :if={@node} task_id={@task.id} identifier={@task.identifier} upstream={@node["upstream_count"]} downstream={@node["downstream_count"]} filters={@filters} session={@session} />
    """
  end

  defp board_path(filters), do: SymphonyElixirWeb.WorkspacePath.path(if(filters == %{}, do: "/", else: "/?" <> URI.encode_query(filters)))

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

  defp session_option?(task, session) do
    Enum.any?(Sessions.options(task), &(&1.id == session or (&1.pr && "pr:#{&1.pr.number}" == session)))
  end

  defp focus_chat_session(socket, task_id, session, focus? \\ true) do
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == task_id and &1.project == socket.assigns.chat_project))

    if (BrowserAuth.authorized?(socket.assigns.auth) and task) && (is_nil(session) or session_option?(task, session)) do
      socket =
        socket
        |> clear_card_context()
        |> assign(chat_task_id: task_id, chat_session_id: session, chat_id: nil, selected: nil)

      socket = push_patch(socket, to: board_location(socket))
      {:noreply, if(focus?, do: push_event(socket, "focus-chat-session", %{}), else: socket)}
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

  defp board_location(socket), do: board_path(board_location_params(socket.assigns))

  defp board_location_params(assigns) do
    params =
      assigns.url_filters
      |> Map.merge(retained_design_source(assigns))
      |> Map.merge(retained_specification_source(assigns))
      |> Map.merge(GraphNavigation.params(assigns.graph_options))

    params = graph_location_params(params, assigns)
    params = if assigns.chat_task_id, do: Map.put(params, "chat_task", assigns.chat_task_id), else: params
    params = if assigns.chat_session_id, do: Map.put(params, "chat_session", assigns.chat_session_id), else: params
    params = if assigns.dialog == :task && assigns.linked_task, do: Map.put(params, "task", assigns.linked_task), else: params

    cond do
      assigns.dialog == :settings -> Map.put(params, "panel", "settings")
      assigns.dialog == :assurance -> Map.put(params, "panel", "coverage")
      true -> params
    end
  end

  defp graph_location_params(params, %{url_filters: %{"view" => "graph"}, graph_requested_baseline: ref}) when is_binary(ref), do: Map.put(params, "baseline", ref)
  defp graph_location_params(params, _assigns), do: params

  defp retained_design_source(%{url_filters: %{"view" => "idea"} = filters, design_source_context: %{project: project, params: params}} = assigns) do
    if selected_project(assigns.board, filters) == project, do: params, else: %{}
  end

  defp retained_design_source(_assigns), do: %{}

  defp retained_specification_source(%{url_filters: %{"view" => "design"} = filters, specification_source_context: %{project: project, params: params}} = assigns) do
    if selected_project(assigns.board, filters) == project, do: params, else: %{}
  end

  defp retained_specification_source(_assigns), do: %{}

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
        session = if session_option?(task, socket.assigns.chat_session_id), do: socket.assigns.chat_session_id
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

  defp refresh_chat_activity(socket, false), do: socket
  defp refresh_chat_activity(socket, true), do: refresh_chat_activity(socket)

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

  defp task_kind(task), do: task[:task_kind] || TaskKind.from_labels(task[:labels])

  defp card_work_status(assigns) do
    works = ChatNavigation.work_sessions(assigns.task)
    assigns = assign(assigns, counts: ChatNavigation.work_counts(assigns.task), first_work: List.first(works))

    ~H"""
    <div :if={@first_work} class="card-work-status" data-work-count={@counts.total} aria-label="Task work sessions">
      <.link patch={session_path(@filters, @task.id, "work:" <> @first_work.id)} aria-label={"Open work agent for #{@task.identifier}"}>{@counts.total} work {if @counts.total == 1, do: "session", else: "sessions"}</.link>
      <span :if={@counts.working > 0} data-working-count={@counts.working}>{@counts.working} working</span>
      <span :if={@counts.queued > 0} data-queued-work={@counts.queued}>{@counts.queued} queued</span>
      <span :if={@counts.review > 0}>{@counts.review} ready for review</span>
      <span :if={@counts.paused > 0}>{@counts.paused} paused</span>
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
    url = SymphonyElixirWeb.WorkspacePath.relative(url)
    uri = URI.parse(url)
    params = URI.decode_query(uri.query || "")

    if uri.path == "/" && is_nil(uri.host) && is_nil(uri.scheme) && is_nil(uri.fragment) && params["project"] == project do
      {:ok, Map.take(params, ["project", "status", "priority", "kind", "milestone", "label", "assignee", "q", "sort", "task"])}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp chat_board_link(_url, _project), do: :error

  defp open_linked_task(%{assigns: %{dialog: dialog}} = socket) when dialog in [:settings, :new_task, :queue_task, :confirm, :graph],
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

  defp subject_tags(labels) do
    Enum.filter(labels, &TaskKind.subject_tag?/1)
  end

  defp task_lane(%{stage: "running"}), do: "in_progress"
  defp task_lane(%{stage: "ready"}), do: "work"
  defp task_lane(task), do: Map.get(task, :lane) || task.stage
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
  defp dialog_title(:assurance, _, _), do: "Coverage & versions"
  defp dialog_title(:settings, _, _), do: "Settings"
  defp dialog_title(:queue_task, _, _), do: "Move task to Work"
  defp dialog_title(:rework, task, _), do: "Return #{task.identifier} to Work"
  defp dialog_title(:new_task, _, _), do: "New task"
  defp dialog_title(:task, task, _), do: task.title
  defp dialog_title(:confirm, _, %{action: "set_concurrency"}), do: "Change concurrency?"
  defp dialog_title(:confirm, _, %{action: "retry", renew_attempts: true} = pending), do: "Retry cycle #{pending.identifier}?"
  defp dialog_title(:confirm, _, pending), do: "#{command_label(pending.action)} #{pending.identifier || "project"}?"

  defp command_description(%{action: "set_concurrency", limit: nil}),
    do: "Restore the workflow concurrency default. Active tasks keep running and cumulative budgets are unchanged. The controller rejects this change if its revision has changed."

  defp command_description(%{action: "set_concurrency", limit: limit}),
    do: "Allow at most #{limit} concurrent tasks. Active tasks keep running; new starts respect this limit and the workflow ceiling. Cumulative budgets are unchanged."

  defp command_description(%{action: "retry", renew_attempts: true, cycle_limit: limit}),
    do:
      "Allow a new cycle of at most #{limit} attempts for this task. Lifetime tokens, runtime and attempt history remain recorded; source scope, launch gates and project limits stay unchanged. The scheduler still checks eligibility before starting work."

  defp command_description(%{action: action}), do: command_description(action)
  defp command_description("drain"), do: "Finish active work, then stop taking new tasks."
  defp command_description("pause"), do: "Interrupt active work and stop dispatch. Work may require recovery before continuing."
  defp command_description("resume"), do: "Allow eligible tasks to run within existing launch gates and budgets."

  defp command_description("cancel"),
    do: "Hold this issue and request cleanup of any active worker, including a worker claimed since the board was read. Cancellation is not complete until cleanup is confirmed."

  defp command_description(action) when action in ["create_pr_work", "continue_pr_work"],
    do: "Return this issue to Work with the corrections below. Priority, concurrency and remaining token/time budgets still apply. Selected comments get an automatically updated GitHub status reply."

  defp command_description("retry"), do: "Clear this issue’s hold without resetting its budget. An eligible task can start again; this does not deliver an answer or automatically repair a candidate."
  defp command_label(%{action: "retry", renew_attempts: true}), do: "retry cycle"
  defp command_label(%{action: action}), do: command_label(action)
  defp command_label(action) when action in ["create_pr_work", "continue_pr_work"], do: "return to Work"
  defp command_label("set_concurrency"), do: "change"
  defp command_label(action), do: action
  defp command_receipt(%{action: "retry", renew_attempts: true}), do: "Retry cycle accepted. Recorded usage is preserved; scheduling still checks project gates."
  defp command_receipt(%{action: action}), do: command_receipt(action)
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

  defp safe_url(value), do: TaskPresentation.safe_url(value)
end
