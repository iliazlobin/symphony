defmodule SymphonyElixirWeb.TaskIntakePanel do
  @moduledoc "Deterministic task forms and durable, explicitly confirmed tracker actions."
  use Phoenix.LiveComponent

  alias SymphonyElixir.GitHub.Admission
  alias SymphonyElixirWeb.{BrowserAuth, Endpoint, Markdown, TaskIntake}

  @fields ~w(title outcome scope acceptance dependencies)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       location: nil,
       project_id: nil,
       auth: nil,
       read_only: false,
       draft: %{},
       submission_id: nonce(),
       record: nil,
       records: [],
       notice: nil,
       subscribed: nil
     )}
  end

  @impl true
  def update(%{refresh_action: id}, socket) do
    if socket.assigns.read_only or not BrowserAuth.authorized?(socket.assigns.auth) do
      {:ok, clear_private_state(socket)}
    else
      socket = if socket.assigns.record && socket.assigns.record["id"] == id, do: load_record(socket, id), else: socket
      {:ok, refresh_history(socket)}
    end
  end

  def update(assigns, socket) do
    location = {assigns.project_id, assigns.form_key}
    socket = assign(socket, Map.take(assigns, [:id, :project_id, :auth, :read_only]))

    socket =
      if location != socket.assigns.location do
        socket
        |> subscribe(nil)
        |> assign(location: location, draft: initial_draft(), submission_id: nonce())
        |> assign(record: nil, records: [], notice: nil)
        |> refresh_history()
      else
        socket
      end

    socket = if socket.assigns.read_only or not BrowserAuth.authorized?(socket.assigns.auth), do: clear_private_state(socket), else: socket
    {:ok, socket}
  end

  @impl true
  def handle_event("draft", %{"task" => params}, socket) when is_map(params) do
    {:noreply, socket |> assign(:draft, fields(params)) |> validate_draft()}
  end

  def handle_event("prepare", %{"task" => params}, socket) when is_map(params) do
    socket = assign(socket, :draft, fields(params))

    if is_nil(socket.assigns.record) do
      with :ok <- field_lengths(socket.assigns.draft),
           {:ok, args} <- action_args(socket),
           {:ok, record} <- prepare_action(socket, args) do
        {:noreply, socket |> put_record(record) |> refresh_history()}
      else
        {:error, reason} -> {:noreply, show_error(socket, reason)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("decide", %{"decision" => decision}, socket) when decision in ~w(confirm cancel reconcile) do
    proposal = proposal(socket.assigns.record)
    allowed = (decision in ~w(confirm cancel) and proposal["status"] == "pending") or (decision == "reconcile" and proposal["status"] == "unknown")

    if allowed do
      case call(socket, :decide, [socket.assigns.project_id, socket.assigns.record["id"], decision]) do
        {:ok, record} -> {:noreply, socket |> put_record(record) |> refresh_history()}
        {:error, reason} -> {:noreply, show_error(socket, reason)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("open-action", %{"id" => id}, socket), do: {:noreply, load_record(socket, id)}

  def handle_event("refresh-actions", _params, socket) do
    socket = if socket.assigns.record, do: load_record(socket, socket.assigns.record["id"]), else: socket
    {:noreply, refresh_history(socket)}
  end

  def handle_event("new-draft", _params, socket) do
    if proposal(socket.assigns.record)["status"] in [nil, "completed", "cancelled", "failed"] do
      {:noreply, socket |> subscribe(nil) |> assign(record: nil, submission_id: nonce(), notice: nil)}
    else
      {:noreply, assign(socket, :notice, "Finish or cancel the pending action before starting another.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp action_args(%{assigns: %{draft: draft}}) do
    with :ok <- required(draft, ~w(title outcome scope acceptance dependencies)),
         {:ok, _} <- Admission.validate_declaration("Depends on: " <> draft["dependencies"]),
         false <- Enum.any?(~w(outcome scope acceptance), &String.match?(draft[&1], ~r/^\s*depends on\b/im)) do
      body = "## Outcome\n\n#{draft["outcome"]}\n\n## Scope\n\n#{draft["scope"]}\n\n## Acceptance checks\n\n#{draft["acceptance"]}\n\nDepends on: #{draft["dependencies"]}"
      {:ok, %{"action" => "create_task", "title" => draft["title"], "body" => body}}
    else
      true -> {:error, :duplicate_dependencies}
      {:error, reason} when is_binary(reason) -> {:error, {:invalid_dependency_declaration, reason}}
      error -> error
    end
  end

  defp required(draft, fields) do
    if Enum.all?(fields, &(is_binary(draft[&1]) and String.trim(draft[&1]) != "")), do: :ok, else: {:error, :required_fields}
  end

  defp fields(params), do: Map.new(@fields, fn key -> {key, if(is_binary(params[key]), do: params[key], else: "")} end)

  defp field_lengths(draft) do
    Enum.reduce_while(@fields, :ok, fn field, :ok ->
      value = draft[field] || ""

      if byte_size(value) <= field_limit(field) do
        {:cont, :ok}
      else
        {:halt, {:error, {:field_too_long, field, field_limit(field)}}}
      end
    end)
  end

  defp field_limit("title"), do: 200
  defp field_limit("dependencies"), do: 400
  defp field_limit(_), do: 4_000

  defp validate_draft(socket) do
    case field_lengths(socket.assigns.draft) do
      :ok -> assign(socket, :notice, nil)
      {:error, reason} -> show_error(socket, reason)
    end
  end

  defp initial_draft, do: %{"title" => "", "outcome" => "", "scope" => "", "acceptance" => "", "dependencies" => "none"}

  defp prepare_action(socket, args) do
    parameters = [socket.assigns.project_id, socket.assigns.submission_id, args]
    call(socket, :prepare, parameters)
  end

  defp call(socket, method, args) do
    cond do
      socket.assigns.read_only -> {:error, :read_only}
      not BrowserAuth.authorized?(socket.assigns.auth) -> {:error, :unauthorized}
      not is_binary(socket.assigns.project_id) -> {:error, :project_required}
      true -> apply(Endpoint.config(:task_intake, TaskIntake), method, args ++ [socket.assigns.auth])
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp refresh_history(socket) do
    case call(socket, :list, [socket.assigns.project_id]) do
      {:ok, records} ->
        socket = assign(socket, :records, records)
        pending = Enum.find(records, &(proposal(&1)["status"] in ~w(pending executing unknown)))
        if is_nil(socket.assigns.record) and pending, do: put_record(socket, pending), else: socket

      {:error, reason} ->
        show_error(socket, reason)
    end
  end

  defp load_record(socket, id) do
    case call(socket, :get, [socket.assigns.project_id, id]) do
      {:ok, record} -> put_record(socket, record)
      {:error, reason} -> show_error(socket, reason)
    end
  end

  defp put_record(socket, record) do
    if proposal(record)["status"] == "completed", do: send(self(), {:task_intake, :changed})
    socket |> subscribe(record["id"]) |> assign(record: record, notice: nil)
  end

  defp subscribe(socket, id) do
    previous = socket.assigns.subscribed
    if previous != id and previous, do: Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "chat:" <> previous)
    if previous != id and id, do: Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat:" <> id)
    if previous != id, do: send(self(), {:task_intake, :subscribed, id})
    assign(socket, :subscribed, id)
  end

  defp clear_private_state(socket), do: socket |> subscribe(nil) |> assign(record: nil, records: [], draft: %{})

  defp show_error(socket, reason) when reason in [:unauthorized, :read_only, :project_changed, :project_not_found],
    do: socket |> clear_private_state() |> assign(:notice, error_message(reason))

  defp show_error(socket, reason), do: assign(socket, :notice, error_message(reason))

  defp error_message({:field_too_long, field, limit}) do
    label = String.capitalize(field)
    "#{label} exceeds the #{limit}-byte limit. Shorten it explicitly or edit the issue in GitHub; the text has not been truncated."
  end

  defp error_message(:required_fields), do: "Complete the required fields before previewing the task."
  defp error_message(:duplicate_dependencies), do: "Use the Dependencies field for dependency declarations. Remove any Depends on lines from the other sections."
  defp error_message(:project_required), do: "Select one project on the board before creating or changing tasks."
  defp error_message(reason), do: TaskIntake.error_message(reason)
  defp proposal(%{"proposals" => [proposal | _]}), do: proposal
  defp proposal(_), do: %{}
  defp nonce, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp history_label(record) do
    args = proposal(record)["args"] || %{}
    args["title"] || if(args["task_id"], do: "Issue #" <> to_string(args["task_id"]), else: record["title"])
  end

  defp receipt(proposal) do
    case proposal["receipt"] do
      %{"widgets" => widgets} when is_list(widgets) -> Enum.find(widgets, %{}, &match?(%{"type" => "receipt"}, &1))
      _ -> %{}
    end
  end

  defp result_url(%{"task_id" => task_id}, "github:" <> repo = project) when is_binary(task_id) do
    prefix = project <> ":"

    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repo) and String.starts_with?(task_id, prefix) do
      issue_id = String.replace_prefix(task_id, prefix, "")
      if Regex.match?(~r/\A[1-9][0-9]*\z/, issue_id), do: "https://github.com/" <> repo <> "/issues/" <> issue_id
    end
  end

  defp result_url(_, _), do: nil

  @impl true
  def render(assigns) do
    proposal = proposal(assigns.record)

    assigns =
      assign(assigns,
        proposal: proposal,
        args: proposal["args"] || %{},
        receipt: receipt(proposal),
        authorized: BrowserAuth.authorized?(assigns.auth) and not assigns.read_only,
        can_start: proposal["status"] in [nil, "completed", "cancelled", "failed"]
      )

    ~H"""
    <section id="task-intake-panel" class="task-intake" aria-label="Task intake">
      <p class="muted">{String.replace_prefix(@project_id || "Select one project", "github:", "")}</p>
      <p :if={@notice} class="board-warning" role="alert">{@notice}</p>
      <div :if={@authorized && @project_id && is_nil(@record)}>
        <p>Create a GitHub issue in Backlog. Saving does not start a worker.</p>
        <form id="task-intake-form" phx-target={@myself} phx-change="draft" phx-submit="prepare" class="intake-form">
          <label><span>Title</span><input name="task[title]" value={@draft["title"]} maxlength="200" required /></label>
          <div class="intake-fields">
            <label><span>Outcome</span><textarea name="task[outcome]" rows="2" maxlength="4000" required placeholder="What should be true when this is done?">{@draft["outcome"]}</textarea></label>
            <label><span>Scope</span><textarea name="task[scope]" rows="3" maxlength="4000" required placeholder="What to change and what to leave alone">{@draft["scope"]}</textarea></label>
            <label><span>Acceptance checks</span><textarea name="task[acceptance]" rows="3" maxlength="4000" required placeholder="Observable checks that prove completion">{@draft["acceptance"]}</textarea></label>
            <label><span>Dependencies</span><input name="task[dependencies]" value={@draft["dependencies"]} maxlength="400" required placeholder="none or #12, #34" /><small>Use none, or issue numbers from this repository: #12, #34.</small></label>
          </div>
          <div class="dialog-actions"><button type="submit" class="button button-primary" phx-disable-with="Preparing…">Preview task</button></div>
        </form>
      </div>
      <section :if={@record} id="task-action-preview" class="dialog-section" aria-label="Action preview">
        <div class="widget-heading"><h3>Create backlog task</h3><span class="evidence-badge">{@proposal["status"]}</span></div>
        <h4 :if={@args["title"]}>{@args["title"]}</h4>
        <div :if={@args["body"]} class="markdown-content intake-preview-body">{Markdown.render(@args["body"])}</div>
        <p :if={@proposal["action"] == "create_task" && @proposal["status"] == "pending"} class="muted">Will create a backlog issue without queue labels. This will not start a worker.</p>
        <div :if={@proposal["status"] == "pending" && @authorized} class="dialog-actions"><button class="button button-primary" phx-target={@myself} phx-click="decide" phx-value-decision="confirm" phx-disable-with="Confirming…">Create task</button><button class="button" phx-target={@myself} phx-click="decide" phx-value-decision="cancel" phx-disable-with="Cancelling…">Cancel action</button></div>
        <p :if={@proposal["status"] == "pending"} class="muted">Nothing changes until you confirm this exact action.</p>
        <p :if={@proposal["status"] == "executing"} role="status">Applying action… You can reopen its result from New task.</p>
        <div :if={@proposal["status"] == "unknown"}><p class="board-warning">The outcome is uncertain. Check the recorded result before creating another action.</p><button :if={@authorized} class="button" phx-target={@myself} phx-click="decide" phx-value-decision="reconcile" phx-disable-with="Checking…">Check outcome</button></div>
        <p :if={@proposal["status"] == "failed"} class="board-warning" role="alert">{@proposal["error"] || "The action could not be completed. Refresh the board before preparing a new action."}</p>
        <p :if={@proposal["status"] == "cancelled"}>Action cancelled. No change was submitted.</p>
        <div :if={@proposal["status"] == "completed"} class="action-receipt"><strong>Action completed</strong><p>{@receipt["summary"]}</p><a :if={result_url(@receipt, @project_id)} href={result_url(@receipt, @project_id)} target="_blank" rel="noopener noreferrer">View in GitHub ↗</a></div>
        <button :if={@can_start && @authorized} class="button" phx-target={@myself} phx-click="new-draft">New task</button>
      </section>
      <section class="dialog-section intake-history" aria-label="Recent submissions">
        <div class="widget-heading"><h3>Recent submissions</h3><button class="button button-small" phx-target={@myself} phx-click="refresh-actions">Refresh</button></div>
        <p :if={@records == []} class="muted">No recorded actions for this project.</p>
        <button :for={record <- @records} type="button" class="intake-history-item" phx-target={@myself} phx-click="open-action" phx-value-id={record["id"]}>
          <span>{history_label(record)}</span><span class="muted">{proposal(record)["status"]}</span>
        </button>
      </section>
    </section>
    """
  end
end
