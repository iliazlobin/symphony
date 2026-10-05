defmodule SymphonyElixir.ControlOrchestratorTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  alias SymphonyElixir.ControlLedger
  alias SymphonyElixirWeb.{ControlApiController, Endpoint}
  @endpoint Endpoint

  setup do
    {:ok, temporary_root} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(temporary_root, "symphony-control-otp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow = root <> "/WORKFLOW.md"

    config = %{
      tracker: %{kind: "memory", active_states: ["open"], terminal_states: ["closed"], required_labels: ["ready"]},
      workspace: %{root: root <> "/workspaces"},
      polling: %{interval_ms: 60_000},
      agent: %{max_concurrent_agents: 3},
      observability: %{dashboard_enabled: false},
      control: %{
        enabled: true,
        state_path: root <> "/control.json",
        initial_mode: "paused",
        max_attempts: 2,
        max_total_runtime_ms: 5_000,
        max_total_tokens: 100
      }
    }

    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(workflow)
    issue = %Issue{id: "7", identifier: "GH-7", title: "Controlled fixture", state: "open", labels: ["ready"], dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    supervisor = start_supervised!({Task.Supervisor, []})
    name = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor})
    on_exit(fn -> File.rm_rf(root) end)
    %{pid: pid, issue: issue, supervisor: supervisor, workflow: workflow, config: config}
  end

  test "concurrency settings retain active work and budgets while lowering admission capacity", ctx do
    {worker, run} = seed_owned_worker(ctx)

    :sys.replace_state(ctx.pid, fn state ->
      {:ok, ledger} = ControlLedger.tokens(state.control, ctx.issue.id, run, 37)
      %{state | control: ledger}
    end)

    before = Orchestrator.control_snapshot(ctx.pid)
    set = %{"command_id" => "settings", "expected_revision" => 1, "action" => "set_concurrency", "limit" => 1, "issue_id" => nil}
    assert {:ok, %{"revision" => 2, "limit" => 1}} = Orchestrator.control_command(set, ctx.pid)
    assert Process.alive?(worker)
    snapshot = Orchestrator.control_snapshot(ctx.pid)
    assert snapshot["issues"] == before["issues"]
    assert snapshot["settings"]["concurrency"] == %{"effective" => 1, "default" => 3, "ceiling" => 3, "override" => 1}
    assert snapshot["settings"]["budgets"] == %{"max_attempts" => 2, "max_total_runtime_ms" => 5_000, "max_total_tokens" => 100}
    assert snapshot["fault"] == nil
    assert {:ok, %{"limit" => 1}} = Orchestrator.control_receipt_guarded(set, Orchestrator.tracker_fingerprint(), ctx.pid)
    assert {:error, :command_id_conflict} = Orchestrator.control_receipt_guarded(%{set | "limit" => 2}, Orchestrator.tracker_fingerprint(), ctx.pid)
    other = %{ctx.issue | id: "8", identifier: "GH-8"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [ctx.issue, other])
    send(ctx.pid, :run_poll_cycle)
    assert %{"issues" => issues} = Orchestrator.control_snapshot(ctx.pid)
    assert Map.keys(issues) == ["7"]
    assert Process.alive?(worker)
  end

  test "changed admission ceiling clamps retained overrides and validates commands against fresh config", ctx do
    set = %{"command_id" => "settings", "expected_revision" => 0, "action" => "set_concurrency", "limit" => 3}
    assert {:ok, _} = Orchestrator.control_command(set, ctx.pid)
    updated = put_in(ctx.config, [:agent, :max_concurrent_agents], 2)
    File.write!(ctx.workflow, "---\n" <> Jason.encode!(updated) <> "\n---\nTask")
    Workflow.set_workflow_file_path(ctx.workflow)
    assert {:error, :concurrency_limit_exceeded} = Orchestrator.control_command(%{set | "command_id" => "too-high", "expected_revision" => 1}, ctx.pid)
    assert %{"fault" => nil, "settings" => %{"concurrency" => %{"effective" => 2, "override" => 3, "ceiling" => 2}}} = Orchestrator.control_snapshot(ctx.pid)
    assert {:ok, %{"replayed" => true}} = Orchestrator.control_command(set, ctx.pid)
    reset = %{set | "command_id" => "reset", "expected_revision" => 1, "limit" => nil}
    assert {:ok, _} = Orchestrator.control_command(reset, ctx.pid)
    assert %{"settings" => %{"concurrency" => %{"effective" => 2, "override" => nil}}} = Orchestrator.control_snapshot(ctx.pid)
  end

  test "failed settings persistence keeps its previous receipt and blocks admission", ctx do
    path = :sys.get_state(ctx.pid).control.path
    File.rename!(path, path <> ".saved")
    File.mkdir!(path)
    set = %{"command_id" => "failed-settings", "expected_revision" => 0, "action" => "set_concurrency", "limit" => 1}
    assert {:error, :control_unavailable} = Orchestrator.control_command(set, ctx.pid)
    snapshot = Orchestrator.control_snapshot(ctx.pid)
    assert snapshot["revision"] == 0
    assert snapshot["settings"]["concurrency"]["override"] == nil
    assert is_binary(snapshot["fault"])
    assert {:error, :control_unavailable} = Orchestrator.control_command(set, ctx.pid)
  end

  test "native dispatch revalidation uses local human acceptance and rejects fresh dependency changes", ctx do
    tracker = %{
      kind: "github",
      provider: %{repo: "owner/repo", token: "fixture-token"},
      active_states: ["open"],
      terminal_states: ["closed"],
      required_labels: ["ready"]
    }

    config = Map.put(ctx.config, :tracker, tracker)
    File.write!(ctx.workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(ctx.workflow)
    candidate = %{ctx.issue | description: "Depends on: #8 (technical: schema)", native_ref: %{"repo" => "owner/repo"}, updated_at: ~U[2026-10-01 10:00:00Z]}
    read = fn ["7"] -> {:ok, [candidate]} end
    state = :sys.get_state(ctx.pid)
    assert {:skip, _} = Orchestrator.revalidate_issue_for_dispatch_for_test(candidate, read, state)

    acceptance = %{
      "command_id" => "human-accept-8",
      "tracker_fingerprint" => "previous-config",
      "project_id" => "github:owner/repo",
      "candidate_sha" => nil,
      "tracker_state" => "closed",
      "issue_updated_at" => "2026-10-01T09:00:00Z",
      "accepted_at" => "2026-10-01T09:10:00Z"
    }

    item = %{"attempts" => 0, "runtime_ms" => 0, "tokens" => 0, "hold" => "accepted", "active" => nil, "acceptance" => acceptance}

    :sys.replace_state(ctx.pid, fn state ->
      data = put_in(state.control.data, ["issues", "8"], item)
      %{state | control: %{state.control | data: data}}
    end)

    state = :sys.get_state(ctx.pid)

    assert {:ok, %Issue{dispatchable: true, dependencies: [%{"issue_id" => "8"}]}} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(candidate, read, state)

    changed = %{candidate | description: "Depends on: #9"}
    changed_read = fn ["7"] -> {:ok, [changed]} end
    assert {:skip, _} = Orchestrator.revalidate_issue_for_dispatch_for_test(candidate, changed_read, state)
    acceptance_path = [Access.key(:control), Access.key(:data), "issues", "8", "acceptance", "project_id"]
    foreign = put_in(state, acceptance_path, "github:other/repo")
    assert {:skip, _} = Orchestrator.revalidate_issue_for_dispatch_for_test(candidate, read, foreign)
    assert Orchestrator.control_snapshot(ctx.pid)["issues"]["8"]["attempts"] == 0
    assert :sys.get_state(ctx.pid).running == %{}
  end

  test "routed settings API validates limits and retains idempotent receipts", ctx do
    token = start_control_endpoint(ctx.pid)
    set = %{"command_id" => "api-settings", "expected_revision" => 0, "action" => "set_concurrency", "limit" => 4}
    assert %{"error" => %{"code" => "concurrency_limit_exceeded"}} = json_response(post(api_conn(token), "/api/v1/control", set), 400)
    set = %{set | "limit" => 2}
    assert %{"limit" => 2, "replayed" => false} = json_response(post(api_conn(token), "/api/v1/control", set), 200)
    assert %{"limit" => 2, "replayed" => true} = json_response(post(api_conn(token), "/api/v1/control", set), 200)
    assert %{"error" => %{"code" => "command_id_conflict"}} = json_response(post(api_conn(token), "/api/v1/control", %{set | "limit" => nil}), 409)
  end

  test "routed renewal stays paused, preserves usage and returns actionable conflicts", ctx do
    token = start_control_endpoint(ctx.pid)

    :sys.replace_state(ctx.pid, fn state ->
      issue = %{"attempts" => 2, "runtime_ms" => 17, "tokens" => 9, "hold" => nil, "active" => nil}
      %{state | control: %{state.control | data: put_in(state.control.data, ["issues", "7"], issue)}}
    end)

    retry = %{"command_id" => "api-recovery", "expected_revision" => 0, "action" => "retry", "issue_id" => "7"}
    assert %{"error" => %{"code" => "budget_exhausted"}} = json_response(post(api_conn(token), "/api/v1/control", retry), 409)
    renewal = Map.put(retry, "renew_attempts", true)
    assert %{"renew_attempts" => true, "mode" => "paused", "replayed" => false} = json_response(post(api_conn(token), "/api/v1/control", renewal), 200)
    assert %{"replayed" => true} = json_response(post(api_conn(token), "/api/v1/control", renewal), 200)
    next = %{renewal | "command_id" => "premature-renewal", "expected_revision" => 1}
    assert %{"error" => %{"code" => "attempts_not_exhausted"}} = json_response(post(api_conn(token), "/api/v1/control", next), 409)
    assert %{"issues" => %{"7" => %{"attempts" => 2, "cycle_attempts" => 0, "runtime_ms" => 17, "tokens" => 9, "active" => nil}}} = Orchestrator.control_snapshot(ctx.pid)

    :sys.replace_state(ctx.pid, fn state ->
      %{state | control: %{state.control | data: put_in(state.control.data, ["issues", "7", "hold"], "owner_review")}}
    end)

    assert %{"error" => %{"code" => "pr_work_continuation_required"}} = json_response(post(api_conn(token), "/api/v1/control", next), 409)
    assert :sys.get_state(ctx.pid).running == %{}
  end

  test "paused poll and queued retry cannot launch an agent", %{pid: pid, issue: issue} do
    send(pid, :run_poll_cycle)
    assert %{"issues" => %{}} = Orchestrator.control_snapshot(pid)
    token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{state | claimed: MapSet.put(state.claimed, issue.id), retry_attempts: %{issue.id => %{attempt: 1, retry_token: token, identifier: issue.identifier, due_at_ms: 0}}}
    end)

    send(pid, {:retry_issue, issue.id, token})
    assert %{"issues" => %{}} = Orchestrator.control_snapshot(pid)
    assert :sys.get_state(pid).running == %{}
    refute MapSet.member?(:sys.get_state(pid).claimed, issue.id)
  end

  test "tracker edits serialize behind a current cancelled hold and reject stale ownership", c do
    scope = Orchestrator.tracker_fingerprint()
    parent = self()

    callback = fn ->
      send(parent, :tracker_write)
      {:ok, :saved}
    end

    guarded = fn fingerprint, revision -> Orchestrator.tracker_action_guarded(fingerprint, revision, c.issue.id, callback, c.pid) end
    assert {:error, :tracker_changed} = guarded.("foreign", 0)
    assert {:error, :task_must_be_cancelled} = guarded.(scope, 0)
    assert {:ok, %{"revision" => 1}} = Orchestrator.control_command(%{"command_id" => "hold-for-edit", "expected_revision" => 0, "action" => "cancel", "issue_id" => c.issue.id}, c.pid)
    assert {:error, :revision_conflict} = guarded.(scope, 0)
    refute_receive :tracker_write
    assert {:ok, :saved} = guarded.(scope, 1)
    assert_receive :tracker_write
    assert {:error, :invalid_command} = Orchestrator.tracker_action_guarded(scope, 1, c.issue.id, nil, c.pid)
    assert {:error, :write_outcome_unknown} = Orchestrator.tracker_action_guarded(scope, 1, c.issue.id, fn -> raise "provider disconnected" end, c.pid)
    assert {:error, :write_outcome_unknown} = Orchestrator.tracker_action_guarded(scope, 1, c.issue.id, fn -> throw(:uncertain) end, c.pid)
    :sys.replace_state(c.pid, fn state -> %{state | retry_attempts: %{c.issue.id => %{}}} end)
    assert {:error, :task_still_active} = guarded.(scope, 1)
    :sys.replace_state(c.pid, fn state -> %{state | retry_attempts: %{}, control_fault: :failed} end)
    assert {:error, :control_unavailable} = guarded.(scope, 1)
  end

  test "fresh queue guard rejects ownership and retained holds without changing execution state", c do
    scope = Orchestrator.tracker_fingerprint()
    parent = self()

    callback = fn ->
      send(parent, :queued)
      {:ok, :saved}
    end

    guard = fn fingerprint, revision -> Orchestrator.tracker_action_guarded(fingerprint, revision, c.issue.id, callback, c.pid, :queue_unheld) end
    before = Orchestrator.control_snapshot(c.pid)
    assert {:error, :tracker_changed} = guard.("foreign", 0)
    assert {:error, :revision_conflict} = guard.(scope, 1)
    assert {:ok, :saved} = guard.(scope, 0)
    assert_receive :queued
    assert Orchestrator.control_snapshot(c.pid) == before

    for ownership <- [:running, :retry_attempts, :blocked, :claimed] do
      original = :sys.get_state(c.pid)
      value = if ownership == :claimed, do: MapSet.new([c.issue.id]), else: %{c.issue.id => %{}}
      :sys.replace_state(c.pid, &Map.put(&1, ownership, value))
      assert {:error, :task_still_active} = guard.(scope, 0)
      :sys.replace_state(c.pid, fn _ -> original end)
    end

    for issue <- [%{"hold" => "cancelled"}, %{"hold" => "owner_review"}, %{"hold" => "interrupted"}, %{"active" => %{}}, %{"handoff" => %{}}] do
      original = :sys.get_state(c.pid)
      :sys.replace_state(c.pid, &put_in(&1.control.data["issues"][c.issue.id], issue))
      assert {:error, :task_not_queueable} = guard.(scope, 0)
      :sys.replace_state(c.pid, fn _ -> original end)
    end

    refute_receive :queued
  end

  test "polling and control reads cannot pass fresh queue mutation and paused mode remains paused", c do
    parent = self()
    scope = Orchestrator.tracker_fingerprint()

    queue =
      Task.async(fn ->
        Orchestrator.tracker_action_guarded(
          scope,
          0,
          c.issue.id,
          fn ->
            send(parent, :queueing)
            receive do: (:complete_queue -> {:ok, :saved})
          end,
          c.pid,
          :queue_unheld
        )
      end)

    assert_receive :queueing
    send(c.pid, :run_poll_cycle)
    status = Task.async(fn -> Orchestrator.control_snapshot(c.pid) end)
    refute Task.yield(status, 20)
    send(c.pid, :complete_queue)
    assert {:ok, :saved} = Task.await(queue)
    assert %{"revision" => 0, "mode" => "paused", "issues" => %{}} = Task.await(status)
    assert :sys.get_state(c.pid).running == %{}
  end

  test "native retry cannot pass a tracker edit in progress", c do
    scope = Orchestrator.tracker_fingerprint()
    assert {:ok, _} = Orchestrator.control_command(%{"command_id" => "hold", "expected_revision" => 0, "action" => "cancel", "issue_id" => c.issue.id}, c.pid)
    parent = self()

    edit =
      Task.async(fn ->
        Orchestrator.tracker_action_guarded(
          scope,
          1,
          c.issue.id,
          fn ->
            send(parent, :editing)

            receive do
              :complete_edit -> {:ok, :saved}
            end
          end,
          c.pid
        )
      end)

    assert_receive :editing
    retry = Task.async(fn -> Orchestrator.control_command(%{"command_id" => "retry", "expected_revision" => 1, "action" => "retry", "issue_id" => c.issue.id}, c.pid) end)
    refute Task.yield(retry, 20)
    send(c.pid, :complete_edit)
    assert {:ok, :saved} = Task.await(edit)
    assert {:ok, %{"revision" => 2}} = Task.await(retry)
    assert %{"issues" => %{"7" => %{"hold" => nil}}} = Orchestrator.control_snapshot(c.pid)
  end

  test "uncertain native commands can be reconciled with a read-only exact receipt", c do
    scope = Orchestrator.tracker_fingerprint()
    command = %{"command_id" => "receipt", "expected_revision" => 0, "action" => "cancel", "issue_id" => c.issue.id}
    assert {:error, :command_not_found} = Orchestrator.control_receipt_guarded(command, scope, c.pid)
    assert {:ok, _} = Orchestrator.control_command(command, c.pid)
    assert {:ok, %{"command_id" => "receipt", "revision" => 1}} = Orchestrator.control_receipt_guarded(command, scope, c.pid)
    assert {:error, :command_id_conflict} = Orchestrator.control_receipt_guarded(Map.put(command, "action", "retry"), scope, c.pid)
    assert {:error, :tracker_changed} = Orchestrator.control_receipt_guarded(command, "foreign", c.pid)
    assert %{"revision" => 1} = Orchestrator.control_snapshot(c.pid)
  end

  test "cancel targets owned execution and stale deadline cannot stop another run", ctx do
    {worker, run} = seed_owned_worker(ctx)
    send(ctx.pid, {:control_deadline, ctx.issue.id, "old-run"})
    Orchestrator.control_snapshot(ctx.pid)
    assert Process.alive?(worker)
    monitor = Process.monitor(worker)
    cancel = %{"command_id" => "cancel", "expected_revision" => 1, "action" => "cancel", "issue_id" => ctx.issue.id}
    assert {:ok, %{"revision" => 2}} = Orchestrator.control_command(cancel, ctx.pid)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert %{"issues" => %{"7" => %{"hold" => "cancelled", "active" => nil, "attempts" => 1}}} = Orchestrator.control_snapshot(ctx.pid)
    send(ctx.pid, {:worker_candidate_ready, "7", %{run_id: run, candidate_sha: String.duplicate("a", 40)}})
    assert %{"issues" => %{"7" => %{"hold" => "cancelled"}}} = Orchestrator.control_snapshot(ctx.pid)
    assert {:ok, %{"replayed" => true}} = Orchestrator.control_command(cancel, ctx.pid)
  end

  test "candidate handoff persists owner-review fence and rejects late token events", ctx do
    {_worker, run} = seed_owned_worker(ctx)
    send(ctx.pid, {:worker_candidate_ready, "7", %{run_id: run, candidate_sha: String.duplicate("a", 40), review: %{verdict: "pass"}}})
    assert %{"issues" => %{"7" => %{"hold" => "owner_review", "active" => nil}}} = Orchestrator.control_snapshot(ctx.pid)
    send(ctx.pid, {:codex_worker_update, "7", run, %{event: :notification, timestamp: DateTime.utc_now()}})
    assert %{"fault" => nil} = Orchestrator.control_snapshot(ctx.pid)
  end

  test "runtime deadline is independent of worker events", ctx do
    {worker, run} = seed_owned_worker(ctx)
    monitor = Process.monitor(worker)
    send(ctx.pid, {:codex_worker_update, "7", run, %{event: :notification, timestamp: DateTime.utc_now()}})
    send(ctx.pid, {:control_deadline, "7", run})
    assert %{"issues" => %{"7" => %{"hold" => "runtime_budget", "active" => nil}}} = Orchestrator.control_snapshot(ctx.pid)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
  end

  test "worker authentication settles once and holds dispatch across restart and resume", ctx do
    {worker, run} = seed_owned_worker(ctx)

    send(
      ctx.pid,
      {:codex_worker_update, "7", run,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{"method" => "thread/tokenUsage/updated", "params" => %{"tokenUsage" => %{"total" => %{"inputTokens" => 23, "outputTokens" => 0, "totalTokens" => 23}}}}
       }}
    )

    assert Orchestrator.control_snapshot(ctx.pid)["issues"]["7"]["active"]["tokens"] == 23
    stop_with_auth_failure(worker)
    snapshot = await_auth_hold(ctx.pid)
    assert %{"attempts" => 1, "tokens" => 23, "active" => nil, "hold" => "worker_auth_required"} = snapshot["issues"]["7"]
    assert snapshot["issues"]["7"]["runtime_ms"] >= 0
    assert :sys.get_state(ctx.pid).retry_attempts == %{}
    assert :sys.get_state(ctx.pid).blocked["7"].error == "Worker sign-in required"
    assert :sys.get_state(ctx.pid).blocked["7"].last_codex_message == nil

    path = :sys.get_state(ctx.pid).control.path
    assert File.read!(path) |> Jason.decode!() |> get_in(["issues", "7", "hold"]) == "worker_auth_required"
    retained = snapshot["issues"]["7"]
    stop_supervised!(Orchestrator)
    pid = start_supervised!({Orchestrator, name: Module.concat(__MODULE__, "Recovered#{System.unique_integer([:positive])}"), task_supervisor: ctx.supervisor})
    assert Orchestrator.control_snapshot(pid)["issues"]["7"] == retained
    resume = %{"command_id" => "resume-auth-held", "expected_revision" => snapshot["revision"], "action" => "resume"}
    assert {:ok, _} = Orchestrator.control_command(resume, pid)
    send(pid, :run_poll_cycle)
    assert Orchestrator.control_snapshot(pid)["issues"]["7"] == retained
    assert :sys.get_state(pid).running == %{}
    assert :sys.get_state(pid).retry_attempts == %{}

    pause = %{resume | "command_id" => "pause-before-retry", "expected_revision" => snapshot["revision"] + 1, "action" => "pause"}
    assert {:ok, _} = Orchestrator.control_command(pause, pid)
    retry = %{"command_id" => "explicit-auth-retry", "expected_revision" => snapshot["revision"] + 2, "action" => "retry", "issue_id" => "7"}
    assert {:ok, receipt} = Orchestrator.control_command(retry, pid)
    assert {:ok, %{"replayed" => true}} = Orchestrator.control_command(retry, pid)
    retried = Orchestrator.control_snapshot(pid)["issues"]["7"]
    assert retried["hold"] == nil
    assert Map.drop(retried, ["hold"]) == Map.drop(retained, ["hold"])
    assert receipt["revision"] == snapshot["revision"] + 3
    assert :sys.get_state(pid).running == %{}
  end

  test "late authentication failures cannot overwrite cancellation or another active run", ctx do
    {worker, run} = seed_owned_worker(ctx)
    ref = :sys.get_state(ctx.pid).running["7"].ref
    send(ctx.pid, {:DOWN, make_ref(), :process, worker, auth_failure()})
    assert Orchestrator.control_snapshot(ctx.pid)["issues"]["7"]["active"]["run_id"] == run
    assert :sys.get_state(ctx.pid).running["7"].ref == ref
    cancel = %{"command_id" => "cancel-before-auth", "expected_revision" => 1, "action" => "cancel", "issue_id" => "7"}
    assert {:ok, _} = Orchestrator.control_command(cancel, ctx.pid)
    send(ctx.pid, {:DOWN, ref, :process, worker, auth_failure()})
    send(ctx.pid, {:codex_worker_update, "7", run, %{event: :turn_failed, timestamp: DateTime.utc_now(), payload: %{"error" => %{"codexErrorInfo" => "unauthorized"}}}})
    assert Orchestrator.control_snapshot(ctx.pid)["issues"]["7"]["hold"] == "cancelled"
    assert :sys.get_state(ctx.pid).retry_attempts == %{}
    assert :sys.get_state(ctx.pid).blocked == %{}
  end

  test "authentication hold persistence failure closes admission without scheduling retry", ctx do
    {worker, _run} = seed_owned_worker(ctx)
    path = :sys.get_state(ctx.pid).control.path
    File.rename!(path, path <> ".saved")
    File.mkdir!(path)
    stop_with_auth_failure(worker)
    wait_for(fn -> not is_nil(Orchestrator.control_snapshot(ctx.pid)["fault"]) end)
    assert :sys.get_state(ctx.pid).running == %{}
    assert :sys.get_state(ctx.pid).retry_attempts == %{}
    assert {:error, :control_unavailable} = Orchestrator.control_command(%{"command_id" => "blocked-resume", "expected_revision" => 1, "action" => "resume"}, ctx.pid)
    assert get_in(File.read!(path <> ".saved") |> Jason.decode!(), ["issues", "7", "active", "run_id"]) != nil
  end

  test "baseline preflight settles its counted attempt and holds dispatch across restart", ctx do
    {worker, _run} = seed_owned_worker(ctx)
    Process.exit(worker, baseline_failure())
    wait_for(fn -> Orchestrator.control_snapshot(ctx.pid)["issues"]["7"]["hold"] == "workspace_baseline_changed" end)
    snapshot = Orchestrator.control_snapshot(ctx.pid)
    retained = snapshot["issues"]["7"]
    assert %{"attempts" => 1, "tokens" => 0, "active" => nil, "hold" => "workspace_baseline_changed"} = retained
    assert retained["runtime_ms"] >= 0
    assert :sys.get_state(ctx.pid).retry_attempts == %{}
    assert :sys.get_state(ctx.pid).blocked["7"].error == "Workspace baseline needs recovery"
    assert :sys.get_state(ctx.pid).blocked["7"].last_codex_event == :workspace_baseline_changed

    path = :sys.get_state(ctx.pid).control.path
    persisted = File.read!(path) |> Jason.decode!() |> get_in(["issues", "7"])
    assert persisted["active"] == nil
    assert persisted["hold"] == "workspace_baseline_changed"
    stop_supervised!(Orchestrator)
    pid = start_supervised!({Orchestrator, name: Module.concat(__MODULE__, "BaselineRecovered#{System.unique_integer([:positive])}"), task_supervisor: ctx.supervisor})
    assert Orchestrator.control_snapshot(pid)["issues"]["7"] == retained
    resume = %{"command_id" => "resume-baseline-held", "expected_revision" => snapshot["revision"], "action" => "resume"}
    assert {:ok, _} = Orchestrator.control_command(resume, pid)
    send(pid, :run_poll_cycle)
    assert Orchestrator.control_snapshot(pid)["issues"]["7"] == retained
    assert :sys.get_state(pid).running == %{}
    assert :sys.get_state(pid).retry_attempts == %{}
  end

  test "late baseline failures cannot overwrite cancellation or a current reservation", ctx do
    {worker, run} = seed_owned_worker(ctx)
    ref = :sys.get_state(ctx.pid).running["7"].ref
    send(ctx.pid, {:DOWN, make_ref(), :process, worker, baseline_failure()})
    assert Orchestrator.control_snapshot(ctx.pid)["issues"]["7"]["active"]["run_id"] == run
    assert :sys.get_state(ctx.pid).running["7"].ref == ref
    cancel = %{"command_id" => "cancel-before-baseline", "expected_revision" => 1, "action" => "cancel", "issue_id" => "7"}
    assert {:ok, _} = Orchestrator.control_command(cancel, ctx.pid)
    send(ctx.pid, {:DOWN, ref, :process, worker, baseline_failure()})
    assert Orchestrator.control_snapshot(ctx.pid)["issues"]["7"]["hold"] == "cancelled"
    assert :sys.get_state(ctx.pid).retry_attempts == %{}
    assert :sys.get_state(ctx.pid).blocked == %{}
  end

  test "baseline hold persistence failure closes admission and retains recovery evidence", ctx do
    {worker, run} = seed_owned_worker(ctx)
    path = :sys.get_state(ctx.pid).control.path
    File.rename!(path, path <> ".saved")
    File.mkdir!(path)
    Process.exit(worker, baseline_failure())
    wait_for(fn -> not is_nil(Orchestrator.control_snapshot(ctx.pid)["fault"]) end)
    assert :sys.get_state(ctx.pid).running == %{}
    assert :sys.get_state(ctx.pid).retry_attempts == %{}
    assert :sys.get_state(ctx.pid).blocked == %{}
    assert {:error, :control_unavailable} = Orchestrator.control_command(%{"command_id" => "blocked-baseline-resume", "expected_revision" => 1, "action" => "resume"}, ctx.pid)
    assert get_in(File.read!(path <> ".saved") |> Jason.decode!(), ["issues", "7", "active", "run_id"]) == run
  end

  test "fresh reviewer thread totals accumulate toward one token ceiling", ctx do
    {worker, run} = seed_owned_worker(ctx)
    monitor = Process.monitor(worker)

    for {thread, total} <- [{"builder", 60}, {"reviewer", 45}] do
      send(ctx.pid, {:codex_worker_update, "7", run, %{event: :session_started, timestamp: DateTime.utc_now(), thread_id: thread, session_id: thread <> "-turn"}})

      send(
        ctx.pid,
        {:codex_worker_update, "7", run,
         %{
           event: :notification,
           timestamp: DateTime.utc_now(),
           payload: %{"method" => "thread/tokenUsage/updated", "params" => %{"tokenUsage" => %{"total" => %{"inputTokens" => total, "outputTokens" => 0, "totalTokens" => total}}}}
         }}
      )
    end

    assert %{"issues" => %{"7" => %{"hold" => "token_budget", "tokens" => 105, "active" => nil}}} = Orchestrator.control_snapshot(ctx.pid)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
  end

  test "failed durable command acknowledgement stops admission and owned work", ctx do
    {worker, _run} = seed_owned_worker(ctx)
    monitor = Process.monitor(worker)
    path = :sys.get_state(ctx.pid).control.path
    File.rename!(path, path <> ".saved")
    File.mkdir!(path)
    command = %{"command_id" => "fail-write", "expected_revision" => 1, "action" => "cancel", "issue_id" => "7"}
    assert {:error, :control_unavailable} = Orchestrator.control_command(command, ctx.pid)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert %{"fault" => fault, "revision" => 1} = Orchestrator.control_snapshot(ctx.pid)
    assert is_binary(fault)
    assert {:error, :control_unavailable} = Orchestrator.control_command(%{command | "action" => "retry"}, ctx.pid)
  end

  test "operator authentication rejects remote hosts, browser Origin and missing bearer" do
    before_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    token = String.duplicate("k", 40)
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)
    on_exit(fn -> restore_env("SYMPHONY_CONTROL_TOKEN", before_token) end)
    conn = Plug.Test.conn(:get, "http://localhost/api/v1/control")
    assert ControlApiController.authorize(conn).status == 401
    valid = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
    refute ControlApiController.authorize(valid).halted
    browser = Plug.Conn.put_req_header(valid, "origin", "https://evil.example")
    assert ControlApiController.authorize(browser).status == 403
    assert ControlApiController.authorize(%{valid | host: "evil.example"}).status == 403
  end

  test "routed API reads durable state and enforces command revision, replay and validation", ctx do
    token = start_control_endpoint(ctx.pid)
    assert %{"mode" => "paused", "revision" => 0} = json_response(get(api_conn(token), "/api/v1/control"), 200)
    command = %{"command_id" => "http-drain", "expected_revision" => 0, "action" => "drain"}

    assert %{"revision" => 1, "mode" => "draining", "replayed" => false} =
             json_response(post(api_conn(token), "/api/v1/control", command), 200)

    assert %{"revision" => 1, "replayed" => true} =
             json_response(post(api_conn(token), "/api/v1/control", command), 200)

    stale = %{command | "command_id" => "http-pause", "action" => "pause"}

    assert %{"error" => %{"code" => "revision_conflict"}} =
             json_response(post(api_conn(token), "/api/v1/control", stale), 409)

    assert %{"error" => %{"code" => "invalid_command"}} =
             json_response(post(api_conn(token), "/api/v1/control", %{"action" => "deploy"}), 400)

    assert %{"revision" => 1} = json_response(get(api_conn(token), "/api/v1/control"), 200)
  end

  test "routed API refuses reads and mutations without configured bearer authentication", ctx do
    token = start_control_endpoint(ctx.pid)

    for {method, params} <- [{:get, nil}, {:post, %{}}] do
      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(dispatch(api_conn("wrong"), @endpoint, method, "/api/v1/control", params), 401)

      System.delete_env("SYMPHONY_CONTROL_TOKEN")

      assert %{"error" => %{"code" => "control_auth_unconfigured"}} =
               json_response(dispatch(api_conn(token), @endpoint, method, "/api/v1/control", params), 503)

      System.put_env("SYMPHONY_CONTROL_TOKEN", token)
    end

    assert %{"revision" => 0} = Orchestrator.control_snapshot(ctx.pid)
  end

  test "routed API reports unavailable owner for both reads and commands", ctx do
    token = start_control_endpoint(ctx.pid)
    GenServer.stop(ctx.pid, :normal)
    assert %{"error" => %{"code" => "unavailable"}} = json_response(get(api_conn(token), "/api/v1/control"), 503)
    command = %{"command_id" => "unavailable", "expected_revision" => 0, "action" => "drain"}

    assert %{"error" => %{"code" => "unavailable"}} =
             json_response(post(api_conn(token), "/api/v1/control", command), 503)
  end

  defp start_control_endpoint(orchestrator) do
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])
    previous_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    token = String.duplicate("t", 40)
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)
    config = Keyword.merge(previous_endpoint, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator)
    Application.put_env(:symphony_elixir, Endpoint, config)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous_endpoint)
      restore_env("SYMPHONY_CONTROL_TOKEN", previous_token)
    end)

    token
  end

  defp api_conn(token) do
    %{build_conn() | host: "localhost"} |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end

  defp auth_failure do
    reason = {:turn_failed, %{"turn" => %{"error" => %{"codexErrorInfo" => "unauthorized", "message" => "PRIVATE_REVOKED_TOKEN"}}}}
    {SymphonyElixir.WorkerFailure.exception(reason: reason), [:private_stack]}
  end

  defp stop_with_auth_failure(worker), do: Process.exit(worker, auth_failure())

  defp baseline_failure do
    {SymphonyElixir.WorkerFailure.exception(reason: :workspace_baseline_changed), [:private_stack]}
  end

  defp await_auth_hold(pid) do
    wait_for(fn -> Orchestrator.control_snapshot(pid)["issues"]["7"]["hold"] == "worker_auth_required" end)
    Orchestrator.control_snapshot(pid)
  end

  defp wait_for(condition, attempts \\ 50)
  defp wait_for(condition, 0), do: assert(condition.())

  defp wait_for(condition, attempts) do
    unless condition.() do
      Process.sleep(10)
      wait_for(condition, attempts - 1)
    end
  end

  defp seed_owned_worker(%{pid: pid, supervisor: supervisor, issue: issue}) do
    # Reserve inside the real owner's mailbox, then attach a supervised inert task.
    # No model or network call is used by these lifecycle tests.
    {:ok, worker} =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    state =
      :sys.replace_state(pid, fn state ->
        {:ok, ledger, _, _} = ControlLedger.command(state.control, %{"command_id" => "seed", "expected_revision" => 0, "action" => "resume"})
        {:ok, ledger, run, _} = ControlLedger.reserve(ledger, issue.id)

        entry = %{
          pid: worker,
          ref: Process.monitor(worker),
          run_id: run,
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          codex_total_tokens: 0,
          started_at: DateTime.utc_now(),
          turn_count: 0,
          last_codex_event: nil,
          last_codex_timestamp: nil,
          last_codex_message: nil
        }

        %{state | control: ledger, running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
      end)

    {worker, state.running[issue.id].run_id}
  end
end
