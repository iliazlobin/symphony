defmodule SymphonyElixir.ControlledWorkerTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{CandidatePipeline, PathSafety, ProcessGroup}

  setup do
    {:ok, root} = PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony-controlled-#{System.unique_integer([:positive])}"))
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "controlled deadline expires despite continuous stream events", %{root: root} do
    workspace = Path.join(root, "issue")
    File.mkdir_p!(workspace)
    fake = fake_server(root, "stream")
    controlled_workflow(root, fake, codex_turn_timeout_ms: 180)
    started = System.monotonic_time(:millisecond)
    assert {:error, :turn_timeout} = AppServer.run(workspace, "bounded", issue())
    assert System.monotonic_time(:millisecond) - started < 1_500
  end

  test "turn deadline includes acknowledgement time and cannot be prolonged by startup chatter", %{root: root} do
    workspace = Path.join(root, "issue")
    File.mkdir_p!(workspace)
    fake = fake_server(root, "ack_storm")
    controlled_workflow(root, fake, codex_turn_timeout_ms: 180, codex_read_timeout_ms: 5_000)
    started = System.monotonic_time(:millisecond)
    assert {:error, {:startup_failed, :turn_start, :response_timeout}} = AppServer.run(workspace, "bounded acknowledgement", issue())
    assert System.monotonic_time(:millisecond) - started < 1_500
  end

  test "startup failures identify the controlled phase while uncontrolled errors stay unchanged",
       %{root: root} do
    for controlled <- [true, false], phase <- [:initialize, :thread_start, :turn_start] do
      fixture = Path.join(root, "#{controlled}-#{phase}")
      workspace = Path.join(fixture, "issue")
      File.mkdir_p!(workspace)
      fake = fake_server(fixture, "error_#{phase}")
      configure_startup(fixture, fake, controlled)

      error = %{
        "code" => -32000,
        "message" => "PRIVATE_RPC_SENTINEL",
        "data" => %{"secret" => "PRIVATE_DATA_SENTINEL"}
      }

      reason = {:response_error, error}
      expected = if controlled, do: {:startup_failed, phase, reason}, else: reason

      logs =
        capture_log(fn ->
          assert {:error, ^expected} =
                   AppServer.run(workspace, "PRIVATE_PROMPT_SENTINEL", issue())
        end)

      diagnostic_lines =
        logs |> String.split("\n") |> Enum.filter(&String.contains?(&1, "Codex startup "))

      if controlled do
        assert Enum.any?(diagnostic_lines, &String.contains?(&1, "failed phase=#{phase}"))
        assert Enum.any?(diagnostic_lines, &String.contains?(&1, "reason=response_error"))
        assert logs =~ "worker_role=builder"
        assert logs =~ "issue_id=42 issue_identifier=EC-42"
        assert logs =~ ~r/elapsed_ms=\d+/
        if phase == :turn_start, do: assert(logs =~ "thread_id=builder")
        refute Enum.any?(diagnostic_lines, &String.contains?(&1, "PRIVATE_"))
      else
        assert diagnostic_lines == []
      end

      assert_startup_stopped(fixture, phase)
    end
  end

  test "guardian kills same-group children and grandchildren after its Erlang owner dies", %{root: root} do
    pid_file = Path.join(root, "pids")
    caller = self()

    owner =
      spawn(fn ->
        {:ok, _port} = ProcessGroup.open("trap '' TERM; sleep 30 & echo \"$$ $!\" > '#{pid_file}'; wait", cd: root)
        send(caller, :opened)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :opened
    wait_until(fn -> File.exists?(pid_file) end)
    pids = File.read!(pid_file) |> String.split()
    assert Enum.all?(pids, &process_alive?/1)
    Process.exit(owner, :kill)
    wait_until(fn -> Enum.all?(pids, &(not process_alive?(&1))) end)
  end

  test "normal completion also stops same-group background descendants and timeout is bounded", %{root: root} do
    pid_file = Path.join(root, "background")
    assert {:ok, {"", 0}} = ProcessGroup.run("sleep 30 & echo $! > '#{pid_file}'", cd: root, timeout_ms: 2_000)
    pid = File.read!(pid_file) |> String.trim()
    wait_until(fn -> not process_alive?(pid) end)
    assert {:error, :command_timeout} = ProcessGroup.run("while true; do echo still-running; sleep 0.01; done", cd: root, timeout_ms: 80)
  end

  test "a replacement command waits for the prior process group to be reaped", %{root: root} do
    pid_file = Path.join(root, "old-owner")

    owner =
      spawn(fn ->
        {:ok, _} = ProcessGroup.open("trap '' TERM; echo $$ > '#{pid_file}'; sleep 30 & wait", cd: root)

        receive do
          :never -> :ok
        end
      end)

    wait_until(fn -> File.exists?(pid_file) end)
    old_pid = File.read!(pid_file) |> String.trim()
    Process.exit(owner, :kill)

    assert {:ok, {"clear\n", 0}} =
             ProcessGroup.run("if kill -0 #{old_pid} 2>/dev/null; then echo overlap; else echo clear; fi", cd: root, timeout_ms: 2_000)
  end

  test "repository Python modules cannot replace the host process guardian imports", %{root: root} do
    File.write!(Path.join(root, "selectors.py"), "raise RuntimeError('repository code executed outside worker sandbox')\n")
    assert {:ok, {"safe\n", 0}} = ProcessGroup.run("echo safe", cd: root, timeout_ms: 2_000)
  end

  test "command output limit prevents an unbounded result from entering the coordinator", %{root: root} do
    assert {:error, :command_output_limit} =
             ProcessGroup.run("python3 -I -c 'print(\"x\" * 1100000)'", cd: root, timeout_ms: 2_000)
  end

  test "missing guardian runtime fails before a command is launched", %{root: root} do
    previous_path = System.get_env("PATH")

    try do
      System.put_env("PATH", root)
      assert {:error, :process_guardian_python_not_found} = ProcessGroup.open("echo should-not-run")
      assert {:error, :process_guardian_python_not_found} = ProcessGroup.run("echo should-not-run", cd: root, timeout_ms: 100)
    after
      restore_env("PATH", previous_path)
    end
  end

  test "cleanup tolerates an already closed or missing port handle", %{root: root} do
    {:ok, port} = ProcessGroup.open("sleep 1", cd: root)
    assert :ok = ProcessGroup.close(port)
    assert :ok = ProcessGroup.close(port)
    assert :ok = ProcessGroup.close(nil)
    assert {:error, :command_timeout} = ProcessGroup.run("sleep 1", cd: root, timeout_ms: 0)
  end

  test "controlled workspaces survive closure and failing setup hooks", %{root: root} do
    controlled_workflow(root, "false", hook_after_create: "echo preserved > evidence; exit 1")
    assert {:error, {:workspace_hook_failed, "after_create", 1, _}} = Workspace.create_for_issue(issue())
    workspace = Path.join(root, issue().identifier)
    assert File.read!(Path.join(workspace, "evidence")) == "preserved\n"
    assert {:ok, []} = Workspace.remove(workspace)
    assert {:ok, []} = Workspace.remove_recorded(workspace, nil)
    assert File.dir?(workspace)
  end

  test "candidate is reviewed in fresh immutable checkout and handed off once", %{root: root} do
    workspace = Path.join(root, issue().identifier)
    init_repo(workspace)
    {base_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    base_sha = String.trim(base_sha)
    File.write!(Path.join(workspace, "source"), "prior attempt\n")
    {_output, 0} = System.cmd("git", ["commit", "-am", "prior attempt"], cd: workspace)
    fake = fake_server(root, "candidate")
    controlled_workflow(root, fake, control_base_sha: base_sha)

    git_calls = trace_git_calls(fn -> assert :ok = AgentRunner.run(issue(), self(), run_id: "run-123") end)
    {clones, other_git_calls} = Enum.split_with(git_calls, fn {command, _opts} -> String.contains?(command, "--no-hardlinks") end)
    assert [{clone_command, clone_opts}] = clones
    assert clone_command =~ "--local"
    assert clone_command =~ "--no-checkout"
    assert clone_opts[:timeout_ms] == 120_000
    assert other_git_calls != []
    assert Enum.all?(other_git_calls, fn {_command, opts} -> opts[:timeout_ms] == 30_000 end)
    assert_receive {:worker_runtime_info, "42", "run-123", %{workspace_path: ^workspace}}
    assert_receive {:codex_worker_update, "42", "run-123", %{event: :session_started}}
    assert_receive {:worker_candidate_ready, "42", candidate}, 1_000
    assert candidate.run_id == "run-123"
    assert candidate.base_sha == base_sha
    assert candidate.review["candidate_sha"] == candidate.candidate_sha
    assert candidate.review["verdict"] == "approve"
    assert candidate.base_sha != candidate.candidate_sha
    assert File.read!(Path.join(candidate.review_workspace_path, "source")) == "candidate\n"
    assert candidate.workspace_path != candidate.review_workspace_path
    assert candidate.builder_session_id != candidate.reviewer_session_id
    assert :ok = CandidatePipeline.verify_revision(candidate.review_workspace_path, candidate.candidate_sha, false)
    refute_receive {:worker_candidate_ready, _, _}

    calls = File.read!(Path.join(root, "trace")) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    threads = Enum.filter(calls, &(&1["method"] == "thread/start"))
    assert length(threads) == 2
    [builder, reviewer] = threads
    assert builder["params"]["config"]["default_permissions"] == "symphony-builder"
    assert reviewer["params"]["config"]["default_permissions"] == "symphony-reviewer"
    assert Enum.all?(threads, &(not Map.has_key?(&1["params"], "sandbox")))
    turns = Enum.filter(calls, &(&1["method"] == "turn/start"))
    assert length(turns) == 2
    assert Enum.all?(turns, &(not Map.has_key?(&1["params"], "sandboxPolicy")))
    assert Enum.all?(threads ++ turns, &(&1["params"]["approvalPolicy"] == "never"))
    assert Enum.all?(threads, &(&1["params"]["dynamicTools"] == []))
    assert builder["params"]["config"]["model_reasoning_effort"] == "medium"
    assert reviewer["params"]["config"]["model_reasoning_effort"] == "high"
    assert Enum.all?(threads, &(&1["params"]["model"] == "gpt-6-astra"))
  end

  test "controlled startup rejects missing, malformed and different active permission profiles before any turn", %{root: root} do
    workspace = Path.join(root, "issue")
    File.mkdir_p!(workspace)

    for role <- [:builder, :reviewer], mode <- ["missing_profile", "malformed_profile", "wrong_profile"] do
      fake = fake_server(root, mode)
      controlled_workflow(root, fake)
      expected = "symphony-#{role}"

      assert {:error, {:startup_failed, :thread_start, {:permission_profile_mismatch, ^expected}}} =
               AppServer.run(workspace, "Must not execute", issue(), profile: role)
    end

    calls = File.read!(Path.join(root, "trace")) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    refute Enum.any?(calls, &(&1["method"] == "turn/start"))
  end

  test "unknown controlled roles are rejected before launching a process", %{root: root} do
    workspace = Path.join(root, "issue")
    File.mkdir_p!(workspace)
    fake = fake_server(root, "candidate")
    controlled_workflow(root, fake)
    assert {:error, :invalid_controlled_worker_profile} = AppServer.start_session(workspace, profile: :publisher)
    refute File.exists?(Path.join(root, "trace"))
  end

  test "handoff rejects dirty source, wrong SHA, branch, malformed checks and symlinks", %{root: root} do
    workspace = Path.join(root, "issue")
    init_repo(workspace)
    controlled_workflow(root, "false")
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    {branch, 0} = System.cmd("git", ["symbolic-ref", "--short", "HEAD"], cd: workspace)
    valid = %{candidate_sha: String.trim(sha), branch: String.trim(branch), summary: "change", checks: [], limitations: []}
    handoff = Path.join(workspace, ".symphony/handoff.json")
    File.mkdir_p!(Path.dirname(handoff))
    File.write!(handoff, Jason.encode!(valid))
    assert {:ok, _} = CandidatePipeline.read_candidate(workspace)
    File.write!(Path.join(workspace, "source"), "changed")
    assert {:error, :candidate_source_is_dirty} = CandidatePipeline.read_candidate(workspace)
    File.write!(Path.join(workspace, "source"), "base\n")
    File.write!(handoff, Jason.encode!(%{valid | candidate_sha: String.duplicate("a", 40)}))
    assert {:error, :candidate_sha_mismatch} = CandidatePipeline.read_candidate(workspace)
    File.write!(handoff, Jason.encode!(%{valid | branch: "other"}))
    assert {:error, :invalid_candidate_handoff} = CandidatePipeline.read_candidate(workspace)
    File.write!(handoff, Jason.encode!(%{valid | checks: ["passed"]}))
    assert {:error, :invalid_candidate_handoff} = CandidatePipeline.read_candidate(workspace)
    File.rm!(handoff)
    File.write!(Path.join(root, "external"), Jason.encode!(valid))
    File.ln_s!(Path.join(root, "external"), handoff)
    assert {:error, :invalid_candidate_handoff} = CandidatePipeline.read_candidate(workspace)
  end

  test "review result rejects stale SHA and contradictory approval" do
    sha = String.duplicate("a", 40)
    valid = %{candidate_sha: sha, verdict: "approve", summary: "reviewed", findings: []}
    assert {:ok, _} = CandidatePipeline.review_result(%{final_messages: [Jason.encode!(valid)]}, sha)
    assert {:error, :invalid_review_result} = CandidatePipeline.review_result(%{final_messages: [Jason.encode!(valid)]}, String.duplicate("b", 40))
    finding = %{severity: "high", path: "source", line: 1, description: "Broken"}
    assert {:error, :invalid_review_result} = CandidatePipeline.review_result(%{final_messages: [Jason.encode!(%{valid | findings: [finding]})]}, sha)
    assert {:error, :invalid_review_result} = CandidatePipeline.review_result(%{final_messages: []}, sha)
  end

  test "candidate validation never invokes repository fsmonitor commands on the host", %{root: root} do
    workspace = Path.join(root, "issue")
    init_repo(workspace)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    marker = Path.join(root, "escaped-worker")
    {_output, 0} = System.cmd("git", ["config", "core.fsmonitor", "echo escaped > '#{marker}'"], cd: workspace)
    assert :ok = CandidatePipeline.verify_revision(workspace, String.trim(sha))
    refute File.exists?(marker)
  end

  test "missing approved baseline stops before launching a builder", %{root: root} do
    workspace = Path.join(root, issue().identifier)
    init_repo(workspace)
    fake = fake_server(root, "candidate")
    controlled_workflow(root, fake)
    assert {:error, :approved_baseline_required} = CandidatePipeline.run(workspace, issue(), [run_id: "no-base"], fn _ -> :ok end)
    refute File.exists?(Path.join(root, "trace"))
  end

  defp configure_startup(root, command, true), do: controlled_workflow(root, command)

  defp configure_startup(root, command, false) do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      tracker_kind: "memory",
      codex_command: command
    )

    WorkflowStore.force_reload()
  end

  defp assert_startup_stopped(root, phase) do
    expected =
      case phase do
        :initialize -> ["initialize"]
        :thread_start -> ["initialize", "initialized", "thread/start"]
        :turn_start -> ["initialize", "initialized", "thread/start", "turn/start"]
      end

    methods =
      File.read!(Path.join(root, "trace"))
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!(&1)["method"])

    assert methods == expected
    pid = File.read!(Path.join(root, "fake-server.pid")) |> String.trim()
    wait_until(fn -> not process_alive?(pid) end)
  end

  defp controlled_workflow(root, command, overrides \\ []) do
    settings = [workspace_root: root, tracker_kind: "memory", codex_command: command] ++ overrides
    write_workflow_file!(Workflow.workflow_file_path(), settings)
    path = Workflow.workflow_file_path()
    base = Keyword.get(overrides, :control_base_sha)
    section = "\ncontrol:\n  enabled: true\n  state_path: #{root}/control.json\n  base_sha: #{base || "null"}\n---\n"
    content = File.read!(path) |> String.replace("\n---\n", section, global: false)
    File.write!(path, content)
    WorkflowStore.force_reload()
  end

  defp trace_git_calls(callback) do
    collect = fn collect, calls ->
      receive do
        {:trace, _pid, :call, {ProcessGroup, :run, [command, opts]}} -> collect.(collect, [{command, opts} | calls])
        {:collect, caller} -> send(caller, {:git_calls, Enum.reverse(calls)})
      end
    end

    tracer = spawn(fn -> collect.(collect, []) end)
    Code.ensure_loaded!(ProcessGroup)
    :erlang.trace_pattern({ProcessGroup, :run, 2}, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      callback.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({ProcessGroup, :run, 2}, false, [])
      reference = :erlang.trace_delivered(self())

      try do
        assert_receive {:trace_delivered, _pid, ^reference}
      after
        send(tracer, {:collect, self()})
      end
    end

    assert_receive {:git_calls, calls}
    calls
  end

  defp issue, do: %Issue{id: "42", identifier: "EC-42", title: "Fixture candidate", description: "Keep behavior", state: "In Progress", labels: []}

  defp init_repo(workspace) do
    File.mkdir_p!(workspace)

    for args <- [["init", "-b", "codex/fixture"], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"]] do
      {_output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    File.write!(Path.join(workspace, "source"), "base\n")
    {_output, 0} = System.cmd("git", ["add", "source"], cd: workspace)
    {_output, 0} = System.cmd("git", ["commit", "-m", "fixture"], cd: workspace)
  end

  defp fake_server(root, mode) do
    path = Path.join(root, "fake-server")

    File.write!(path, """
    #!/usr/bin/env python3
    import json, os, subprocess, sys, time
    mode = #{Jason.encode!(mode)}
    trace = #{Jason.encode!(Path.join(root, "trace"))}
    with open(#{Jason.encode!(Path.join(root, "fake-server.pid"))}, 'w') as f: f.write(str(os.getpid()))
    role = 'builder'
    def send(value):
        print(json.dumps(value), flush=True)
    for line in sys.stdin:
        msg = json.loads(line)
        with open(trace, 'a') as f: f.write(json.dumps(msg) + '\\n')
        method = msg.get('method')
        if mode == 'error_' + method.replace('/', '_'):
            send({'id': msg['id'], 'error': {'code': -32000, 'message': 'PRIVATE_RPC_SENTINEL', 'data': {'secret': 'PRIVATE_DATA_SENTINEL'}}})
            continue
        if method == 'initialize': send({'id': 1, 'result': {}})
        elif method == 'thread/start':
            profile = msg['params'].get('config', {}).get('default_permissions', 'symphony-builder')
            role = 'reviewer' if profile == 'symphony-reviewer' else 'builder'
            result = {'thread': {'id': role}, 'activePermissionProfile': {'id': profile}}
            if mode == 'missing_profile': result.pop('activePermissionProfile')
            if mode == 'malformed_profile': result['activePermissionProfile'] = 'invalid'
            if mode == 'wrong_profile': result['activePermissionProfile'] = {'id': ':workspace'}
            send({'id': 2, 'result': result})
        elif method == 'turn/start':
            if mode == 'ack_storm':
                for n in range(100):
                    send({'method': 'item/updated', 'params': {'n': n}})
                    time.sleep(0.025)
            send({'id': 3, 'result': {'turn': {'id': 'turn'}}})
            if mode == 'stream':
                for n in range(100):
                    send({'method': 'item/updated', 'params': {'n': n}})
                    time.sleep(0.025)
            else:
                if role == 'builder':
                    with open('source', 'w') as f: f.write('candidate\\n')
                    subprocess.run(['git', 'add', 'source'], check=True)
                    subprocess.run(['git', 'commit', '-m', 'candidate'], check=True, stdout=subprocess.DEVNULL)
                    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
                    branch = subprocess.check_output(['git', 'symbolic-ref', '--short', 'HEAD'], text=True).strip()
                    os.makedirs('.symphony', exist_ok=True)
                    with open('.symphony/handoff.json', 'w') as f:
                        json.dump({'candidate_sha': sha, 'branch': branch, 'summary': 'fixture', 'checks': [], 'limitations': []}, f)
                    result = 'Ready for review'
                else:
                    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
                    result = json.dumps({'candidate_sha': sha, 'verdict': 'approve', 'summary': 'Reviewed fixture', 'findings': []})
                send({'method': 'item/completed', 'params': {'item': {'type': 'agentMessage', 'text': result}}})
            send({'method': 'turn/completed', 'params': {'turn': {'status': 'completed'}}})
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp process_alive?(pid) do
    {_output, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    status == 0
  end

  defp wait_until(fun, attempts \\ 40)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    unless fun.() do
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end
end
