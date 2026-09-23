defmodule SymphonyElixirWeb.TaskBoard do
  @moduledoc """
  Read-only board projection of tracker issues, runtime activity and durable holds.

  `load/2` bounds the three reads by one timeout. A non-nil `source_error` or
  `runtime_error` means the caller must retain its previous complete task list.
  Reads never admit, retry, close or otherwise mutate a tracker issue.

  Work includes queued and running tasks. With native controls, Done requires
  explicit human acceptance; tracker closure remains Review until accepted.
  Uncontrolled trackers retain their terminal-state behavior. Each task retains the distinction in
  `completion_evidence`, `tracker_state`, `hold` and `attention`.
  """

  alias SymphonyElixir.{Config, IssueAcceptance, Orchestrator, Tracker}
  alias SymphonyElixir.GitHub.{Admission, Board, Client}
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixirWeb.Presenter

  @spec load(GenServer.name(), pos_integer()) :: map()
  def load(orchestrator, timeout) when is_integer(timeout) and timeout > 0 do
    case Config.settings() do
      {:ok, settings} -> load_settings(orchestrator, timeout, settings)
      {:error, _reason} -> unavailable_configuration()
    end
  end

  @doc "Initial runtime-only view while the tracker is loading. It is not a complete board."
  @spec from_runtime(map()) :: map()
  def from_runtime(runtime) do
    case Config.settings() do
      {:ok, settings} ->
        []
        |> project(runtime, %{}, settings)
        |> Map.put(:source_error, "Tracker issues are loading.")

      {:error, _reason} ->
        unavailable_configuration()
    end
  end

  @doc "Projects already-read data without performing IO or changing workflow state."
  @spec project([Issue.t()], map(), map(), map()) :: map()
  def project(issues, runtime, control, settings) do
    settings = projection_settings(settings, control)
    project = project_identity(settings.tracker)
    issues = visible_issues(issues, settings.tracker.kind)
    admitted = admission_index(issues, settings)
    runtime_index = runtime_index(runtime)
    ledger = Map.get(control, "issues", %{})
    known_ids = MapSet.new(issues, & &1.id)

    tasks =
      Enum.map(issues, fn issue ->
        task(issue, Map.get(admitted, issue.id, issue), runtime_index[issue.id], ledger[issue.id], project, settings)
      end)

    missing =
      (Map.keys(runtime_index) ++ Map.keys(ledger))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(known_ids, &1))
      |> Enum.map(fn id ->
        entry = runtime_index[id]
        identifier = (entry && entry.issue_identifier) || fallback_identifier(settings.tracker.kind, id)
        issue = %Issue{id: id, identifier: identifier, title: identifier}

        issue
        |> task(issue, entry, ledger[id], project, settings)
        |> Map.put(:source_missing, true)
        |> Map.put(:github_status, "source_missing")
        |> Map.update!(:blocker_reason, &missing_reason/1)
      end)

    %{
      tasks: Enum.sort_by(tasks ++ missing, & &1.id),
      projects: [project],
      generated_at: timestamp(),
      source_error: nil,
      runtime_error: nil,
      enrichment_error: nil,
      control: control,
      runtime: runtime
    }
  end

  defp projection_settings(settings, control) do
    settings
    |> Map.put(:control, Map.put(settings.control, :enabled, settings.control.enabled or control["enabled"] == true))
    |> Map.put(:tracker_fingerprint, control["tracker_fingerprint"] || tracker_fingerprint(settings.tracker))
  end

  defp load_settings(orchestrator, timeout, settings) do
    deadline = System.monotonic_time(:millisecond) + timeout

    reads = [
      source: fn -> read_issues(settings.tracker) end,
      runtime: fn -> Presenter.state_payload(orchestrator, timeout) end,
      control: fn ->
        if settings.control.enabled, do: Orchestrator.control_snapshot(orchestrator), else: %{"enabled" => false}
      end
    ]

    pending = Enum.map(reads, fn {name, read} -> {name, Task.async(fn -> safe_read(read) end)} end)

    results =
      pending
      |> Enum.map(&elem(&1, 1))
      |> Task.yield_many(timeout)
      |> Enum.map(fn {task, result} -> result || Task.shutdown(task, :brutal_kill) || {:exit, :timeout} end)

    results = pending |> Enum.map(&elem(&1, 0)) |> Enum.zip(results) |> Map.new()
    {issues, source_error} = source_result(results.source, settings.tracker)
    {runtime, runtime_error} = runtime_result(results.runtime)
    {control, control_error} = control_result(results.control)

    issues
    |> project(runtime, control, settings)
    |> Map.put(:source_error, source_error)
    |> Map.put(:runtime_error, runtime_error || control_error)
    |> Board.enrich(settings, max(0, deadline - System.monotonic_time(:millisecond)))
    |> verify_tracker(settings.tracker)
  end

  defp verify_tracker(board, tracker) do
    case Config.settings() do
      {:ok, %{tracker: ^tracker}} -> board
      _ -> %{board | source_error: "Tracker configuration changed during refresh. Waiting for a complete board."}
    end
  end

  defp safe_read(read) do
    read.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp read_issues(tracker) do
    result = fetch_issues(tracker)

    # Existing adapter callbacks read global settings. Do not attach their data
    # to the previous project if the workflow changed while the read was pending.
    case Config.settings() do
      {:ok, %{tracker: ^tracker}} -> result
      _ -> {:error, :tracker_changed}
    end
  end

  defp fetch_issues(%{kind: "github"}) do
    Application.get_env(:symphony_elixir, :github_client_module, Client).fetch_issues_by_states(["open", "closed"])
  end

  defp fetch_issues(tracker) do
    Tracker.fetch_issues_by_states(Enum.uniq(tracker.active_states ++ tracker.terminal_states))
  end

  defp source_result({:ok, {:ok, issues}}, tracker) when is_list(issues) do
    if Enum.all?(issues, &(match?(%Issue{id: id} when is_binary(id), &1) and valid_scope?(&1, tracker))),
      do: {issues, nil},
      else: {[], "Tracker returned invalid issue data."}
  end

  defp source_result({:ok, {:error, :tracker_changed}}, _tracker),
    do: {[], "Tracker configuration changed during refresh. Waiting for a complete board."}

  defp source_result(_, _tracker), do: {[], "Tracker unavailable. Showing the last complete board when available."}

  defp valid_scope?(issue, %{kind: "github", provider: provider}), do: (issue.native_ref || %{})["repo"] == provider["repo"]
  defp valid_scope?(_issue, _tracker), do: true

  defp runtime_result({:ok, %{} = runtime}) do
    if Map.has_key?(runtime, :error),
      do: {runtime, "Runtime unavailable. Task activity may be stale."},
      else: {runtime, nil}
  end

  defp runtime_result(_), do: {%{}, "Runtime unavailable. Task activity may be stale."}

  defp control_result({:ok, %{} = control}) do
    cond do
      not is_nil(control["fault"]) ->
        {control, "Execution unavailable. Durable controls require recovery."}

      Map.has_key?(control, "error") or Map.has_key?(control, :error) ->
        {control, "Durable controls unavailable. Task holds may be stale."}

      true ->
        {control, nil}
    end
  end

  defp control_result(_), do: {%{"error" => "unavailable"}, "Durable controls unavailable. Task holds may be stale."}

  defp unavailable_configuration do
    %{
      tasks: [],
      projects: [],
      generated_at: timestamp(),
      source_error: "Workflow configuration unavailable.",
      runtime_error: nil,
      enrichment_error: nil,
      control: %{},
      runtime: %{}
    }
  end

  defp visible_issues(issues, kind) do
    issues
    |> Enum.filter(fn issue -> kind != "github" or issue.dispatchable end)
    |> Enum.uniq_by(& &1.id)
  end

  defp admission_index(issues, %{tracker: %{kind: "github"}, control: %{enabled: true}}) do
    by_id = Map.new(issues, &{&1.id, &1})
    evaluated = Admission.evaluate(issues, fn ids -> {:ok, Enum.flat_map(ids, &List.wrap(by_id[&1]))} end)
    Map.new(evaluated, &{&1.id, &1})
  end

  defp admission_index(issues, _settings), do: Map.new(issues, &{&1.id, &1})

  defp runtime_index(runtime) do
    # The final running entry wins if an in-flight snapshot includes a retry too.
    Enum.reduce([:retrying, :blocked, :running], %{}, fn status, acc ->
      Enum.reduce(Map.get(runtime, status, []), acc, fn entry, entries ->
        Map.put(entries, entry.issue_id, Map.put(entry, :status, Atom.to_string(status)))
      end)
    end)
  end

  defp task(issue, admitted, runtime, ledger, project, settings) do
    ledger = ledger || %{}
    hold = ledger["hold"]
    handoff = ledger["handoff"]
    terminal = terminal?(issue, settings.tracker)
    controlled = settings.control.enabled
    accepted = accepted?(ledger, settings)
    stage = project_stage(issue, admitted, runtime, ledger, terminal, accepted, settings)
    attention = project_attention(issue, admitted, runtime, ledger, terminal, accepted, settings)
    url = issue_url(issue, runtime, project, settings.tracker.kind)

    %{
      id: project.id <> ":" <> issue.id,
      issue_id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      project: project.id,
      project_label: project.label,
      url: url,
      links: links(url, project.url),
      pull_requests: [],
      github_status: if(settings.tracker.kind == "github", do: "not_loaded", else: "not_applicable"),
      stage: stage,
      lane: if(stage in ["ready", "running"], do: "work", else: stage),
      attention: attention,
      blocker_reason: blocker_reason(runtime, hold, attention),
      execution_status: execution_status(runtime, hold, ledger),
      priority: issue.priority,
      created_at: iso8601(issue.created_at),
      updated_at: iso8601(issue.updated_at),
      description: issue.description,
      labels: issue.labels,
      milestone: issue.milestone,
      assignees: issue.assignees,
      runtime: runtime,
      handoff: handoff,
      hold: hold,
      ledger: ledger,
      tracker_state: issue.state,
      tracker_terminal: terminal,
      acceptance: if(accepted, do: ledger["acceptance"]),
      completion_evidence: completion_evidence(accepted, controlled, terminal, issue.state),
      source_missing: false
    }
  end

  defp accepted?(ledger, settings) do
    settings.control.enabled and IssueAcceptance.accepted?(ledger) and
      get_in(ledger, ["acceptance", "tracker_fingerprint"]) == settings.tracker_fingerprint
  end

  defp tracker_fingerprint(tracker), do: :crypto.hash(:sha256, :erlang.term_to_binary(tracker)) |> Base.url_encode64(padding: false)

  defp project_stage(issue, admitted, runtime, ledger, terminal, accepted, settings) do
    routed = if settings.control.enabled, do: issue, else: admitted
    queued = active?(issue, settings.tracker) and Issue.routable?(routed, settings.tracker.required_labels)

    if settings.control.enabled,
      do: controlled_stage(runtime, ledger["hold"], ledger["handoff"], terminal, queued, accepted),
      else: stage(runtime, ledger["hold"], ledger["handoff"], terminal, queued)
  end

  defp project_attention(_issue, _admitted, _runtime, _ledger, _terminal, true, _settings), do: nil

  defp project_attention(issue, admitted, runtime, ledger, terminal, false, settings) do
    issue_attention =
      if settings.control.enabled and terminal,
        do: "Awaiting your acceptance",
        else: attention(runtime, ledger["hold"], admitted, issue, settings.tracker, terminal)

    reservation_attention(runtime, ledger) || issue_attention
  end

  defp completion_evidence(true, _controlled, _terminal, _state), do: "Accepted by you. Merge and deployment status remain separate."
  defp completion_evidence(false, true, true, _state), do: "GitHub issue is closed; your acceptance is still required."
  defp completion_evidence(false, false, true, state), do: "Tracker marked this issue #{state}; merge and deployment are not verified."
  defp completion_evidence(_, _, _, _), do: nil

  defp controlled_stage(%{status: "running"}, _hold, _handoff, _terminal, _queued, _accepted), do: "running"
  defp controlled_stage(_runtime, _hold, _handoff, _terminal, _queued, true), do: "done"
  defp controlled_stage(_runtime, _hold, _handoff, true, _queued, false), do: "review"
  defp controlled_stage(_runtime, hold, handoff, _terminal, queued, false), do: stage(nil, hold, handoff, false, queued)

  defp blocker_reason(%{error: error}, _hold, _attention) when is_binary(error) and error != "", do: String.slice(error, 0, 2_000)
  defp blocker_reason(_runtime, hold, attention) when is_binary(hold), do: attention || humanize_hold(hold)
  defp blocker_reason(_runtime, _hold, attention), do: attention

  defp execution_status(%{status: status}, _hold, _ledger), do: status
  defp execution_status(_runtime, _hold, %{"active" => active}) when is_map(active), do: "unknown"
  defp execution_status(_runtime, hold, _ledger) when is_binary(hold), do: "held"
  defp execution_status(_runtime, _hold, _ledger), do: "idle"

  defp missing_reason(nil), do: "Tracker issue is missing from this refresh; retained execution data may be stale."
  defp missing_reason(reason), do: reason <> " Tracker issue is missing from this refresh."

  defp issue_url(issue, _runtime, %{url: url}, "github") when is_binary(url) do
    if is_binary(issue.id) and String.match?(issue.id, ~r/^[1-9][0-9]{0,9}$/), do: url <> "/issues/" <> issue.id
  end

  defp issue_url(_issue, _runtime, _project, "github"), do: nil
  defp issue_url(issue, runtime, _project, _kind), do: safe_url(issue.url || (runtime && runtime[:issue_url]))

  defp safe_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil} when scheme in ["http", "https"] and is_binary(host) -> url
      _ -> nil
    end
  end

  defp safe_url(_url), do: nil

  defp links(issue_url, repo_url) do
    [%{label: "GitHub issue", url: issue_url, kind: "issue"}, %{label: "Repository", url: repo_url, kind: "repository"}]
    |> Enum.reject(&is_nil(&1.url))
  end

  defp stage(%{status: "running"}, _hold, _handoff, _terminal, _routable), do: "running"
  defp stage(_runtime, _hold, _handoff, true, _routable), do: "done"
  defp stage(_runtime, "cancelled", _handoff, _terminal, _routable), do: "backlog"
  defp stage(_runtime, "owner_review", handoff, _terminal, _routable) when is_map(handoff), do: "review"
  defp stage(_runtime, _hold, _handoff, _terminal, true), do: "ready"
  defp stage(_runtime, _hold, _handoff, _terminal, _routable), do: "backlog"

  defp reservation_attention(%{status: "running"}, _ledger), do: nil
  defp reservation_attention(_runtime, %{"active" => active}) when is_map(active), do: "Execution reservation needs reconciliation"
  defp reservation_attention(_runtime, _ledger), do: nil

  defp attention(%{status: "blocked"}, _hold, _admitted, _issue, _tracker, _terminal), do: "Worker needs input"
  defp attention(%{status: "retrying"}, _hold, _admitted, _issue, _tracker, _terminal), do: "Retry scheduled"
  defp attention(_runtime, hold, _admitted, _issue, _tracker, _terminal) when is_binary(hold), do: humanize_hold(hold)

  defp attention(_runtime, _hold, admitted, issue, tracker, false) do
    if active?(issue, tracker) and Issue.routable?(issue, tracker.required_labels),
      do: get_in(admitted.native_ref || %{}, ["admission_reason"]),
      else: nil
  end

  defp attention(_runtime, _hold, _admitted, _issue, _tracker, _terminal), do: nil

  defp humanize_hold("owner_review"), do: "Candidate needs review"
  defp humanize_hold("cancelled"), do: "Cancelled execution"
  defp humanize_hold("interrupted"), do: "Interrupted execution"
  defp humanize_hold(hold), do: hold |> String.replace("_", " ") |> String.capitalize()

  defp active?(issue, tracker), do: normalize(issue.state) in Enum.map(tracker.active_states, &normalize/1)
  defp terminal?(issue, tracker), do: normalize(issue.state) in Enum.map(tracker.terminal_states, &normalize/1)
  defp normalize(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize(_), do: ""

  defp project_identity(tracker) do
    provider = tracker.provider || %{}
    scope = provider["repo"] || tracker.project_slug || provider["project_id"] || provider["project"] || "configured-project"
    kind = tracker.kind || "tracker"
    url = Board.repository_url(tracker)
    %{id: kind <> ":" <> scope, label: scope, url: url}
  end

  defp fallback_identifier("github", id), do: "GH-" <> id
  defp fallback_identifier(_kind, id), do: id
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_), do: nil
  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
