defmodule SymphonyElixir.ControlLedgerTest do
  use ExUnit.Case
  alias SymphonyElixir.ControlLedger

  @work String.duplicate("a", 32)
  @base String.duplicate("a", 40)
  @head String.duplicate("b", 40)
  @work_context %{tracker_fingerprint: "retry-fixture", base_sha: @base, repository: "owner/repo"}

  defmodule Owner do
    use GenServer
    alias SymphonyElixir.ControlLedger
    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def init({settings, root}), do: ControlLedger.open(settings, root)
    def terminate(_, ledger), do: ControlLedger.close(ledger)
    def handle_call(:snapshot, _, ledger), do: {:reply, ControlLedger.snapshot(ledger), ledger}

    def handle_call({:command, params}, from, ledger), do: handle_call({:command, params, %{}}, from, ledger)

    def handle_call({:command, params, context}, _, ledger) do
      case ControlLedger.command(ledger, params, 5, context) do
        {:ok, next, reply, replay} -> {:reply, {:ok, reply, replay}, next}
        error -> {:reply, error, ledger}
      end
    end

    def handle_call({:tokens, id, run, total}, _, ledger) do
      case ControlLedger.tokens(ledger, id, run, total) do
        {:ok, next} -> {:reply, :ok, next}
        error -> {:reply, error, ledger}
      end
    end

    def handle_call({:checkpoint, id, run, work, attrs}, _, ledger) do
      case ControlLedger.checkpoint_pr_work(ledger, id, run, work, attrs) do
        {:ok, next} -> {:reply, :ok, next}
        error -> {:reply, error, ledger}
      end
    end

    def handle_call({:reserve, id}, _, ledger) do
      case ControlLedger.reserve(ledger, id) do
        {:ok, next, run, remaining} -> {:reply, {:ok, run, remaining}, next}
        error -> {:reply, error, ledger}
      end
    end

    def handle_call({:finish, id, run, hold}, from, ledger), do: handle_call({:finish, id, run, hold, nil}, from, ledger)

    def handle_call({:finish, id, run, hold, evidence}, _, ledger) do
      case ControlLedger.finish(ledger, id, run, hold, evidence) do
        {:ok, next} -> {:reply, :ok, next}
        error -> {:reply, error, ledger}
      end
    end
  end

  setup do
    {:ok, temporary_root} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(temporary_root, "symphony-control-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    settings = %{
      enabled: true,
      state_path: root <> "/control.json",
      initial_mode: "paused",
      max_attempts: 2,
      max_total_runtime_ms: 1_000,
      max_total_tokens: 100
    }

    %{settings: settings, workspace: root <> "/workspaces"}
  end

  defp command(action, revision, id \\ nil, command_id \\ nil) do
    %{"command_id" => command_id || "#{action}-#{revision}", "action" => action, "expected_revision" => revision, "issue_id" => id}
  end

  defp renew(revision, id \\ "7", key \\ nil), do: Map.put(command("retry", revision, id, key), "renew_attempts", true)

  defp issue(attrs \\ %{}), do: Map.merge(%{"attempts" => 2, "attempt_base" => 0, "runtime_ms" => 100, "tokens" => 23, "hold" => "interrupted", "active" => nil}, attrs)

  defp seed_issues(pid, issues) do
    :sys.replace_state(pid, fn ledger ->
      data = Map.put(ledger.data, "issues", issues)
      File.write!(ledger.path, Jason.encode!(data))
      %{ledger | data: data}
    end)
  end

  defp assert_rejected_without_change(pid, path, params, reason) do
    snapshot = GenServer.call(pid, :snapshot)
    bytes = File.read!(path)
    assert {:error, ^reason} = GenServer.call(pid, {:command, params})
    assert GenServer.call(pid, :snapshot) == snapshot
    assert File.read!(path) == bytes
  end

  defp create_work(revision) do
    Map.merge(command("create_pr_work", revision, "7"), %{"work_id" => @work, "base_sha" => @base, "instruction" => "Recover the existing scoped work"})
  end

  defp reviewed_handoff(run) do
    %{
      "run_id" => run,
      "work_id" => @work,
      "expected_head_sha" => nil,
      "goal_revision" => 1,
      "candidate_sha" => @head,
      "base_sha" => @base,
      "branch" => "codex/gh-7-#{@work}",
      "builder_session_id" => "retained-builder-turn",
      "reviewer_session_id" => "independent-review-turn",
      "review" => %{"candidate_sha" => @head, "verdict" => "approve", "findings" => []}
    }
  end

  test "commands persist, replay once and reject stale or conflicting writes", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert %{"mode" => "paused", "revision" => 0} = GenServer.call(pid, :snapshot)
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
    resume = command("resume", 0)
    assert {:ok, %{"revision" => 1}, false} = GenServer.call(pid, {:command, resume})
    assert {:ok, %{"revision" => 1}, true} = GenServer.call(pid, {:command, resume})
    assert {:error, :command_id_conflict} = GenServer.call(pid, {:command, %{resume | "action" => "pause"}})
    assert {:error, :revision_conflict} = GenServer.call(pid, {:command, command("pause", 0)})
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("drain", 1)})
    stop_supervised!(Owner)
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert %{"mode" => "draining", "revision" => 2} = GenServer.call(pid, :snapshot)
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
  end

  test "concurrency overrides survive restart and receipts retain the exact requested limit", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert ControlLedger.effective_concurrency(nil, 5) == 5
    set = Map.put(command("set_concurrency", 0), "limit", 3)
    assert {:ok, %{"limit" => 3, "revision" => 1}, false} = GenServer.call(pid, {:command, set})
    assert {:error, :command_id_conflict} = GenServer.call(pid, {:command, %{set | "limit" => 2}})
    assert {:error, :revision_conflict} = GenServer.call(pid, {:command, Map.put(set, "command_id", "stale")})
    assert {:error, :concurrency_limit_exceeded} = GenServer.call(pid, {:command, Map.put(command("set_concurrency", 1), "limit", 6)})
    ledger = :sys.get_state(pid)
    assert ControlLedger.effective_concurrency(ledger, 5) == 3
    assert ControlLedger.effective_concurrency(ledger, 2) == 2
    stop_supervised!(Owner)
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert %{"concurrency_override" => 3, "revision" => 1} = GenServer.call(pid, :snapshot)
    assert {:ok, %{"limit" => 3}, true} = GenServer.call(pid, {:command, set})
    assert {:ok, %{"limit" => nil}, false} = GenServer.call(pid, {:command, Map.put(command("set_concurrency", 1), "limit", nil)})
    assert %{"concurrency_override" => nil} = GenServer.call(pid, :snapshot)
    assert ControlLedger.effective_concurrency(:sys.get_state(pid), 4) == 4
  end

  test "legacy state loads without override; malformed overrides and settings commands fail closed", ctx do
    legacy = %{"version" => 1, "revision" => 0, "mode" => "paused", "issues" => %{}, "commands" => %{}}
    File.write!(ctx.settings.state_path, Jason.encode!(legacy))
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert ControlLedger.effective_concurrency(:sys.get_state(pid), 5) == 5

    for params <-
          [command("set_concurrency", 0), Map.put(command("set_concurrency", 0, "7"), "limit", 1), Map.put(command("pause", 0), "limit", 1)] ++
            Enum.map([0, -1, "2", 1.5, true], &Map.put(command("set_concurrency", 0), "limit", &1)) do
      assert {:error, :invalid_command} = GenServer.call(pid, {:command, params})
    end

    assert %{"revision" => 0} = GenServer.call(pid, :snapshot)
    stop_supervised!(Owner)

    for invalid <- [0, -1, "2", false, %{}] do
      File.write!(ctx.settings.state_path, Jason.encode!(Map.put(legacy, "concurrency_override", invalid)))
      assert {:error, :invalid_control_state} = ControlLedger.open(ctx.settings, ctx.workspace)
    end
  end

  test "cancel and manual retry preserve total attempt budget and fence stale completions", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert {:ok, _, _} = GenServer.call(pid, {:command, command("resume", 0)})
    assert {:ok, run, _} = GenServer.call(pid, {:reserve, "7"})
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
    assert {:ok, _, _} = GenServer.call(pid, {:command, command("cancel", 1, "7")})
    assert :ok = GenServer.call(pid, {:finish, "7", run, nil})
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
    assert {:ok, _, _} = GenServer.call(pid, {:command, command("retry", 2, "7")})
    assert {:ok, run2, _} = GenServer.call(pid, {:reserve, "7"})
    assert {:error, :stale_run} = GenServer.call(pid, {:finish, "7", run, nil})
    assert :ok = GenServer.call(pid, {:finish, "7", run2, nil})
    assert {:error, :budget_exhausted} = GenServer.call(pid, {:command, command("retry", 3, "7")})
  end

  test "explicit renewal grants one bounded attempt cycle while retaining lifetime usage and other issues", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("resume", 0)})

    assert {:ok, other_run, _} = GenServer.call(pid, {:reserve, "8"})
    assert :ok = GenServer.call(pid, {:tokens, "8", other_run, 9})
    assert :ok = GenServer.call(pid, {:finish, "8", other_run, "cancelled"})

    for tokens <- [7, 11] do
      assert {:ok, run, _} = GenServer.call(pid, {:reserve, "7"})
      assert :ok = GenServer.call(pid, {:tokens, "7", run, tokens})
      assert :ok = GenServer.call(pid, {:finish, "7", run, nil})
    end

    before = GenServer.call(pid, :snapshot)
    assert %{"attempts" => 2, "cycle_attempts" => 2, "tokens" => 18} = before["issues"]["7"]
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
    assert_rejected_without_change(pid, ctx.settings.state_path, command("retry", 1, "7"), :budget_exhausted)
    assert_rejected_without_change(pid, ctx.settings.state_path, Map.put(command("retry", 1, "7"), "renew_attempts", false), :budget_exhausted)

    assert {:ok, %{"revision" => 2, "renew_attempts" => true}, false} = GenServer.call(pid, {:command, renew(1)})
    renewed = GenServer.call(pid, :snapshot)
    assert %{"attempts" => 2, "attempt_base" => 2, "cycle_attempts" => 0, "hold" => nil} = renewed["issues"]["7"]
    assert Map.drop(renewed["issues"]["7"], ~w(attempt_base cycle_attempts hold)) == Map.drop(before["issues"]["7"], ~w(attempt_base cycle_attempts hold))
    assert renewed["issues"]["8"] == before["issues"]["8"]
    assert :sys.get_state(pid).settings == ctx.settings

    for _ <- 1..ctx.settings.max_attempts do
      prior = GenServer.call(pid, :snapshot)["issues"]["7"]
      assert {:ok, run, remaining} = GenServer.call(pid, {:reserve, "7"})
      assert remaining == ctx.settings.max_total_runtime_ms - prior["runtime_ms"]
      assert :ok = GenServer.call(pid, {:finish, "7", run, nil})
    end

    assert %{"attempts" => 4, "attempt_base" => 2, "cycle_attempts" => 2, "tokens" => 18} = GenServer.call(pid, :snapshot)["issues"]["7"]
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
    assert_rejected_without_change(pid, ctx.settings.state_path, command("retry", 2, "7"), :budget_exhausted)
  end

  test "renewal survives restart and exact replay cannot renew another cycle", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    seed_issues(pid, %{"7" => issue(%{"attempts" => 5, "attempt_base" => 3}), "8" => issue(%{"tokens" => 67, "hold" => "cancelled"})})
    params = renew(0, "7", "renew-existing-cycle")
    assert {:ok, %{"revision" => 1, "mode" => "paused", "renew_attempts" => true} = receipt, false} = GenServer.call(pid, {:command, params})
    expected = GenServer.call(pid, :snapshot)
    assert expected["issues"]["7"]["attempt_base"] == 5
    stop_supervised!(Owner)
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert GenServer.call(pid, :snapshot) == expected
    bytes = File.read!(ctx.settings.state_path)
    assert {:ok, ^receipt, true} = GenServer.call(pid, {:command, params})
    assert GenServer.call(pid, :snapshot) == expected
    assert File.read!(ctx.settings.state_path) == bytes
    assert_rejected_without_change(pid, ctx.settings.state_path, %{params | "renew_attempts" => false}, :command_id_conflict)
    assert_rejected_without_change(pid, ctx.settings.state_path, %{params | "command_id" => "different-stale-key"}, :revision_conflict)
    assert_rejected_without_change(pid, ctx.settings.state_path, renew(1), :attempts_not_exhausted)
  end

  test "premature renewal is rejected while default and false retry retain ordinary behavior", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert_rejected_without_change(pid, ctx.settings.state_path, renew(0), :attempts_not_exhausted)
    row = issue(%{"attempts" => 4, "attempt_base" => 3})
    seed_issues(pid, %{"7" => row, "8" => row})
    assert_rejected_without_change(pid, ctx.settings.state_path, renew(0), :attempts_not_exhausted)
    assert {:ok, receipt, false} = GenServer.call(pid, {:command, command("retry", 0, "7")})
    refute receipt["renew_attempts"]
    assert {:ok, receipt, false} = GenServer.call(pid, {:command, Map.put(command("retry", 1, "8"), "renew_attempts", false)})
    refute receipt["renew_attempts"]

    for id <- ["7", "8"] do
      assert %{"attempts" => 4, "attempt_base" => 3, "cycle_attempts" => 1, "tokens" => 23, "runtime_ms" => 100, "hold" => nil} = GenServer.call(pid, :snapshot)["issues"][id]
    end
  end

  test "renewal cannot bypass active work, acceptance, lifetime budgets or legacy review", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})

    acceptance = %{
      "command_id" => "human-acceptance",
      "tracker_fingerprint" => "retry-fixture",
      "candidate_sha" => @head,
      "tracker_state" => "closed",
      "issue_updated_at" => "2026-10-04T00:00:00Z",
      "accepted_at" => "2026-10-04T00:00:00Z"
    }

    active = %{"run_id" => "owned-active-run", "started_at_ms" => System.system_time(:millisecond), "tokens" => 0}

    for {attrs, reason} <- [
          {%{"active" => active}, :issue_running},
          {%{"acceptance" => acceptance, "hold" => "accepted"}, :task_already_accepted},
          {%{"tokens" => ctx.settings.max_total_tokens}, :budget_exhausted},
          {%{"runtime_ms" => ctx.settings.max_total_runtime_ms}, :budget_exhausted},
          {%{"hold" => "owner_review", "handoff" => %{"candidate_sha" => @head}}, :pr_work_continuation_required}
        ] do
      seed_issues(pid, %{"7" => issue(attrs), "8" => issue(%{"tokens" => 41})})
      assert_rejected_without_change(pid, ctx.settings.state_path, renew(0), reason)
    end
  end

  test "renewal requeues the same paused PR work without changing its retained builder identity", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("resume", 0)})
    assert {:ok, _, false} = GenServer.call(pid, {:command, create_work(1), @work_context})
    assert {:ok, first, _} = GenServer.call(pid, {:reserve, "7"})
    assert :ok = GenServer.call(pid, {:checkpoint, "7", first, @work, %{"builder_thread_id" => "retained-builder"}})
    assert :ok = GenServer.call(pid, {:tokens, "7", first, 7})
    assert :ok = GenServer.call(pid, {:finish, "7", first, "auth_required"})
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("retry", 2, "7")})
    assert {:ok, second, _} = GenServer.call(pid, {:reserve, "7"})
    assert :ok = GenServer.call(pid, {:checkpoint, "7", second, @work, %{"working_head_sha" => @head}})
    assert :ok = GenServer.call(pid, {:tokens, "7", second, 11})
    assert :ok = GenServer.call(pid, {:finish, "7", second, "interrupted"})
    before = GenServer.call(pid, :snapshot)["issues"]["7"]
    assert before["pr_work"][@work]["phase"] == "paused"
    assert {:ok, %{"revision" => 4}, false} = GenServer.call(pid, {:command, renew(3)})
    renewed = GenServer.call(pid, :snapshot)["issues"]["7"]
    assert renewed["hold"] == nil
    assert renewed["attempt_base"] == 2
    assert renewed["selected_work_id"] == @work
    assert renewed["pr_work"][@work]["phase"] == "queued"
    assert Map.drop(renewed["pr_work"][@work], ~w(phase updated_at)) == Map.drop(before["pr_work"][@work], ~w(phase updated_at))
    assert Map.drop(renewed, ~w(attempt_base cycle_attempts hold pr_work)) == Map.drop(before, ~w(attempt_base cycle_attempts hold pr_work))

    stop_supervised!(Owner)
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert GenServer.call(pid, :snapshot)["issues"]["7"] == renewed
    assert {:ok, third, _} = GenServer.call(pid, {:reserve, "7"})
    assert GenServer.call(pid, :snapshot)["issues"]["7"]["active"]["work_id"] == @work
    assert {:error, :stale_run} = GenServer.call(pid, {:finish, "7", second, nil})
    assert :ok = GenServer.call(pid, {:finish, "7", third, nil})
  end

  test "renewal cannot reopen a reviewed PR even after its attempt cycle is exhausted", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("resume", 0)})
    assert {:ok, _, false} = GenServer.call(pid, {:command, create_work(1), @work_context})
    assert {:ok, first, _} = GenServer.call(pid, {:reserve, "7"})
    assert :ok = GenServer.call(pid, {:checkpoint, "7", first, @work, %{"builder_thread_id" => "retained-builder"}})
    assert :ok = GenServer.call(pid, {:finish, "7", first, nil})
    assert {:ok, second, _} = GenServer.call(pid, {:reserve, "7"})
    assert :ok = GenServer.call(pid, {:finish, "7", second, "owner_review", reviewed_handoff(second)})
    assert GenServer.call(pid, :snapshot)["issues"]["7"]["cycle_attempts"] == 2
    assert_rejected_without_change(pid, ctx.settings.state_path, renew(2), :pr_work_continuation_required)
    assert GenServer.call(pid, :snapshot)["issues"]["7"]["pr_work"][@work]["head_sha"] == @head
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("cancel", 2, "7")})
    assert GenServer.call(pid, :snapshot)["issues"]["7"]["hold"] == "cancelled"
    assert_rejected_without_change(pid, ctx.settings.state_path, renew(3), :pr_work_continuation_required)
    assert GenServer.call(pid, :snapshot)["issues"]["7"]["pr_work"][@work]["phase"] == "owner_review"
  end

  test "baseline recovery selects fresh work while preserving the hold and lifetime evidence until explicit retry", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    evidence = reviewed_handoff("retained-run") |> Map.drop(~w(work_id expected_head_sha goal_revision))
    retained = issue(%{"hold" => "workspace_baseline_changed", "handoff" => evidence})
    seed_issues(pid, %{"7" => retained})

    assert_rejected_without_change(pid, ctx.settings.state_path, command("retry", 0, "7"), :budget_exhausted)
    create = create_work(0)
    assert {:ok, %{"revision" => 1}, false} = GenServer.call(pid, {:command, create, @work_context})
    created = GenServer.call(pid, :snapshot)["issues"]["7"]
    assert created["hold"] == "workspace_baseline_changed"
    assert created["attempt_base"] == retained["attempts"]
    assert created["cycle_attempts"] == 0
    assert Map.take(created, ~w(attempts tokens runtime_ms)) == Map.take(retained, ~w(attempts tokens runtime_ms))
    assert created["legacy_handoff"] == evidence
    assert created["pr_work"][@work]["workspace_key"] != "GH-7"
    assert created["pr_work"][@work]["base_sha"] == @base
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
    assert {:ok, _, true} = GenServer.call(pid, {:command, create, @work_context})
    assert GenServer.call(pid, :snapshot)["issues"]["7"] == created

    retry = command("retry", 1, "7")
    assert {:ok, %{"revision" => 2}, false} = GenServer.call(pid, {:command, retry})
    released = GenServer.call(pid, :snapshot)["issues"]["7"]
    assert released["hold"] == nil
    assert Map.drop(released, ~w(hold)) == Map.drop(created, ~w(hold))
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})

    stop_supervised!(Owner)
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert GenServer.call(pid, :snapshot)["issues"]["7"] == released
    assert {:ok, %{"revision" => 3}, false} = GenServer.call(pid, {:command, command("resume", 2)})
    assert {:ok, run, _} = GenServer.call(pid, {:reserve, "7"})
    assert GenServer.call(pid, :snapshot)["issues"]["7"]["active"]["work_id"] == @work
    assert :ok = GenServer.call(pid, {:finish, "7", run, "cancelled"})
  end

  test "cancelling a legacy reviewed candidate cannot hide its continuation requirement", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("resume", 0)})
    assert {:ok, first, _} = GenServer.call(pid, {:reserve, "7"})
    assert :ok = GenServer.call(pid, {:finish, "7", first, nil})
    assert {:ok, second, _} = GenServer.call(pid, {:reserve, "7"})
    evidence = reviewed_handoff(second) |> Map.drop(~w(work_id expected_head_sha goal_revision))
    assert :ok = GenServer.call(pid, {:finish, "7", second, "owner_review", evidence})
    assert_rejected_without_change(pid, ctx.settings.state_path, renew(1), :pr_work_continuation_required)
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("cancel", 1, "7")})
    before = GenServer.call(pid, :snapshot)
    assert before["issues"]["7"]["hold"] == "cancelled"
    assert before["issues"]["7"]["handoff"] == evidence
    assert_rejected_without_change(pid, ctx.settings.state_path, renew(2), :pr_work_continuation_required)
    assert GenServer.call(pid, :snapshot)["issues"]["7"]["handoff"] == evidence
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
  end

  test "attempt renewal accepts only booleans on retry and rejects unrelated command fields", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    seed_issues(pid, %{"7" => issue()})

    for value <- [nil, "true", "false", 0, 1, [], %{}] do
      assert_rejected_without_change(pid, ctx.settings.state_path, Map.put(command("retry", 0, "7"), "renew_attempts", value), :invalid_command)
    end

    for params <- [command("resume", 0), command("cancel", 0, "7"), Map.put(command("set_concurrency", 0), "limit", 2)] do
      assert_rejected_without_change(pid, ctx.settings.state_path, Map.put(params, "renew_attempts", true), :invalid_command)
    end
  end

  test "restart retains interrupted attempt and pauses before dispatch", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    GenServer.call(pid, {:command, command("resume", 0)})
    {:ok, _, _} = GenServer.call(pid, {:reserve, "7"})
    stop_supervised!(Owner)
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert %{"mode" => "paused", "issues" => %{"7" => %{"hold" => "interrupted", "attempts" => 1, "active" => nil}}} = GenServer.call(pid, :snapshot)
  end

  test "live accounting ignores wall-clock rollback and unknown restart consumes reservation", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    GenServer.call(pid, {:command, command("resume", 0)})
    {:ok, run, _} = GenServer.call(pid, {:reserve, "7"})

    :sys.replace_state(pid, fn ledger ->
      data =
        ledger.data
        |> put_in(["issues", "7", "active", "started_at_ms"], System.system_time(:millisecond) + 60_000)
        |> put_in(["issues", "7", "active", "started_monotonic_ms"], System.monotonic_time(:millisecond) - 300)

      %{ledger | data: data}
    end)

    assert :ok = GenServer.call(pid, {:finish, "7", run, nil})
    assert %{"issues" => %{"7" => %{"runtime_ms" => runtime}}} = GenServer.call(pid, :snapshot)
    assert runtime >= 300
    {:ok, _, _} = GenServer.call(pid, {:reserve, "8"})
    stop_supervised!(Owner)
    data = ctx.settings.state_path |> File.read!() |> Jason.decode!() |> put_in(["issues", "8", "active", "runtime_epoch"], "previous-runtime")
    File.write!(ctx.settings.state_path, Jason.encode!(data))
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert %{"issues" => %{"8" => %{"runtime_ms" => 1_000, "hold" => "interrupted"}}} = GenServer.call(pid, :snapshot)
    assert {:error, :budget_exhausted} = GenServer.call(pid, {:command, command("retry", 1, "8")})
  end

  test "second owner rejected; corrupt file and workspace-contained ledger fail closed", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert {:error, :control_state_locked} = ControlLedger.open(ctx.settings, ctx.workspace)
    assert %{"revision" => 0} = GenServer.call(pid, :snapshot)
    stop_supervised!(Owner)
    File.write!(ctx.settings.state_path, "{broken")
    assert {:error, :invalid_control_state} = ControlLedger.open(ctx.settings, ctx.workspace)
    inside = %{ctx.settings | state_path: ctx.workspace <> "/control.json"}
    assert {:error, :control_state_inside_workspace} = ControlLedger.open(inside, ctx.workspace)
  end

  test "invalid commands and retry of a running issue leave the durable revision unchanged", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})

    for params <- [%{}, command("launch", 0), command("cancel", 0), command("pause", 0, "7")] do
      assert {:error, :invalid_command} = GenServer.call(pid, {:command, params})
    end

    assert %{"revision" => 0, "issues" => %{}} = GenServer.call(pid, :snapshot)
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("resume", 0)})
    assert {:ok, run, _} = GenServer.call(pid, {:reserve, "7"})
    assert {:error, :issue_running} = GenServer.call(pid, {:command, command("retry", 1, "7")})
    assert %{"revision" => 1, "issues" => %{"7" => %{"active" => %{"run_id" => ^run}}}} = GenServer.call(pid, :snapshot)
  end

  test "corrupt schema versions, command receipts, issue counters and active reservations fail closed", ctx do
    valid = %{"version" => 1, "revision" => 0, "mode" => "paused", "issues" => %{}, "commands" => %{}}
    issue = %{"attempts" => 0, "runtime_ms" => 0, "tokens" => 0, "hold" => nil, "active" => %{}}

    for data <- [
          %{valid | "version" => 2},
          %{valid | "commands" => %{"bad" => %{}}},
          %{valid | "issues" => %{"7" => %{}}},
          %{valid | "issues" => %{"7" => issue}},
          %{valid | "issues" => %{"7" => %{issue | "tokens" => -1}}}
        ] do
      File.write!(ctx.settings.state_path, Jason.encode!(data))
      assert {:error, :invalid_control_state} = ControlLedger.open(ctx.settings, ctx.workspace)
    end

    File.rm!(ctx.settings.state_path)
    File.mkdir!(ctx.settings.state_path)
    assert {:error, :unreadable_control_state} = ControlLedger.open(ctx.settings, ctx.workspace)
  end

  test "state path, ancestor and lock symlinks cannot redirect ledger writes", ctx do
    root = Path.dirname(ctx.settings.state_path)
    assert {:error, :missing_control_state_path} = ControlLedger.open(%{ctx.settings | state_path: nil}, ctx.workspace)
    File.ln_s!(root, root <> "/alias")
    via_parent = %{ctx.settings | state_path: root <> "/alias/control.json"}
    assert {:error, :control_path_symlink} = ControlLedger.open(via_parent, ctx.workspace)

    for path <- [ctx.settings.state_path, ctx.settings.state_path <> ".lock"] do
      File.ln_s!(root <> "/target", path)
      assert {:error, :control_path_symlink} = ControlLedger.open(ctx.settings, ctx.workspace)
      File.rm!(path)
    end

    refute File.exists?(root <> "/target")
  end

  test "loss of the state directory rejects writes and leaves the last durable receipt intact", ctx do
    parent = Path.join(Path.dirname(ctx.settings.state_path), "state")
    settings = %{ctx.settings | state_path: parent <> "/control.json"}
    {:ok, ledger} = ControlLedger.open(settings, ctx.workspace)
    on_exit(fn -> ControlLedger.close(ledger) end)
    File.rename!(parent, parent <> ".retained")
    assert {:error, {:control_persistence, :enoent}} = ControlLedger.command(ledger, command("resume", 0))
    assert %{"revision" => 0, "mode" => "paused"} = Jason.decode!(File.read!(parent <> ".retained/control.json"))
  end

  test "missing lock runtime and missing handshake fail closed, including an unresponsive lock process", ctx do
    before_path = System.get_env("PATH")
    python = System.find_executable("python3")
    bin = Path.join(Path.dirname(ctx.settings.state_path), "bin")
    File.mkdir!(bin)
    on_exit(fn -> SymphonyElixir.TestSupport.restore_env("PATH", before_path) end)
    System.put_env("PATH", bin)
    assert {:error, :python3_required_for_control_lock} = ControlLedger.open(ctx.settings, ctx.workspace)

    # A helper that never acknowledges the lock and ignores the close request
    # must be disconnected within the handshake plus shutdown deadlines.
    File.write!(bin <> "/python3", "#!#{python}\nimport sys\nsys.stdin.buffer.read()\n")
    File.chmod!(bin <> "/python3", 0o700)
    started = System.monotonic_time(:millisecond)
    assert {:error, :control_lock_timeout} = ControlLedger.open(ctx.settings, ctx.workspace)
    assert System.monotonic_time(:millisecond) - started < 8_000
    refute File.exists?(ctx.settings.state_path)
  end

  test "closing an already exited lock owner is safe" do
    port = Port.open({:spawn_executable, System.find_executable("true")}, [:exit_status])
    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert :ok = ControlLedger.close(%ControlLedger{lock: port})
  end
end
