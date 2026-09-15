defmodule SymphonyElixir.ControlledConcurrencyTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{PathSafety, ProcessGroup}

  test "two issue reservations run independently and cancellation admits the queued third" do
    {:ok, root} = PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony-concurrency-#{System.unique_integer([:positive])}"))
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    source = Path.join(root, "source")
    base = fixture_repository(source)
    server = fake_server(root)
    workspaces = Path.join(root, "workspaces")
    workflow = Path.join(root, "WORKFLOW.md")

    settings = %{
      tracker: %{kind: "memory", active_states: ["open"], terminal_states: ["closed"], required_labels: ["ready"]},
      workspace: %{root: workspaces},
      hooks: %{after_create: "git clone --local --no-hardlinks -- '#{source}' ."},
      polling: %{interval_ms: 60_000},
      agent: %{max_concurrent_agents: 2},
      observability: %{dashboard_enabled: false},
      codex: %{command: server, read_timeout_ms: 5_000, turn_timeout_ms: 30_000},
      control: %{enabled: true, state_path: Path.join(root, "control.json"), initial_mode: "paused", base_sha: base, max_attempts: 2, max_total_runtime_ms: 30_000, max_total_tokens: 100}
    }

    File.write!(workflow, "---\n" <> Jason.encode!(settings) <> "\n---\nKeep the fixture alive until cancelled.")
    Workflow.set_workflow_file_path(workflow)
    WorkflowStore.force_reload()

    issues =
      for number <- 7..9 do
        %Issue{id: to_string(number), identifier: "GH-#{number}", title: "Concurrent fixture #{number}", state: "open", labels: ["ready"], dispatchable: true}
      end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    supervisor = start_supervised!({Task.Supervisor, []})
    name = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor})

    try do
      assert {:ok, %{"revision" => 1}} = control(pid, "resume", "resume")
      first = await_running(pid, ["7", "8"])
      ledger = Orchestrator.control_snapshot(pid)
      assert Map.keys(ledger["issues"]) |> Enum.sort() == ["7", "8"]

      assert Enum.all?(ledger["issues"], fn {id, issue} ->
               issue["attempts"] == 1 and issue["active"]["run_id"] == first.running[id].run_id
             end)

      refute first.running["7"].run_id == first.running["8"].run_id
      refute File.exists?(Path.join(workspaces, "GH-9"))

      # Another poll while both slots are occupied must not reserve the third issue.
      send(pid, :run_poll_cycle)
      assert Orchestrator.control_snapshot(pid)["issues"] == ledger["issues"]
      assert map_size(:sys.get_state(pid).running) == 2
      survivor = first.running["8"]
      survivor_ledger = ledger["issues"]["8"]
      cancelled_ref = Process.monitor(first.running["7"].pid)

      assert {:ok, %{"revision" => 2}} = control(pid, "cancel-seven", "cancel", "7")
      assert_receive {:DOWN, ^cancelled_ref, :process, _pid, _reason}, 1_000
      assert Process.alive?(survivor.pid)
      assert Orchestrator.control_snapshot(pid)["issues"]["8"] == survivor_ledger

      assert %{"attempts" => 1, "tokens" => 7, "active" => nil, "hold" => "cancelled"} =
               Orchestrator.control_snapshot(pid)["issues"]["7"]

      send(pid, :run_poll_cycle)
      next = await_running(pid, ["8", "9"])
      assert next.running["8"].pid == survivor.pid
      assert next.running["8"].run_id == survivor.run_id
      assert Process.alive?(survivor.pid)
      refute next.running["9"].run_id in [first.running["7"].run_id, survivor.run_id]
      next_ledger = Orchestrator.control_snapshot(pid)
      assert next_ledger["issues"]["8"] == survivor_ledger
      assert %{"attempts" => 1, "active" => %{"tokens" => 9}} = next_ledger["issues"]["9"]
    after
      if Process.alive?(pid), do: control(pid, "cleanup", "pause")
      # Taking each workspace lock waits for its fake app-server's guardian cleanup.
      for number <- 7..9, workspace = Path.join(workspaces, "GH-#{number}"), File.dir?(workspace) do
        assert {:ok, {"clean", 0}} = ProcessGroup.run("printf clean", cd: workspace, timeout_ms: 5_000)
      end
    end
  end

  defp control(pid, command_id, action, issue_id \\ nil) do
    revision = Orchestrator.control_snapshot(pid)["revision"]
    command = %{"command_id" => command_id, "expected_revision" => revision, "action" => action}
    command = if issue_id, do: Map.put(command, "issue_id", issue_id), else: command
    Orchestrator.control_command(command, pid)
  end

  defp await_running(pid, expected) do
    Enum.find_value(1..1_000, fn _ ->
      state = :sys.get_state(pid)

      ready =
        Enum.sort(Map.keys(state.running)) == expected and
          Enum.all?(expected, fn id -> state.running[id].codex_total_tokens == String.to_integer(id) end)

      if ready do
        state
      else
        Process.sleep(10)
        nil
      end
    end) || flunk("Expected live fake app-server token reports for #{inspect(expected)}")
  end

  defp fixture_repository(source) do
    File.mkdir_p!(source)

    for args <- [["init", "-b", "main"], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"]] do
      {_, 0} = System.cmd("git", args, cd: source, stderr_to_stdout: true)
    end

    File.write!(Path.join(source, "source.txt"), "fixture\n")
    {_, 0} = System.cmd("git", ["add", "source.txt"], cd: source)
    {_, 0} = System.cmd("git", ["commit", "-m", "Fixture"], cd: source)
    {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source)
    String.trim(base)
  end

  defp fake_server(root) do
    path = Path.join(root, "fake-server")

    File.write!(path, """
    #!/usr/bin/env python3
    import json, os, sys, time
    identifier = os.path.basename(os.getcwd())
    def send(value):
        print(json.dumps(value), flush=True)
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get('method')
        if method == 'initialize':
            send({'id': 1, 'result': {}})
        elif method == 'thread/start':
            profile = message['params']['config']['default_permissions']
            send({'id': 2, 'result': {'thread': {'id': identifier}, 'activePermissionProfile': {'id': profile}}})
        elif method == 'turn/start':
            send({'id': 3, 'result': {'turn': {'id': identifier + '-turn'}}})
            tokens = int(identifier.split('-')[1])
            send({'method': 'thread/tokenUsage/updated', 'params': {'tokenUsage': {'total': {
                'inputTokens': tokens, 'outputTokens': 0, 'totalTokens': tokens}}}})
            time.sleep(30)
            break
    """)

    File.chmod!(path, 0o700)
    path
  end
end
