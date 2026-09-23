defmodule SymphonyElixir.IssueAcceptanceTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ControlLedger, IssueAcceptance}

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)
  @updated ~U[2026-09-23 10:00:00Z]

  defmodule RawGitHub do
    def fetch_issues_by_ids(_ids), do: {:ok, Application.fetch_env!(:symphony_elixir, :acceptance_issues)}
    def fetch_issues_by_states(_states), do: {:ok, []}
  end

  setup do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(root, "symphony-acceptance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow = Path.join(root, "WORKFLOW.md")

    config = %{
      tracker: %{kind: "memory", active_states: ["open"], terminal_states: ["closed"], required_labels: []},
      workspace: %{root: root <> "/workspaces"},
      polling: %{interval_ms: 60_000},
      agent: %{max_concurrent_agents: 1},
      observability: %{dashboard_enabled: false},
      control: %{
        enabled: true,
        state_path: root <> "/control.json",
        initial_mode: "paused",
        base_sha: @base,
        max_attempts: 2,
        max_total_runtime_ms: 60_000,
        max_total_tokens: 100
      }
    }

    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(workflow)
    issue = %Issue{id: "7", identifier: "GH-7", title: "Acceptance", state: "open", dispatchable: true, updated_at: @updated}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    supervisor = start_supervised!({Task.Supervisor, []})
    name = Module.concat(__MODULE__, "Owner#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor})
    on_exit(fn -> File.rm_rf(root) end)
    %{pid: pid, issue: issue, config: config, workflow: workflow, root: root}
  end

  test "acceptance requires exact idle review evidence and preserves all consumed budgets", c do
    assert {:error, :task_not_reviewable} = Orchestrator.control_command(accept(), c.pid)
    seed(c.pid, %{"hold" => "owner_review", "handoff" => %{"candidate_sha" => @head}, "attempts" => 2, "runtime_ms" => 200, "tokens" => 90})
    command = accept(@head)
    assert {:error, :candidate_changed} = Orchestrator.control_command(accept(), c.pid)
    assert {:error, :task_changed} = Orchestrator.control_command(%{command | "expected_tracker_state" => "closed"}, c.pid)
    assert {:error, :task_changed} = Orchestrator.control_command(%{command | "expected_updated_at" => "2026-09-23T09:00:00Z"}, c.pid)
    assert {:error, :revision_conflict} = Orchestrator.control_command(%{command | "expected_revision" => 1}, c.pid)
    seed(c.pid, %{"active" => %{"run_id" => "active", "started_at_ms" => 0, "tokens" => 0}})
    assert {:error, :issue_running} = Orchestrator.control_command(command, c.pid)
    seed(c.pid, %{"active" => nil})
    assert {:ok, %{"revision" => 1, "replayed" => false}} = Orchestrator.control_command(command, c.pid)
    snapshot = Orchestrator.control_snapshot(c.pid)
    item = snapshot["issues"]["7"]
    assert item["hold"] == "accepted"
    assert item["attempts"] == 2
    assert item["runtime_ms"] == 200
    assert item["tokens"] == 90
    assert item["acceptance"]["candidate_sha"] == @head
    assert IssueAcceptance.accepted?(item)
    assert Jason.decode!(File.read!(c.config.control.state_path))["issues"]["7"]["acceptance"] == item["acceptance"]
    assert {:error, :task_already_accepted} = Orchestrator.control_command(control("retry", 1), c.pid)
    assert {:error, :task_already_accepted} = Orchestrator.control_command(control("cancel", 1), c.pid)
    refute ControlLedger.eligible?(:sys.get_state(c.pid).control, "7")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    assert {:ok, %{"replayed" => true}} = Orchestrator.control_command(command, c.pid)
    assert {:error, :command_id_conflict} = Orchestrator.control_command(%{command | "expected_candidate_sha" => nil}, c.pid)

    stop_supervised!(Orchestrator)
    {:ok, ledger} = ControlLedger.open(Map.merge(c.config.control, %{state_path: c.config.control.state_path}), c.config.workspace.root)
    assert ledger.data["issues"]["7"]["acceptance"] == item["acceptance"]
    assert {:ok, _, _, true} = ControlLedger.command(ledger, command)
    ControlLedger.close(ledger)
  end

  test "acceptance validation rejects malformed persisted records and direct invalid commands" do
    assert IssueAcceptance.valid_record?(nil)
    refute IssueAcceptance.valid_record?(false)
    refute IssueAcceptance.valid_record?(%{})
    assert {:error, :invalid_command} = IssueAcceptance.accept(%{}, %{}, %{})
    verified = %{id: "7", state: "open", updated_at: DateTime.to_iso8601(@updated), terminal: true}
    context = %{tracker_fingerprint: "scope", acceptance_issue: verified}
    assert {:ok, accepted} = IssueAcceptance.accept(%{}, accept(), context)
    assert {:error, :task_already_accepted} = IssueAcceptance.accept(accepted, accept(), context)
    refute IssueAcceptance.valid_record?(Map.put(accepted["acceptance"], "accepted_at", "not-a-date"))
  end

  test "native feedback poller reads owner state without publishing absent selected feedback", c do
    alias SymphonyElixir.FeedbackSync
    request = fn _, _, _, _, _ -> flunk("No feedback is selected") end
    pid = start_supervised!({FeedbackSync, name: nil, interval_ms: :manual, request_fun: request})
    FeedbackSync.sync(pid)
    config = put_in(c.config, [:tracker, :kind], "github")
    config = put_in(config, [:tracker, :provider], %{repo: "owner/repo", token: "fake-token"})
    File.write!(c.workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(c.workflow)
    FeedbackSync.sync(pid)
  end

  test "closed tracker issues require explicit acceptance and raw GitHub identity is checked", c do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, RawGitHub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :github_client_module)

      Application.delete_env(:symphony_elixir, :acceptance_issues)
    end)

    tracker = %{
      kind: "github",
      provider: %{repo: "owner/repo", token: "test-token"},
      active_states: ["open"],
      terminal_states: ["closed"],
      required_labels: []
    }

    config = Map.put(c.config, :tracker, tracker)
    File.write!(c.workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(c.workflow)
    issue = %{c.issue | state: "closed", description: nil, native_ref: %{"repo" => "other/repo"}}
    Application.put_env(:symphony_elixir, :acceptance_issues, [issue])
    command = %{accept() | "expected_tracker_state" => "closed"}
    assert {:error, :task_not_found} = Orchestrator.control_command(command, c.pid)
    Application.put_env(:symphony_elixir, :acceptance_issues, [%{issue | native_ref: %{"repo" => "owner/repo"}, dispatchable: false}])
    assert {:error, :task_not_found} = Orchestrator.control_command(command, c.pid)
    Application.put_env(:symphony_elixir, :acceptance_issues, [%{issue | native_ref: %{"repo" => "owner/repo"}}])
    fingerprint = Orchestrator.tracker_fingerprint()
    assert {:error, :unauthorized} = Orchestrator.control_command_guarded(command, fingerprint, c.pid, fn -> false end)
    assert {:ok, _} = Orchestrator.control_command_guarded(command, fingerprint, c.pid, fn -> true end)
    assert Orchestrator.control_snapshot(c.pid)["issues"]["7"]["acceptance"]["candidate_sha"] == nil
  end

  test "acceptance rechecks authorization and failed persistence cannot create a receipt", c do
    seed(c.pid, %{"hold" => "owner_review", "handoff" => %{"candidate_sha" => @head}})
    {:ok, count} = Agent.start_link(fn -> 0 end)
    authorize = fn -> Agent.get_and_update(count, fn n -> {n == 0, n + 1} end) end
    fingerprint = Orchestrator.tracker_fingerprint()
    assert {:error, :unauthorized} = Orchestrator.control_command_guarded(accept(@head), fingerprint, c.pid, authorize)
    assert Orchestrator.control_snapshot(c.pid)["revision"] == 0
    assert Orchestrator.control_snapshot(c.pid)["issues"]["7"]["acceptance"] == nil
    File.rename!(c.config.control.state_path, c.config.control.state_path <> ".saved")
    File.mkdir!(c.config.control.state_path)
    assert {:error, :control_unavailable} = Orchestrator.control_command(accept(@head), c.pid)
    snapshot = Orchestrator.control_snapshot(c.pid)
    assert snapshot["revision"] == 0
    assert snapshot["issues"]["7"]["acceptance"] == nil
    assert is_binary(snapshot["fault"])
  end

  test "explicit PR rework opens a fresh attempt cycle without replenishing token or time budgets", c do
    seed(c.pid, %{"attempts" => 2, "tokens" => 23, "runtime_ms" => 100, "hold" => "owner_review", "handoff" => %{"candidate_sha" => @head}})
    state = :sys.get_state(c.pid)
    context = %{tracker_fingerprint: Orchestrator.tracker_fingerprint(), base_sha: @base, repository: "owner/repo"}
    create = Map.merge(control("create_pr_work", 0), %{"work_id" => String.duplicate("a", 32), "instruction" => "Address human feedback", "base_sha" => @base})
    assert {:ok, ledger, _, false} = ControlLedger.command(state.control, create, 1, context)
    assert ledger.data["issues"]["7"]["attempts"] == 2
    assert ledger.data["issues"]["7"]["attempt_base"] == 2
    assert ledger.data["issues"]["7"]["tokens"] == 23
    assert ledger.data["issues"]["7"]["runtime_ms"] == 100
    assert ControlLedger.snapshot(ledger)["issues"]["7"]["cycle_attempts"] == 0
    assert {:ok, ledger, _, _} = ControlLedger.command(ledger, %{"action" => "resume", "command_id" => "resume", "expected_revision" => 1})
    assert {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    assert {:ok, ledger} = ControlLedger.finish(ledger, "7", run)
    assert {:ok, ledger, _, true} = ControlLedger.command(ledger, create, 1, context)
    assert ControlLedger.snapshot(ledger)["issues"]["7"]["cycle_attempts"] == 1
    assert {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    assert {:ok, ledger} = ControlLedger.finish(ledger, "7", run)
    assert {:error, :not_admitted} = ControlLedger.reserve(ledger, "7")
    assert {:error, :budget_exhausted} = ControlLedger.command(ledger, control("retry", 2), 1, context)
    assert {:ok, ledger} = ControlLedger.hold(ledger, "7", "cancelled")
    continue = Map.merge(control("continue_pr_work", 2), %{"work_id" => create["work_id"], "instruction" => "A new explicit correction", "expected_head_sha" => nil})
    assert {:ok, next, _, false} = ControlLedger.command(ledger, continue, 1, context)
    assert next.data["issues"]["7"]["attempt_base"] == 4
    assert next.data["issues"]["7"]["attempts"] == 4
    assert next.data["issues"]["7"]["hold"] == "cancelled"

    for {key, value} <- [{"tokens", 100}, {"runtime_ms", 60_000}] do
      exhausted = %{ledger | data: put_in(ledger.data, ["issues", "7", key], value)}
      assert {:error, :budget_exhausted} = ControlLedger.command(exhausted, continue, 1, context)
    end
  end

  defp seed(pid, attrs) do
    :sys.replace_state(pid, fn state ->
      item = Map.get(state.control.data["issues"], "7", %{"attempts" => 0, "runtime_ms" => 0, "tokens" => 0, "hold" => nil, "active" => nil})
      ledger = %{state.control | data: put_in(state.control.data, ["issues", "7"], Map.merge(item, attrs))}
      %{state | control: ledger}
    end)
  end

  defp control(action, revision), do: %{"action" => action, "issue_id" => "7", "command_id" => "#{action}-#{revision}", "expected_revision" => revision}
  defp accept(sha \\ nil), do: Map.merge(control("accept_task", 0), %{"expected_candidate_sha" => sha, "expected_updated_at" => DateTime.to_iso8601(@updated), "expected_tracker_state" => "open"})
end
