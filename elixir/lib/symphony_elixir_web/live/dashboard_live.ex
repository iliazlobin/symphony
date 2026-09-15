defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc "Live task board with browser preferences and authenticated native controls."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{BoardActions, BrowserAuth, Endpoint, ObservabilityPubSub, Presenter, TaskBoard}

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
      |> assign(:notice, nil)
      |> assign(:auth, BrowserAuth.context(session, socket))
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:lanes, @lanes)
      |> assign(:url_filters, %{})
      |> assign(:linked_task, nil)

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
    socket = socket |> assign(:dialog, dialog) |> assign(:url_filters, filters) |> assign(:linked_task, params["task"])
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
    socket = socket |> assign(:board, result) |> assign(:selected, current) |> assign(:loading, false)
    socket = if selected && is_nil(current) && socket.assigns.dialog == :task, do: socket |> assign(:dialog, nil) |> assign(:notice, "Task no longer available in this board."), else: socket
    {:noreply, open_linked_task(socket)}
  end

  def handle_async(:board, {:exit, _reason}, socket) do
    board = Map.put(socket.assigns.board, :source_error, "Board refresh failed; showing last-known tasks.")
    {:noreply, socket |> assign(:board, board) |> assign(:loading, false)}
  end

  @impl true
  def handle_event("open-task", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.board.tasks, &(&1.id == id)) do
      nil -> {:noreply, assign(socket, :notice, "That task is no longer in the current board. Refresh and try again.")}
      task -> {:noreply, socket |> assign(:selected, task) |> assign(:dialog, :task)}
    end
  end

  def handle_event("open-settings", _params, socket), do: {:noreply, assign(socket, :dialog, :settings)}
  def handle_event("new-task", _params, socket), do: {:noreply, assign(socket, :dialog, :new_task)}

  def handle_event("close-dialog", _params, socket) do
    socket = socket |> assign(:dialog, nil) |> assign(:pending_command, nil) |> assign(:linked_task, nil)
    {:noreply, push_patch(socket, to: board_path(socket.assigns.url_filters))}
  end

  def handle_event("board-filters", params, socket) do
    filters = url_filters(params)
    {:noreply, socket |> assign(:url_filters, filters) |> push_patch(to: board_path(filters), replace: true)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, refresh_board(socket)}

  def handle_event("move-task", %{"id" => id, "stage" => stage}, socket) do
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

  def handle_event("prepare-command", %{"action" => action} = params, socket) do
    task = Enum.find(socket.assigns.board.tasks, &(&1.id == params["id"]))

    if action in ["pause", "drain", "resume"] or (action in ["cancel", "retry"] and task) do
      prepare_command(socket, action, task)
    else
      {:noreply, assign(socket, :notice, "Unsupported action.")}
    end
  end

  def handle_event("confirm-command", _params, %{assigns: %{pending_command: nil}} = socket), do: {:noreply, socket}

  def handle_event("confirm-command", _params, socket) do
    pending = socket.assigns.pending_command

    case BoardActions.command(pending.action, pending.issue_id, pending.revision, pending.id, socket.assigns.auth, orchestrator()) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:dialog, nil)
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

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :authorized, BrowserAuth.authorized?(assigns.auth))

    ~H"""
    <section id="task-board-app" class="dashboard-shell" phx-hook="TaskBoard"
      data-scope={scope(@board)} data-projects={Jason.encode!(@board.projects)} data-url-filters={Jason.encode!(@url_filters)}>
      <header class="board-header">
        <a href="/" class="brand">∿ Symphony</a><nav class="workspace-tabs" aria-label="Workspace"><a href="/" aria-current="page">Board</a><a href={chat_path(@url_filters)}>Chat</a></nav>
        <span class="header-spacer"></span>
        <div id="board-search" phx-update="ignore"><input type="search" data-board-search aria-label="Search tasks" placeholder="Search tasks…" /></div>
        <button id="settings-button" class="button button-quiet" phx-click="open-settings">Settings</button>
        <button id="new-task-button" class="button button-primary" phx-click="new-task">+ New task</button>
      </header>

      <div id="board-toolbar" class="board-toolbar" phx-update="ignore">
        <div class="filter-row">
          <div :for={key <- ["project", "status", "priority"]} class="filter-combo" data-filter={key}>
            <div class="combo-control"><input id={"filter-#{key}"} role="combobox" aria-label={"#{String.capitalize(key)} filter"}
              autocomplete="off" aria-autocomplete="list" aria-expanded="false" aria-controls={"options-#{key}"}
              placeholder={"#{String.capitalize(key)}: All"} /><button type="button" data-filter-toggle={key} aria-label={"Open #{key} filter"}>⌄</button></div>
            <div id={"options-#{key}"} class="combo-options" role="listbox" aria-label={"#{String.capitalize(key)} options"} aria-multiselectable="true" hidden></div>
          </div>
          <label class="sort-control"><span>Sort</span><select data-board-sort aria-label="Sort cards">
            <option value="manual">Manual order</option><option value="priority">Priority first</option>
            <option value="updated">Recently updated</option><option value="oldest">Oldest first</option><option value="title">Title A–Z</option>
          </select></label>
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
        <div class="board-summary"><span data-result-count>{length(@board.tasks)} tasks</span>
          <span class="summary-right"><span :if={@loading}>Refreshing…</span><time :if={@board.generated_at}>Checked {@board.generated_at}</time>
          <button class="button button-small" phx-click="refresh" disabled={@loading}>Refresh</button></span></div>
        <div id="mobile-lane-control" class="mobile-lane-control" phx-update="ignore"><label>Lane <select data-mobile-lane aria-label="Board lane">
          <option :for={{id, label} <- @lanes} value={id}>{label}</option>
        </select></label></div>
        <div class="kanban-board">
          <section :for={{stage, label} <- @lanes} id={"lane-#{stage}"} class="kanban-lane" data-stage={stage} aria-label={"#{label} lane"}>
            <h2><span class={"lane-dot lane-dot-#{stage}"}></span>{label}<span class="lane-count" data-lane-count>{Enum.count(@board.tasks, &(&1.stage == stage))}</span></h2>
            <div class="lane-cards" data-lane-cards>
              <article :for={task <- Enum.filter(@board.tasks, &(&1.stage == stage))} id={card_id(task)} class="task-card" draggable="true"
                data-task-id={task.id} data-project={task.project} data-priority={priority(task.priority)} data-attention={to_string(not is_nil(task.attention))}
                data-title={task.title} data-identifier={task.identifier} data-created={task.created_at || ""} data-updated={task.updated_at || ""}>
                <div class="card-top"><a :if={safe_url(task.url)} href={safe_url(task.url)} target="_blank" rel="noopener noreferrer"
                  aria-label={"Open #{task.identifier} in the issue tracker"}>{task.identifier}</a><span :if={!safe_url(task.url)}>{task.identifier}</span>
                  <span class="priority" data-priority={priority(task.priority)}>{priority(task.priority)}</span></div>
                <button id={"open-#{card_id(task)}"} class="card-title" phx-click="open-task" phx-value-id={task.id}>{task.title}</button>
                <div class="card-project">{task.project_label}</div>
                <span :if={task.attention} class="attention-badge">{task.attention}</span>
                <p :if={current_activity(task, @payload)} class="card-activity">{current_activity(task, @payload)}</p>
                <div class="card-bottom"><span>{age(task.updated_at)}</span>
                  <select class="move-select" data-move-task={task.id} aria-label={"Move #{task.identifier}"}>
                    <option value="">Move…</option><option :for={{value, title} <- @lanes} :if={value != task.stage} value={value}>{title}</option>
                  </select></div>
              </article>
            </div>
            <p class="lane-empty" data-lane-empty>No tasks</p>
          </section>
        </div>
      </div>
      <footer class="board-footer"><span class="status-stack"><span class="status-badge-live">Connected</span><span class="status-badge-offline">Disconnected · last-known state</span></span>
        <span>Manual order is a browser preference; scheduling follows repository policy.</span></footer>

      <dialog :if={@dialog} id="board-dialog" class="board-dialog" phx-hook="BoardDialog" aria-labelledby="dialog-title">
        <div class="dialog-inner"><div class="dialog-heading"><h2 id="dialog-title">{dialog_title(@dialog, @selected, @pending_command)}</h2>
          <button id="close-dialog" class="button button-quiet" phx-click="close-dialog" aria-label="Close dialog">Close ×</button></div>
          <p :if={@notice} class="board-notice" role="status">{@notice}</p>
          <%= case @dialog do %>
            <% :settings -> %>
              <section class="dialog-section"><h3>Operator controls</h3>
                <p class="muted">Mode: {@board.control["mode"] || "Unavailable"}. Connection status does not establish worker readiness.</p>
                <%= if @authorized do %>
                  <div class="dialog-actions"><button :for={action <- ["drain", "pause", "resume"]} class="button" phx-click="prepare-command" phx-value-action={action}>{String.capitalize(action)}</button></div>
                  <form action="/operator/session/logout" method="post"><input type="hidden" name="_csrf_token" value={@csrf_token} /><button class="button button-quiet">Lock controls</button></form>
                <% else %>
                  <p class="muted">Read-only until unlocked on this local host. Use the operator token from your local Symphony configuration.</p>
                  <form action="/operator/session" method="post"><input type="hidden" name="_csrf_token" value={@csrf_token} />
                    <label class="field">Operator token<input type="password" name="operator_token" autocomplete="off" required /></label>
                    <button class="button button-primary">Unlock local controls</button></form>
                <% end %>
              </section>
              <section class="dialog-section"><h3>Projects</h3><p :for={project <- @board.projects}><a :if={safe_url(project.url)} href={safe_url(project.url)} target="_blank" rel="noopener noreferrer">{project.label}</a><span :if={!safe_url(project.url)}>{project.label}</span></p>
                <p class="muted">This service represents its configured repository. Additional project services and remote Google sign-in are not configured by this page.</p></section>
              <section class="dialog-section"><h3>Runtime</h3>
                <p>Total tokens: {get_in(@payload, [:codex_totals, :total_tokens]) || "Unavailable"}</p>
                <p>Runtime: {runtime_duration(@payload)}</p>
                <details><summary>Rate limits</summary><pre>{pretty(@payload[:rate_limits])}</pre></details>
              </section>
            <% :task -> %>
              <p class="muted">{@selected.project_label} · {@selected.identifier} · {lane_label(@selected.stage)}</p>
              <a :if={safe_url(@selected.url)} class="button" href={safe_url(@selected.url)} target="_blank" rel="noopener noreferrer">Open issue in tracker ↗</a>
              <p :if={@selected.attention} class="attention-badge">{@selected.attention}</p>
              <p :if={Map.get(@selected, :completion_evidence)} class="muted">{Map.get(@selected, :completion_evidence)}</p>
              <section class="dialog-section"><h3>Scope &amp; acceptance</h3><p class="task-description">{@selected.description || "No description available."}</p></section>
              <section class="dialog-section"><h3>Codex update</h3><p>{current_activity(@selected, @payload) || "No current worker activity."}</p>
                <button :if={session_id(@selected)} class="button button-small" data-copy={session_id(@selected)}>Copy ID</button>
              </section>
              <section :if={@selected.handoff} class="dialog-section"><h3>Candidate handoff</h3><pre>{pretty(@selected.handoff)}</pre><p class="muted">A handoff does not establish successful checks, merge or deployment. Review the candidate and PR evidence in GitHub.</p></section>
              <section class="dialog-section"><h3>Execution</h3><p class="muted">Cancel requests a hold and worker cleanup. Retry clears a hold without resetting the budget; it does not answer a question or approve a candidate.</p>
                <div class="dialog-actions"><button :for={action <- ["cancel", "retry"]} class="button" phx-click="prepare-command" phx-value-action={action} phx-value-id={@selected.id}>{String.capitalize(action)}</button></div>
                <details><summary>Runtime details</summary><pre>{pretty(@selected.runtime)}</pre></details>
              </section>
            <% :confirm -> %>
              <p>{command_description(@pending_command.action)}</p>
              <p class="muted">{@pending_command.identifier || "Configured project"} · operator revision {@pending_command.revision}</p>
              <div class="dialog-actions"><button class="button button-primary" phx-click="confirm-command" phx-disable-with="Submitting…">Confirm {String.downcase(@pending_command.action)}</button><button class="button" phx-click="close-dialog">Cancel</button></div>
            <% :new_task -> %>
              <p>Create the canonical task in the configured issue tracker. Specify its outcome, scope, acceptance checks and dependencies before queueing.</p>
              <div class="dialog-actions"><a :for={project <- @board.projects} :if={new_issue_url(project)} class="button button-primary" href={new_issue_url(project)} target="_blank" rel="noopener noreferrer">New issue · {project.label} ↗</a></div>
              <p class="muted">Return here and refresh after saving. Queue labels remain managed in GitHub; saving an issue alone does not start a worker.</p>
          <% end %>
        </div>
      </dialog>
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

  defp current_activity(task, payload) do
    entries = Map.get(payload, :running, []) ++ Map.get(payload, :blocked, [])
    entry = Enum.find(entries, &(&1.issue_id == task.issue_id))
    runtime = task.runtime || %{}
    (entry && entry[:last_message]) || runtime[:last_message] || runtime[:error]
  end

  defp orchestrator, do: Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  defp load_payload, do: Presenter.state_payload(orchestrator(), Endpoint.config(:snapshot_timeout_ms) || 15_000)

  defp url_filters(params),
    do: params |> Map.take(["project", "status", "priority", "q", "sort"]) |> Map.reject(fn {_key, value} -> not is_binary(value) or byte_size(value) > 2_000 or value == "" end)

  defp board_path(filters), do: if(filters == %{}, do: "/", else: "/?" <> URI.encode_query(filters))
  defp chat_path(%{"project" => project}), do: "/chat?" <> URI.encode_query(%{"project" => project |> String.split(",") |> List.first()})
  defp chat_path(_filters), do: "/chat"

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
  defp dialog_title(:settings, _, _), do: "Settings"
  defp dialog_title(:new_task, _, _), do: "New task"
  defp dialog_title(:task, task, _), do: task.title
  defp dialog_title(:confirm, _, pending), do: "#{String.capitalize(pending.action)} #{pending.identifier || "project"}?"
  defp command_description("drain"), do: "Finish active work, then stop taking new tasks."
  defp command_description("pause"), do: "Interrupt active work and stop dispatch. Work may require recovery before continuing."
  defp command_description("resume"), do: "Allow eligible tasks to run within existing launch gates and budgets."

  defp command_description("cancel"),
    do: "Hold this issue and request cleanup of any active worker, including a worker claimed since the board was read. Cancellation is not complete until cleanup is confirmed."

  defp command_description("retry"), do: "Clear this issue’s hold without resetting its budget. An eligible task can start again; this does not deliver an answer or automatically repair a candidate."
  defp command_receipt("cancel"), do: "Cancel accepted. The issue is held; verify worker cleanup before treating it as stopped."
  defp command_receipt(action), do: "#{String.capitalize(action)} accepted. Refreshing confirmed execution state."
  defp command_error(:revision_conflict), do: "State changed. Close this dialog and review the refreshed board before trying again."
  defp command_error(:tracker_changed), do: "Project configuration changed. Reload the page and unlock controls again."
  defp command_error(:unauthorized), do: "Operator session unavailable or expired. Unlock controls in Settings."
  defp command_error(reason), do: "Command not confirmed (#{inspect(reason)}). A repeated confirmation uses the same command ID."

  defp safe_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil} when scheme in ["http", "https"] and is_binary(host) and host != "" -> url
      _ -> nil
    end
  end

  defp safe_url(_), do: nil

  defp new_issue_url(%{id: "github:" <> _, url: url}) do
    case safe_url(url) do
      nil -> nil
      safe -> String.trim_trailing(safe, "/") <> "/issues/new"
    end
  end

  defp new_issue_url(_), do: nil
end
