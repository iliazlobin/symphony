defmodule SymphonyElixir.GitHub.Board do
  @moduledoc "Optional, bounded GitHub evidence for the read-only board; never changes scheduling."

  alias SymphonyElixir.GitHub.{Client, Feedback}

  @issue_limit 50
  @check_limit 20
  @unavailable "GitHub PR evidence unavailable. Issue and execution data remain visible."
  @partial "GitHub PR evidence is partial or changed during refresh; some relationships are not shown."
  @history_partial "Older PR history not loaded; current PR details remain available."

  @doc "Enriches an existing project snapshot within a separate bounded read budget."
  def enrich(board, settings, timeout \\ 2_000)

  @spec enrich(map(), map(), non_neg_integer()) :: map()
  def enrich(board, %{tracker: %{kind: "github"} = tracker}, timeout) do
    tasks = Enum.reject(board.tasks, & &1.source_missing)

    cond do
      tasks == [] or not is_nil(board.source_error) -> board
      is_nil(repository_url(tracker)) -> unavailable(board, "GitHub PR evidence is supported only for github.com repositories.")
      not Enum.all?(tasks, &(&1.project == "github:" <> tracker.provider["repo"] and valid_number?(&1.issue_id))) -> unavailable(board, @unavailable)
      timeout <= 0 -> unavailable(board, @unavailable)
      true -> fetch_bounded(board, tracker, tasks, min(timeout, 5_000))
    end
  end

  def enrich(board, _settings, _timeout), do: board

  @spec repository_url(map()) :: String.t() | nil
  def repository_url(%{kind: "github", provider: provider}) when is_map(provider) do
    repo = provider["repo"]

    if provider["api_url"] in [nil, "https://api.github.com"] and is_binary(repo) and
         String.match?(repo, ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/),
       do: "https://github.com/" <> repo
  end

  def repository_url(_tracker), do: nil

  defp fetch_bounded(board, tracker, tasks, timeout) do
    selected = tasks |> Enum.sort_by(&{&1.updated_at || "", &1.issue_id}, :desc) |> Enum.take(@issue_limit)
    reader = Task.async(fn -> fetch(tracker, selected) end)

    case Task.yield(reader, timeout) || Task.shutdown(reader, :brutal_kill) do
      {:ok, {:ok, data, errors}} -> apply_evidence(board, tracker, selected, data, errors, length(tasks) > @issue_limit)
      _ -> unavailable(board, @unavailable)
    end
  end

  defp fetch(tracker, tasks) do
    repo = tracker.provider["repo"]

    [owner, name] = String.split(repo, "/")
    body = %{"query" => query(tasks), "variables" => %{"owner" => owner, "name" => name}}
    request_fun = Application.get_env(:symphony_elixir, :github_board_request, &request_once/5)

    case Client.request("POST", "/graphql", %{}, body, tracker_settings: tracker, request_fun: request_fun) do
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"nameWithOwner" => ^repo} = data}} = response}} ->
        {:ok, data, error_scope(Map.get(response, "errors", []), tasks)}

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp error_scope(errors, tasks) do
    aliases = Map.new(tasks, &{"issue_" <> &1.issue_id, true})
    scope_errors(errors, aliases)
  end

  defp scope_errors(errors, aliases) when is_list(errors) do
    Enum.reduce(errors, %{}, fn error, affected ->
      case error do
        %{"path" => ["repository", issue | _]} when is_map_key(aliases, issue) -> Map.put(affected, issue, true)
        _ -> aliases
      end
    end)
  end

  defp scope_errors(_errors, aliases), do: aliases

  @doc false
  @spec request_once(String.t(), String.t(), map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def request_once("POST", "/graphql", %{} = params, body, settings) do
    case Req.request(
           method: :post,
           url: settings.api_url <> "/graphql",
           params: params,
           json: body,
           auth: {:bearer, settings.token},
           headers: [{"accept", "application/vnd.github+json"}, {"user-agent", "symphony-board"}],
           retry: false,
           redirect: false,
           receive_timeout: 2_000,
           request_timeout: 4_000,
           finch: [pool_timeout: 500, conn_opts: [transport_opts: [timeout: 1_500]]]
         ) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp query(tasks) do
    issues =
      Enum.map_join(tasks, "\n", fn task ->
        """
        issue_#{task.issue_id}: issue(number: #{task.issue_id}) {
          number url updatedAt
          comments(last: 20) {
            totalCount pageInfo { hasPreviousPage }
            nodes { id url body updatedAt author { __typename login } }
          }
          closedByPullRequestsReferences(first: 5, includeClosedPrs: true) {
            pageInfo { hasNextPage } nodes { ...BoardPullRequest }
          }
          timelineItems(last: 5, itemTypes: [CROSS_REFERENCED_EVENT]) {
            pageInfo { hasPreviousPage }
            nodes { ... on CrossReferencedEvent {
              target { ... on Issue { number repository { nameWithOwner } } }
              source { __typename ... on PullRequest { body } ...BoardPullRequest }
            } }
          }
        }
        """
      end)

    """
    query BoardEvidence($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) { nameWithOwner #{issues} }
    }
    fragment BoardPullRequest on PullRequest {
      number title url state isDraft reviewDecision headRefOid createdAt updatedAt repository { nameWithOwner }
      headRefName baseRefName author { login } additions deletions changedFiles mergeable
      comments(last: 20) {
        totalCount pageInfo { hasPreviousPage }
        nodes { id url body updatedAt author { __typename login } }
      }
      reviews(last: 20, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) {
        totalCount pageInfo { hasPreviousPage }
        nodes { id url body updatedAt state author { __typename login } }
      }
      reviewThreads(last: 10) {
        totalCount pageInfo { hasPreviousPage }
        nodes { isResolved comments(last: 3) {
          totalCount pageInfo { hasPreviousPage }
          nodes { id url body updatedAt state author { __typename login } }
        } }
      }
      commits(last: 1) { nodes { commit { oid statusCheckRollup {
        state contexts(first: #{@check_limit}) {
          totalCount pageInfo { hasNextPage }
          nodes {
            __typename
            ... on CheckRun {
              id name status conclusion detailsUrl startedAt completedAt
              checkSuite { app { slug } workflowRun { workflow { name } url runNumber event } }
            }
            ... on StatusContext { context state targetUrl }
          }
        }
      } } } }
    }
    """
  end

  defp apply_evidence(board, tracker, selected, data, errors, truncated) do
    repo = tracker.provider["repo"]
    index = Map.new(selected, &{&1.issue_id, evidence(data["issue_" <> &1.issue_id], &1, repo, Map.has_key?(errors, "issue_" <> &1.issue_id))})

    tasks =
      Enum.map(board.tasks, fn task ->
        case index[task.issue_id] do
          {:ok, prs, reason, feedback} ->
            links = Enum.flat_map(prs, &pr_links/1)
            status = evidence_status(not is_nil(reason))

            %{task | pull_requests: prs, links: base_links(task) ++ links, github_status: status}
            |> Map.put(:feedback, feedback)
            |> Map.put(:github_partial_reason, reason)

          nil ->
            status = empty_status(task)

            %{task | pull_requests: [], links: base_links(task), github_status: status}
            |> Map.put(:feedback, Feedback.unavailable())
            |> Map.put(:github_partial_reason, nil)

          _ ->
            %{task | pull_requests: [], links: base_links(task), github_status: "unavailable"}
            |> Map.put(:feedback, Feedback.unavailable())
            |> Map.put(:github_partial_reason, "evidence_unavailable")
        end
      end)

    reason = enrichment_reason(tasks, truncated)
    %{board | tasks: tasks, enrichment_error: enrichment_message(reason)} |> Map.put(:enrichment_reason, reason)
  end

  defp enrichment_reason(tasks, truncated) do
    cond do
      Enum.any?(tasks, &(&1[:github_partial_reason] == "evidence_unavailable")) -> "evidence_unavailable"
      truncated -> "issue_limit"
      Enum.any?(tasks, &(&1[:github_partial_reason] == "history_truncated")) -> "history_truncated"
      true -> nil
    end
  end

  defp enrichment_message(nil), do: nil
  defp enrichment_message("history_truncated"), do: @history_partial
  defp enrichment_message(_reason), do: @partial

  defp evidence(%{"number" => number, "url" => url, "updatedAt" => updated} = issue, task, repo, query_partial) when is_integer(number) and number > 0 do
    if Integer.to_string(number) == task.issue_id and url == "https://github.com/#{repo}/issues/#{number}" and
         (is_nil(task.updated_at) or task.updated_at == updated) do
      {linked, linked_partial} = connection(issue["closedByPullRequestsReferences"], "hasNextPage")
      {events, events_partial} = connection(issue["timelineItems"], "hasPreviousPage")
      linked = Enum.map(linked, &{&1, "linked"})
      references = Enum.flat_map(events, &referenced_pr(&1, number, repo))
      parsed = Enum.map(linked ++ references, fn {pr, relation} -> pull_request(pr, repo, relation) end)
      prs = parsed |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.number) |> Enum.sort_by(& &1.number, :desc) |> partial_checks(query_partial)
      invalid = query_partial or Enum.any?(parsed, &is_nil/1)
      reason = partial_reason(issue, invalid, linked_partial or events_partial)

      raw_prs =
        Enum.zip(linked ++ references, parsed)
        |> Enum.reject(fn {_raw, parsed} -> is_nil(parsed) end)
        |> Enum.map(fn {{raw, _relation}, _parsed} -> raw end)
        |> Enum.uniq_by(& &1["number"])

      {:ok, prs, reason, Feedback.collect(issue, raw_prs, task, repo, not is_nil(reason))}
    else
      {:error, :stale_issue}
    end
  end

  defp evidence(_issue, _task, _repo, _query_partial), do: {:error, :missing_issue}

  defp partial_reason(_issue, false, false), do: nil

  defp partial_reason(issue, false, true) do
    if valid_connection?(issue["closedByPullRequestsReferences"], "hasNextPage") and valid_connection?(issue["timelineItems"], "hasPreviousPage"),
      do: "history_truncated",
      else: "evidence_unavailable"
  end

  defp partial_reason(_issue, true, _partial), do: "evidence_unavailable"

  defp valid_connection?(%{"nodes" => nodes, "pageInfo" => page}, direction) when is_list(nodes) and length(nodes) <= 5 and is_map(page), do: is_boolean(page[direction])
  defp valid_connection?(_connection, _direction), do: false

  defp partial_checks(prs, false), do: prs
  defp partial_checks(prs, true), do: Enum.map(prs, &partial_check/1)
  defp partial_check(%{checks: "stale"} = pr), do: pr

  defp partial_check(pr) do
    %{pr | checks: if(pr.checks == "success", do: "unknown", else: pr.checks), check_details_status: if(pr.check_details_status == "unavailable", do: "unavailable", else: "partial")}
  end

  defp connection(%{"nodes" => nodes, "pageInfo" => page}, direction) when is_list(nodes) and length(nodes) <= 5 and is_map(page),
    do: {nodes, page[direction] != false}

  defp connection(_connection, _direction), do: {[], true}

  defp referenced_pr(%{"target" => %{"number" => number, "repository" => %{"nameWithOwner" => repo}}, "source" => %{"__typename" => "PullRequest", "body" => body} = pr}, number, repo)
       when is_binary(body) do
    # The host publisher marks issue ownership; a casual mention is not attribution.
    attributed =
      [~r/<!-- symphony issue=GH-(\d+)(?: work=[a-f0-9]{32})? -->/, ~r/^Symphony task: GH-(\d+)(?:; work [a-f0-9]{32})?\.\r?$/m]
      |> Enum.flat_map(&Regex.scan(&1, body))
      |> Enum.any?(fn [_, issue_id] -> issue_id == Integer.to_string(number) end)

    if attributed, do: [{pr, "published"}], else: []
  end

  defp referenced_pr(_event, _number, _repo), do: []

  defp pull_request(%{"number" => number, "title" => title, "url" => url, "state" => state, "isDraft" => draft, "headRefOid" => sha, "repository" => %{"nameWithOwner" => repo}} = pr, repo, relation)
       when is_integer(number) and number > 0 and is_binary(title) and is_boolean(draft) do
    if url == "https://github.com/#{repo}/pull/#{number}" and is_binary(sha) and String.match?(sha, ~r/^[0-9a-f]{40}$/) and
         byte_size(title) <= 1_024 and state in ~w(OPEN CLOSED MERGED) do
      %{
        number: number,
        title: title,
        url: url,
        state: String.downcase(state),
        draft: draft,
        created_at: timestamp(pr["createdAt"]),
        updated_at: timestamp(pr["updatedAt"]),
        review: review(Map.fetch(pr, "reviewDecision")),
        head_ref: optional_text(pr["headRefName"]),
        base_ref: optional_text(pr["baseRefName"]),
        author: author(pr["author"]),
        additions: nonnegative_integer(pr["additions"]),
        deletions: nonnegative_integer(pr["deletions"]),
        changed_files: nonnegative_integer(pr["changedFiles"]),
        mergeable: enum(pr["mergeable"], ~w(MERGEABLE CONFLICTING UNKNOWN)),
        head_sha: sha,
        relation: relation
      }
      |> Map.merge(checks(pr["commits"], sha))
    end
  end

  defp pull_request(_pr, _repo, _relation), do: nil

  defp review({:ok, nil}), do: "no_decision"
  defp review({:ok, value}), do: enum(value, ~w(APPROVED CHANGES_REQUESTED REVIEW_REQUIRED))
  defp review(_value), do: "unknown"

  defp checks(%{"nodes" => [%{"commit" => %{"oid" => sha, "statusCheckRollup" => rollup}}]}, sha) when is_map(rollup) do
    {runs, total, status} = check_details(rollup["contexts"])
    %{checks: enum(rollup["state"], ~w(SUCCESS PENDING FAILURE ERROR EXPECTED)), check_runs: runs, check_total: total, check_details_status: status}
  end

  defp checks(%{"nodes" => [%{"commit" => %{"oid" => oid}}]}, sha) when oid != sha, do: empty_checks("stale", "stale")
  defp checks(_commits, _sha), do: empty_checks("unknown", "unavailable")

  defp empty_checks(state, status), do: %{checks: state, check_runs: [], check_total: nil, check_details_status: status}

  defp check_details(%{"nodes" => nodes} = contexts) when is_list(nodes) do
    runs = nodes |> Enum.take(@check_limit) |> Enum.map(&check_run/1) |> Enum.reject(&is_nil/1)
    total = nonnegative_integer(contexts["totalCount"])
    complete = contexts["pageInfo"] == %{"hasNextPage" => false} and total == length(nodes) and length(runs) == length(nodes)
    {runs, total, if(complete, do: "available", else: "partial")}
  end

  defp check_details(_contexts), do: {[], nil, "unavailable"}

  defp check_run(%{"__typename" => "CheckRun", "name" => name, "status" => status} = run)
       when is_binary(name) and byte_size(name) in 1..1_024 and status in ~w(COMPLETED IN_PROGRESS PENDING QUEUED REQUESTED WAITING) do
    started = timestamp(run["startedAt"])
    completed = timestamp(run["completedAt"])

    %{
      kind: "check_run",
      id: optional_text(run["id"]),
      app_slug: optional_text(get_in(run, ["checkSuite", "app", "slug"])),
      name: name,
      status: String.downcase(status),
      conclusion: if(status == "COMPLETED", do: enum(run["conclusion"], ~w(ACTION_REQUIRED CANCELLED FAILURE NEUTRAL SKIPPED STALE STARTUP_FAILURE SUCCESS TIMED_OUT)), else: "unknown"),
      url: safe_url(run["detailsUrl"]),
      started_at: started,
      completed_at: completed,
      duration_ms: duration(status, started, completed)
    }
    |> Map.merge(workflow(run["checkSuite"]))
  end

  defp check_run(%{"__typename" => "StatusContext", "context" => name, "state" => state} = context)
       when is_binary(name) and byte_size(name) in 1..1_024 and state in ~w(SUCCESS PENDING FAILURE ERROR EXPECTED) do
    pending = state in ~w(PENDING EXPECTED)

    %{
      kind: "status_context",
      name: name,
      status: if(pending, do: "pending", else: "completed"),
      conclusion: if(pending, do: "unknown", else: String.downcase(state)),
      url: safe_url(context["targetUrl"]),
      started_at: nil,
      completed_at: nil,
      duration_ms: nil
    }
    |> Map.merge(workflow(nil))
  end

  defp check_run(_run), do: nil

  defp workflow(%{"workflowRun" => %{"workflow" => %{"name" => name}} = run}) do
    %{
      workflow_name: optional_text(name),
      run_url: safe_url(run["url"]),
      run_number: nonnegative_integer(run["runNumber"]),
      run_event: optional_text(run["event"])
    }
  end

  defp workflow(_suite), do: %{workflow_name: nil, run_url: nil, run_number: nil, run_event: nil}

  defp timestamp(value) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> DateTime.to_iso8601(time)
      _ -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp duration("COMPLETED", started, completed) when is_binary(started) and is_binary(completed) do
    {:ok, started, _} = DateTime.from_iso8601(started)
    {:ok, completed, _} = DateTime.from_iso8601(completed)
    milliseconds = DateTime.diff(completed, started, :millisecond)
    if milliseconds >= 0, do: milliseconds
  end

  defp duration(_status, _started, _completed), do: nil

  defp safe_url(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} when scheme in ["https", "http"] and is_binary(host) ->
        if host != "" and not String.match?(value, ~r/[\x00-\x20\x7f\\]/), do: value

      _ ->
        nil
    end
  end

  defp safe_url(_value), do: nil
  defp author(%{"login" => login}), do: optional_text(login)
  defp author(_value), do: nil
  defp optional_text(value) when is_binary(value) and byte_size(value) in 1..1_024, do: value
  defp optional_text(_value), do: nil
  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value), do: nil
  defp enum(value, allowed), do: if(value in allowed, do: String.downcase(value), else: "unknown")

  defp valid_number?(id), do: is_binary(id) and String.match?(id, ~r/^[1-9][0-9]{0,9}$/)
  defp base_links(task), do: Enum.filter(task.links, &(&1.kind in ["issue", "repository"]))
  defp empty_status(%{source_missing: true}), do: "source_missing"
  defp empty_status(_task), do: "not_loaded"
  defp evidence_status(true), do: "partial"
  defp evidence_status(false), do: "available"

  defp pr_links(pr) do
    [
      %{label: "PR ##{pr.number}", url: pr.url, kind: "pull_request"},
      %{label: "PR ##{pr.number} checks", url: pr.url <> "/checks", kind: "checks"}
    ]
  end

  defp unavailable(board, message) do
    tasks =
      Enum.map(board.tasks, fn task ->
        %{task | pull_requests: [], links: base_links(task), github_status: if(task.source_missing, do: "source_missing", else: "unavailable")}
        |> Map.put(:feedback, Feedback.unavailable())
        |> Map.put(:github_partial_reason, "evidence_unavailable")
      end)

    %{board | tasks: tasks, enrichment_error: message} |> Map.put(:enrichment_reason, "evidence_unavailable")
  end
end
