defmodule SymphonyElixir.Chat.Artifacts do
  @moduledoc "Bounded, project-scoped snapshots projected from a conversation's durable tool results."

  @limit 100
  @actions ~w(create_task edit_task feedback queue_task unqueue_task pause drain resume cancel retry set_concurrency)
  @action_statuses ~w(pending executing completed cancelled unknown failed)

  @spec entries(term()) :: [map()]
  def entries(%{"project_id" => "github:" <> repo} = chat) do
    if String.match?(repo, ~r/^[A-Za-z0-9][A-Za-z0-9_-]*\/(?!\.{1,2}$)[A-Za-z0-9_.-]+$/) do
      project = "github:" <> repo

      messages =
        chat["messages"]
        |> items(400)
        |> Enum.flat_map(fn message ->
          message["widgets"] |> items(60) |> Enum.flat_map(&widget_entries(&1, project, repo))
        end)

      actions = chat["proposals"] |> items(400) |> Enum.flat_map(&action_entries(&1, project, repo))

      (messages ++ actions)
      |> Enum.reverse()
      |> Enum.uniq_by(&{&1["kind"], &1["id"]})
      |> Enum.take(@limit)
    else
      []
    end
  end

  def entries(_), do: []

  defp widget_entries(%{"type" => "task", "task" => task}, project, repo) when is_map(task),
    do: task_entries(task, task["checked_at"], project, repo)

  defp widget_entries(%{"type" => "tasks", "tasks" => tasks} = widget, project, repo),
    do: tasks |> items(50) |> Enum.flat_map(&task_entries(&1, widget["checked_at"], project, repo))

  defp widget_entries(_, _, _), do: []

  defp task_entries(task, checked_at, project, repo) do
    number = number(task["issue_id"])

    if number && task["id"] == project <> ":" <> number && task["project"] == project do
      issue =
        entry("issue", task["id"], text(task["title"]) || "Issue ##{number}", "https://github.com/#{repo}/issues/#{number}", choice(task["tracker_state"], ~w(open closed)), task, checked_at, [
          metric("Workflow", choice(task["stage"], ~w(backlog ready running review done))),
          metric("Priority", priority(task["priority"]))
        ])

      [issue | task["pull_requests"] |> items(20) |> Enum.flat_map(&pull_request_entries(&1, checked_at, repo))]
    else
      []
    end
  end

  defp pull_request_entries(pr, checked_at, repo) do
    number = number(pr["number"])
    url = "https://github.com/#{repo}/pull/#{number}"

    if number && pr["url"] == url do
      metrics = [
        metric("Review", choice(pr["review"], ~w(approved changes_requested review_required no_decision))),
        metric("Checks", choice(pr["checks"], ~w(success pending failure error expected stale))),
        metric("Check details", choice(pr["check_details_status"], ~w(available partial stale unavailable))),
        metric("Check count", count(pr["check_total"])),
        metric("Draft", boolean(pr["draft"])),
        metric("Additions", count(pr["additions"])),
        metric("Deletions", count(pr["deletions"])),
        metric("Files", count(pr["changed_files"]))
      ]

      [entry("pull_request", "github:#{repo}:pull:#{number}", text(pr["title"]) || "Pull request ##{number}", url, choice(pr["state"], ~w(open closed merged)), pr, checked_at, metrics)]
    else
      []
    end
  end

  defp action_entries(proposal, project, repo) do
    if proposal["project_id"] == project && text(proposal["id"]) && proposal["action"] in @actions && proposal["status"] in @action_statuses do
      receipt = if is_map(proposal["receipt"]), do: proposal["receipt"], else: %{}
      title = proposal["action"] |> String.replace("_", " ") |> String.capitalize()
      widgets = items(receipt["widgets"], 20)
      number = widgets |> Enum.map(&receipt_number(&1["task_id"], project)) |> Enum.find(& &1)
      url = if number, do: "https://github.com/#{repo}/issues/#{number}", else: nil

      [
        entry("action", proposal["id"], title, url, proposal["status"], proposal, receipt["checked_at"], [
          metric("Outcome", if(proposal["status"] == "completed" and map_size(receipt) > 0, do: "Confirmed by action receipt", else: "No confirmed success"))
        ])
      ]
    else
      []
    end
  end

  defp receipt_number(id, project) when is_binary(id) do
    prefix = project <> ":"
    if String.starts_with?(id, prefix), do: id |> String.replace_prefix(prefix, "") |> number(), else: nil
  end

  defp receipt_number(_, _), do: nil

  defp entry(kind, id, title, url, status, source, checked_at, metrics) do
    %{
      "kind" => kind,
      "id" => id,
      "title" => title,
      "url" => url,
      "status" => status,
      "created_at" => timestamp(source["created_at"]),
      "updated_at" => timestamp(source["updated_at"]),
      "checked_at" => timestamp(checked_at),
      "metrics" => metrics
    }
  end

  defp items(value, limit) when is_list(value), do: value |> Enum.take(-limit) |> Enum.filter(&is_map/1)
  defp items(_, _), do: []
  defp text(value) when is_binary(value), do: if(String.valid?(value), do: String.slice(value, 0, 1_024), else: nil)
  defp text(_), do: nil
  defp number(value) when is_integer(value) and value > 0, do: Integer.to_string(value)
  defp number(value) when is_binary(value), do: if(String.match?(value, ~r/^[1-9][0-9]{0,15}$/), do: value, else: nil)
  defp number(_), do: nil
  defp choice(value, allowed), do: if(value in allowed, do: value, else: "unknown")
  defp priority(value) when value in 1..4, do: "P#{value}"
  defp priority(_), do: "unknown"
  defp count(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp count(_), do: "unknown"
  defp boolean(true), do: "Yes"
  defp boolean(false), do: "No"
  defp boolean(_), do: "unknown"
  defp metric(label, value), do: %{"label" => label, "value" => value}

  defp timestamp(value) when is_binary(value) and byte_size(value) <= 40 do
    if match?({:ok, _, _}, DateTime.from_iso8601(value)), do: value, else: nil
  end

  defp timestamp(_), do: nil
end
