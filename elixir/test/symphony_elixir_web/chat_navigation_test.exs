defmodule SymphonyElixirWeb.ChatNavigationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.ChatNavigation

  @project "github:example/fixture"

  test "category suggestions remain available for empty groups in workflow order" do
    categories = ChatNavigation.categories()
    assert Enum.map(categories, & &1.id) == ~w(work review attention backlog done)
    assert Enum.map(categories, & &1.label) == ["Work", "Ready for review", "Needs attention", "Backlog", "Done"]
    assert ChatNavigation.issues([], %{}, @project, "review") == []
    assert %{id: "review", label: "Ready for review"} in categories
  end

  test "PR sessions distinguish queued, working, validating, reviewed, paused and unknown phases" do
    phases = [
      {"queued", "Queued"},
      {"building", "Working"},
      {"reviewing", "Validating"},
      {"owner_review", "Ready for review"},
      {"paused", "Paused"},
      {"future-phase", "Unknown"}
    ]

    works =
      phases
      |> Enum.with_index(1)
      |> Map.new(fn {{phase, _label}, number} ->
        work_id = String.pad_leading(Integer.to_string(number), 32, "0")
        work = %{"id" => work_id, "issue_id" => "11", "phase" => phase, "updated_at" => ~U[2026-09-23 10:00:00Z]}
        {work_id, work}
      end)

    issue = task("11", "ready", issue_id: "11", ledger: %{"pr_work" => works})
    sessions = ChatNavigation.work_sessions(issue)
    assert Enum.map(sessions, & &1.phase) == Enum.map(phases, &elem(&1, 1))
    assert Enum.all?(sessions, &(&1.updated_at == "2026-09-23T10:00:00Z" and not &1.session_retained))
    assert List.last(sessions).phase != "Ready for review"
    assert ChatNavigation.work_counts(issue) == %{total: 6, working: 2, queued: 1, review: 1, paused: 1}
    assert ChatNavigation.work_counts(nil) == %{total: 0, working: 0, queued: 0, review: 0, paused: 0}
    assert ChatNavigation.work_counts(%{issue | issue_id: "other"}).total == 0
  end

  test "PR resources and chat activity cannot create work-session counts" do
    issue = task("11", "running", issue_id: "11", pull_requests: [%{number: 14, state: "merged"}], runtime: %{status: "running"})
    assert ChatNavigation.work_counts(issue) == %{total: 0, working: 0, queued: 0, review: 0, paused: 0}
  end

  test "native DateTime activity preserves microsecond ordering alongside tracker timestamps" do
    tasks = [
      task("issue", "ready", updated_at: ~U[2026-09-23 10:00:00.000001Z]),
      task("worker", "ready", runtime: %{last_event_at: ~U[2026-09-23 10:00:00.000002Z]}),
      task("tracker", "ready", updated_at: "2026-09-23T03:00:00-07:00")
    ]

    assert [%{issues: [worker, issue, tracker]}] = ChatNavigation.issues(tasks, %{}, @project)
    assert worker.activity_at == "2026-09-23T10:00:00.000002Z"
    assert worker.activity_label == "Worker update"
    assert issue.activity_at == "2026-09-23T10:00:00.000001Z"
    assert tracker.activity_at == "2026-09-23T10:00:00Z"
  end

  test "projects issue-owned PR sessions and uses their latest activity without leaking runtime paths" do
    id = String.duplicate("a", 32)

    work = %{
      "id" => id,
      "issue_id" => "11",
      "phase" => "reviewing",
      "instruction" => "Validate new checks",
      "updated_at" => "2026-09-23T10:00:00Z",
      "builder_thread_id" => "thread",
      "home" => "/private/auth/home"
    }

    issue = task("11", "running", issue_id: "11", ledger: %{"pr_work" => %{id => work}})
    assert [session] = ChatNavigation.work_sessions(issue)
    assert session.phase == "Validating"
    assert session.name == "Validate new checks"
    long_name = String.duplicate("Feature name ", 20) |> String.trim()
    renamed = put_in(issue, [:ledger, "pr_work", id, "instruction"], long_name <> "\nDetails")
    assert [%{name: ^long_name}] = ChatNavigation.work_sessions(renamed)
    assert session.session_retained
    refute Map.has_key?(session, :home)
    assert [%{issues: [row]}] = ChatNavigation.issues([issue], %{}, @project, "checks")
    assert row.activity_at == "2026-09-23T10:00:00Z"
    assert [] == ChatNavigation.work_sessions(%{issue | issue_id: "12"})
    assert [] == ChatNavigation.work_sessions(nil)
  end

  test "groups issue and chat activity while keeping completed work last" do
    tasks = [
      task("done", "done"),
      task("backlog", "backlog"),
      task("ready", "ready"),
      task("blocked", "ready", attention: "Needs input"),
      task("review", "review"),
      task("worker", "running"),
      task("chat", "backlog")
    ]

    activities = Map.new(["done", "chat"], &{id(&1), activity(&1, status: "running")})
    groups = ChatNavigation.issues(tasks, activities, @project)
    assert Enum.map(groups, & &1.id) == ~w(work review attention backlog done)
    assert Enum.map(hd(groups).issues, & &1.id) == [id("chat"), id("ready"), id("worker")]
    assert Enum.find(groups, &(&1.id == "review")).label == "Ready for review"
    assert List.last(groups).issues |> hd() |> Map.fetch!(:id) == id("done")
  end

  test "a responding management chat never hides execution blockers or a candidate needing review" do
    tasks = [task("held", "ready", attention: "Worker sign-in required"), task("review", "review", attention: "Awaiting acceptance")]
    activities = Map.new(["held", "review"], &{id(&1), activity(&1, status: "running")})
    groups = ChatNavigation.issues(tasks, activities, @project)
    assert Enum.map(groups, & &1.id) == ["review", "attention"]
    assert hd(List.last(groups).issues).id == id("held")
  end

  test "Work combines queued and running tasks without changing execution stages" do
    tasks = [task("queued", "ready"), task("active", "running")]
    assert [%{id: "work", issues: issues}] = ChatNavigation.issues(tasks, %{}, @project, "work")
    assert Enum.all?(issues, &(&1.lane == "work"))
    assert Enum.map(issues, & &1.stage) == ["running", "ready"]

    for query <- ["queued", "running", "ready"] do
      assert [%{id: "work"}] = ChatNavigation.issues(tasks, %{}, @project, query)
    end

    assert [%{id: "review", issues: [%{lane: "review", stage: "ready"}]}] =
             ChatNavigation.issues([task("review", "ready", lane: "review")], %{}, @project)
  end

  test "uses latest valid source activity with deterministic ties and missing timestamps last" do
    tasks = [
      task("missing", "ready", updated_at: "tomorrow"),
      task("older", "ready", updated_at: "2026-09-21T10:00:00Z"),
      task("b", "ready", runtime: %{last_event_at: "2026-09-22T10:00:00Z", last_message: "Worker checked tests"}),
      task("a", "ready", pull_requests: [%{number: 8, title: "Fresh change", updated_at: "2026-09-22T03:00:00-07:00"}]),
      task("chat", "ready")
    ]

    activities = %{id("chat") => activity("chat", updated_at: "2026-09-22T11:00:00Z", snippet: "Latest response")}
    [group] = ChatNavigation.issues(tasks, activities, @project)
    assert Enum.map(group.issues, & &1.id) == Enum.map(~w(chat a b older missing), &id/1)
    assert hd(group.issues).preview == "Latest response"
    assert Enum.at(group.issues, 1).activity_at == "2026-09-22T10:00:00Z"
    assert Enum.at(group.issues, 1).activity_label == "PR #8 updated"
    assert List.last(group.issues).activity_at == nil
    assert List.last(group.issues).activity_label == "No activity recorded"
  end

  test "search requires every case-insensitive token and includes category synonyms and latest activity" do
    tasks = [task("11", "review", title: "Document test command", updated_at: "2026-09-20T10:00:00Z")]
    activities = %{id("11") => activity("11", updated_at: "2026-09-22T10:00:00Z", snippet: "README verified")}
    assert [%{issues: [_]}] = ChatNavigation.issues(tasks, activities, @project, "APPROVAL gh-11 readme")
    assert [] = ChatNavigation.issues(tasks, activities, @project, "review missingword")
    assert [%{issues: [_]}] = ChatNavigation.issues(tasks, activities, @project, "  ready   for review  ")
  end

  test "rejects another project's tasks and wrongly bound chat summaries" do
    tasks = [task("1", "backlog"), task("other", "running", project: "github:other/repo")]

    for wrong <- [%{activity("1", status: "running") | "project_id" => "github:other/repo"}, %{activity("1", status: "running") | "task_id" => id("2")}] do
      assert [%{id: "backlog", issues: [%{id: task_id}]}] = ChatNavigation.issues(tasks, %{id("1") => wrong}, @project)
      assert task_id == id("1")
    end
  end

  test "issue picker retains creation time, priority and PR evidence without inventing missing metadata" do
    created = ~U[2026-09-22 21:27:05Z]
    prs = [%{number: 9}, %{number: 10}]

    for priority <- [1, 2, 3, 4, nil, 0, 5, "1"] do
      issue = task("1", "backlog", created_at: created, priority: priority, github_status: "available", pull_requests: prs)
      [%{issues: [row]}] = ChatNavigation.issues([issue], %{}, @project)
      assert row.created_at == "2026-09-22T21:27:05Z"
      assert row.priority == if(priority in 1..4, do: priority)
      assert row.pull_request_count == 2
      assert row.github_status == "available"
    end

    incomplete = task("2", "backlog", created_at: "unknown", github_status: "unavailable")
    [%{issues: [missing]}] = ChatNavigation.issues([incomplete], %{}, @project)
    assert missing.created_at == nil
    assert missing.priority == nil
    assert missing.github_status == "unavailable"
  end

  test "retains all PRs, puts active PRs first and normalizes status and evidence" do
    prs = [
      %{number: 1, title: "Merged latest", state: "MERGED", updated_at: "2026-09-22T12:00:00Z"},
      %{number: 2, title: "Open older", state: "OPEN", checks: "SUCCESS", review: "APPROVED", updated_at: "2026-09-21T12:00:00Z", url: "https://github.com/example/fixture/pull/2", check_total: 5},
      %{
        "number" => 3,
        "title" => "Draft newest",
        "state" => "open",
        "draft" => true,
        "updated_at" => "2026-09-22T10:00:00Z",
        "checks" => "unexpected",
        "review" => "changes_requested",
        "check_runs" => [%{}]
      },
      %{number: 4, title: "Closed invalid date", state: "closed", updated_at: "invalid"}
    ]

    task = task("1", "ready", pull_requests: prs)
    [group] = ChatNavigation.issues([task], %{}, @project)
    row = hd(group.issues)
    assert row.pull_request_count == 4
    assert Enum.map(row.pull_requests, & &1.number) == [3, 2, 1, 4]
    assert [draft, open | _] = ChatNavigation.pull_requests(task)
    assert {draft.status, draft.ci, draft.review, draft.check_count} == {"Draft", "unknown", "changes_requested", 1}
    assert {open.status, open.ci, open.review, open.check_count} == {"Open", "success", "approved", 5}
    assert open.checks_url == "https://github.com/example/fixture/pull/2/checks"
  end

  test "fresh CI completion contributes activity without changing the recorded PR update time" do
    pr = %{number: 9, state: "open", updated_at: "2026-09-21T10:00:00Z", check_runs: [%{completed_at: "2026-09-22T12:00:00Z"}]}
    [group] = ChatNavigation.issues([task("1", "review", pull_requests: [pr])], %{}, @project)
    row = hd(group.issues)
    assert row.activity_at == "2026-09-22T12:00:00Z"
    assert hd(row.pull_requests).updated_at == "2026-09-21T10:00:00Z"
  end

  test "unsafe URLs and malformed timestamps are never exposed or invented" do
    for url <- [
          "javascript:alert(1)",
          "//example.com/1",
          "https://user:secret@example.com/1",
          "https://example.com/with space",
          "https://example.com\\evil/path",
          "https://example.com/path\\part",
          "https://"
        ] do
      [group] = ChatNavigation.issues([task("1", "ready", url: url, pull_requests: [%{number: 1, url: url, updated_at: "2026-99-99"}])], %{}, @project)
      row = hd(group.issues)
      assert row.url == nil
      assert [%{url: nil, checks_url: nil, updated_at: nil}] = row.pull_requests
      assert row.activity_at == nil
    end

    [group] = ChatNavigation.issues([task("1", "ready", created_at: "2026-09-21T00:00:00Z", updated_at: "invalid")], %{}, @project)
    assert hd(group.issues).activity_at == "2026-09-21T00:00:00Z"
  end

  defp task(id, stage, attrs \\ []) do
    Map.merge(%{id: id(id), title: "Task #{id}", identifier: "GH-#{id}", project: @project, stage: stage, runtime: nil, updated_at: nil, created_at: nil, pull_requests: []}, Map.new(attrs))
  end

  defp activity(id, attrs) do
    Map.merge(%{"project_id" => @project, "task_id" => id(id), "status" => "idle", "updated_at" => nil}, Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end))
  end

  defp id(value), do: @project <> ":" <> value
end
