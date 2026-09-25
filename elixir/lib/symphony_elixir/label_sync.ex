defmodule SymphonyElixir.LabelSync do
  @moduledoc "Mirrors durable local routing to owned GitHub labels; never schedules work or edits issue content."
  use GenServer
  require Logger

  alias SymphonyElixir.Chat.GitHub
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.TaskRouting

  @interval 15_000
  @audit_interval 60_000
  @max_backoff 300_000
  @intent_fields ~w(tracker_fingerprint repository labels queued revision)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc false
  @spec sync(GenServer.server()) :: :ok
  def sync(server), do: GenServer.call(server, :sync, 120_000)

  @impl true
  def init(opts) do
    state = %{
      context: Keyword.get(opts, :context_fun, &native_context/0),
      request: Keyword.get(opts, :request_fun, &GitHub.request_once/5),
      acknowledge: Keyword.get(opts, :ack_fun, &Orchestrator.routing_sync_result/4),
      clock: Keyword.get(opts, :clock_fun, fn -> System.monotonic_time(:millisecond) end),
      interval: Keyword.get(opts, :interval_ms, @interval),
      scope: nil,
      due: %{},
      cursor: 0
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, tick(state)}

  @impl true
  def handle_info(:tick, state) do
    state = tick(state)
    schedule(state)
    {:noreply, state}
  end

  defp schedule(%{interval: :manual}), do: :ok
  defp schedule(state), do: Process.send_after(self(), :tick, state.interval)

  defp native_context do
    with {:ok, config} <- Config.settings(),
         control <- Config.control_settings(),
         true <- control.enabled and config.tracker.kind == "github",
         snapshot when is_map(snapshot) <- Orchestrator.control_snapshot() do
      {:ok, %{tracker: config.tracker, control: control, snapshot: snapshot}}
    else
      _ -> :disabled
    end
  end

  defp context(state) do
    with {:ok, %{tracker: tracker, control: control, snapshot: snapshot} = context} <- state.context.(),
         true <- control.enabled and tracker.kind == "github" and is_binary(control.state_path),
         true <- snapshot["enabled"] == true and is_nil(snapshot["fault"]) and is_nil(snapshot["error"]),
         instance when is_binary(instance) <- snapshot["instance_id"],
         fingerprint when is_binary(fingerprint) <- snapshot["tracker_fingerprint"],
         true <- fingerprint == TaskRouting.fingerprint(tracker),
         repo when is_binary(repo) <- tracker.provider["repo"],
         true <- Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repo),
         true <- is_map(snapshot["issues"]) do
      {:ok, Map.merge(context, %{repo: repo, tag: {tracker, control, instance}})}
    else
      _ -> :disabled
    end
  rescue
    _ -> :disabled
  catch
    :exit, _ -> :disabled
  end

  defp tick(state) do
    case context(state) do
      {:ok, context} -> tick(state, context)
      :disabled -> %{state | scope: nil, due: %{}, cursor: 0}
    end
  end

  defp tick(state, context) do
    state = if state.scope == context.tag, do: state, else: %{state | scope: context.tag, due: %{}, cursor: 0}

    issues =
      context.snapshot["issues"]
      |> Enum.filter(fn {id, issue} -> valid_intent?(context, id, issue["routing"]) and due?(state, id, issue["routing"]) end)
      |> Enum.sort_by(&elem(&1, 0))

    count = length(issues)
    cursor = if count > 0, do: rem(state.cursor, count), else: 0
    entries = (Enum.drop(issues, cursor) ++ Enum.take(issues, cursor)) |> Enum.take(5)
    state = %{state | due: Map.take(state.due, Map.keys(context.snapshot["issues"]))}
    next = Enum.reduce(entries, state, fn {id, issue}, acc -> sync_issue(acc, context, id, issue["routing"]) end)
    %{next | cursor: cursor + 5}
  end

  defp sync_issue(state, context, id, routing) do
    result = deliver(state, context, id, routing)

    case acknowledge(state, context, id, routing, result) do
      :ok when result == :ok -> checked(state, id, routing)
      :ok -> failed(state, id, routing, elem(result, 1))
      {:error, reason} -> failed(state, id, routing, reason, routing["status"])
    end
  end

  defp valid_intent?(context, id, routing) when is_binary(id) and is_map(routing) do
    Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, id) and TaskRouting.valid?(routing) and
      routing["tracker_fingerprint"] == context.snapshot["tracker_fingerprint"] and
      routing["repository"] == context.repo and routing["labels"] == context.tracker.required_labels
  end

  defp valid_intent?(_context, _id, _routing), do: false

  defp deliver(state, context, id, routing) do
    with {:ok, labels} <- read_issue(state, context, id, routing) do
      if matches?(labels, routing), do: :ok, else: write_and_verify(state, context, id, routing, labels)
    end
  end

  defp write_and_verify(state, context, id, routing, labels) do
    with :ok <- update_labels(state, context, id, routing, labels),
         {:ok, actual} <- read_issue(state, context, id, routing),
         true <- matches?(actual, routing) or {:error, :github_labels_not_converged} do
      :ok
    end
  end

  defp read_issue(state, context, id, routing) do
    with {:ok, %{status: 200, body: issue}} <- request(state, context, id, routing, "GET", issue_path(context, id)),
         true <- identity?(issue, context, id) or {:error, :github_issue_identity},
         {:ok, labels} <- label_names(issue["labels"]) do
      {:ok, labels}
    else
      {:error, _} = error -> error
      _ -> {:error, :github_issue_unavailable}
    end
  end

  defp identity?(issue, context, id) when is_map(issue) do
    issue["number"] == String.to_integer(id) and is_nil(issue["pull_request"]) and issue["state"] in ["open", "closed"] and
      issue["html_url"] == "https://github.com/#{context.repo}/issues/#{id}"
  end

  defp identity?(_issue, _context, _id), do: false

  defp label_names(labels) when is_list(labels) do
    if Enum.all?(labels, &(is_map(&1) and is_binary(&1["name"]) and &1["name"] != "")),
      do: {:ok, Enum.map(labels, & &1["name"])},
      else: {:error, :github_labels_invalid}
  end

  defp label_names(_labels), do: {:error, :github_labels_invalid}

  defp matches?(labels, routing) do
    actual = MapSet.new(labels, &String.downcase/1)
    owned = Enum.map(routing["labels"], &String.downcase/1)
    if routing["queued"], do: Enum.all?(owned, &MapSet.member?(actual, &1)), else: Enum.all?(owned, &(not MapSet.member?(actual, &1)))
  end

  defp update_labels(state, context, id, %{"queued" => true} = routing, labels) do
    actual = MapSet.new(labels, &String.downcase/1)
    missing = Enum.reject(routing["labels"], &MapSet.member?(actual, String.downcase(&1)))
    path = issue_path(context, id) <> "/labels"

    case request(state, context, id, routing, "POST", path, %{"labels" => missing}) do
      {:ok, %{status: 200}} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :github_labels_write_failed}
    end
  end

  defp update_labels(state, context, id, routing, labels) do
    owned = MapSet.new(routing["labels"], &String.downcase/1)

    labels
    |> Enum.filter(&MapSet.member?(owned, String.downcase(&1)))
    |> Enum.reduce_while(:ok, fn label, :ok ->
      path = issue_path(context, id) <> "/labels/" <> URI.encode(label, &URI.char_unreserved?/1)

      case request(state, context, id, routing, "DELETE", path) do
        {:ok, %{status: status}} when status in [200, 404] -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :github_labels_write_failed}}
      end
    end)
  end

  defp request(state, context, id, routing, method, path, body \\ nil) do
    with :ok <- guard(state, context, id, routing) do
      Client.request(method, path, %{}, body, tracker_settings: context.tracker, request_fun: state.request)
    end
  rescue
    _ -> {:error, :github_unavailable}
  catch
    :exit, _ -> {:error, :github_unavailable}
  end

  defp acknowledge(state, context, id, routing, result) do
    with :ok <- guard(state, context, id, routing) do
      case state.acknowledge.(id, routing["revision"], routing["tracker_fingerprint"], result) do
        :ok -> :ok
        {:ok, _receipt} -> :ok
        _ -> {:error, :routing_acknowledgement_failed}
      end
    end
  rescue
    _ -> {:error, :routing_acknowledgement_failed}
  catch
    :exit, _ -> {:error, :routing_acknowledgement_failed}
  end

  defp guard(state, captured, id, routing) do
    with {:ok, current} <- context(state),
         true <- current.tag == captured.tag,
         intent when is_map(intent) <- get_in(current.snapshot, ["issues", id, "routing"]),
         true <- Map.take(intent, @intent_fields) == Map.take(routing, @intent_fields) do
      :ok
    else
      _ -> {:error, :routing_scope_or_intent_changed}
    end
  end

  defp due?(state, id, routing) do
    case state.due[id] do
      %{revision: revision, at: at, status: status} ->
        revision != routing["revision"] or status != routing["status"] or state.clock.() >= at

      nil ->
        true
    end
  end

  defp checked(state, id, routing) do
    due = %{revision: routing["revision"], status: "synced", at: state.clock.() + @audit_interval, delay: 0, reason: nil}
    %{state | due: Map.put(state.due, id, due)}
  end

  defp failed(state, id, routing, reason, status \\ "pending") do
    previous = state.due[id]
    delay = if previous && previous.revision == routing["revision"], do: min(max(previous.delay * 2, @interval), @max_backoff), else: @interval
    reason = if is_atom(reason), do: reason, else: :github_unavailable
    if is_nil(previous) or previous.reason != reason, do: Logger.warning("Routing label mirror pending issue_id=#{id} reason=#{reason}")
    due = %{revision: routing["revision"], status: status, at: state.clock.() + delay, delay: delay, reason: reason}
    %{state | due: Map.put(state.due, id, due)}
  end

  defp issue_path(context, id), do: "/repos/#{context.repo}/issues/#{id}"
end
