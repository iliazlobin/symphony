defmodule SymphonyElixir.PrWorkRuntimeTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{CandidatePipeline, PathSafety}

  setup do
    {:ok, root} = PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony-pr-work-#{System.unique_integer([:positive])}"))
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    id = String.duplicate("a", 32)
    key = "GH-42-#{id}"
    workspace = Path.join(root, key)
    File.mkdir_p!(workspace)

    for args <- [["init", "-b", "codex/" <> String.downcase(key)], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"]] do
      {_, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    File.write!(Path.join(workspace, "source"), "base\n")
    git(workspace, ["add", "source"])
    git(workspace, ["commit", "-m", "baseline"])
    base = git(workspace, ["rev-parse", "HEAD"])

    work = %{
      "id" => id,
      "issue_id" => "42",
      "workspace_key" => key,
      "branch" => "codex/" <> String.downcase(key),
      "base_sha" => base,
      "head_sha" => nil,
      "builder_thread_id" => nil,
      "instruction" => "Implement only this PR scope"
    }

    configure(root, fake_server(root, "normal"), base)
    %{root: root, workspace: workspace, work: work}
  end

  test "one PR builder resumes its checkpointed native thread while each reviewer is fresh", c do
    assert :ok = AgentRunner.run(issue(), self(), options(c))
    assert_receive {:worker_candidate_ready, "42", first}, 1_000
    assert first.work_id == c.work["id"]
    assert first.expected_head_sha == nil
    assert first.builder_thread_id == "retained-builder"
    assert first.branch == c.work["branch"]
    assert first.base_sha == c.work["base_sha"]
    assert first.review["candidate_sha"] == first.candidate_sha
    second_work = Map.merge(c.work, %{"builder_thread_id" => first.builder_thread_id, "head_sha" => first.candidate_sha})
    File.rm!(Path.join(c.root, "checkpoint"))
    assert {:ok, second} = CandidatePipeline.run(c.workspace, issue(), options(%{c | work: second_work}), fn _ -> :ok end)
    assert second.builder_thread_id == first.builder_thread_id
    assert second.expected_head_sha == first.candidate_sha
    assert second.candidate_sha != first.candidate_sha
    assert second.reviewer_session_id != first.reviewer_session_id
    assert second.review_workspace_path != first.review_workspace_path
    assert :ok = CandidatePipeline.verify_revision(second.review_workspace_path, second.candidate_sha, false)
    calls = calls(c)
    [resume] = Enum.filter(calls, &(&1["method"] == "thread/resume"))
    assert resume["params"]["threadId"] == first.builder_thread_id
    assert resume["params"]["config"]["default_permissions"] == "symphony-builder"
    assert resume["params"]["dynamicTools"] == []
    assert resume["params"]["approvalPolicy"] == "never"
    starts = Enum.filter(calls, &(&1["method"] == "thread/start"))
    assert length(starts) == 3
    assert Enum.count(starts, &(&1["params"]["config"]["default_permissions"] == "symphony-reviewer")) == 2
    assert Enum.all?(Enum.filter(calls, &(&1["method"] == "turn/start")), &(not Map.has_key?(&1["params"], "sandboxPolicy")))
  end

  test "selected feedback reaches both roles and requires exact per-comment evidence", c do
    feedback = %{
      "id" => "IC_42",
      "revision" => String.duplicate("d", 64),
      "body" => "Correct the example",
      "author" => "human",
      "source" => "issue",
      "pr_number" => nil,
      "url" => "https://github.com/example/repo/issues/42#issuecomment-42"
    }

    result = Map.merge(Map.take(feedback, ~w(id revision)), %{"status" => "addressed", "details" => "Example corrected; focused check passed"})
    File.write!(Path.join(c.root, "feedback-results"), Jason.encode!([result]))
    context = %{c | work: Map.put(c.work, "feedback", [feedback])}
    assert {:ok, candidate} = CandidatePipeline.run(c.workspace, issue(), options(context), fn _ -> :ok end)
    assert candidate.feedback_items == [feedback]
    assert candidate.feedback_results == [result]
    prompts = calls(c) |> Enum.filter(&(&1["method"] == "turn/start")) |> Jason.encode!()
    assert prompts =~ "Correct the example"
    assert prompts =~ "Verify every feedback_results disposition"
  end

  test "omitted selected feedback disposition prevents review and handoff", c do
    feedback = %{
      "id" => "IC_42",
      "revision" => String.duplicate("d", 64),
      "body" => "Correct the example",
      "author" => "human",
      "source" => "issue",
      "pr_number" => nil,
      "url" => "https://github.com/example/repo/issues/42#issuecomment-42"
    }

    context = %{c | work: Map.put(c.work, "feedback", [feedback])}
    assert {:error, :invalid_feedback_handoff} = CandidatePipeline.run(c.workspace, issue(), options(context), fn _ -> :ok end)
    assert Enum.count(calls(c), &(&1["method"] == "thread/start")) == 1
  end

  test "owner checkpoint failure stops before turn start and retains the verified thread identity", c do
    parent = self()

    checkpoint = fn attrs ->
      send(parent, {:checkpoint, attrs})
      {:error, :stale_owner}
    end

    opts = Keyword.put(options(c), :checkpoint_pr_work, checkpoint)
    assert {:error, :stale_owner} = CandidatePipeline.run(c.workspace, issue(), opts, fn _ -> :ok end)
    assert_received {:checkpoint, %{"builder_thread_id" => "retained-builder"}}
    refute Enum.any?(calls(c), &(&1["method"] == "turn/start"))
    assert git(c.workspace, ["rev-parse", "HEAD"]) == c.work["base_sha"]
  end

  test "a failed reviewer resumes the validated working head without advancing the publication fence", c do
    configure(c.root, fake_server(c.root, "review_failure"), c.work["base_sha"])
    assert {:error, :invalid_review_result} = CandidatePipeline.run(c.workspace, issue(), options(c), fn _ -> :ok end)
    checkpoint = File.read!(Path.join(c.root, "checkpoint")) |> Jason.decode!()
    assert checkpoint["working_head_sha"] == git(c.workspace, ["rev-parse", "HEAD"])
    work = Map.merge(c.work, checkpoint)
    assert work["head_sha"] == nil
    configure(c.root, fake_server(c.root, "normal"), c.work["base_sha"])
    assert {:ok, candidate} = CandidatePipeline.run(c.workspace, issue(), options(%{c | work: work}), fn _ -> :ok end)
    assert candidate.expected_head_sha == nil
    assert candidate.builder_thread_id == checkpoint["builder_thread_id"]
    reviewer_starts = Enum.filter(calls(c), &(&1["params"]["config"]["default_permissions"] == "symphony-reviewer"))
    assert length(reviewer_starts) == 2
    assert Enum.any?(calls(c), &(&1["method"] == "thread/resume"))
  end

  test "working head checkpoint failure prevents review and keeps committed source", c do
    checkpoint = fn attrs ->
      if attrs["working_head_sha"], do: {:error, :owner_persistence_failed}, else: options(c)[:checkpoint_pr_work].(attrs)
    end

    opts = Keyword.put(options(c), :checkpoint_pr_work, checkpoint)
    assert {:error, :owner_persistence_failed} = CandidatePipeline.run(c.workspace, issue(), opts, fn _ -> :ok end)
    refute git(c.workspace, ["rev-parse", "HEAD"]) == c.work["base_sha"]
    assert Enum.count(calls(c), &(&1["method"] == "thread/start")) == 1
  end

  test "mismatched resume identity or permission response never checkpoints or starts a turn", c do
    work = %{c.work | "builder_thread_id" => "retained-builder"}

    for mode <- ["wrong_id", "wrong_cwd", "wrong_approval", "wrong_profile"] do
      configure(c.root, fake_server(c.root, mode), work["base_sha"])
      File.rm(Path.join(c.root, "trace"))

      assert {:error, {:startup_failed, :thread_resume, _}} =
               CandidatePipeline.run(c.workspace, issue(), options(%{c | work: work}), fn _ -> flunk("Turn started") end)

      refute File.exists?(Path.join(c.root, "checkpoint"))
      assert Enum.any?(calls(c), &(&1["method"] == "thread/resume"))
      refute Enum.any?(calls(c), &(&1["method"] in ["thread/start", "turn/start"]))
    end
  end

  test "stale head and dirty workspace fail before model execution without resetting source", c do
    File.write!(Path.join(c.workspace, "source"), "retained changes\n")
    assert {:error, :candidate_source_is_dirty} = CandidatePipeline.run(c.workspace, issue(), options(c), fn _ -> :ok end)
    git(c.workspace, ["commit", "-am", "unexpected head"])
    assert {:error, :candidate_sha_mismatch} = CandidatePipeline.run(c.workspace, issue(), options(c), fn _ -> :ok end)
    assert File.read!(Path.join(c.workspace, "source")) == "retained changes\n"
    refute File.exists?(Path.join(c.root, "trace"))
  end

  test "work scope and callback are validated before worker execution", c do
    for work <- [
          nil,
          %{},
          %{c.work | "id" => "../other"},
          %{c.work | "issue_id" => "43"},
          %{c.work | "branch" => "codex/other"},
          %{c.work | "base_sha" => String.duplicate("f", 40)},
          %{c.work | "workspace_key" => "../outside"}
        ] do
      assert {:error, :invalid_pr_work_scope} = Workspace.create_for_pr_work(issue(), work)
    end

    for instruction <- [nil, "", String.duplicate("x", 16_001)] do
      opts = options(%{c | work: %{c.work | "instruction" => instruction}})
      assert {:error, :invalid_pr_work_scope} = CandidatePipeline.run(c.workspace, issue(), opts, fn _ -> :ok end)
    end

    for head <- [false, "bad", c.work["base_sha"]] do
      opts = options(%{c | work: %{c.work | "head_sha" => head}})
      assert {:error, :invalid_pr_work_scope} = CandidatePipeline.run(c.workspace, issue(), opts, fn _ -> :ok end)
    end

    opts = options(%{c | work: Map.delete(c.work, "head_sha")})
    assert {:error, :invalid_pr_work_scope} = CandidatePipeline.run(c.workspace, issue(), opts, fn _ -> :ok end)
    opts = Keyword.delete(options(c), :checkpoint_pr_work)
    assert {:error, :invalid_pr_work_scope} = CandidatePipeline.run(c.workspace, issue(), opts, fn _ -> :ok end)
    assert {:ok, workspace} = Workspace.create_for_pr_work(issue(), c.work)
    assert workspace == c.workspace

    assert {:error, :invalid_pr_work_scope} =
             CandidatePipeline.run(Path.join(c.root, "other"), issue(), options(c), fn _ -> :ok end)
  end

  test "branch drift is rejected before execution or independent review", c do
    git(c.workspace, ["branch", "-m", "codex/other"])
    assert {:error, :pr_work_branch_mismatch} = CandidatePipeline.run(c.workspace, issue(), options(c), fn _ -> :ok end)
    refute File.exists?(Path.join(c.root, "trace"))
    git(c.workspace, ["branch", "-m", c.work["branch"]])
    configure(c.root, fake_server(c.root, "change_branch"), c.work["base_sha"])
    assert {:error, :pr_work_branch_mismatch} = CandidatePipeline.run(c.workspace, issue(), options(c), fn _ -> :ok end)
    starts = Enum.filter(calls(c), &(&1["method"] == "thread/start"))
    assert length(starts) == 1
  end

  test "PR work never enters the uncontrolled compatibility runner", c do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, workspace_root: c.root, tracker_kind: "memory", codex_command: "false")
    WorkflowStore.force_reload()

    assert_raise RuntimeError, ~r/pr_work_requires_controlled_execution/, fn ->
      AgentRunner.run(issue(), self(), options(c))
    end
  end

  test "retained options are rejected for reviewers or unrelated execution", c do
    invalid_options = [
      [profile: :reviewer, pr_work_id: c.work["id"]],
      [thread_id: "retained-builder"],
      [pr_work_id: "bad"],
      [pr_work_id: c.work["id"], thread_id: "../bad"]
    ]

    for opts <- invalid_options do
      assert {:error, :invalid_retained_session} = AppServer.start_session(c.workspace, opts)
    end

    refute File.exists?(Path.join(c.root, "trace"))
  end

  defp options(c) do
    [
      run_id: "fixture-run",
      pr_work: c.work,
      checkpoint_pr_work: fn attrs ->
        path = Path.join(c.root, "checkpoint")
        prior = if File.exists?(path), do: Jason.decode!(File.read!(path)), else: %{}
        File.write!(path, Jason.encode!(Map.merge(prior, attrs)))
        :ok
      end
    ]
  end

  defp calls(c), do: File.read!(Path.join(c.root, "trace")) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp issue, do: %Issue{id: "42", identifier: "GH-42", title: "Fixture", description: "Issue scope", state: "open", labels: []}

  defp git(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    String.trim(output)
  end

  defp configure(root, command, base) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, workspace_root: root, tracker_kind: "memory", codex_command: command)
    section = "\ncontrol:\n  enabled: true\n  state_path: #{root}/control.json\n  base_sha: #{base}\n---\n"
    File.write!(path, String.replace(File.read!(path), "\n---\n", section, global: false))
    WorkflowStore.force_reload()
  end

  defp fake_server(root, mode) do
    path = Path.join(root, "fake-server")

    File.write!(path, """
    #!/usr/bin/env python3
    import json, os, pathlib, subprocess, sys, uuid
    root = pathlib.Path(#{Jason.encode!(root)})
    mode = #{Jason.encode!(mode)}
    role = os.environ['SYMPHONY_WORKER_ROLE']
    work_id = os.environ.get('SYMPHONY_PR_WORK_ID')
    if role == 'reviewer': assert work_id is None and 'SYMPHONY_PR_WORK_RESUME' not in os.environ
    def send(value): print(json.dumps(value), flush=True)
    for line in sys.stdin:
        msg = json.loads(line)
        with (root / 'trace').open('a') as stream: stream.write(json.dumps(msg) + '\\n')
        method = msg['method']
        if method == 'initialize': send({'id': 1, 'result': {}})
        elif method in ('thread/start', 'thread/resume'):
            thread = 'retained-builder' if role == 'builder' else str(uuid.uuid4())
            if method == 'thread/resume': assert os.environ['SYMPHONY_PR_WORK_RESUME'] == 'true'
            result = {'thread': {'id': thread}, 'cwd': os.getcwd(), 'approvalPolicy': 'never',
                      'activePermissionProfile': {'id': 'symphony-' + role}}
            if mode == 'wrong_id': result['thread']['id'] = 'other-thread'
            if mode == 'wrong_cwd': result['cwd'] = '/wrong'
            if mode == 'wrong_approval': result['approvalPolicy'] = 'on-request'
            if mode == 'wrong_profile': result['activePermissionProfile']['id'] = 'other'
            send({'id': 2, 'result': result})
        elif method == 'turn/start':
            assert role != 'builder' or json.loads((root / 'checkpoint').read_text())['builder_thread_id'] == 'retained-builder'
            send({'id': 3, 'result': {'turn': {'id': str(uuid.uuid4())}}})
            if role == 'builder':
                with open('source', 'a') as stream: stream.write('next change\\n')
                subprocess.run(['git', 'commit', '-am', 'candidate'], check=True, stdout=subprocess.DEVNULL)
                if mode == 'change_branch': subprocess.run(['git', 'branch', '-m', 'codex/other'], check=True)
            sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
            if role == 'builder':
                branch = subprocess.check_output(['git', 'symbolic-ref', '--short', 'HEAD'], text=True).strip()
                os.makedirs('.symphony', exist_ok=True)
                handoff = {'candidate_sha': sha, 'branch': branch, 'summary': 'scoped work', 'checks': [], 'limitations': []}
                if (root / 'feedback-results').exists(): handoff['feedback_results'] = json.loads((root / 'feedback-results').read_text())
                with open('.symphony/handoff.json', 'w') as stream:
                    json.dump(handoff, stream)
                result = 'Ready'
            else: result = 'invalid review' if mode == 'review_failure' else json.dumps({'candidate_sha': sha, 'verdict': 'approve', 'summary': 'Reviewed', 'findings': []})
            send({'method': 'item/completed', 'params': {'item': {'type': 'agentMessage', 'text': result}}})
            send({'method': 'turn/completed', 'params': {'turn': {'status': 'completed'}}})
    """)

    File.chmod!(path, 0o755)
    path
  end
end
