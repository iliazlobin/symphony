defmodule SymphonyElixirWeb.TaskOperatorTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.TaskOperator

  test "needs input prepares scoped discussion without a worker answer or retry" do
    task = task(%{hold: "input_required", runtime: %{status: "blocked"}})
    summary = TaskOperator.summary(task, board(), %{})
    assert summary.attention?
    assert summary.blocker.kind == "input"
    assert summary.primary_action.event == "operator-question"
    assert summary.question_prompt =~ "Read-only: inspect GH-7"
    assert summary.question_prompt =~ "Do not queue, retry, cancel, approve, publish or launch work"
    refute Enum.any?(summary.actions, &(&1[:action] == "retry"))
    html = panel(task)
    assert html =~ "does not answer or approve the coding worker"
    refute html =~ "phx-value-renew_attempts"
  end

  test "a retained reservation without worker status requires reconciliation before recovery" do
    task = task(%{ledger: Map.put(ledger(2), "active", %{"run_id" => "retained-run", "tokens" => 3})})
    summary = TaskOperator.summary(task, board(), %{})
    assert summary.attention?
    assert summary.blocker.kind == "reconciliation"
    assert summary.primary_action.label == "Discuss blocker"
    assert summary.primary_action.event == "operator-question"
    refute summary.execution.retry?
    refute summary.execution.renew_attempts?
    html = panel(task)
    assert html =~ "Execution ownership needs reconciliation"
    refute html =~ "phx-click=\"prepare-command\""
  end

  test "attempt renewal is distinct from ordinary retry and unavailable authority disables its button" do
    task = task(%{hold: "interrupted"})
    summary = TaskOperator.summary(task, board(), %{})
    assert summary.primary_action.id == "retry-cycle"
    assert summary.primary_action.action == "retry"
    assert summary.primary_action.renew_attempts == "true"
    assert summary.blocker.kind == "attempts"
    html = panel(task)
    assert html =~ "phx-value-renew_attempts=\"true\""
    assert html =~ "requires confirmation"
    assert html =~ "recorded tokens, runtime, task scope and project gates stay unchanged"
    refute panel(task, controls_available: false) =~ "phx-click=\"prepare-command\""
    assert TaskOperator.summary(task, %{board() | runtime_error: "unavailable"}, %{}).primary_action.event == "refresh"
    refute TaskOperator.summary(task, %{board() | runtime_error: "unavailable"}, %{}).execution.renew_attempts?
  end

  test "normal retry and prerequisite waiting remain progress while malformed dependencies need action" do
    for task <- [
          task(%{stage: "ready", runtime: %{status: "retrying"}, attention: "Retry scheduled"}),
          task(%{stage: "ready", ledger: ledger(0), dependency_error: "Dependencies require human-accepted Done in this project."})
        ] do
      refute TaskOperator.summary(task, board(), %{}).attention?
      refute TaskOperator.attention?(task, board().control)
    end

    malformed = task(%{stage: "ready", ledger: ledger(0), dependency_error: "Dependency cycle: revise prerequisites."})
    assert TaskOperator.summary(malformed, board(), %{}).attention?
    assert TaskOperator.attention?(malformed, board().control)
    paused = TaskOperator.summary(task(%{stage: "ready", ledger: ledger(0)}), %{board() | control: Map.put(board().control, "mode", "paused")}, %{})
    refute paused.attention?
    assert paused.primary_action.event == "open-settings"
  end

  test "candidate readiness uses exact native work and observed PR head" do
    task = reviewed_task()
    summary = TaskOperator.summary(task, board(), %{})
    assert summary.evidence.current?
    assert summary.evidence.status == "ready"
    assert summary.evidence.candidate_sha == String.duplicate("a", 40)
    assert summary.evidence.reviewed_sha == summary.evidence.candidate_sha
    assert summary.evidence.checks_label == "Passed"
    assert summary.primary_action.event == "operator-question"
    assert Enum.any?(summary.actions, &(&1.id == "accept"))
    assert Enum.any?(summary.actions, &(&1.id == "correct"))

    changed = %{task | pull_requests: [put_in(hd(task.pull_requests), [:head_sha], String.duplicate("c", 40))]}
    stale = TaskOperator.summary(changed, board(), %{})
    refute stale.evidence.current?
    assert stale.evidence.status == "stale"
    assert stale.evidence.current_label =~ "changed"
    refute stale.execution.renew_attempts?

    missing = TaskOperator.summary(%{task | github_status: "unavailable"}, board(), %{})
    refute missing.evidence.current?
    assert missing.evidence.current_label == "Currentness unconfirmed"
  end

  test "incomplete legacy handoff remains unverified and never invents a candidate or review" do
    handoff = %{"candidate_sha" => "not-a-commit", "review" => %{"verdict" => "not_reported"}}
    task = task(%{stage: "review", hold: "owner_review", handoff: handoff})
    summary = TaskOperator.summary(task, board(), %{})
    refute summary.evidence.current?
    assert summary.evidence.candidate_sha == nil
    assert summary.evidence.reviewed_sha == nil
    assert summary.evidence.review_label == "Not reported"
    assert summary.evidence.checks_label == "Not verified against current work"
    html = panel(task)
    assert html =~ "Not recorded"
    assert html =~ "currentness unconfirmed"
    refute html =~ "not-a-commit"

    missing = %{task | handoff: Map.delete(handoff, "review")}
    assert TaskOperator.summary(missing, board(), %{}).evidence.review_label == "Not reported"
  end

  test "closed issue supports explicit manual acceptance but cannot offer a dead rework action" do
    task = task(%{stage: "review", tracker_state: "closed", tracker_terminal: true})
    summary = TaskOperator.summary(task, board(), %{})
    assert Enum.any?(summary.actions, &(&1.id == "accept"))
    refute Enum.any?(summary.actions, &(&1.id == "correct"))
    assert summary.blocker.detail =~ "reopen the issue on GitHub"
    assert summary.evidence == nil
    done = TaskOperator.summary(%{task | stage: "done", attention: "Old failure"}, board(), %{})
    assert done.primary_action == nil
    assert done.actions == []
    refute done.attention?
  end

  test "kind does not promise a noncoding adapter and repeated component IDs remain scoped" do
    task = task(%{stage: "backlog", hold: nil, ledger: ledger(0), task_kind: "testing", title: "<script>unsafe</script>"})
    summary = TaskOperator.summary(task, board(), %{})
    assert summary.capability =~ "intent"
    assert summary.capability =~ "adapters are not enabled"
    full = panel(task, id: "details", controls_available: true)
    compact = panel(task, id: "dock", compact: true, controls_available: true)
    assert full =~ "id=\"queue-task-button\""
    assert compact =~ "id=\"dock-queue\""
    assert compact =~ "data-compact=\"true\""
    assert compact =~ "Coding work · other adapters unavailable"
    refute compact =~ "Stop reply affects chat"
    refute full =~ "<script>"
    assert full =~ "&lt;script&gt;"
  end

  test "explicit outcome remains source text and raw failure text never becomes a new blocker" do
    source = task(%{description: "## Outcome\n\nUsers can open the updated guide.\n\n## Verification\nCheck the link.", attention: "RuntimeError Bearer private-provider-token", ledger: ledger(0)})
    assert TaskOperator.summary(source, board(), %{}).outcome == "Users can open the updated guide."
    html = panel(source)
    assert html =~ "Task needs attention"
    refute html =~ "RuntimeError"
    refute html =~ "private-provider-token"
  end

  defp panel(task, opts \\ []) do
    assigns = %{task: task, board: board(), payload: %{}, controls_available: true, compact: false, id: "fixture"}
    render_component(&TaskOperator.panel/1, Map.merge(assigns, Map.new(opts)))
  end

  defp reviewed_task do
    id = String.duplicate("d", 32)
    candidate = String.duplicate("a", 40)
    base = String.duplicate("b", 40)

    handoff = %{
      "work_id" => id,
      "run_id" => "run",
      "goal_revision" => 1,
      "candidate_sha" => candidate,
      "base_sha" => base,
      "review" => %{"verdict" => "approve", "candidate_sha" => candidate, "findings" => []},
      "checks" => [%{"name" => "unit", "result" => "passed", "details" => "local"}]
    }

    url = "https://github.com/example/fixture/pull/1"

    work = %{
      "id" => id,
      "issue_id" => "7",
      "purpose" => "coding",
      "goal_revision" => 1,
      "phase" => "owner_review",
      "head_sha" => candidate,
      "base_sha" => base,
      "handoff" => handoff,
      "publication" => %{"pr_number" => 1, "pr_url" => url}
    }

    task(%{
      stage: "review",
      hold: "owner_review",
      handoff: handoff,
      github_status: "available",
      pull_requests: [%{number: 1, url: url, head_sha: candidate}],
      ledger: Map.merge(ledger(2), %{"hold" => "owner_review", "selected_work_id" => id, "pr_work" => %{id => work}, "handoff" => handoff})
    })
  end

  defp task(updates) do
    Map.merge(
      %{
        id: "github:example/fixture:7",
        issue_id: "7",
        identifier: "GH-7",
        title: "Fix one link",
        stage: "ready",
        runtime: nil,
        hold: nil,
        attention: nil,
        handoff: nil,
        ledger: ledger(2),
        tracker_state: "open",
        tracker_terminal: false,
        task_kind: "general",
        source_missing: false
      },
      updates
    )
  end

  defp ledger(attempts), do: %{"attempts" => attempts, "tokens" => 10, "runtime_ms" => 20, "active" => nil}

  defp board do
    %{
      source_error: nil,
      runtime_error: nil,
      control: %{"enabled" => true, "revision" => 1, "mode" => "running", "settings" => %{"budgets" => %{"max_attempts" => 2, "max_total_tokens" => 100, "max_total_runtime_ms" => 100}}}
    }
  end
end
