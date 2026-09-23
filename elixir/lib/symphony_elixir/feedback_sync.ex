defmodule SymphonyElixir.FeedbackSync do
  @moduledoc "Mirrors explicitly selected native feedback to one GitHub status reply; never schedules work."
  use GenServer
  require Logger

  alias SymphonyElixir.Chat.GitHub
  alias SymphonyElixir.Config
  alias SymphonyElixir.Feedback
  alias SymphonyElixir.FeedbackSync.Journal
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Orchestrator

  @interval 15_000
  @max_backoff 300_000

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
      journal: nil,
      backoff: %{},
      cursor: 0,
      interval: Keyword.get(opts, :interval_ms, @interval)
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

  def handle_info({port, {:exit_status, _}}, %{journal: %{lock: port}} = state), do: {:noreply, close(state)}
  def handle_info({_port, {:exit_status, _}}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close(state)
    :ok
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
    with {:ok, context} <- state.context.(),
         %{tracker: tracker, control: control, snapshot: snapshot} <- context,
         true <- control.enabled and tracker.kind == "github" and is_binary(control.state_path),
         true <- snapshot["enabled"] == true and is_nil(snapshot["fault"]) and is_nil(snapshot["error"]),
         instance when is_binary(instance) <- snapshot["instance_id"],
         fingerprint when is_binary(fingerprint) <- snapshot["tracker_fingerprint"],
         true <- fingerprint == fingerprint(tracker),
         repo when is_binary(repo) <- tracker.provider["repo"],
         true <- Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repo),
         true <- is_map(snapshot["issues"]) do
      {:ok, Map.merge(context, %{repo: repo, scope: hash([fingerprint, control.state_path]), tag: {tracker, control, instance}})}
    else
      _ -> :disabled
    end
  rescue
    _ -> :disabled
  catch
    :exit, _ -> :disabled
  end

  defp tick(state) do
    with {:ok, context} <- context(state),
         {:ok, state} <- open(state, context.control.state_path <> ".feedback") do
      issues = context.snapshot["issues"] |> Enum.sort_by(&elem(&1, 0))
      count = length(issues)
      cursor = if count > 0, do: rem(state.cursor, count), else: 0
      entries = (Enum.drop(issues, cursor) ++ Enum.take(issues, cursor)) |> Enum.take(5)
      next = Enum.reduce(entries, state, fn {id, ledger}, acc -> sync_issue(acc, context, id, ledger) end)
      %{next | cursor: cursor + 5}
    else
      :disabled -> close(state)
      {:error, next} -> next
    end
  end

  defp open(%{journal: %{root: root}} = state, root), do: {:ok, state}

  defp open(state, root) do
    state = close(state)

    case Journal.open(root) do
      {:ok, journal} -> {:ok, %{state | journal: journal}}
      {:error, _reason} -> {:error, state}
    end
  end

  defp close(%{journal: nil} = state), do: state

  defp close(state) do
    Journal.close(state.journal)
    %{state | journal: nil, backoff: %{}, cursor: 0}
  end

  defp sync_issue(state, context, id, ledger) do
    with true <- is_binary(id) and Regex.match?(~r/\A[1-9][0-9]*\z/, id),
         key = hash([context.scope, id]),
         record = state.journal.records[key],
         items = selected(ledger, context, id),
         true <- items != [] or not is_nil(record),
         true <- due?(state, key),
         body = render(items, key),
         digest = hash(body),
         false <- not is_nil(record) and record["state"] == "confirmed" and record["hash"] == digest do
      case deliver(state, context, id, key, body, digest, record) do
        {:ok, next} -> %{next | backoff: Map.delete(next.backoff, key)}
        {:error, reason, next} -> failed(next, key, id, reason)
      end
    else
      _ -> state
    end
  end

  defp selected(ledger, context, id) do
    works = ledger["pr_work"] || %{}
    scoped = Map.filter(works, fn {_key, work} -> work["issue_id"] == id and work["tracker_fingerprint"] == context.snapshot["tracker_fingerprint"] end)

    work = scoped[ledger["selected_work_id"]] || %{}
    items = if Feedback.valid_items?(work["feedback"] || []), do: work["feedback"] || [], else: []

    items
    |> Enum.filter(&safe_link?(&1, context.repo, id))
    |> Enum.take(100)
    |> Feedback.progress(Map.put(ledger, "pr_work", scoped))
    |> Enum.sort_by(& &1["id"])
  end

  defp safe_link?(item, repo, issue) do
    {path, number, fragment} =
      case item["source"] do
        "issue" -> {"issues", issue, ~r/\Aissuecomment-[1-9][0-9]*\z/}
        "pr" -> {"pull", item["pr_number"], ~r/\Aissuecomment-[1-9][0-9]*\z/}
        "review" -> {"pull", item["pr_number"], ~r/\A(?:discussion_r|pullrequestreview-)[1-9][0-9]*\z/}
      end

    url = URI.parse(item["url"])

    trusted_url?(url) and not is_nil(number) and url.path == "/#{repo}/#{path}/#{number}" and
      is_binary(url.fragment) and Regex.match?(fragment, url.fragment)
  end

  defp trusted_url?(url),
    do: url.scheme == "https" and url.host == "github.com" and is_nil(url.userinfo) and is_nil(url.query) and url.port == 443

  defp render(items, key) do
    counts = Feedback.counts(items)
    summary = "#{counts["queued"]} queued · 👀 #{counts["working"]} working · ✅ #{counts["addressed"]} addressed · ❗ #{counts["blocked"]} blocked"
    lines = render_items(items)

    "#{marker(key)}\nSymphony — current feedback batch\n\n#{summary}\n\n#{lines}\n\nStatus follows the currently selected feedback revisions in Symphony. Addressed means candidate review evidence; human acceptance remains separate."
  end

  defp render_items([]), do: "No comments selected for the current work batch."

  defp render_items(items),
    do: Enum.map_join(items, "\n", fn item -> "- #{status(item["status"])} — [source](#{item["url"]}) · revision `#{String.slice(item["revision"], 0, 12)}`" end)

  defp status("working"), do: "👀 Working"
  defp status("addressed"), do: "✅ Addressed"
  defp status("blocked"), do: "❗ Blocked"
  defp status("queued"), do: "Queued"
  defp status(_), do: "Pending"

  defp deliver(state, context, id, key, body, digest, record) do
    with :ok <- guard(state, context, id, body, key),
         {:ok, %{status: 200, body: viewer}} <- request(state, context, "GET", "/user"),
         viewer_id when is_integer(viewer_id) and viewer_id > 0 <- viewer["id"],
         {:ok, comments} <- comments(state, context, id, 1, []),
         matches = Enum.filter(comments, &(get_in(&1, ["user", "id"]) == viewer_id and is_binary(&1["body"]) and String.starts_with?(&1["body"], marker(key) <> "\n"))),
         {:ok, found} <- unique(matches, record, context, id) do
      publish(state, context, id, key, body, digest, found, record)
    else
      {:error, reason} -> {:error, reason, state}
      _ -> {:error, :feedback_remote_unavailable, state}
    end
  end

  defp comments(_state, _context, _id, page, _acc) when page > 10, do: {:error, :feedback_comments_partial}

  defp comments(state, context, id, page, acc) do
    path = issue_path(context, id) <> "/comments"
    params = %{"per_page" => 100, "page" => page}

    with :ok <- same_scope(state, context),
         {:ok, %{status: 200, body: items}} when is_list(items) <- request(state, context, "GET", path, params) do
      if length(items) < 100, do: {:ok, acc ++ items}, else: comments(state, context, id, page + 1, acc ++ items)
    else
      _ -> {:error, :feedback_comments_unavailable}
    end
  end

  defp unique([], nil, _context, _id), do: {:ok, nil}
  defp unique([], _record, _context, _id), do: {:error, :feedback_write_outcome_unknown}

  defp unique([comment], record, context, id) do
    number = comment["id"]
    valid_id = is_integer(number) and number > 0
    expected_url = "https://github.com/#{context.repo}/issues/#{id}#issuecomment-#{number}"
    matches_record = is_nil(record) or is_nil(record["comment_id"]) or record["comment_id"] == number

    if valid_id and comment["html_url"] == expected_url and matches_record do
      {:ok, comment}
    else
      {:error, :feedback_comment_identity_changed}
    end
  end

  defp unique(_matches, _record, _context, _id), do: {:error, :feedback_duplicate_markers}

  defp publish(state, context, id, key, body, digest, nil, nil) do
    # Explicit human selection and native rework confirmation authorize this status reply.
    # Persist intent before the sole POST attempt; unknown results recover only by marker.
    pending = %{"state" => "pending", "comment_id" => nil, "hash" => nil}

    with {:ok, %{status: 200, body: issue}} <- request(state, context, "GET", issue_path(context, id)),
         true <- issue_identity?(issue, context, id),
         :ok <- guard(state, context, id, body, key),
         {:ok, journal} <- Journal.put(state.journal, key, pending) do
      state = %{state | journal: journal}
      path = issue_path(context, id) <> "/comments"

      result =
        with :ok <- guard(state, context, id, body, key) do
          request(state, context, "POST", path, %{}, %{"body" => body})
        end

      case result do
        {:ok, %{status: 201, body: %{"id" => comment_id}}} when is_integer(comment_id) and comment_id > 0 ->
          confirmed(state, key, comment_id, digest)

        _ ->
          {:error, :feedback_write_outcome_unknown, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
      _ -> {:error, :feedback_issue_identity_changed, state}
    end
  end

  defp publish(state, context, id, key, body, digest, comment, _record) do
    if comment["body"] == body do
      confirmed(state, key, comment["id"], digest)
    else
      with :ok <- guard(state, context, id, body, key),
           {:ok, %{status: 200}} <- request(state, context, "PATCH", "/repos/#{context.repo}/issues/comments/#{comment["id"]}", %{}, %{"body" => body}) do
        confirmed(state, key, comment["id"], digest)
      else
        _ -> {:error, :feedback_update_unavailable, state}
      end
    end
  end

  defp confirmed(state, key, comment_id, digest) do
    case Journal.put(state.journal, key, %{"state" => "confirmed", "comment_id" => comment_id, "hash" => digest}) do
      {:ok, journal} -> {:ok, %{state | journal: journal}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp issue_identity?(issue, context, id) do
    issue["number"] == String.to_integer(id) and is_nil(issue["pull_request"]) and
      issue["html_url"] == "https://github.com/#{context.repo}/issues/#{id}"
  end

  defp guard(state, captured, id, body, key) do
    with {:ok, current} <- context(state),
         true <- current.tag == captured.tag,
         ledger when is_map(ledger) <- current.snapshot["issues"][id],
         true <- render(selected(ledger, current, id), key) == body,
         true <- Journal.owned?(state.journal) do
      :ok
    else
      _ -> {:error, :feedback_scope_or_progress_changed}
    end
  end

  defp same_scope(state, captured) do
    case context(state) do
      {:ok, %{tag: tag}} when tag == captured.tag -> :ok
      _ -> {:error, :feedback_scope_changed}
    end
  end

  defp request(state, context, method, path, params \\ %{}, body \\ nil),
    do: Client.request(method, path, params, body, tracker_settings: context.tracker, request_fun: state.request)

  defp due?(state, key), do: is_nil(state.backoff[key]) or System.monotonic_time(:millisecond) >= state.backoff[key].at

  defp failed(state, key, id, reason) do
    previous = state.backoff[key]
    delay = if previous, do: min(previous.delay * 2, @max_backoff), else: @interval
    if is_nil(previous) or previous.reason != reason, do: Logger.warning("Feedback mirror held issue_id=#{id} reason=#{inspect(reason)}")
    %{state | backoff: Map.put(state.backoff, key, %{delay: delay, at: System.monotonic_time(:millisecond) + delay, reason: reason})}
  end

  defp fingerprint(tracker), do: :crypto.hash(:sha256, :erlang.term_to_binary(tracker)) |> Base.url_encode64(padding: false)
  defp hash(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
  defp marker(key), do: "<!-- symphony-feedback:#{key} -->"
  defp issue_path(context, id), do: "/repos/#{context.repo}/issues/#{id}"
end
