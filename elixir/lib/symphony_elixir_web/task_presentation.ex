defmodule SymphonyElixirWeb.TaskPresentation do
  @moduledoc "Shared task identity and dependency navigation for planning views."
  use Phoenix.Component
  alias SymphonyElixirWeb.WorkspacePath

  attr(:identifier, :string, required: true)
  attr(:url, :any, default: nil)
  attr(:kind, :any, default: "general")
  attr(:priority, :any, default: nil)
  attr(:class, :string, default: nil)
  slot(:inner_block)

  @spec identity(map()) :: Phoenix.LiveView.Rendered.t()
  def identity(assigns) do
    assigns = assign(assigns, url: safe_url(assigns.url), kind: kind(assigns.kind), priority: priority(assigns.priority))

    ~H"""
    <div class={["task-identity", @class]}>
      <a :if={@url} class="task-reference" href={@url} target="_blank" rel="noopener noreferrer" aria-label={"Open #{@identifier} in the issue tracker"}>{@identifier}</a>
      <span :if={!@url} class="task-reference">{@identifier}</span>
      <span class="card-task-kind" data-task-kind={@kind}>{kind_label(@kind)}</span>
      <span :if={@priority} class="priority" data-priority={@priority}>{@priority}</span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:task_id, :string, required: true)
  attr(:identifier, :string, required: true)
  attr(:upstream, :integer, required: true)
  attr(:downstream, :integer, required: true)
  attr(:filters, :map, default: %{})
  attr(:session, :string, default: nil)
  attr(:baseline_ref, :string, default: nil)
  attr(:live_task_id, :string, default: nil)

  @spec dependencies(map()) :: Phoenix.LiveView.Rendered.t()
  def dependencies(assigns) do
    historical = is_binary(assigns.baseline_ref)
    params = assigns.filters |> Map.merge(%{"view" => "graph", "graph_mode" => "focus", "graph_anchor" => assigns.task_id, "graph_page" => "0"}) |> Map.delete("graph_query")
    params = if historical, do: Map.put(params, "baseline", assigns.baseline_ref), else: Map.delete(params, "baseline")
    task_id = if historical, do: assigns.live_task_id, else: assigns.task_id
    params = if task_id, do: Map.put(params, "chat_task", task_id), else: Map.delete(params, "chat_task")
    params = if assigns.session, do: Map.put(params, "chat_session", assigns.session), else: params
    assigns = assign(assigns, path: WorkspacePath.path("/?" <> URI.encode_query(params)), historical: historical)

    ~H"""
    <span class="card-dependencies" aria-label="Task dependencies">
      <.link patch={@path} data-board-view-link={if !@historical, do: "graph"} data-board-view-task={if !@historical, do: @task_id} aria-label={"#{@upstream} prerequisites for #{@identifier}; open graph"} title="Prerequisites · open graph"><span aria-hidden="true">↑</span>{@upstream}</.link>
      <.link patch={@path} data-board-view-link={if !@historical, do: "graph"} data-board-view-task={if !@historical, do: @task_id} aria-label={"#{@downstream} dependent tasks for #{@identifier}; open graph"} title="Dependents · open graph"><span aria-hidden="true">↓</span>{@downstream}</.link>
    </span>
    """
  end

  @spec safe_url(term()) :: String.t() | nil
  def safe_url(value) when is_binary(value) do
    with false <- String.match?(value, ~r/[\\\x00-\x20\x7f]/),
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} <- URI.new(value),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      value
    else
      _ -> nil
    end
  end

  def safe_url(_value), do: nil

  defp kind(value) when is_binary(value) and value != "", do: value
  defp kind(_value), do: "general"
  defp kind_label("invalid"), do: "Needs classification"
  defp kind_label(value), do: String.capitalize(value)
  defp priority(value) when is_integer(value) and value > 0, do: "P#{value}"
  defp priority(_value), do: nil
end
