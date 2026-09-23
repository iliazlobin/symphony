defmodule SymphonyElixirWeb.ChatNavigation do
  @moduledoc "Pure issue navigation projected from the board and its project-bound chat summaries."

  @categories [
    %{id: "work", label: "Work"},
    %{id: "review", label: "Ready for review"},
    %{id: "attention", label: "Needs attention"},
    %{id: "backlog", label: "Backlog"},
    %{id: "done", label: "Done"}
  ]
  @synonyms %{
    "work" => "work processing working active in progress running ready queued scheduled",
    "review" => "ready for review candidate approval",
    "attention" => "needs attention blocked failed error paused confirmation",
    "backlog" => "backlog pending unstarted",
    "done" => "done completed closed finished"
  }

  @spec categories() :: [map()]
  def categories, do: @categories

  @spec issues([map()], map(), String.t() | nil, String.t()) :: [map()]
  def issues(tasks, activities, project, query \\ "") do
    tokens = query |> text() |> String.downcase() |> String.split(~r/\s+/u, trim: true)

    rows =
      tasks
      |> Enum.filter(&(is_map(&1) and field(&1, :project) == project and is_binary(field(&1, :id))))
      |> Enum.uniq_by(&field(&1, :id))
      |> Enum.map(&issue(&1, scoped_activity(activities, &1, project)))
      |> Enum.filter(&matches?(&1, tokens))
      |> Enum.sort_by(&order(&1.activity_at, &1.id))
      |> Enum.group_by(& &1.category)

    Enum.flat_map(@categories, fn category ->
      case Map.get(rows, category.id, []) do
        [] -> []
        issues -> [Map.put(category, :issues, issues)]
      end
    end)
  end

  @spec chat_activity([map()], String.t()) :: map()
  def chat_activity(chats, project) do
    chats
    |> Enum.filter(&(is_binary(&1["task_id"]) and &1["project_id"] == project))
    |> Enum.group_by(& &1["task_id"])
    |> Map.new(fn {task, entries} ->
      latest = Enum.max_by(entries, &(&1["updated_at"] || ""))
      running = Enum.any?(entries, &(&1["status"] == "running"))
      activity = latest |> Map.put("queued_count", Enum.reduce(entries, 0, &((&1["queued_count"] || 0) + &2)))
      activity = if running, do: Map.merge(activity, %{"status" => "running", "display_status" => "running"}), else: activity
      {task, activity}
    end)
  end

  @spec pull_requests(map()) :: [map()]
  def pull_requests(task) do
    task
    |> field(:pull_requests)
    |> records()
    |> Enum.map(&pull_request/1)
    |> Enum.sort_by(&{pr_order(&1.state), order(&1.activity_at, &1.number || 0)})
  end

  @doc "Safe, issue-bound summaries of native PR sessions; never exposes retained runtime paths."
  @spec work_sessions(map() | nil) :: [map()]
  def work_sessions(task) do
    works = field(field(task, :ledger), :pr_work)

    if is_map(works) do
      works
      |> Enum.filter(fn {id, work} ->
        is_binary(id) and String.match?(id, ~r/^[0-9a-f]{32}$/) and is_map(work) and
          work["id"] == id and work["issue_id"] == field(task, :issue_id)
      end)
      |> Enum.map(fn {id, work} ->
        publication = work["publication"] || %{}
        handoff = work["handoff"] || %{}

        %{
          id: id,
          title: if(is_integer(publication["pr_number"]), do: "PR ##{publication["pr_number"]}", else: "PR session #{String.slice(id, 0, 8)}"),
          pr_number: publication["pr_number"],
          pr_url: safe_url(publication["pr_url"]),
          phase: work_phase(work["phase"]),
          instruction: String.slice(text(work["instruction"]), 0, 16_000),
          summary: String.slice(text(handoff["summary"]), 0, 4_000),
          branch: String.slice(text(work["branch"]), 0, 120),
          head: String.slice(text(work["head_sha"]), 0, 7),
          review: field(handoff["review"], :verdict),
          updated_at: timestamp(work["updated_at"]),
          session_retained: text(work["builder_thread_id"]) != ""
        }
      end)
      |> Enum.sort_by(&order(&1.updated_at, &1.id))
      |> Enum.take(20)
    else
      []
    end
  end

  defp work_phase("queued"), do: "Queued"
  defp work_phase("building"), do: "Working"
  defp work_phase("reviewing"), do: "Validating"
  defp work_phase("owner_review"), do: "Ready for review"
  defp work_phase("paused"), do: "Paused"
  defp work_phase(_), do: "Unknown"

  defp issue(task, activity) do
    prs = pull_requests(task)
    category = category(task, activity)
    event = latest_event(task, activity, prs)

    %{
      id: field(task, :id),
      title: text(field(task, :title)),
      identifier: text(field(task, :identifier)),
      url: safe_url(field(task, :url)),
      stage: field(task, :stage),
      created_at: timestamp(field(task, :created_at)),
      priority: priority(field(task, :priority)),
      github_status: field(task, :github_status),
      lane: lane(task),
      category: category,
      activity_at: event.at,
      activity_label: event.label,
      preview: event.preview,
      pull_requests: prs,
      pull_request_count: length(prs)
    }
  end

  defp scoped_activity(activities, task, project) do
    case Map.get(activities, field(task, :id)) do
      %{"project_id" => ^project, "task_id" => id} = activity -> if id == field(task, :id), do: activity, else: %{}
      _ -> %{}
    end
  end

  defp category(task, activity) do
    lane = lane(task)
    runtime = field(task, :runtime)

    cond do
      lane == "done" -> "done"
      field(task, :stage) == "running" or field(runtime, :status) == "running" or chat_running?(activity) -> "work"
      lane == "review" -> "review"
      attention?(task, activity) -> "attention"
      lane == "work" -> "work"
      true -> "backlog"
    end
  end

  defp lane(task) do
    case field(task, :lane) || field(task, :stage) do
      stage when stage in ["ready", "running"] -> "work"
      stage -> stage
    end
  end

  defp chat_running?(activity), do: activity["status"] == "running" or activity["display_status"] == "action"

  defp attention?(task, activity) do
    text(field(task, :attention)) != "" or text(field(task, :blocker_reason)) != "" or
      activity["display_status"] in ~w(error interrupted queue_paused needs_reconciliation awaiting_confirmation) or
      activity["status"] in ~w(error interrupted)
  end

  defp latest_event(task, activity, prs) do
    runtime = field(task, :runtime)
    runtime_times = [field(runtime, :last_event_at), field(runtime, :started_at)]
    runtime_preview = field(runtime, :last_message) || field(runtime, :error)

    events = [
      event([field(task, :updated_at), field(task, :created_at)], "Issue updated", field(task, :title)),
      event(runtime_times, "Worker update", runtime_preview),
      event([activity["updated_at"]], "Chat updated", activity["snippet"])
      | Enum.map(prs, &event([&1.activity_at], "PR ##{&1.number} updated", &1.title)) ++
          Enum.map(work_sessions(task), &event([&1.updated_at], "#{&1.title} · #{&1.phase}", &1.instruction))
    ]

    events
    |> Enum.reject(&is_nil(&1.at))
    |> Enum.min_by(&order(&1.at, &1.label), fn -> %{at: nil, label: "No activity recorded", preview: ""} end)
  end

  defp event(timestamps, label, preview) do
    at = timestamps |> Enum.map(&timestamp/1) |> Enum.reject(&is_nil/1) |> Enum.min_by(&order(&1, ""), fn -> nil end)
    %{at: at, label: label, preview: preview |> text() |> String.replace(~r/\s+/u, " ") |> String.slice(0, 160)}
  end

  defp matches?(row, tokens) do
    haystack = [row.title, row.identifier, row.activity_label, row.preview, row.category, @synonyms[row.category]] |> Enum.join(" ") |> String.downcase()
    Enum.all?(tokens, &String.contains?(haystack, &1))
  end

  defp pull_request(pr) do
    state = normalized(field(pr, :state), ~w(open closed merged))
    draft = field(pr, :draft) == true
    url = safe_url(field(pr, :url))
    checks = records(field(pr, :check_runs))
    check_times = Enum.flat_map(checks, &[field(&1, :started_at), field(&1, :completed_at)])
    times = [field(pr, :updated_at), field(pr, :created_at)] ++ check_times

    %{
      number: nonnegative(field(pr, :number)),
      title: text(field(pr, :title)),
      url: url,
      state: state,
      status: if(state == "open" and draft, do: "Draft", else: String.capitalize(state)),
      ci: normalized(field(pr, :checks), ~w(success pending failure error expected unknown unavailable stale)),
      review: normalized(field(pr, :review), ~w(approved changes_requested review_required no_decision unknown)),
      updated_at: timestamp(field(pr, :updated_at)),
      created_at: timestamp(field(pr, :created_at)),
      activity_at: event(times, "", "").at,
      check_count: nonnegative(field(pr, :check_total)) || length(records(field(pr, :check_runs))),
      checks_url: checks_url(url)
    }
  end

  defp checks_url(nil), do: nil

  defp checks_url(url) do
    uri = URI.parse(url)
    URI.to_string(%{uri | path: String.trim_trailing(uri.path || "", "/") <> "/checks", query: nil, fragment: nil})
  end

  defp pr_order("open"), do: 0
  defp pr_order("unknown"), do: 1
  defp pr_order(_state), do: 2

  defp order(nil, tie), do: {true, 0, tie}

  defp order(value, tie) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    {false, -DateTime.to_unix(datetime, :microsecond), tie}
  end

  defp timestamp(%DateTime{} = datetime), do: datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp safe_url(value) when is_binary(value) do
    with false <- String.match?(value, ~r/[\\\x00-\x20\x7f]/),
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} <- URI.new(value),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      value
    else
      _ -> nil
    end
  end

  defp safe_url(_value), do: nil
  defp normalized(value, allowed), do: if(String.downcase(text(value)) in allowed, do: String.downcase(text(value)), else: "unknown")
  defp priority(value) when value in 1..4, do: value
  defp priority(_value), do: nil
  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: nil
  defp records(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp records(_value), do: []
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
  defp field(value, key) when is_map(value), do: Map.get(value, key, Map.get(value, Atom.to_string(key)))
  defp field(_value, _key), do: nil
end
