defmodule SymphonyElixir.TaskRoutingTest do
  use ExUnit.Case

  alias SymphonyElixir.{ControlLedger, PathSafety, TaskRouting}
  alias SymphonyElixir.Tracker.Issue

  @updated ~U[2026-09-24 10:00:00Z]
  @base String.duplicate("a", 40)

  # A real ledger owner exercises atomic persistence and lock release across restart.
  defmodule Owner do
    use GenServer
    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def init({settings, root}), do: ControlLedger.open(settings, root)
    def terminate(_, ledger), do: ControlLedger.close(ledger)
    def handle_call(:snapshot, _, ledger), do: {:reply, ControlLedger.snapshot(ledger), ledger}

    def handle_call({operation, args}, _, ledger) do
      case apply(ControlLedger, operation, [ledger | args]) do
        {:ok, next} -> {:reply, :ok, next}
        {:ok, next, value, extra} -> {:reply, {:ok, value, extra}, next}
        error -> {:reply, error, ledger}
      end
    end
  end

  setup do
    {:ok, temporary_root} = PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(temporary_root, "symphony-routing-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    settings = %{
      enabled: true,
      state_path: Path.join(root, "control.json"),
      initial_mode: "paused",
      max_attempts: 3,
      max_total_runtime_ms: 60_000,
      max_total_tokens: 500
    }

    tracker = %{
      kind: "github",
      provider: %{"repo" => "example/tasks", "token" => "fixture-token"},
      required_labels: ["symphony:ready"],
      active_states: ["open"],
      terminal_states: ["closed"]
    }

    context = %{
      tracker_kind: "github",
      tracker_fingerprint: TaskRouting.fingerprint(tracker),
      repository: "example/tasks",
      required_labels: tracker.required_labels,
      base_sha: @base
    }

    %{settings: settings, workspace: Path.join(root, "workspaces"), tracker: tracker, context: context}
  end

  test "local routing wins over mirrored labels while legacy and other scopes keep their own policy", c do
    queued = TaskRouting.intent(%{}, "queue_task", 1, c.context)
    cancelled = TaskRouting.intent(queued, "cancel", 2, c.context)
    unlabeled = issue(labels: ["bug", "priority:p2"])
    labeled = issue(labels: ["bug", "Symphony:Ready", "priority:p2"])

    assert TaskRouting.routable?(unlabeled, queued, c.tracker)
    refute TaskRouting.routable?(labeled, cancelled, c.tracker)
    refute TaskRouting.routable?(%{unlabeled | dispatchable: false}, queued, c.tracker)
    assert TaskRouting.routable?(labeled, nil, c.tracker)
    refute TaskRouting.routable?(unlabeled, %{}, c.tracker)

    other = %{c.tracker | provider: %{"repo" => "example/other", "token" => "fixture-token"}}
    assert TaskRouting.scoped(queued, TaskRouting.fingerprint(other)) == nil
    refute TaskRouting.routable?(unlabeled, queued, other)
    assert TaskRouting.routable?(labeled, cancelled, other)
    assert queued["routing"]["labels"] == ["symphony:ready"]
    assert unlabeled.labels == ["bug", "priority:p2"]
    assert labeled.labels == ["bug", "Symphony:Ready", "priority:p2"]
    assert TaskRouting.intent(%{"hold" => "cancelled"}, "retry", 1, %{tracker_kind: "memory"}) == %{"hold" => "cancelled"}

    for action <- ~w(pause drain resume set_concurrency) do
      assert TaskRouting.intent(queued, action, 2, c.context) == queued
    end
  end

  test "queue decision and pending mirror survive restart together without resuming or spending budget", c do
    pid = owner(c)
    assert :ok = call(pid, :observe_issues, [[issue()], c.tracker])

    assert [%{"issue_id" => "8", "kind" => "technical", "reason" => "schema"}] =
             TaskRouting.observation(issue(description: "Depends on: #8 (technical: schema)"), c.tracker)["dependencies"]

    queue = command("queue_task", 0)
    assert {:ok, %{"revision" => 1, "mode" => "paused"}, false} = execute(pid, queue, c.context)
    assert %{"queued" => true, "revision" => 1, "status" => "pending", "error" => nil} = routing(pid)

    saved = Jason.decode!(File.read!(c.settings.state_path))
    assert saved["issues"]["7"]["routing"] == routing(pid)
    assert saved["commands"][queue["command_id"]]["result"]["revision"] == 1
    assert saved["tracker_issues"]["7"]["updated_at"] == DateTime.to_iso8601(@updated)
    stop_supervised!(Owner)

    pid = owner(c)
    assert snapshot(pid)["mode"] == "paused"
    assert %{"attempts" => 0, "tokens" => 0, "runtime_ms" => 0, "hold" => nil} = snapshot(pid)["issues"]["7"]
    assert routing(pid) == saved["issues"]["7"]["routing"]
    assert TaskRouting.routable?(issue(), snapshot(pid)["issues"]["7"], c.tracker)
    assert {:error, :not_admitted} = call(pid, :reserve, ["7"])
    assert {:ok, %{"revision" => 1}, true} = execute(pid, queue, c.context)
  end

  test "typed dependency source records survive owner restart and legacy observations remain valid", c do
    pid = owner(c)
    assert :ok = call(pid, :observe_issues, [[issue(description: "Depends on: #8 (design: reviewed baseline)")], c.tracker])
    original = snapshot(pid)["tracker_issues"]["7"]
    assert [%{"issue_id" => "8", "kind" => "design", "blocking" => true, "reason" => "reviewed baseline"}] = original["dependencies"]
    assert TaskRouting.valid_observation?(Map.delete(original, "dependencies"))
    refute TaskRouting.valid_observation?(Map.put(original, "dependencies", [%{}]))
    stop_supervised!(Owner)
    pid = owner(c)
    assert snapshot(pid)["tracker_issues"]["7"] == original
  end

  test "replayed queue commands cannot undo a later cancellation and changed requests are rejected", c do
    pid = owner(c)
    assert :ok = call(pid, :observe_issues, [[issue()], c.tracker])
    queue = command("queue_task", 0)
    assert {:ok, _, false} = execute(pid, queue, c.context)
    assert {:error, :command_id_conflict} = execute(pid, %{queue | "expected_updated_at" => "2026-09-24T09:00:00Z"}, c.context)
    assert {:error, :revision_conflict} = execute(pid, Map.put(queue, "command_id", "stale-request"), c.context)
    assert {:ok, _, false} = execute(pid, command("cancel", 1), c.context)
    after_cancel = snapshot(pid)
    assert {:ok, %{"revision" => 1}, true} = execute(pid, queue, c.context)
    assert snapshot(pid) == after_cancel
    assert routing(pid)["queued"] == false
    assert routing(pid)["revision"] == 2
  end

  test "observations reject stale task edits and ignore older tracker snapshots", c do
    pid = owner(c)
    newer = issue(updated_at: DateTime.add(@updated, 60), state: "closed")
    assert :ok = call(pid, :observe_issues, [[newer], c.tracker])
    assert :ok = call(pid, :observe_issues, [[issue()], c.tracker])
    assert snapshot(pid)["revision"] == 0
    assert snapshot(pid)["tracker_issues"]["7"]["state"] == "closed"
    assert {:error, :task_changed} = execute(pid, command("queue_task", 0), c.context)

    current = Map.put(command("queue_task", 0), "expected_updated_at", DateTime.to_iso8601(newer.updated_at))
    assert {:error, :task_not_queueable} = execute(pid, current, c.context)
    assert snapshot(pid)["issues"] == %{}
  end

  test "queue commands require an observed task in the current tracker scope", c do
    pid = owner(c)
    queue = command("queue_task", 0)
    assert {:error, :task_not_found} = execute(pid, queue, c.context)
    invalid = issue(native_ref: %{"repo" => "example/other"})
    assert :ok = call(pid, :observe_issues, [[invalid, issue(updated_at: nil)], c.tracker])
    assert snapshot(pid)["tracker_issues"] in [nil, %{}]
    assert :ok = call(pid, :observe_issues, [[issue()], c.tracker])
    other = %{c.context | tracker_fingerprint: "another-project"}
    assert {:error, :task_not_found} = execute(pid, queue, other)
    assert {:error, :task_not_found} = execute(pid, queue, %{c.context | tracker_kind: "memory"})
    assert snapshot(pid)["revision"] == 0
  end

  test "malformed tracker rows cannot replace a valid observation or enter the local task catalog", c do
    pid = owner(c)
    assert :ok = call(pid, :observe_issues, [[issue()], c.tracker])
    original = snapshot(pid)

    malformed = [
      nil,
      %{},
      issue(id: "not-an-issue-number"),
      issue(state: "unknown"),
      issue(native_ref: nil),
      issue(dispatchable: "true")
    ]

    assert :ok = call(pid, :observe_issues, [malformed, c.tracker])
    assert snapshot(pid) == original
    assert {:ok, _, false} = execute(pid, command("queue_task", 0), c.context)
  end

  test "a different tracker scope replaces the same issue number even with an older timestamp", c do
    pid = owner(c)
    assert :ok = call(pid, :observe_issues, [[issue(state: "closed")], c.tracker])
    other = %{c.tracker | provider: %{"repo" => "example/other", "token" => "fixture-token"}}
    other_context = %{c.context | repository: "example/other", tracker_fingerprint: TaskRouting.fingerprint(other)}
    older = issue(native_ref: %{"repo" => "example/other"}, updated_at: DateTime.add(@updated, -60))
    assert :ok = call(pid, :observe_issues, [[older], other])
    observed = snapshot(pid)["tracker_issues"]["7"]
    assert observed["repository"] == "example/other"
    assert observed["tracker_fingerprint"] == other_context.tracker_fingerprint
    assert observed["updated_at"] == DateTime.to_iso8601(older.updated_at)
    assert observed["state"] == "open"
    assert snapshot(pid)["revision"] == 0
    assert {:error, :task_not_found} = execute(pid, command("queue_task", 0), c.context)

    queue = Map.put(command("queue_task", 0), "expected_updated_at", observed["updated_at"])
    assert {:ok, _, false} = execute(pid, queue, other_context)
    assert routing(pid)["tracker_fingerprint"] == other_context.tracker_fingerprint
  end

  test "mirror failures remain pending and stale acknowledgements cannot overwrite a newer intent", c do
    pid = owner(c)
    assert :ok = call(pid, :observe_issues, [[issue()], c.tracker])
    assert {:ok, _, false} = execute(pid, command("queue_task", 0), c.context)
    scope = c.context.tracker_fingerprint
    assert :ok = call(pid, :routing_sync_result, ["7", 1, scope, {:error, :github_unavailable}])
    assert %{"status" => "pending", "error" => "github_unavailable", "queued" => true} = routing(pid)
    assert snapshot(pid)["revision"] == 1
    assert :ok = call(pid, :routing_sync_result, ["7", 1, scope, :ok])
    assert %{"status" => "synced", "error" => nil, "synced_at" => synced_at} = routing(pid)
    assert {:ok, _, _} = DateTime.from_iso8601(synced_at)
    assert snapshot(pid)["revision"] == 1
    assert {:ok, _, false} = execute(pid, command("cancel", 1), c.context)
    before_ack = snapshot(pid)
    assert {:error, :stale_routing_intent} = call(pid, :routing_sync_result, ["7", 1, scope, :ok])
    assert {:error, :stale_routing_intent} = call(pid, :routing_sync_result, ["7", 2, "other-scope", :ok])
    assert {:error, :invalid_sync_result} = call(pid, :routing_sync_result, ["7", 2, scope, :unknown])
    assert snapshot(pid) == before_ack
    assert :ok = call(pid, :routing_sync_result, ["7", 2, scope, :ok])
    synced = routing(pid)
    stop_supervised!(Owner)
    pid = owner(c)
    assert routing(pid) == synced
    assert snapshot(pid)["revision"] == 2
  end

  test "cancel unqueue queue and retry retain consumed budgets and require an idle hold", c do
    pid = owner(c)
    assert :ok = call(pid, :observe_issues, [[issue()], c.tracker])
    assert {:error, :task_must_be_cancelled} = execute(pid, command("unqueue_task", 0), c.context)
    assert {:ok, _, false} = execute(pid, command("resume", 0, nil), c.context)
    assert {:ok, run, _remaining} = call(pid, :reserve, ["7"])
    assert :ok = call(pid, :tokens, ["7", run, 23])
    assert {:error, :issue_running} = execute(pid, command("queue_task", 1), c.context)
    assert {:ok, _, false} = execute(pid, command("cancel", 1), c.context)
    assert routing(pid)["queued"] == false
    assert {:error, :issue_running} = execute(pid, command("unqueue_task", 2), c.context)
    assert :ok = call(pid, :finish, ["7", run])
    assert {:ok, _, false} = execute(pid, command("unqueue_task", 2), c.context)
    assert {:ok, _, false} = execute(pid, command("queue_task", 3), c.context)
    held = snapshot(pid)["issues"]["7"]
    assert held["hold"] == "cancelled"
    assert held["attempts"] == 1
    assert held["tokens"] == 23
    assert routing(pid)["queued"] == true
    assert {:error, :not_admitted} = call(pid, :reserve, ["7"])
    assert {:ok, _, false} = execute(pid, command("retry", 4), c.context)
    retried = snapshot(pid)["issues"]["7"]
    assert retried["hold"] == nil
    assert Map.take(retried, ~w(attempts tokens runtime_ms)) == Map.take(held, ~w(attempts tokens runtime_ms))
    assert routing(pid)["revision"] == 5
  end

  test "acceptance and explicit PR work update routing in the same retained decision", c do
    pid = owner(c)
    work_id = String.duplicate("b", 32)
    create = Map.merge(command("create_pr_work", 0), %{"work_id" => work_id, "instruction" => "Document the unit test command", "base_sha" => @base})
    assert {:ok, _, false} = execute(pid, create, c.context)
    assert routing(pid)["queued"] == true
    assert snapshot(pid)["issues"]["7"]["selected_work_id"] == work_id
    assert {:ok, _, false} = execute(pid, command("cancel", 1), c.context)
    continue = Map.merge(command("continue_pr_work", 2), %{"work_id" => work_id, "instruction" => "Clarify prerequisites", "expected_head_sha" => nil})
    assert {:ok, _, false} = execute(pid, continue, c.context)
    assert routing(pid)["queued"] == true
    assert snapshot(pid)["issues"]["7"]["hold"] == "cancelled"
    assert {:ok, _, false} = execute(pid, command("cancel", 3), c.context)

    accept = Map.merge(command("accept_task", 4), %{"expected_candidate_sha" => nil, "expected_updated_at" => DateTime.to_iso8601(@updated), "expected_tracker_state" => "closed"})
    context = Map.put(c.context, :acceptance_issue, %{id: "7", state: "closed", updated_at: DateTime.to_iso8601(@updated), terminal: true})
    assert {:ok, _, false} = execute(pid, accept, context)
    assert %{"queued" => false, "revision" => 5, "status" => "pending"} = routing(pid)
    assert snapshot(pid)["issues"]["7"]["hold"] == "accepted"
    assert snapshot(pid)["issues"]["7"]["acceptance"]["command_id"] == accept["command_id"]
  end

  test "reopening an accepted tracker issue does not authorize another local queue decision", c do
    pid = owner(c)
    closed = issue(state: "closed")
    assert :ok = call(pid, :observe_issues, [[closed], c.tracker])

    accept =
      Map.merge(command("accept_task", 0), %{
        "expected_candidate_sha" => nil,
        "expected_updated_at" => DateTime.to_iso8601(@updated),
        "expected_tracker_state" => "closed"
      })

    verified = %{id: "7", state: "closed", updated_at: DateTime.to_iso8601(@updated), terminal: true}
    assert {:ok, _, false} = execute(pid, accept, Map.put(c.context, :acceptance_issue, verified))
    reopened = issue(updated_at: DateTime.add(@updated, 60))
    assert :ok = call(pid, :observe_issues, [[reopened], c.tracker])
    before_queue = snapshot(pid)
    queue = Map.put(command("queue_task", 1), "expected_updated_at", DateTime.to_iso8601(reopened.updated_at))
    assert {:error, :task_already_accepted} = execute(pid, queue, c.context)
    assert snapshot(pid) == before_queue
    assert snapshot(pid)["issues"]["7"]["hold"] == "accepted"
    assert routing(pid)["queued"] == false
  end

  test "malformed routing or observation records fail closed instead of dropping durable intent", c do
    pid = owner(c)
    assert :ok = call(pid, :observe_issues, [[issue()], c.tracker])
    assert {:ok, _, false} = execute(pid, command("queue_task", 0), c.context)
    valid = Jason.decode!(File.read!(c.settings.state_path))
    stop_supervised!(Owner)

    for {field, value} <- [{"queued", "true"}, {"revision", 0}, {"status", "unknown"}, {"labels", [1]}, {"repository", "../other"}, {"tracker_fingerprint", nil}, {"synced_at", "yesterday"}] do
      corrupt = put_in(valid, ["issues", "7", "routing", field], value)
      bytes = Jason.encode!(corrupt)
      File.write!(c.settings.state_path, bytes)
      assert {:error, :invalid_control_state} = ControlLedger.open(c.settings, c.workspace)
      assert File.read!(c.settings.state_path) == bytes
    end

    corrupt = put_in(valid, ["tracker_issues", "7", "updated_at"], "not-a-timestamp")
    File.write!(c.settings.state_path, Jason.encode!(corrupt))
    assert {:error, :invalid_control_state} = ControlLedger.open(c.settings, c.workspace)

    malformed = [
      put_in(valid, ["issues", "7", "routing"], "queued"),
      Map.put(valid, "tracker_issues", []),
      Map.put(valid, "tracker_issues", "unreadable"),
      put_in(valid, ["tracker_issues", "7"], []),
      put_in(valid, ["tracker_issues", "7"], %{})
    ]

    for corrupt <- malformed do
      bytes = Jason.encode!(corrupt)
      File.write!(c.settings.state_path, bytes)
      assert {:error, :invalid_control_state} = ControlLedger.open(c.settings, c.workspace)
      assert File.read!(c.settings.state_path) == bytes
    end
  end

  defp owner(c), do: start_supervised!({Owner, {c.settings, c.workspace}})
  defp snapshot(pid), do: GenServer.call(pid, :snapshot)
  defp routing(pid), do: snapshot(pid)["issues"]["7"]["routing"]
  defp call(pid, operation, args), do: GenServer.call(pid, {operation, args})
  defp execute(pid, params, context), do: call(pid, :command, [params, 5, context])

  defp issue(attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge([id: "7", identifier: "GH-7", title: "Routing fixture", state: "open", dispatchable: true, native_ref: %{"repo" => "example/tasks"}, updated_at: @updated, labels: []], attrs)
    )
  end

  defp command(action, revision, id \\ "7") do
    params = %{"action" => action, "expected_revision" => revision, "command_id" => "#{action}-#{revision}", "issue_id" => id}
    if action in ~w(queue_task unqueue_task), do: Map.put(params, "expected_updated_at", DateTime.to_iso8601(@updated)), else: params
  end
end
