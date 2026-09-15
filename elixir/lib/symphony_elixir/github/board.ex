defmodule SymphonyElixir.GitHub.Board do
  @moduledoc "Optional, bounded GitHub evidence for the read-only board; never changes scheduling."

  alias SymphonyElixir.GitHub.Client

  @issue_limit 50
  @unavailable "GitHub PR evidence unavailable. Issue and execution data remain visible."
  @partial "GitHub PR evidence is partial or changed during refresh; some relationships are not shown."

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
      {:ok, {:ok, data}} -> apply_evidence(board, tracker, selected, data, length(tasks) > @issue_limit)
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
        if Map.get(response, "errors", []) == [], do: {:ok, data}, else: {:error, :partial_response}

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

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
          closedByPullRequestsReferences(first: 5, includeClosedPrs: true) {
            pageInfo { hasNextPage } nodes { ...BoardPullRequest }
          }
          timelineItems(last: 5, itemTypes: [CROSS_REFERENCED_EVENT]) {
            pageInfo { hasPreviousPage }
            nodes { ... on CrossReferencedEvent {
              target { ... on Issue { number repository { nameWithOwner } } }
              source { __typename ...BoardPullRequest }
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
      number title url state isDraft reviewDecision headRefOid repository { nameWithOwner }
      commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
    }
    """
  end

  defp apply_evidence(board, tracker, selected, data, truncated) do
    repo = tracker.provider["repo"]
    index = Map.new(selected, &{&1.issue_id, evidence(data["issue_" <> &1.issue_id], &1, repo)})

    {tasks, incomplete} =
      Enum.map_reduce(board.tasks, truncated, fn task, incomplete ->
        case index[task.issue_id] do
          {:ok, prs, partial} ->
            links = Enum.flat_map(prs, &pr_links/1)
            status = evidence_status(partial)
            task = %{task | pull_requests: prs, links: base_links(task) ++ links, github_status: status}
            {task, incomplete or partial}

          nil ->
            status = empty_status(task)
            {%{task | pull_requests: [], links: base_links(task), github_status: status}, incomplete}

          _ ->
            {%{task | pull_requests: [], links: base_links(task), github_status: "unavailable"}, true}
        end
      end)

    %{board | tasks: tasks, enrichment_error: if(incomplete, do: @partial)}
  end

  defp evidence(%{"number" => number, "url" => url, "updatedAt" => updated} = issue, task, repo) when is_integer(number) and number > 0 do
    if Integer.to_string(number) == task.issue_id and url == "https://github.com/#{repo}/issues/#{number}" and
         (is_nil(task.updated_at) or task.updated_at == updated) do
      {linked, linked_partial} = connection(issue["closedByPullRequestsReferences"], "hasNextPage")
      {events, events_partial} = connection(issue["timelineItems"], "hasPreviousPage")
      linked = Enum.map(linked, &{&1, "linked"})
      references = Enum.flat_map(events, &referenced_pr(&1, number, repo))
      parsed = Enum.map(linked ++ references, fn {pr, relation} -> pull_request(pr, repo, relation) end)
      prs = parsed |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.number) |> Enum.sort_by(& &1.number, :desc)
      {:ok, prs, linked_partial or events_partial or Enum.any?(parsed, &is_nil/1)}
    else
      {:error, :stale_issue}
    end
  end

  defp evidence(_issue, _task, _repo), do: {:error, :missing_issue}

  defp connection(%{"nodes" => nodes, "pageInfo" => page}, direction) when is_list(nodes) and length(nodes) <= 5 and is_map(page),
    do: {nodes, page[direction] != false}

  defp connection(_connection, _direction), do: {[], true}

  defp referenced_pr(%{"target" => %{"number" => number, "repository" => %{"nameWithOwner" => repo}}, "source" => %{"__typename" => "PullRequest"} = pr}, number, repo),
    do: [{pr, "referenced"}]

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
        review: review(pr["reviewDecision"]),
        checks: checks(pr["commits"], sha),
        head_sha: sha,
        relation: relation
      }
    end
  end

  defp pull_request(_pr, _repo, _relation), do: nil

  defp review(value) when value in ~w(APPROVED CHANGES_REQUESTED REVIEW_REQUIRED), do: String.downcase(value)
  defp review(_value), do: "unknown"

  defp checks(%{"nodes" => [%{"commit" => %{"oid" => sha, "statusCheckRollup" => %{"state" => state}}}]}, sha)
       when state in ~w(SUCCESS PENDING FAILURE ERROR EXPECTED), do: String.downcase(state)

  defp checks(%{"nodes" => [%{"commit" => %{"oid" => oid}}]}, sha) when oid != sha, do: "stale"
  defp checks(_commits, _sha), do: "unknown"

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
    tasks = Enum.map(board.tasks, &%{&1 | pull_requests: [], links: base_links(&1), github_status: if(&1.source_missing, do: "source_missing", else: "unavailable")})
    %{board | tasks: tasks, enrichment_error: message}
  end
end
