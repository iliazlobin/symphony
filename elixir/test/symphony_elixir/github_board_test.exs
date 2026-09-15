defmodule SymphonyElixir.GitHub.BoardTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.Board
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixirWeb.TaskBoard

  @sha String.duplicate("a", 40)

  setup do
    previous = Application.get_env(:symphony_elixir, :github_board_request)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_board_request, previous),
        else: Application.delete_env(:symphony_elixir, :github_board_request)
    end)

    :ok
  end

  test "one bounded query enriches exact linked and referenced PRs without changing tasks or scheduling" do
    owner = self()
    linked = pr(7, %{"reviewDecision" => nil})
    referenced = pr(8, %{"state" => "MERGED", "isDraft" => false, "reviewDecision" => "APPROVED"})
    data = evidence([linked], [event(referenced), event(linked)])

    respond(fn method, path, params, body, settings ->
      assert method == "POST"
      assert path == "/graphql"
      assert params == %{}
      assert body["variables"] == %{"owner" => "example", "name" => "repo"}
      assert body["query"] =~ "includeClosedPrs: true"
      assert body["query"] =~ "CROSS_REFERENCED_EVENT"
      refute body["query"] =~ "mutation"
      assert settings.repo == "example/repo"
      send(owner, :read)
      payload(data)
    end)

    original = board()
    result = Board.enrich(original, settings())
    assert_receive :read
    refute_received :read
    assert result.enrichment_error == nil
    [card] = result.tasks
    assert card.stage == hd(original.tasks).stage
    assert card.execution_status == "idle"
    assert card.github_status == "available"
    assert [referenced, linked] = card.pull_requests
    assert %{number: 8, state: "merged", draft: false, relation: "referenced", review: "approved"} = referenced
    assert %{number: 7, draft: true, relation: "linked", review: "unknown"} = linked
    assert Enum.all?(card.pull_requests, &(&1.head_sha == @sha and &1.checks == "success"))
    assert Enum.count(card.links, &(&1.kind == "pull_request")) == 2
    assert Enum.count(card.links, &(&1.kind == "checks" and String.ends_with?(&1.url, "/checks"))) == 2
    refute Enum.any?(card.links, &(&1.kind == "commit"))
  end

  test "CI evidence remains unknown or stale unless its commit matches the current PR head" do
    for {change, expected} <- [
          {%{"commits" => %{"nodes" => []}}, "unknown"},
          {%{"commits" => %{"nodes" => [%{"commit" => %{"oid" => @sha, "statusCheckRollup" => nil}}]}}, "unknown"},
          {%{"headRefOid" => String.duplicate("b", 40)}, "stale"},
          {%{"commits" => %{"nodes" => [%{"commit" => %{"oid" => @sha, "statusCheckRollup" => %{"state" => "PENDING"}}}]}}, "pending"}
        ] do
      respond(payload(evidence([pr(7, change)])))
      assert [card] = Board.enrich(board(), settings()).tasks
      assert [pull] = card.pull_requests
      assert pull.checks == expected
    end
  end

  test "foreign repositories, untrusted links, and malformed PR facts are not rendered" do
    invalid = [
      pr(7, %{"repository" => %{"nameWithOwner" => "other/repo"}}),
      pr(8, %{"url" => "https://github.com.evil.test/example/repo/pull/8"}),
      pr(9, %{"url" => "javascript:alert(1)"}),
      pr(10, %{"headRefOid" => "unpublished"}),
      pr(11, %{"number" => "11"})
    ]

    respond(payload(evidence(invalid)))
    result = Board.enrich(board(), settings())
    assert result.enrichment_error =~ "partial"
    assert [%{pull_requests: [], github_status: "partial"}] = result.tasks
  end

  test "unrelated issue references and foreign targets never create a PR relationship" do
    refs = [event(pr(7), 99), event(pr(8), 1, "other/repo"), %{"source" => %{"__typename" => "Issue"}}]
    respond(payload(evidence([], refs)))
    assert [%{pull_requests: [], github_status: "available"}] = Board.enrich(board(), settings()).tasks
  end

  test "missing, changed and malformed issue identity cannot enrich a stale card" do
    for data <- [
          nil,
          %{},
          Map.put(evidence(), "number", "1"),
          Map.put(evidence(), "number", 2),
          Map.put(evidence(), "url", "https://other/1"),
          Map.put(evidence(), "updatedAt", "2026-09-16T00:00:00Z")
        ] do
      respond(payload(data))
      result = Board.enrich(board(), settings())
      assert result.enrichment_error =~ "partial"
      assert [%{github_status: "unavailable", pull_requests: []}] = result.tasks
    end
  end

  test "partial connections and issue limit are explicit and old evidence cannot appear current" do
    for data <- [
          put_in(evidence(), ["closedByPullRequestsReferences", "pageInfo", "hasNextPage"], true),
          Map.put(evidence(), "timelineItems", nil),
          Map.put(evidence(), "closedByPullRequestsReferences", %{"nodes" => List.duplicate(pr(7), 6), "pageInfo" => %{}})
        ] do
      respond(payload(data))
      assert [%{github_status: "partial"}] = Board.enrich(board(), settings()).tasks
    end

    respond(fn _, _, _, body, _ ->
      assert length(Regex.scan(~r/issue\(number:/, body["query"])) == 50
      payload(evidence())
    end)

    result = Board.enrich(board(Enum.map(1..51, &Integer.to_string/1)), settings())
    assert result.enrichment_error =~ "partial"
    assert Enum.count(result.tasks, &(&1.github_status == "not_loaded")) == 1
    assert length(result.tasks) == 51
  end

  test "transport and GraphQL failures are sanitized and preserve the complete source list" do
    failures = [
      {:error, "private token"},
      {:ok, %{status: 403, body: "private response"}},
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"nameWithOwner" => "other/repo"}}}}},
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"nameWithOwner" => "example/repo"}}, "errors" => [%{"message" => "secret"}]}}}
    ]

    for result <- failures ++ [:raise, :throw] do
      respond(fn _, _, _, _, _ ->
        case result do
          :raise -> raise "secret"
          :throw -> throw("secret")
          other -> other
        end
      end)

      enriched = Board.enrich(board(), settings())
      assert enriched.source_error == nil
      assert length(enriched.tasks) == 1
      assert enriched.enrichment_error =~ "unavailable"
      refute enriched.enrichment_error =~ "secret"
    end
  end

  test "the optional read timeout kills only enrichment and leaves source facts visible" do
    owner = self()

    respond(fn _, _, _, _, _ ->
      send(owner, {:reader, self()})
      receive do: (:finish -> payload(evidence()))
    end)

    result = Board.enrich(board(), settings(), 20)
    assert_receive {:reader, reader}
    refute Process.alive?(reader)
    assert result.source_error == nil
    assert result.enrichment_error =~ "unavailable"
    assert [card] = result.tasks
    assert card.title == "Task 1"
    assert Board.enrich(board(), settings(), 0).enrichment_error =~ "unavailable"
  end

  test "scope and configured API host are validated before any network request" do
    respond(fn _, _, _, _, _ -> flunk("unexpected GitHub request") end)
    assert Board.enrich(board([]), settings()) == board([])
    source_failed = Map.put(board(), :source_error, "source unavailable")
    assert Board.enrich(source_failed, settings()) == source_failed
    assert Board.enrich(board(), put_in(settings(), [:tracker, :kind], "memory")) == board()

    for provider <- [%{"repo" => "example/repo", "api_url" => "https://enterprise.example/api"}, %{"repo" => "example/../evil"}, %{"repo" => "example/repo?token=secret"}, %{}] do
      settings = put_in(settings(), [:tracker, :provider], provider)
      assert Board.enrich(board(), settings).enrichment_error =~ "only for github.com"
    end

    for changes <- [%{project: "github:other/repo"}, %{issue_id: "1) { secret }"}, %{issue_id: 1}] do
      untrusted = Map.update!(board(), :tasks, fn [task] -> [Map.merge(task, changes)] end)
      assert Board.enrich(untrusted, settings()).enrichment_error =~ "unavailable"
    end

    assert Board.repository_url(%{kind: "memory", provider: %{}}) == nil
  end

  test "source-missing rows preserve holds and cannot gain fabricated PR or candidate links" do
    handoff = %{"candidate_sha" => @sha}
    source = TaskBoard.project([], %{}, %{"issues" => %{"1" => %{"hold" => "owner_review", "handoff" => handoff}}}, settings())
    respond(fn _, _, _, _, _ -> flunk("must not query synthetic rows") end)
    assert [%{source_missing: true, github_status: "source_missing", pull_requests: [], blocker_reason: reason}] = Board.enrich(source, settings()).tasks
    assert reason =~ "Tracker issue is missing"
  end

  test "transport does not retry or follow redirects" do
    for status <- [200, 302, 503] do
      {port, server} = http_server(status)
      options = %{api_url: "http://127.0.0.1:#{port}", token: "test-token"}
      assert {:ok, %{status: ^status, body: %{}}} = Board.request_once("POST", "/graphql", %{}, %{"query" => "query {}"}, options)
      assert :ok = Task.await(server)
    end

    assert {:error, :unavailable} = Board.request_once("POST", "/graphql", %{}, %{}, %{api_url: "http://127.0.0.1:1", token: "test-token"})
  end

  defp settings do
    provider = %{"repo" => "example/repo", "token" => "test-token"}

    %{
      tracker: %{
        kind: "github",
        provider: provider,
        project_slug: nil,
        active_states: ["open"],
        terminal_states: ["closed"],
        required_labels: []
      },
      control: %{enabled: false}
    }
  end

  defp board(ids \\ ["1"]) do
    issues =
      Enum.map(ids, &%Issue{id: &1, identifier: "GH-" <> &1, title: "Task " <> &1, state: "open", dispatchable: true, updated_at: ~U[2026-09-15 00:00:00Z], native_ref: %{"repo" => "example/repo"}})

    TaskBoard.project(issues, %{}, %{}, settings())
  end

  defp respond(fun) when is_function(fun, 5), do: Application.put_env(:symphony_elixir, :github_board_request, fun)
  defp respond(result), do: respond(fn _, _, _, _, _ -> result end)
  defp payload(issue), do: {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"nameWithOwner" => "example/repo", "issue_1" => issue}}}}}

  defp evidence(prs \\ [], events \\ []) do
    %{
      "number" => 1,
      "url" => "https://github.com/example/repo/issues/1",
      "updatedAt" => "2026-09-15T00:00:00Z",
      "closedByPullRequestsReferences" => %{"nodes" => prs, "pageInfo" => %{"hasNextPage" => false}},
      "timelineItems" => %{"nodes" => events, "pageInfo" => %{"hasPreviousPage" => false}}
    }
  end

  defp event(pr, target \\ 1, repo \\ "example/repo"), do: %{"target" => %{"number" => target, "repository" => %{"nameWithOwner" => repo}}, "source" => Map.put(pr, "__typename", "PullRequest")}

  defp pr(number, changes \\ %{}) do
    Map.merge(
      %{
        "number" => number,
        "title" => "PR #{number}",
        "url" => "https://github.com/example/repo/pull/#{number}",
        "repository" => %{"nameWithOwner" => "example/repo"},
        "state" => "OPEN",
        "isDraft" => true,
        "reviewDecision" => "REVIEW_REQUIRED",
        "headRefOid" => @sha,
        "commits" => %{"nodes" => [%{"commit" => %{"oid" => @sha, "statusCheckRollup" => %{"state" => "SUCCESS"}}}]}
      },
      changes
    )
  end

  defp http_server(status) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        assert request =~ "POST /graphql"
        :ok = :gen_tcp.send(socket, "HTTP/1.1 #{status} response\r\nContent-Type: application/json\r\nContent-Length: 2\r\nLocation: http://127.0.0.1:1/untrusted\r\nConnection: close\r\n\r\n{}")
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {port, server}
  end
end
