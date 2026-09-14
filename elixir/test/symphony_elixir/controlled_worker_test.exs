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
    assert {:error, :response_timeout} = AppServer.run(workspace, "bounded acknowledgement", issue())
    assert System.monotonic_time(:millisecond) - started < 1_500
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

    assert :ok = AgentRunner.run(issue(), self(), run_id: "run-123")
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
    assert builder["params"]["sandbox"] == "workspace-write"
    assert reviewer["params"]["sandbox"] == "read-only"
    assert Enum.all?(threads, &(&1["params"]["dynamicTools"] == []))
    assert builder["params"]["config"]["model_reasoning_effort"] == "medium"
    assert reviewer["params"]["config"]["model_reasoning_effort"] == "high"
    assert Enum.all?(threads, &(&1["params"]["model"] == "gpt-6-astra"))
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
    role = 'builder'
    def send(value):
        print(json.dumps(value), flush=True)
    for line in sys.stdin:
        msg = json.loads(line)
        with open(trace, 'a') as f: f.write(json.dumps(msg) + '\\n')
        method = msg.get('method')
        if method == 'initialize': send({'id': 1, 'result': {}})
        elif method == 'thread/start':
            role = 'reviewer' if msg['params'].get('sandbox') == 'read-only' else 'builder'
            send({'id': 2, 'result': {'thread': {'id': role}}})
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
