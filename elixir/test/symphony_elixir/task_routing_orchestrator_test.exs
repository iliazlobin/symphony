defmodule SymphonyElixir.TaskRoutingOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PathSafety

  @updated ~U[2026-09-24 10:00:00Z]

  defmodule GitHubFixture do
    def fetch_issues_by_states(states), do: read({:states, states}, fn issues -> Enum.filter(issues, &(&1.state in states)) end)
    def fetch_issues_by_ids(ids), do: read({:ids, ids}, fn issues -> Enum.filter(issues, &(&1.id in ids)) end)

    defp read(call, select) do
      Agent.get_and_update(Application.fetch_env!(:symphony_elixir, :task_routing_fixture), fn state ->
        {{:ok, select.(state.issues)}, %{state | calls: [call | state.calls]}}
      end)
    end
  end

  setup do
    {:ok, root} = PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony-routing-otp-#{System.unique_integer([:positive])}"))
    File.mkdir_p!(root)
    workflow = Path.join(root, "WORKFLOW.md")

    config = %{
      tracker: %{
        kind: "github",
        provider: %{repo: "example/tasks", token: "fixture-token"},
        required_labels: ["symphony:ready"],
        active_states: ["open"],
        terminal_states: ["closed"]
      },
      workspace: %{root: Path.join(root, "workspaces")},
      polling: %{interval_ms: 60_000},
      agent: %{max_concurrent_agents: 2},
      observability: %{dashboard_enabled: false},
      control: %{
        enabled: true,
        initial_mode: "paused",
        state_path: Path.join(root, "control.json"),
        max_attempts: 2,
        max_total_runtime_ms: 60_000,
        max_total_tokens: 100
      }
    }

    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(workflow)
    original_client = Application.get_env(:symphony_elixir, :github_client_module)
    original_fixture = Application.get_env(:symphony_elixir, :task_routing_fixture)
    fixture = start_supervised!({Agent, fn -> %{issues: [], calls: []} end})
    Application.put_env(:symphony_elixir, :github_client_module, GitHubFixture)
    Application.put_env(:symphony_elixir, :task_routing_fixture, fixture)
    supervisor = start_supervised!({Task.Supervisor, []})
    name = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor})
    Agent.update(fixture, &%{&1 | calls: []})

    on_exit(fn ->
      restore_application(:github_client_module, original_client)
      restore_application(:task_routing_fixture, original_fixture)
      File.rm_rf(root)
    end)

    %{pid: pid, fixture: fixture, scope: Orchestrator.tracker_fingerprint(), supervisor: supervisor, config: config}
  end

  test "native observed queue is durable and authorized without GitHub calls or automatic resume", c do
    assert :ok = Orchestrator.observe_tracker_issues([issue()], c.scope, c.pid)
    assert {:error, :unauthorized} = Orchestrator.control_command_guarded(queue(), c.scope, c.pid, fn -> false end)
    assert {:error, :tracker_changed} = Orchestrator.control_command_guarded(queue(), "other", c.pid)
    assert {:ok, %{"revision" => 1, "replayed" => false}} = Orchestrator.control_command_guarded(queue(), c.scope, c.pid)
    snapshot = Orchestrator.control_snapshot(c.pid)
    assert snapshot["mode"] == "paused"
    assert %{"attempts" => 0, "tokens" => 0, "routing" => %{"queued" => true, "status" => "pending"}} = snapshot["issues"]["7"]
    assert Jason.decode!(File.read!(c.config.control.state_path))["issues"]["7"]["routing"] == snapshot["issues"]["7"]["routing"]
    assert {:ok, %{"replayed" => true}} = Orchestrator.control_command_guarded(queue(), c.scope, c.pid)
    send(c.pid, :run_poll_cycle)
    assert Orchestrator.control_snapshot(c.pid)["revision"] == 1
    assert :sys.get_state(c.pid).running == %{}
    assert calls(c) == []
  end

  test "native observation and acknowledgement reject stale tracker scope without losing decisions", c do
    assert {:error, :tracker_changed} = Orchestrator.observe_tracker_issues([issue()], "other", c.pid)
    assert {:error, :task_not_found} = Orchestrator.control_command(queue(), c.pid)
    assert :ok = Orchestrator.observe_tracker_issues([issue()], c.scope, c.pid)
    assert {:ok, _} = Orchestrator.control_command(queue(), c.pid)
    assert {:error, :tracker_changed} = Orchestrator.routing_sync_result("7", 1, "other", :ok, c.pid)
    assert :ok = Orchestrator.routing_sync_result("7", 1, c.scope, {:error, :github_unavailable}, c.pid)
    assert Orchestrator.control_snapshot(c.pid)["revision"] == 1
    assert {:ok, _} = Orchestrator.control_command(command("cancel", 1), c.pid)
    assert {:error, :stale_routing_intent} = Orchestrator.routing_sync_result("7", 1, c.scope, :ok, c.pid)
    assert %{"queued" => false, "revision" => 2, "status" => "pending"} = Orchestrator.control_snapshot(c.pid)["issues"]["7"]["routing"]
    assert calls(c) == []
  end

  test "failed local persistence retains previous revision and closes further routing writes", c do
    assert :ok = Orchestrator.observe_tracker_issues([issue()], c.scope, c.pid)
    path = c.config.control.state_path
    File.rename!(path, path <> ".saved")
    File.mkdir!(path)
    assert {:error, :control_unavailable} = Orchestrator.control_command(queue(), c.pid)
    snapshot = Orchestrator.control_snapshot(c.pid)
    assert snapshot["revision"] == 0
    assert snapshot["issues"] == %{}
    assert is_binary(snapshot["fault"])
    assert {:error, :control_unavailable} = Orchestrator.observe_tracker_issues([issue()], c.scope, c.pid)
    assert {:error, :control_unavailable} = Orchestrator.control_command(queue(), c.pid)
    assert calls(c) == []
  end

  test "candidate selection honors local queue before label mirroring without bypassing eligibility", c do
    state = queue_state(c)
    assert Orchestrator.should_dispatch_issue_for_test(issue(), state)
    refute Orchestrator.should_dispatch_issue_for_test(issue(), %{state | control: nil})
    assert Orchestrator.should_dispatch_issue_for_test(issue(labels: ["symphony:ready"]), %{state | control: nil})

    for task <- [issue(state: "closed"), issue(dispatchable: false), issue(title: ""), issue(identifier: "")] do
      refute Orchestrator.should_dispatch_issue_for_test(task, state)
    end

    for unavailable <- [
          %{state | claimed: MapSet.new(["7"])},
          %{state | running: %{"7" => %{issue: issue()}}},
          %{state | blocked: %{"7" => %{}}},
          %{state | max_concurrent_agents: 0}
        ] do
      refute Orchestrator.should_dispatch_issue_for_test(issue(), unavailable)
    end

    assert {:ok, _} = Orchestrator.control_command(command("cancel", 1), c.pid)
    refute Orchestrator.should_dispatch_issue_for_test(issue(labels: ["symphony:ready"]), :sys.get_state(c.pid))
  end

  test "fresh dispatch refresh uses local queue but rejects closure invisibility and identity changes", c do
    state = queue_state(c)
    fresh = issue(title: "Fresh title")
    assert {:ok, ^fresh} = revalidate(issue(), {:ok, [fresh]}, state)
    assert {:skip, :missing} = revalidate(issue(), {:ok, []}, state)
    assert {:error, :github_unavailable} = revalidate(issue(), {:error, :github_unavailable}, state)

    for task <- [issue(state: "closed"), issue(dispatchable: false)] do
      assert {:skip, ^task} = revalidate(issue(), {:ok, [task]}, state)
    end

    foreign = issue(id: "8", identifier: "GH-8", labels: ["symphony:ready"])
    assert {:skip, _} = revalidate(issue(), {:ok, [foreign]}, state)
    assert {:skip, _} = revalidate(issue(), {:ok, [fresh, foreign]}, state)

    assert {:ok, _} = Orchestrator.control_command(command("cancel", 1), c.pid)
    labeled = issue(labels: ["symphony:ready"])
    assert {:skip, ^labeled} = revalidate(issue(), {:ok, [labeled]}, :sys.get_state(c.pid))
  end

  test "fresh GitHub dependency admission still blocks local queue until dependencies close", c do
    state = queue_state(c)
    dependent = issue(description: "Depends on: #8")
    dependency = issue(id: "8", identifier: "GH-8")
    Agent.update(c.fixture, &%{&1 | issues: [dependent, dependency]})
    blocked = Orchestrator.revalidate_issue_for_dispatch_for_test(issue(), &Tracker.fetch_issues_by_ids/1, state)
    assert {:skip, %Issue{dispatchable: false, blocked_by: [%{id: "8"}]}} = blocked
    Agent.update(c.fixture, &%{&1 | issues: [dependent, %{dependency | state: "closed"}]})
    admitted = Orchestrator.revalidate_issue_for_dispatch_for_test(issue(), &Tracker.fetch_issues_by_ids/1, state)
    assert {:ok, %Issue{dispatchable: true, labels: []}} = admitted
    assert {:ids, ["8"]} in calls(c)
  end

  test "running and blocked reconciliation retain local queue while mirrored labels lag", c do
    state = queue_state(c)
    {:ok, worker} = Task.Supervisor.start_child(c.supervisor, fn -> receive do: (:finish -> :ok) end)
    entry = %{pid: worker, ref: nil, identifier: "GH-7", issue: issue(), started_at: DateTime.utc_now()}
    active = %{state | running: %{"7" => entry}, claimed: MapSet.new(["7"])}
    retained = Orchestrator.reconcile_issue_states_for_test([issue(title: "Updated")], active)
    assert Process.alive?(worker)
    assert retained.running["7"].issue.title == "Updated"

    blocked = %{state | blocked: %{"7" => %{issue: issue(), identifier: "GH-7"}}, claimed: MapSet.new(["7"])}
    assert Map.has_key?(Orchestrator.reconcile_blocked_issue_states_for_test([issue()], blocked).blocked, "7")
    assert {:ok, _} = Orchestrator.control_command(command("cancel", 1), c.pid)
    cancelled = :sys.get_state(c.pid).control
    monitor = Process.monitor(worker)
    stopped = Orchestrator.reconcile_issue_states_for_test([issue(labels: ["symphony:ready"])], %{active | control: cancelled})
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert stopped.running == %{}
    assert stopped.claimed == MapSet.new()
    labeled = issue(labels: ["symphony:ready"])
    released = Orchestrator.reconcile_blocked_issue_states_for_test([labeled], %{blocked | control: cancelled})
    assert released.blocked == %{}
    assert released.claimed == MapSet.new()
  end

  defp queue_state(c) do
    :ok = Orchestrator.observe_tracker_issues([issue()], c.scope, c.pid)
    {:ok, _} = Orchestrator.control_command(queue(), c.pid)
    :sys.get_state(c.pid)
  end

  defp revalidate(issue, result, state) do
    Orchestrator.revalidate_issue_for_dispatch_for_test(
      issue,
      fn ids ->
        assert ids == [issue.id]
        result
      end,
      state
    )
  end

  defp calls(c), do: Agent.get(c.fixture, & &1.calls)

  defp command(action, revision), do: %{"command_id" => "#{action}-#{revision}", "action" => action, "issue_id" => "7", "expected_revision" => revision}
  defp queue, do: Map.put(command("queue_task", 0), "expected_updated_at", DateTime.to_iso8601(@updated))

  defp issue(attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: "7",
          identifier: "GH-7",
          title: "Local routing",
          state: "open",
          description: "Depends on: none",
          dispatchable: true,
          updated_at: @updated,
          native_ref: %{"repo" => "example/tasks"},
          labels: []
        ],
        attrs
      )
    )
  end

  defp restore_application(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
