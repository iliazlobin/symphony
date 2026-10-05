defmodule SymphonyElixir.AgentProtocolTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{AgentProtocol, TaskKind, WorkEvidence}

  @base String.duplicate("a", 40)
  @head String.duplicate("b", 40)

  test "roles constrain actions independently from model names and task flavors" do
    assert AgentProtocol.role(%{"conversation_role" => "pr"}) == "work"
    assert AgentProtocol.role(%{"conversation_role" => "task"}) == "task"
    assert AgentProtocol.role(%{}) == "project"
    assert AgentProtocol.context_role(%{session_id: "pr:7", task_id: "task"}) == "work"
    assert AgentProtocol.context_role(%{session_id: nil, task_id: "task"}) == "task"
    assert AgentProtocol.context_role(%{}) == "project"
    assert AgentProtocol.actions("unknown") == []
    assert AgentProtocol.authorize_action("project", "create_task") == :ok
    assert AgentProtocol.authorize_action("task", "create_pr_work") == :ok
    assert AgentProtocol.authorize_action("work", "continue_pr_work") == :ok

    for {role, action} <- [{"task", "pause"}, {"task", "create_task"}, {"work", "feedback"}, {"work", "create_pr_work"}, {"unknown", "cancel"}] do
      assert AgentProtocol.authorize_action(role, action) == {:error, :agent_role_forbidden}
    end

    assert AgentProtocol.purposes() == ~w(coding testing security analysis deployment)
    assert AgentProtocol.executable_purpose?("coding")
    for purpose <- ~w(testing security analysis deployment), do: refute(AgentProtocol.executable_purpose?(purpose))

    for {work, state} <- [
          {nil, "discussion"},
          {%{"phase" => "building"}, "running"},
          {%{"phase" => "reviewing"}, "running"},
          {%{"phase" => "owner_review"}, "review"},
          {%{"phase" => "queued"}, "queued"},
          {%{"phase" => "paused"}, "paused"},
          {%{}, "unknown"}
        ] do
      assert AgentProtocol.execution_state(work) == state
    end
  end

  test "intent labels are independent from execution and old domain tags" do
    for kind <- TaskKind.values(), do: assert(TaskKind.from_labels(["kind:" <> kind]) == kind)
    assert TaskKind.from_labels([%{"name" => " KIND:TESTING "}, "work:application"]) == "testing"
    assert TaskKind.from_labels(nil) == "general"
    assert TaskKind.from_labels([nil, 3, %{}, "work:application", "work:infrastructure"]) == "general"
    assert TaskKind.from_labels(["work:deployment"]) == "release"
    assert TaskKind.from_labels(["work:operations"]) == "operations"
    assert TaskKind.from_labels(["work:deployment", "work:operations"]) == "invalid"
    assert TaskKind.from_labels(["kind:bug", "work:operations"]) == "bug"
    assert TaskKind.from_labels(["kind:unknown"]) == "invalid"
    assert TaskKind.from_labels(["kind:bug", "kind:security"]) == "invalid"
  end

  test "subject tags exclude workflow and intent labels across casing and malformed metadata" do
    for label <- ~w(ready RUNNING Backlog review done KIND:feature Priority:P1 Symphony:pilot WORK:deployment),
        do: refute(TaskKind.subject_tag?(label))

    for label <- ["category:performance", "frontend", "Graph", "prereview"], do: assert(TaskKind.subject_tag?(label))
    for label <- [nil, 42, %{"name" => "frontend"}], do: refute(TaskKind.subject_tag?(label))
  end

  test "readiness is commit, base, work and instruction revision specific; checks do not accept tasks" do
    assert WorkEvidence.result(nil) == nil
    work = reviewed()
    assert %{"status" => "ready", "current" => true, "candidate_sha" => @head, "reviewed_sha" => @head, "goal_revision" => 2, "checks_status" => "passed"} = WorkEvidence.result(work)

    for changed <- [
          Map.put(work, "head_sha", @base),
          Map.put(work, "base_sha", @head),
          Map.put(work, "id", "other"),
          Map.put(work, "goal_revision", 3),
          put_in(work, ["handoff", "review", "candidate_sha"], @base),
          put_in(work, ["handoff", "run_id"], nil),
          Map.put(work, "head_sha", nil)
        ] do
      assert %{"status" => "unverified", "current" => false} = WorkEvidence.result(changed)
    end

    assert WorkEvidence.result(Map.put(work, "phase", "queued"))["status"] == "stale"
    assert WorkEvidence.result(put_in(work, ["handoff", "review", "verdict"], "blocked"))["status"] == "blocked"
    assert WorkEvidence.result(put_in(work, ["handoff", "review", "verdict"], "request_changes"))["status"] == "changes_requested"
    assert WorkEvidence.result(put_in(work, ["handoff", "review", "findings"], [%{}]))["status"] == "unverified"

    for {checks, state} <- [{[], "not_reported"}, {[check("failed")], "failed"}, {[check("not_run")], "not_run"}, {[%{"result" => "passed"}], "invalid"}, {"invalid", "invalid"}] do
      result = WorkEvidence.result(put_in(work, ["handoff", "checks"], checks))
      assert result["status"] == "reviewed"
      assert result["checks_status"] == state
    end

    assert WorkEvidence.result(Map.put(work, "handoff", []))["status"] == "unverified"
    assert WorkEvidence.result(put_in(work, ["handoff", "review"], false))["status"] == "unverified"
    assert WorkEvidence.result(put_in(work, ["handoff", "limitations"], "bad"))["limitations"] == []
    assert WorkEvidence.result(work)["limitations"] == ["No deployment performed"]
  end

  test "published work readiness is invalidated by changed, missing or unavailable remote head" do
    work = Map.put(reviewed(), "publication", %{"pr_number" => 7, "pr_url" => "https://github.com/example/repo/pull/7"})
    pr = %{number: 7, url: "https://github.com/example/repo/pull/7", head_sha: @head}
    task = %{pull_requests: [pr], github_status: "available"}
    assert WorkEvidence.for_task(nil, task) == nil
    assert %{"current" => true, "status" => "ready", "external_head_state" => "not_published"} = WorkEvidence.for_task(reviewed(), %{})
    assert %{"current" => true, "status" => "ready", "external_head_state" => "current"} = WorkEvidence.for_task(work, task)
    assert %{"current" => true} = WorkEvidence.for_task(work, %{task | github_status: "partial"})
    changed = %{task | pull_requests: [%{pr | head_sha: @base}]}
    assert %{"native_current" => true, "current" => false, "status" => "stale", "external_head_state" => "changed"} = WorkEvidence.for_task(work, changed)

    for unknown <- [
          %{task | pull_requests: []},
          %{task | github_status: "unavailable"},
          %{task | pull_requests: [%{pr | head_sha: nil}]},
          %{task | pull_requests: [%{pr | url: "https://github.com/other/repo/pull/7"}]}
        ] do
      assert %{"current" => false, "status" => "unverified", "external_head_state" => "unavailable"} = WorkEvidence.for_task(work, unknown)
    end
  end

  defp reviewed do
    %{
      "id" => "work",
      "phase" => "owner_review",
      "head_sha" => @head,
      "base_sha" => @base,
      "goal_revision" => 2,
      "handoff" => %{
        "work_id" => "work",
        "run_id" => "run",
        "goal_revision" => 2,
        "candidate_sha" => @head,
        "base_sha" => @base,
        "review" => %{"candidate_sha" => @head, "verdict" => "approve", "findings" => []},
        "checks" => [check("passed")],
        "limitations" => ["No deployment performed", nil]
      }
    }
  end

  defp check(result), do: %{"name" => "unit", "result" => result, "details" => "Executed on candidate"}
end
