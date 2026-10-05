defmodule SymphonyElixir.GitHub.FeedbackTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Feedback
  alias SymphonyElixir.GitHub.Feedback, as: GitHubFeedback

  @repo "example/repo"
  @task %{issue_id: "1", ledger: %{}}

  test "issue comments, PR comments, review summaries and replies retain exact identities and stay pending" do
    issue = %{"comments" => connection([comment(1)])}

    thread = %{
      "isResolved" => true,
      "comments" => connection([comment(4, source: "review", thread: true), comment(5, source: "review", thread: true)])
    }

    pr =
      pr(%{
        "comments" => connection([comment(2, source: "pr")]),
        "reviews" => connection([comment(3, source: "review")]),
        "reviewThreads" => connection([thread])
      })

    result = GitHubFeedback.collect(issue, [pr], @task, @repo, false)
    assert result.status == "available"
    assert result.counts["pending"] == 5
    assert result.counts["addressed"] == 0
    assert Enum.map(result.items, & &1["id"]) == ~w(comment-5 comment-4 comment-3 comment-2 comment-1)
    assert Enum.map(result.items, & &1["source"]) == ~w(review review review pr issue)
    assert Enum.map(result.items, & &1["pr_number"]) == [7, 7, 7, 7, nil]
    assert Enum.all?(result.items, &(&1["status"] == "pending" and &1["author"] == "octocat"))
    assert Feedback.valid_items?(Enum.map(result.items, &Map.delete(&1, "status")))
  end

  test "bots, pending drafts, empty reviews and host status messages are excluded while human chat feedback remains" do
    nodes = [
      comment(1, author: %{"__typename" => "Bot", "login" => "copilot"}),
      comment(2, author: %{"__typename" => "User", "login" => "service[bot]"}),
      comment(3, state: "PENDING"),
      comment(4, body: "  \n  "),
      comment(5, body: "Published\n<!-- symphony issue=GH-1 -->"),
      comment(6, body: "Addressed\n<!-- symphony-feedback:abc -->"),
      comment(7, body: "Fix behavior.\n<!-- symphony-chat:abc -->")
    ]

    result = collect(nodes)
    assert result.status == "available"
    assert [%{"id" => "comment-7", "body" => body}] = result.items
    assert body =~ "Fix behavior"
  end

  test "source fields are bounded and links remain scoped to the owning repository, issue and PR" do
    invalid = [
      comment(1, url: "https://github.com/other/repo/issues/1#issuecomment-1"),
      comment(2, url: "https://github.com/example/repo/issues/2#issuecomment-2"),
      comment(3, url: "https://github.com.evil.test/example/repo/issues/1#issuecomment-3"),
      comment(4, url: "https://user:secret@github.com/example/repo/issues/1#issuecomment-4"),
      comment(5, url: "https://github.com/example/repo/issues/1#issuecomment-5?token=x"),
      comment(6, url: nil),
      comment(7, body: String.duplicate("é", 4_001)),
      comment(8, body: <<255>>),
      comment(9, updated_at: "yesterday"),
      comment(10, updated_at: 1),
      comment(11, updated_at: String.duplicate("x", 65)),
      comment(12, author: nil),
      comment(13, author: %{"login" => "unknown-type"}),
      comment(14, id: String.duplicate("x", 129)),
      comment(15, body: "do\0not"),
      %{},
      nil
    ]

    assert %{status: "partial", items: []} = collect(invalid)
    wrong_pr = pr(%{"comments" => connection([comment(1, source: "pr", url: "https://github.com/example/repo/pull/8#issuecomment-1")])})
    assert %{status: "partial", items: []} = GitHubFeedback.collect(%{"comments" => connection([])}, [wrong_pr], @task, @repo, false)
  end

  test "pagination and missing connections are explicit rather than exact totals" do
    assert %{status: "partial"} = GitHubFeedback.collect(%{"comments" => connection([comment(1)], true)}, [], @task, @repo, false)
    assert %{status: "partial"} = GitHubFeedback.collect(%{"comments" => connection([])}, [], @task, @repo, true)
    assert %{status: "unavailable", items: []} = GitHubFeedback.collect(%{}, [], @task, @repo, false)
    assert %{status: "partial"} = GitHubFeedback.collect(%{"comments" => connection([])}, [%{"number" => 7}], @task, @repo, false)

    for missing <- [nil, %{}, %{"nodes" => "all"}, %{"nodes" => [], "pageInfo" => %{}, "totalCount" => -1}] do
      assert %{status: "unavailable"} = GitHubFeedback.collect(%{"comments" => missing}, [], @task, @repo, false)
    end

    threads = Enum.map(1..11, &%{"comments" => connection([comment(&1, source: "review", thread: true)])})
    many_threads = pr(%{"reviewThreads" => connection(threads)})

    assert %{status: "partial", counts: %{"total" => 10}} =
             GitHubFeedback.collect(%{"comments" => connection([])}, [many_threads], @task, @repo, false)

    replies = Enum.map(1..4, &comment(&1, source: "review", thread: true))
    many_replies = pr(%{"reviewThreads" => connection([%{"comments" => connection(replies)}])})

    assert %{status: "partial", counts: %{"total" => 3}} =
             GitHubFeedback.collect(%{"comments" => connection([])}, [many_replies], @task, @repo, false)

    malformed_thread = pr(%{"reviewThreads" => connection([nil])})
    assert %{status: "partial"} = GitHubFeedback.collect(%{"comments" => connection([])}, [malformed_thread], @task, @repo, false)
  end

  test "newest twenty items and serialized byte budget are bounded with partial status" do
    issue = %{"comments" => connection(Enum.map(1..20, &comment/1))}
    pr = pr(%{"comments" => connection(Enum.map(21..30, &comment(&1, source: "pr")))})
    result = GitHubFeedback.collect(issue, [pr], @task, @repo, false)
    assert result.status == "partial"
    assert result.counts["total"] == 20
    assert hd(result.items)["id"] == "comment-30"
    assert List.last(result.items)["id"] == "comment-11"
    bytes = collect(Enum.map(1..20, &comment(&1, body: String.duplicate("x", 7_900))))
    assert bytes.status == "partial"
    assert bytes.counts["total"] < 20
    assert Feedback.valid_items?(Enum.map(bytes.items, &Map.delete(&1, "status")))
  end

  test "durable exact revisions supply progress; edits and conflicting duplicates cannot inherit completion" do
    [item] = collect([comment(1)]).items
    original = Map.delete(item, "status")
    work = %{"feedback" => [original], "phase" => "building", "updated_at" => "2026-09-23T01:00:00Z"}
    task = %{issue_id: "1", ledger: %{"pr_work" => %{"one" => work}}}
    assert [%{"status" => "working"}] = collect([comment(1)], task).items
    result = Map.merge(original, %{"status" => "addressed", "details" => "Validated", "candidate_sha" => String.duplicate("a", 40)})
    completed = put_in(task, [:ledger, "pr_work", "one"], Map.merge(work, %{"phase" => "owner_review", "feedback_history" => %{item["id"] => result}}))
    assert [%{"status" => "addressed"}] = collect([comment(1)], completed).items
    assert [%{"status" => "pending", "revision" => updated}] = collect([comment(1, body: "New correction")], completed).items
    refute updated == original["revision"]
    refute hd(collect([comment(1, updated_at: "2026-09-23T00:00:02Z")]).items)["revision"] == original["revision"]
    assert %{status: "available", counts: %{"total" => 1}} = collect([comment(1), comment(1)])
    assert %{status: "partial", items: []} = collect([comment(1), comment(1, body: "Conflicting revision")])
    assert GitHubFeedback.unavailable().status == "unavailable"
  end

  defp collect(nodes, task \\ @task), do: GitHubFeedback.collect(%{"comments" => connection(nodes)}, [], task, @repo, false)
  defp connection(nodes, more \\ false), do: %{"nodes" => nodes, "totalCount" => length(nodes) + if(more, do: 1, else: 0), "pageInfo" => %{"hasPreviousPage" => more}}
  defp pr(changes), do: Map.merge(%{"number" => 7, "comments" => connection([]), "reviews" => connection([]), "reviewThreads" => connection([])}, changes)

  defp comment(number, options \\ []) do
    source = Keyword.get(options, :source, "issue")
    path = if source == "issue", do: "issues/1", else: "pull/7"

    fragment =
      cond do
        Keyword.get(options, :thread, false) -> "discussion_r"
        source == "review" -> "pullrequestreview-"
        true -> "issuecomment-"
      end

    %{
      "id" => Keyword.get(options, :id, "comment-#{number}"),
      "url" => Keyword.get(options, :url, "https://github.com/#{@repo}/#{path}##{fragment}#{number}"),
      "body" => Keyword.get(options, :body, "Correction #{number}"),
      "updatedAt" => Keyword.get(options, :updated_at, "2026-09-23T00:00:#{String.pad_leading(to_string(number), 2, "0")}Z"),
      "author" => Keyword.get(options, :author, %{"__typename" => "User", "login" => "octocat"}),
      "state" => Keyword.get(options, :state, "SUBMITTED")
    }
  end
end
