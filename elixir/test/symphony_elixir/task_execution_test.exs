defmodule SymphonyElixir.TaskExecutionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.TaskExecution

  test "closed unaccepted review awaits acceptance without misleading retry controls" do
    for ledger <- [%{}, %{"attempts" => 1, "tokens" => 10, "runtime_ms" => 10}] do
      task = task(%{stage: "review", tracker_state: "closed", hold: "interrupted", ledger: ledger})
      summary = TaskExecution.summary(task, control())
      assert summary.status == "Awaiting acceptance"
      refute summary.cancel?
      refute summary.retry?
      assert TaskExecution.summary(%{task | runtime: %{status: "running"}}, control()).status == "Running"
      assert TaskExecution.summary(put_in(task, [:ledger, "active"], %{}), control()).status == "Needs reconciliation"
    end
  end

  test "explicit rework displays its bounded attempt cycle while retaining lifetime usage" do
    task = task(%{stage: "ready", ledger: %{"attempts" => 6, "attempt_base" => 5, "tokens" => 517_755, "runtime_ms" => 189_000}, hold: "interrupted"})
    summary = TaskExecution.summary(task, control())
    assert metric(summary, "Attempts").value == "1 / 2"
    assert metric(summary, "Attempts").title =~ "6 lifetime attempts"
    assert summary.retry?
    assert metric(summary, "Tokens").value == "518k / 1M"
    assert metric(TaskExecution.summary(task, %{"enabled" => false}), "Attempts").value == "6"

    for base <- [7, -1, nil, "5"] do
      assert metric(TaskExecution.summary(put_in(task, [:ledger, "attempt_base"], base), control()), "Attempts").value == "— / 2"
    end
  end

  test "settled candidate shows retained totals and owner review without worker controls" do
    task = task(%{hold: "owner_review", handoff: %{"review" => %{"verdict" => "approve"}}})
    summary = TaskExecution.summary(task, control())

    assert summary.status == "Awaiting your review"
    assert summary.note == nil
    refute summary.cancel?
    refute summary.retry?
    assert metric(summary, "Tokens").value == "518k / 1M"
    assert metric(summary, "Tokens").title == "Tokens: 517,755 used; limit 1,000,000"
    assert metric(summary, "Attempts").value == "2 / 2"
    assert metric(summary, "Time").value == "3m 9s / 1h 0m"
  end

  test "active usage adds the current reservation once and ignores old candidate review" do
    task =
      task(%{hold: nil, handoff: %{"review" => %{"verdict" => "approve"}}})
      |> put_in([:ledger, "active"], %{"tokens" => 12_000, "started_at_ms" => 1})
      |> Map.put(:runtime, %{status: "running", started_at: past_time(12), tokens: %{total_tokens: 99_999}})

    before = DateTime.utc_now()
    summary = TaskExecution.summary(task, control())
    after_summary = DateTime.utc_now()
    assert summary.status == "Running"
    assert summary.cancel?
    refute summary.retry?
    assert metric(summary, "Tokens").title == "Tokens: 529,755 used; limit 1,000,000"
    assert metric(summary, "Attempts").value == "2 / 2"
    assert_elapsed(summary, task.runtime.started_at, before, after_summary, 189_000)
  end

  test "a reservation without a worker needs reconciliation and never uses wall clock age" do
    task = put_in(task(), [:ledger, "active"], %{"tokens" => 10, "started_at_ms" => 1})
    summary = TaskExecution.summary(task, control())
    assert summary.status == "Needs reconciliation"
    assert metric(summary, "Time").value == "— / 1h 0m"
    refute summary.cancel?
    refute summary.retry?
  end

  test "missing or malformed metrics stay unknown instead of becoming zero" do
    for ledger <- [%{}, %{"tokens" => "10", "attempts" => -1, "runtime_ms" => nil}] do
      summary = TaskExecution.summary(task(%{ledger: ledger, hold: "interrupted"}), control())
      assert metric(summary, "Tokens").value == "— / 1M"
      assert metric(summary, "Attempts").value == "— / 2"
      assert metric(summary, "Time").value == "— / 1h 0m"
      refute summary.retry?
    end

    summary = TaskExecution.summary(task(), Map.delete(control(), "settings"))
    assert metric(summary, "Tokens").value == "518k / —"
    assert metric(summary, "Attempts").title == "Attempts: 2 used; limit not reported"
  end

  test "an active reservation with unknown counters does not pretend settled totals are current" do
    task =
      task()
      |> put_in([:ledger, "active"], %{})
      |> Map.put(:runtime, %{status: "running"})

    summary = TaskExecution.summary(task, control())
    assert metric(summary, "Tokens").value == "— / 1M"
    assert metric(summary, "Time").value == "— / 1h 0m"
  end

  test "stale, missing and unhealthy sources preserve recorded usage but disable actions" do
    for control <- [
          Map.delete(control(), "revision"),
          Map.put(control(), "revision", -1),
          Map.put(control(), "fault", "unavailable"),
          Map.put(control(), "error", "disconnected")
        ] do
      summary = TaskExecution.summary(task(%{stage: "ready"}), control)
      assert summary.status == "Status unavailable"
      assert metric(summary, "Tokens").title =~ "Last recorded"
      refute summary.cancel?
      refute summary.retry?
    end

    assert TaskExecution.summary(task(), control(), true).status == "Status unavailable"
    assert TaskExecution.summary(task(%{source_missing: true}), control()).status == "Status unavailable"
  end

  test "done tasks have no execution actions even if old runtime data remains" do
    summary = TaskExecution.summary(task(%{stage: "done", runtime: %{status: "running"}}), control())
    assert summary.status == "Done"
    refute summary.cancel?
    refute summary.retry?
  end

  test "ready tasks show the controller mode while retries remain distinct" do
    for {mode, expected} <- [{"running", "Queued"}, {"paused", "Queued · paused"}, {"draining", "Queued · draining"}] do
      queued = put_in(task(%{stage: "ready"}), [:ledger, "attempts"], 1)
      summary = TaskExecution.summary(queued, Map.put(control(), "mode", mode))
      assert summary.status == expected
      assert summary.cancel?
      refute summary.retry?
    end

    summary = TaskExecution.summary(task(%{runtime: %{status: "retrying"}}), control())
    assert summary.status == "Retry scheduled"
    assert summary.cancel?
    refute summary.retry?
  end

  test "owner review verdicts never offer a retry that would omit review findings" do
    for {verdict, expected} <- [{"request_changes", "Changes requested"}, {"blocked", "Review blocked"}, {nil, "Review pending"}] do
      task = task(%{hold: "owner_review", handoff: %{"review" => %{"verdict" => verdict}}})
      summary = TaskExecution.summary(task, control())
      assert summary.status == expected
      assert is_binary(summary.note)
      refute summary.cancel?
      refute summary.retry?
    end
  end

  test "only held tasks with fully known remaining budgets can retry" do
    task = put_in(task(%{hold: "interrupted"}), [:ledger, "attempts"], 1)
    summary = TaskExecution.summary(task, control())
    assert summary.status == "Interrupted"
    assert summary.retry?
    refute summary.cancel?

    for {key, value, message} <- [
          {"attempts", 2, "Attempts limit reached"},
          {"tokens", 1_000_000, "Token limit reached"},
          {"runtime_ms", 3_600_000, "Time limit reached"}
        ] do
      summary = TaskExecution.summary(put_in(task, [:ledger, key], value), control())
      assert summary.note =~ message
      refute summary.retry?
    end

    summary = TaskExecution.summary(task, Map.delete(control(), "settings"))
    assert summary.note =~ "not fully reported"
    refute summary.retry?
  end

  test "input requests cannot be answered by retry" do
    for hold <- ["input_required", "needs_input", "approval_required"] do
      summary = TaskExecution.summary(task(%{hold: hold}), control())
      assert summary.status == "Needs input"
      refute summary.retry?
      refute summary.cancel?
    end

    assert TaskExecution.summary(task(%{runtime: %{status: "blocked"}}), control()).status == "Needs input"
  end

  test "worker authentication blocks coding separately and retry preserves remaining limits" do
    held = task(%{stage: "ready", hold: "worker_auth_required", ledger: %{"attempts" => 1, "tokens" => 10, "runtime_ms" => 50, "active" => nil}})
    summary = TaskExecution.summary(held, control())
    assert summary.status == "Worker sign-in required"
    assert summary.note =~ "credential ownership"
    assert summary.note =~ "Codex sign-in"
    assert summary.note =~ "Project chat remains available"
    assert summary.retry?
    refute summary.cancel?
    assert metric(summary, "Attempts").value == "1 / 2"

    exhausted = TaskExecution.summary(put_in(held, [:ledger, "attempts"], 2), control())
    assert exhausted.status == "Worker sign-in required"
    assert exhausted.note =~ "Attempts limit reached"
    refute exhausted.retry?

    unknown = TaskExecution.summary(%{held | ledger: %{}}, control())
    assert unknown.note =~ "confirmed usage and limits"
    refute unknown.retry?
    assert TaskExecution.summary(held, control(), true).status == "Status unavailable"
    assert TaskExecution.summary(%{held | stage: "done"}, control()).status == "Done"
    assert TaskExecution.summary(%{held | runtime: %{status: "running"}}, control()).status == "Running"
    assert TaskExecution.summary(put_in(held, [:ledger, "active"], %{}), control()).status == "Needs reconciliation"
    assert TaskExecution.summary(%{held | runtime: %{status: "blocked", error: "Worker sign-in required"}}, control()).retry?
  end

  test "legacy authentication retries never imply automatic recovery or offer an unsafe retry" do
    error = legacy_authentication_error()

    for status <- ["retrying", "blocked"], error <- [error, "Worker sign-in required"] do
      summary = TaskExecution.summary(task(%{stage: "ready", runtime: %{status: status, error: error}}), control())
      assert summary.status == "Worker sign-in required"
      assert summary.note =~ "Codex sign-in"
      refute summary.retry?
      refute summary.cancel?
      refute summary.note =~ "refresh token"
      assert TaskExecution.summary(task(%{runtime: %{status: status, error: error}}), %{"enabled" => false}).status == "Worker sign-in required"
    end
  end

  test "settled owner review wins over a normal completion continuation timer" do
    task = task(%{hold: "owner_review", handoff: %{"review" => %{"verdict" => "approve"}}, runtime: %{status: "retrying", due_at: past_time(0)}})
    summary = TaskExecution.summary(task, control())
    assert summary.status == "Awaiting your review"
    assert metric(summary, "Time").value == "3m 9s / 1h 0m"
    refute summary.cancel?
    refute summary.retry?

    active = put_in(task, [:ledger, "active"], %{"tokens" => 5})
    assert TaskExecution.summary(active, control()).status == "Retry scheduled"
    assert TaskExecution.summary(%{task | runtime: %{status: "running"}}, control()).status == "Running"
  end

  test "a ready task with exhausted usage cannot masquerade as waiting for a worker" do
    for {key, exhausted, message} <- [
          {"attempts", 2, "Attempts limit reached"},
          {"tokens", 1_000_000, "Token limit reached"},
          {"runtime_ms", 3_600_000, "Time limit reached"}
        ] do
      task = task(%{stage: "ready"}) |> put_in([:ledger, "attempts"], 1) |> put_in([:ledger, key], exhausted)
      summary = TaskExecution.summary(task, control())
      assert summary.status == "Limit reached"
      assert summary.note =~ message
      assert summary.cancel?
      refute summary.retry?
    end

    assert TaskExecution.summary(task(%{stage: "ready", ledger: %{}}), control()).status == "Queued"
  end

  test "disabled controls preserve running observability without inventing budgets or attempts" do
    task = task(%{ledger: %{}, runtime: %{status: "running", started_at: past_time(5), tokens: %{total_tokens: 500}}})
    summary = TaskExecution.summary(task, %{"enabled" => false})
    assert summary.status == "Running"
    assert metric(summary, "Tokens").value == "500"
    assert metric(summary, "Tokens").title == "Recorded · Tokens: 500"
    assert metric(summary, "Time").value =~ ~r/^\d+s$/
    refute metric(summary, "Attempts")
    refute summary.cancel?
    refute summary.retry?

    for {update, status} <- [
          {%{stage: "done"}, "Done"},
          {%{stage: "ready", runtime: nil}, "Queued"},
          {%{stage: "backlog", runtime: nil}, "Not queued"},
          {%{runtime: %{status: "retrying"}}, "Retry scheduled"}
        ] do
      summary = TaskExecution.summary(Map.merge(task, update), %{"enabled" => false})
      assert summary.status == status
      refute summary.cancel?
      refute summary.retry?
    end
  end

  test "disabling controls keeps durable records visible and stale upstream time does not grow" do
    summary = TaskExecution.summary(task(), %{"enabled" => false})
    assert metric(summary, "Tokens").value == "518k"
    assert metric(summary, "Attempts").value == "2"
    assert metric(summary, "Time").value == "3m 9s"

    runtime_task = task(%{ledger: %{}, runtime: %{status: "running", started_at: past_time(10), tokens: %{total_tokens: 500}}})

    for control <- [%{"enabled" => false, "error" => "disconnected"}, %{"enabled" => false, "fault" => "failed"}] do
      summary = TaskExecution.summary(runtime_task, control)
      assert summary.status == "Status unavailable"
      assert metric(summary, "Tokens").title == "Last recorded · Tokens: 500"
      refute metric(summary, "Time")
      refute summary.cancel?
    end

    assert TaskExecution.summary(runtime_task, %{"enabled" => false}, true).status == "Status unavailable"
    assert TaskExecution.summary(%{runtime_task | source_missing: true}, %{"enabled" => false}).status == "Status unavailable"

    active = put_in(runtime_task, [:ledger], %{"active" => %{"tokens" => 1}, "tokens" => 1, "runtime_ms" => 1})
    assert metric(TaskExecution.summary(active, control(), true), "Time").value == "— / 1h 0m"
  end

  test "running elapsed accepts DateTime, rejects invalid starts and clamps future clock skew" do
    task = put_in(task(), [:ledger, "active"], %{"tokens" => 0, "started_at_ms" => 1})
    started_at = DateTime.add(DateTime.utc_now(), -10, :second)
    before = DateTime.utc_now()
    summary = TaskExecution.summary(%{task | runtime: %{status: "running", started_at: started_at}}, control())
    assert_elapsed(summary, started_at, before, DateTime.utc_now(), 189_000)

    for invalid <- ["yesterday", nil, 123] do
      summary = TaskExecution.summary(%{task | runtime: %{status: "running", started_at: invalid}}, control())
      assert metric(summary, "Time").value == "— / 1h 0m"
    end

    summary = TaskExecution.summary(%{task | runtime: %{status: "running", started_at: DateTime.add(DateTime.utc_now(), 60, :second)}}, control())
    assert metric(summary, "Time").value == "3m 9s / 1h 0m"
  end

  test "malformed active state, unknown worker and controller modes do not enable actions" do
    summary = TaskExecution.summary(put_in(task(), [:ledger, "active"], "invalid"), control())
    assert summary.status == "Needs reconciliation"
    assert metric(summary, "Tokens").value == "— / 1M"

    summary = TaskExecution.summary(task(%{runtime: %{status: "unknown"}}), control())
    assert summary.status == "Status unavailable"
    refute summary.cancel?
    refute summary.retry?

    summary = TaskExecution.summary(task(%{stage: "ready", ledger: %{}}), Map.delete(control(), "mode"))
    assert summary.status == "Queued"
    assert summary.note == "Controller mode is not reported."
    refute summary.cancel?
  end

  test "cancelled and other recoverable holds retain remaining usage" do
    for {hold, status} <- [{"cancelled", "Cancelled"}, {"worker_failed", "Held"}] do
      task = put_in(task(%{hold: hold}), [:ledger, "attempts"], 1)
      summary = TaskExecution.summary(task, control())
      assert summary.status == status
      assert summary.retry?
    end

    assert TaskExecution.summary(task(), control()).status == "Not queued"
  end

  defp metric(summary, label), do: Enum.find(summary.metrics, &(&1.label == label))

  defp legacy_authentication_error do
    payload = {:turn_failed, %{"turn" => %{"error" => %{"codexErrorInfo" => "unauthorized", "message" => "Your access token could not be refreshed because your refresh token was revoked."}}}}
    exception = %RuntimeError{message: "Agent run failed for issue_id=2 issue_identifier=GH-2: #{inspect(payload)}"}
    "agent exited: #{inspect({exception, [{SymphonyElixir.AgentRunner, :run, 3, [file: "lib/private.ex", line: 44]}]})}"
  end

  defp past_time(seconds), do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

  defp assert_elapsed(summary, started_at, before, after_summary, settled) when is_binary(started_at) do
    {:ok, started_at, _offset} = DateTime.from_iso8601(started_at)
    assert_elapsed(summary, started_at, before, after_summary, settled)
  end

  defp assert_elapsed(summary, started_at, before, after_summary, settled) do
    [_, measured] = Regex.run(~r/Time: ([\d,]+) ms used/, metric(summary, "Time").title)
    measured = measured |> String.replace(",", "") |> String.to_integer()
    assert measured >= settled + DateTime.diff(before, started_at, :millisecond)
    assert measured <= settled + DateTime.diff(after_summary, started_at, :millisecond)
  end

  defp task(updates \\ %{}) do
    Map.merge(
      %{
        stage: "backlog",
        source_missing: false,
        runtime: nil,
        hold: nil,
        handoff: nil,
        ledger: %{"tokens" => 517_755, "attempts" => 2, "runtime_ms" => 189_000, "active" => nil}
      },
      updates
    )
  end

  defp control do
    %{
      "enabled" => true,
      "revision" => 5,
      "fault" => nil,
      "mode" => "running",
      "settings" => %{"budgets" => %{"max_attempts" => 2, "max_total_tokens" => 1_000_000, "max_total_runtime_ms" => 3_600_000}}
    }
  end
end
