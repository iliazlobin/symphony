defmodule SymphonyElixir.Chat.ArtifactsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Chat.Artifacts

  @project "github:example/repo"
  @time "2026-09-16T12:00:00Z"

  test "issue and multiple PR snapshots expose observed metadata and retain latest observation" do
    first = task(%{"title" => "Earlier title", "pull_requests" => [pr(10), pr(11)]})
    later = task(%{"title" => "Current title", "tracker_state" => "closed", "pull_requests" => [pr(10, %{"state" => "merged"})]})
    chat = chat([%{"type" => "tasks", "tasks" => [first], "checked_at" => @time}, %{"type" => "task", "task" => later}])
    entries = Artifacts.entries(chat)
    assert length(entries) == 3
    issue = Enum.find(entries, &(&1["kind"] == "issue"))
    assert issue["title"] == "Current title"
    assert issue["status"] == "closed"
    assert issue["url"] == "https://github.com/example/repo/issues/1"
    assert issue["created_at"] == @time
    assert issue["updated_at"] == @time
    assert issue["checked_at"] == @time
    assert issue["metrics"] == [%{"label" => "Workflow", "value" => "review"}, %{"label" => "Priority", "value" => "P2"}]
    assert Enum.find(entries, &(&1["id"] == "github:example/repo:pull:10"))["status"] == "merged"
    unchanged = Enum.find(entries, &(&1["id"] == "github:example/repo:pull:11"))
    assert unchanged["created_at"] == nil
    assert unchanged["updated_at"] == nil
    assert unchanged["checked_at"] == @time
    assert %{"label" => "Check count", "value" => "4"} in unchanged["metrics"]
    assert %{"label" => "Draft", "value" => "No"} in unchanged["metrics"]
  end

  test "invalid, foreign and deceptive identities never become navigable artifacts" do
    for invalid <- [nil, %{}, %{"project_id" => "linear:team"}, %{"project_id" => "github:example/repo/extra"}] do
      assert Artifacts.entries(invalid) == []
    end

    foreign_prs = [pr(3, %{"url" => "https://github.com/foreign/repo/pull/3"}), pr(4, %{"url" => "javascript:alert(1)"}), pr(nil)]

    widgets = [
      nil,
      %{"type" => "unknown"},
      %{"type" => "task", "task" => []},
      %{"type" => "tasks", "tasks" => [nil, task(%{"project" => "github:foreign/repo"}), task(%{"id" => @project <> ":2"}), task(%{"issue_id" => "../1"})]},
      %{"type" => "task", "task" => task(%{"pull_requests" => foreign_prs})}
    ]

    assert [%{"kind" => "issue"}] = Artifacts.entries(chat(widgets))
    assert Artifacts.entries(%{"project_id" => @project, "messages" => "invalid", "proposals" => [nil, %{}]}) == []
  end

  test "old and partial results remain readable without inventing unavailable fields" do
    task =
      task(%{
        "title" => nil,
        "priority" => -1,
        "tracker_state" => "invented",
        "stage" => [],
        "created_at" => "bad",
        "updated_at" => 5,
        "checked_at" => "bad",
        "pull_requests" => [pr(5, %{"title" => <<255>>, "draft" => nil, "review" => "invented", "checks" => nil, "check_total" => -1, "additions" => nil})]
      })

    entries = Artifacts.entries(chat([%{"type" => "task", "task" => task}]))
    assert [%{"kind" => "pull_request", "title" => "Pull request #5"} = pr, %{"kind" => "issue", "title" => "Issue #1"} = issue] = entries
    assert issue["status"] == "unknown"
    assert Enum.all?(~w(created_at updated_at checked_at), &is_nil(issue[&1]))
    assert %{"label" => "Priority", "value" => "unknown"} in issue["metrics"]
    assert %{"label" => "Draft", "value" => "unknown"} in pr["metrics"]
    assert %{"label" => "Checks", "value" => "unknown"} in pr["metrics"]
    assert %{"label" => "Additions", "value" => "unknown"} in pr["metrics"]
  end

  test "action records remain separate from observed issues and unsafe receipt links are ignored" do
    proposal = %{
      "id" => "operation-1",
      "project_id" => @project,
      "action" => "create_task",
      "status" => "completed",
      "created_at" => @time,
      "receipt" => %{"widgets" => [%{"task_id" => @project <> ":9", "url" => "javascript:bad"}]}
    }

    actions = [proposal, %{proposal | "id" => "operation-2", "action" => "pause", "status" => "unknown", "receipt" => nil}]
    entries = Artifacts.entries(Map.put(chat([]), "proposals", actions))
    assert [%{"kind" => "action", "status" => "unknown", "url" => nil}, %{"kind" => "action", "title" => "Create task", "url" => "https://github.com/example/repo/issues/9"}] = entries
    assert hd(entries)["metrics"] == [%{"label" => "Outcome", "value" => "No confirmed success"}]
    assert List.last(entries)["metrics"] == [%{"label" => "Outcome", "value" => "Confirmed by action receipt"}]

    for receipt_id <- [nil, "github:foreign/repo:9", @project <> ":../9"] do
      invalid = put_in(proposal, ["receipt", "widgets"], [%{"task_id" => receipt_id}])
      assert [%{"url" => nil}] = Artifacts.entries(Map.put(chat([]), "proposals", [invalid]))
    end

    assert Artifacts.entries(Map.put(chat([]), "proposals", [%{proposal | "project_id" => "github:foreign/repo"}])) == []
  end

  test "bounded output favors recent results without silently manufacturing missing metadata" do
    messages =
      for n <- 1..150,
          do: %{
            "widgets" => [
              %{"type" => "task", "task" => task(%{"id" => @project <> ":#{n}", "issue_id" => "#{n}", "title" => String.duplicate("x", 2_000), "pull_requests" => [pr(n, %{"draft" => true})]})}
            ]
          }

    entries = Artifacts.entries(%{"project_id" => @project, "messages" => messages, "proposals" => []})
    assert length(entries) == 100
    assert hd(entries)["id"] == "github:example/repo:pull:150"
    assert %{"label" => "Draft", "value" => "Yes"} in hd(entries)["metrics"]
    assert String.length(Enum.at(entries, 1)["title"]) == 1_024
    refute Enum.any?(entries, &(&1["id"] == @project <> ":1"))
  end

  defp chat(widgets), do: %{"project_id" => @project, "messages" => [%{"widgets" => widgets}], "proposals" => []}

  defp task(overrides),
    do:
      Map.merge(
        %{
          "id" => @project <> ":1",
          "issue_id" => "1",
          "project" => @project,
          "title" => "Task",
          "tracker_state" => "open",
          "stage" => "review",
          "priority" => 2,
          "created_at" => @time,
          "updated_at" => @time,
          "checked_at" => @time
        },
        overrides
      )

  defp pr(number, overrides \\ %{}),
    do:
      Map.merge(
        %{
          "number" => number,
          "title" => "Change",
          "url" => "https://github.com/example/repo/pull/#{number}",
          "state" => "open",
          "draft" => false,
          "review" => "approved",
          "checks" => "success",
          "check_details_status" => "available",
          "check_total" => 4,
          "additions" => 8,
          "deletions" => 2,
          "changed_files" => 1
        },
        overrides
      )
end
