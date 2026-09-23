defmodule SymphonyElixir.Chat.SessionsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Chat.Sessions
  alias SymphonyElixirWeb.ChatNavigation

  test "PR options retain native identity after publication and reject unbound or foreign sessions" do
    task = task()
    id = "work:" <> String.duplicate("a", 32)
    assert [%{id: ^id, pr: nil, name: "Implement", discussion: false}] = Sessions.options(task)
    assert {:ok, %{"work_id" => work_id, "pr_number" => nil}} = Sessions.resolve(task, id, "scope")
    assert work_id == String.duplicate("a", 32)
    refute Sessions.valid_id?("pr:0")
    refute Sessions.valid_id?("pr:../1")
    refute Sessions.valid_id?(nil)
    assert Sessions.options(nil) == []
    assert {:error, :pr_session_unavailable} = Sessions.resolve(task, id, "another-project")
    assert {:error, :pr_session_unavailable} = Sessions.resolve(task, "pr:7", "scope")

    published = put_in(task, [:ledger, "pr_work", work_id, "publication"], %{"pr_number" => 7, "pr_url" => "https://github.com/example/repo/pull/7"})
    published = Map.put(published, :pull_requests, [pr()])
    assert [%{id: ^id, pr: %{number: 7}, name: "Fix", discussion: false}] = Sessions.options(published)
    assert {:ok, %{"work_id" => ^work_id, "pr_number" => 7}} = Sessions.resolve(published, id, "scope")
    external = %{published | ledger: %{}}
    assert [%{discussion: true}] = Sessions.options(external)
    assert {:ok, %{"work_id" => nil}} = Sessions.resolve(external, "pr:7", "scope")
    assert [%{name: "PR #7"}] = Sessions.options(%{external | pull_requests: [%{pr() | title: ""}]})
    foreign = %{external | pull_requests: [%{pr() | url: "https://github.com/other/repo/pull/7"}]}
    assert {:error, :pr_session_unavailable} = Sessions.resolve(foreign, "pr:7", "scope")
    assert {:error, :pr_session_unavailable} = Sessions.resolve(Map.put(external, :source_missing, true), "pr:7", "scope")
    assert {:error, :pr_session_unavailable} = Sessions.resolve(%{external | project: "linear:team"}, "pr:7", "scope")
  end

  test "worker report identity includes correction run and candidate; stale CI is never reported as successful" do
    task = task()
    [first] = Sessions.reports(task, "scope")
    assert first["text"] =~ "Working"
    assert Sessions.reports(task, "foreign") == []
    updated = put_in(task, [:ledger, "active"], %{"run_id" => "new-attempt", "work_id" => String.duplicate("a", 32)})
    [next] = Sessions.reports(updated, "scope")
    refute next["signature"] == first["signature"]

    task = %{task | ledger: %{}, pull_requests: [pr()]}
    [success] = Sessions.reports(task, "scope")
    assert success["text"] =~ "CI: Success"
    stale = %{pr() | check_details_status: "stale"}
    [report] = Sessions.reports(%{task | pull_requests: [stale]}, "scope")
    assert report["text"] =~ "CI: Stale"
    refute report["text"] =~ "CI: Success"
    assert Sessions.reports(%{task | github_status: "unavailable"}, "scope") == []
    assert Sessions.reports(%{task | pull_requests: [%{pr() | head_sha: nil}]}, "scope") == []

    [merged] = Sessions.reports(%{task | pull_requests: [%{pr() | state: "merged"}]}, "scope")
    assert merged["text"] =~ "Merged"
    assert merged["text"] =~ "acceptance remains separate"
  end

  test "discussion history remains read-only and receives updates after a worker publication arrives" do
    task = %{task() | ledger: %{}, pull_requests: [pr()]}
    assert {:ok, %{"work_id" => nil}} = Sessions.resolve(task, "pr:7", "scope")
    id = String.duplicate("a", 32)
    published = put_in(task(), [:ledger, "pr_work", id, "publication"], %{"pr_number" => 7, "pr_url" => pr().url}) |> Map.put(:pull_requests, [pr()])
    assert [%{work: %{}}, %{id: "pr:7", work: nil, title: "PR #7 · Discussion"}] = Sessions.options(published, ["pr:7"])
    assert {:ok, %{"work_id" => nil}} = Sessions.resolve(published, "pr:7", "scope")
    assert [%{"session_id" => "pr:7"}] = Sessions.reports(published, "scope", "pr:7")
    assert length(Sessions.reports(published, "scope")) == 2
  end

  test "another work's active run does not re-emit an unchanged milestone" do
    task = task()
    first = Sessions.reports(task, "scope")
    another = put_in(task, [:ledger, "active"], %{"run_id" => "other-run", "work_id" => String.duplicate("b", 32)})
    assert Sessions.reports(another, "scope") == first
  end

  test "task activity combines processing and queued counts from main and PR chats" do
    chats = [
      %{"project_id" => "p", "task_id" => "p:1", "updated_at" => "2026-09-20", "status" => "running", "queued_count" => 2},
      %{"project_id" => "p", "task_id" => "p:1", "updated_at" => "2026-09-21", "status" => "idle", "queued_count" => 3},
      %{"project_id" => "other", "task_id" => "p:1", "status" => "running", "queued_count" => 9}
    ]

    assert %{"p:1" => %{"status" => "running", "queued_count" => 5, "updated_at" => "2026-09-21"}} = ChatNavigation.chat_activity(chats, "p")
  end

  defp task do
    id = String.duplicate("a", 32)
    work = %{"id" => id, "issue_id" => "1", "tracker_fingerprint" => "scope", "phase" => "building", "instruction" => "Implement", "updated_at" => "2026-09-23T10:00:00Z"}
    %{id: "github:example/repo:1", project: "github:example/repo", issue_id: "1", ledger: %{"pr_work" => %{id => work}}, pull_requests: [], github_status: "available"}
  end

  defp pr do
    %{
      number: 7,
      url: "https://github.com/example/repo/pull/7",
      title: "Fix",
      state: "open",
      review: "approved",
      checks: "success",
      head_sha: String.duplicate("b", 40),
      check_details_status: "available"
    }
  end
end
