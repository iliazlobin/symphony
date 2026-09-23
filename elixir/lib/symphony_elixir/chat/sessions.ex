defmodule SymphonyElixir.Chat.Sessions do
  @moduledoc "Issue-bound PR chat identities and reports projected from authoritative work and PR evidence."

  alias SymphonyElixirWeb.ChatNavigation

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and String.match?(id, ~r/\A(?:work:[a-f0-9]{32}|pr:[1-9][0-9]{0,19})\z/)

  def options(task, retained \\ [])
  @spec options(map() | nil, [String.t() | nil]) :: [map()]
  def options(nil, _retained), do: []

  def options(task, retained) do
    works = ChatNavigation.work_sessions(task)
    prs = ChatNavigation.pull_requests(task)

    published =
      Enum.map(prs, fn pr ->
        work = Enum.find(works, &(&1.pr_number == pr.number and &1.pr_url == pr.url))
        name = if String.trim(pr.title) == "", do: "PR ##{pr.number}", else: pr.title

        %{
          id: if(work, do: "work:" <> work.id, else: "pr:#{pr.number}"),
          title: "PR ##{pr.number} · #{pr.title}",
          name: name,
          discussion: is_nil(work),
          label: "PR ##{pr.number}",
          status: pr.status,
          pr: pr,
          work: work
        }
      end)

    pending =
      works
      |> Enum.reject(fn work -> Enum.any?(published, &(&1.work && &1.work.id == work.id)) end)
      |> Enum.map(&%{id: "work:" <> &1.id, title: &1.title, name: &1.name, discussion: false, label: &1.title, status: &1.phase, pr: nil, work: &1})

    # A discussion opened before the publication receipt must keep its history and
    # remain read-only when a native worker is subsequently associated with the PR.
    discussions =
      published
      |> Enum.filter(&(&1.work && "pr:#{&1.pr.number}" in retained))
      |> Enum.map(&%{&1 | id: "pr:#{&1.pr.number}", title: "PR ##{&1.pr.number} · Discussion", discussion: true, work: nil})

    pending ++ published ++ discussions
  end

  @spec resolve(map(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def resolve(task, id, fingerprint) do
    with true <- valid_id?(id),
         %{} = option <- Enum.find(options(task, [id]), &(&1.id == id)),
         true <- valid_binding?(task, option, fingerprint) do
      {:ok,
       %{
         "session_id" => id,
         "task_id" => task.id,
         "work_id" => option.work && option.work.id,
         "pr_number" => (option.pr && option.pr.number) || (option.work && option.work.pr_number),
         "title" => option.title,
         "status" => option.status
       }}
    else
      _ -> {:error, :pr_session_unavailable}
    end
  end

  defp valid_binding?(task, %{work: %{id: id}}, fingerprint) do
    work = get_in(task, [:ledger, "pr_work", id])
    is_map(work) and work["id"] == id and work["issue_id"] == task.issue_id and work["tracker_fingerprint"] == fingerprint
  end

  defp valid_binding?(%{project: "github:" <> repo} = task, %{pr: pr}, _fingerprint) do
    task[:source_missing] != true and is_integer(pr.number) and pr.number > 0 and pr.url == "https://github.com/#{repo}/pull/#{pr.number}"
  end

  defp valid_binding?(_, _, _), do: false

  @doc "Current milestones only. Missing evidence never becomes a success or a new execution instruction."
  @spec reports(map(), String.t(), String.t() | nil) :: [map()]
  def reports(task, fingerprint, session_id \\ nil) do
    options(task, [session_id])
    |> Enum.filter(&((is_nil(session_id) or &1.id == session_id) and valid_binding?(task, &1, fingerprint)))
    |> Enum.flat_map(&reports_for(task, &1))
    |> Enum.take(100)
  end

  defp reports_for(task, %{work: work} = option) do
    native = if work, do: native_report(task, option), else: []
    github = if option.pr && task[:github_status] in ["available", "partial"], do: github_report(task, option), else: []
    native ++ github
  end

  defp native_report(task, option) do
    work = get_in(task, [:ledger, "pr_work", option.work.id])
    handoff = work["handoff"] || %{}
    publication = work["publication"] || %{}
    status = if publication["status"] == "merged", do: "Merged", else: option.work.phase
    summary = if work["phase"] == "owner_review", do: handoff["summary"], else: nil
    text = "#{option.label} · #{status}" <> if(is_binary(summary) and summary != "", do: "\n" <> String.slice(summary, 0, 1_500), else: "")

    active = get_in(task, [:ledger, "active"]) || %{}
    active_run = if active["work_id"] == option.work.id, do: active["run_id"]

    evidence =
      Map.take(work, ~w(phase head_sha working_head_sha builder_thread_id instruction publication))
      |> Map.put("run_id", handoff["run_id"])
      |> Map.put("active_run_id", active_run)
      |> Map.put("review", handoff["review"])

    [report(option.id, "worker", text, evidence, work["updated_at"])]
  end

  defp github_report(task, option) do
    pr = Enum.find(task[:pull_requests] || [], &(&1[:number] == option.pr.number))
    head = pr && pr[:head_sha]

    if is_binary(head) and String.match?(head, ~r/\A[a-f0-9]{40}\z/) do
      ci = if pr[:check_details_status] in ["stale", "unavailable"], do: pr[:check_details_status], else: option.pr.ci
      evidence = Map.take(pr, ~w(state draft head_sha checks review check_total)a) |> Map.put(:checks, ci)
      text = "#{option.label} · #{option.pr.status} · CI: #{String.capitalize(ci)} · Review: #{String.replace(option.pr.review, "_", " ")}"
      text = if option.pr.state == "merged", do: text <> "\nIssue acceptance remains separate.", else: text
      [report(option.id, "github", text, evidence, option.pr.activity_at)]
    else
      []
    end
  end

  defp truncate_bytes(text, limit) when byte_size(text) <= limit, do: text

  defp truncate_bytes(text, limit) do
    prefix = binary_part(text, 0, limit - 3)
    valid = if String.valid?(prefix), do: prefix, else: valid_prefix(prefix)
    valid <> "…"
  end

  defp valid_prefix(text) do
    prefix = binary_part(text, 0, byte_size(text) - 1)
    if String.valid?(prefix), do: prefix, else: valid_prefix(prefix)
  end

  defp report(session, source, text, evidence, at) do
    signature = :crypto.hash(:sha256, :erlang.term_to_binary(evidence)) |> Base.encode16(case: :lower)
    %{"session_id" => session, "key" => session <> "/" <> source, "signature" => signature, "text" => truncate_bytes(text, 8_000), "source_at" => at}
  end
end
