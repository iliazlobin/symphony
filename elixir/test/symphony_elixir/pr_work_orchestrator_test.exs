defmodule SymphonyElixir.PRWorkOrchestratorTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  alias SymphonyElixir.ControlLedger
  alias SymphonyElixirWeb.Endpoint
  @endpoint Endpoint
  @work String.duplicate("a", 32)
  @base String.duplicate("a", 40)
  @head String.duplicate("b", 40)

  defmodule IssueAdapter do
    def run(request) do
      issue = %{"number" => 7, "title" => "PR scope", "state" => "open", "labels" => [], "body" => "Depends on: none"}
      body = if String.ends_with?(request.url.path, "/7"), do: issue, else: [issue]
      {request, Req.Response.new(status: 200, body: body)}
    end
  end

  setup do
    {:ok, temporary_root} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(temporary_root, "symphony-pr-work-otp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow = root <> "/WORKFLOW.md"

    budgets = %{max_attempts: 10, max_total_runtime_ms: 60_000, max_total_tokens: 1_000}
    control = %{enabled: true, base_sha: @base, state_path: root <> "/control.json", initial_mode: "paused"}

    config = %{
      tracker: %{kind: "memory", provider: %{repo: "owner/repo"}, active_states: ["open"], terminal_states: ["closed"]},
      workspace: %{root: root <> "/workspaces"},
      polling: %{interval_ms: 60_000},
      agent: %{max_concurrent_agents: 1},
      observability: %{dashboard_enabled: false},
      control: Map.merge(control, budgets)
    }

    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(workflow)
    issue = %Issue{id: "7", identifier: "GH-7", title: "PR scope", state: "open", labels: [], dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    supervisor = start_supervised!({Task.Supervisor, []})
    name = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor})
    on_exit(fn -> File.rm_rf(root) end)
    %{pid: pid, issue: issue, supervisor: supervisor, workflow: workflow, config: config}
  end

  test "guarded commands reject missing issues, revoked access and invalid scope before durable admission", c do
    scope = Orchestrator.tracker_fingerprint()
    assert {:error, :unauthorized} = Orchestrator.control_command_guarded(create(), scope, c.pid, fn -> false end)
    assert {:error, :tracker_changed} = Orchestrator.control_command_guarded(create(), "different", c.pid)
    assert {:error, :invalid_command} = Orchestrator.control_command(Map.put(create(), "work_id", "../unsafe"), c.pid)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    assert {:error, :task_not_found} = Orchestrator.control_command(create(), c.pid)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{c.issue | state: "closed"}])
    assert {:error, :task_not_queueable} = Orchestrator.control_command(create(), c.pid)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [c.issue])
    assert {:ok, %{"work_id" => @work, "revision" => 1}} = Orchestrator.control_command_guarded(create(), scope, c.pid, fn -> true end)
    snapshot = Orchestrator.control_snapshot(c.pid)
    assert snapshot["tracker_fingerprint"] == scope
    assert snapshot["mode"] == "paused"
    assert :sys.get_state(c.pid).running == %{}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    assert {:ok, %{"replayed" => true}} = Orchestrator.control_command(create(), c.pid)
    assert {:ok, %{"work_id" => @work}} = Orchestrator.control_receipt_guarded(create(), scope, c.pid)
  end

  test "checkpoint only acknowledges the active worker and durable thread identity", c do
    {:ok, _} = Orchestrator.control_command(create(), c.pid)
    {worker, run} = seed_worker(c)
    update = %{event: :notification, timestamp: DateTime.utc_now(), payload: %{}}
    send(c.pid, {:codex_worker_update, "7", run, update})
    assert get_in(Orchestrator.control_snapshot(c.pid), ["issues", "7", "pr_work", @work, "builder_usage", "total_tokens"]) == 0
    assert {:error, :stale_run} = Orchestrator.checkpoint_pr_work("7", run, @work, %{"builder_thread_id" => "builder"}, c.pid)
    assert :ok = checkpoint(worker, %{"builder_thread_id" => "builder"})
    assert {:error, :builder_thread_changed} = checkpoint(worker, %{"builder_thread_id" => "other"})
    assert :ok = checkpoint(worker, %{"working_head_sha" => @head})
    snapshot = Orchestrator.control_snapshot(c.pid)
    work = get_in(snapshot, ["issues", "7", "pr_work", @work])
    assert work["builder_thread_id"] == "builder"
    assert work["working_head_sha"] == @head
    assert work["phase"] == "reviewing"
    assert work["head_sha"] == nil
    assert Jason.decode!(File.read!(c.config.control.state_path))["issues"]["7"]["pr_work"][@work] == work
    assert {:error, :issue_running} = Orchestrator.control_command(%{create() | "expected_revision" => 2, "command_id" => "another"}, c.pid)
    monitor = Process.monitor(worker)
    assert {:ok, _} = Orchestrator.control_command(command("cancel", 2), c.pid)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert {:error, :stale_run} = Orchestrator.checkpoint_pr_work("7", run, @work, %{"phase" => "reviewing"}, c.pid)
    assert get_in(Orchestrator.control_snapshot(c.pid), ["issues", "7", "pr_work", @work, "working_head_sha"]) == @head
  end

  test "authorization is rechecked after fresh admission reads and before durable acceptance", c do
    token = endpoint(c.pid)
    original = Orchestrator.control_snapshot(c.pid)

    authorize = fn ->
      valid = System.get_env("SYMPHONY_CONTROL_TOKEN") == token
      System.put_env("SYMPHONY_CONTROL_TOKEN", "revoked-during-admission")
      valid
    end

    assert {:error, :unauthorized} =
             Orchestrator.control_command_guarded(create(), Orchestrator.tracker_fingerprint(), c.pid, authorize)

    assert Orchestrator.control_snapshot(c.pid)["revision"] == original["revision"]
    assert Orchestrator.control_snapshot(c.pid)["issues"] == original["issues"]
  end

  test "fresh PR reads cannot admit a revoked command or dispatch across a workflow change", c do
    tracker = %{c.config.tracker | kind: "github", provider: %{repo: "owner/repo", token: "fixture"}}
    config = Map.put(c.config, :tracker, tracker)
    write_config(c.workflow, config)
    assert Config.settings!().tracker.kind == "github"
    defaults = Req.default_options()
    Req.default_options(adapter: IssueAdapter)
    previous = Application.get_env(:symphony_elixir, :pr_work_github_request)

    on_exit(fn ->
      Req.default_options(defaults)

      if previous,
        do: Application.put_env(:symphony_elixir, :pr_work_github_request, previous),
        else: Application.delete_env(:symphony_elixir, :pr_work_github_request)
    end)

    {:ok, _} = Orchestrator.control_command(create(), c.pid)
    {worker, run} = seed_worker(c)
    :ok = checkpoint(worker, %{"builder_thread_id" => "builder"})
    send(c.pid, {:worker_candidate_ready, "7", candidate(run)})
    Orchestrator.control_snapshot(c.pid)
    stop_worker(c, worker)

    receipt = candidate(run) |> Map.take(~w(run_id work_id expected_head_sha candidate_sha base_sha branch)a)
    receipt = Map.new(receipt, fn {key, value} -> {to_string(key), value} end)
    receipt = Map.merge(receipt, %{"issue_id" => "7", "pr_number" => 18, "pr_url" => "https://github.com/owner/repo/pull/18", "status" => "draft_pr"})
    {:ok, _} = Orchestrator.record_pr_publication(receipt, c.pid)
    token = endpoint(c.pid)
    continuation = Map.merge(command("continue_pr_work", 2), %{"work_id" => @work, "expected_head_sha" => @head, "instruction" => "Fix CI"})
    pr = remote_pr()

    Application.put_env(:symphony_elixir, :pr_work_github_request, fn _, _, _, _, _ ->
      System.put_env("SYMPHONY_CONTROL_TOKEN", "revoked-during-PR-read")
      {:ok, %{status: 200, body: pr}}
    end)

    authorize = fn -> System.get_env("SYMPHONY_CONTROL_TOKEN") == token end
    scope = Orchestrator.tracker_fingerprint()
    assert {:error, :unauthorized} = Orchestrator.control_command_guarded(continuation, scope, c.pid, authorize)
    assert Orchestrator.control_snapshot(c.pid)["revision"] == 2
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)
    revoked = post(conn(token), "/api/v1/control", continuation)
    assert json_response(revoked, 401)["error"]["code"] == "unauthorized"
    reader = fn _, _, _, _, _ -> {:ok, %{status: 200, body: pr}} end
    Application.put_env(:symphony_elixir, :pr_work_github_request, reader)
    assert {:ok, _} = Orchestrator.control_command(continuation, c.pid)

    parent = self()

    Application.put_env(:symphony_elixir, :pr_work_github_request, fn _, _, _, _, _ ->
      write_config(c.workflow, put_in(config.control.base_sha, @head))
      send(parent, :dispatch_read_changed_config)
      {:ok, %{status: 200, body: pr}}
    end)

    :sys.replace_state(c.pid, fn state ->
      ledger = state.control
      %{state | control: put_in(ledger.data["mode"], "running")}
    end)

    send(c.pid, :run_poll_cycle)
    assert_receive :dispatch_read_changed_config, 1_000
    snapshot = Orchestrator.control_snapshot(c.pid)
    assert snapshot["issues"]["7"]["active"] == nil
    assert snapshot["issues"]["7"]["attempts"] == 1
    assert :sys.get_state(c.pid).running == %{}
  end

  defp write_config(path, config) do
    File.write!(path, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(path)
  end

  defp remote_pr do
    %{
      "number" => 18,
      "html_url" => "https://github.com/owner/repo/pull/18",
      "state" => "open",
      "merged" => false,
      "head" => %{"sha" => @head, "ref" => "codex/gh-7-#{@work}", "repo" => %{"full_name" => "owner/repo"}},
      "base" => %{"sha" => @base, "repo" => %{"full_name" => "owner/repo"}}
    }
  end

  test "resumed cumulative builder usage charges only new tokens while fresh reviewer usage accumulates", c do
    {:ok, _} = Orchestrator.control_command(create(), c.pid)
    {worker, run} = seed_worker(c)
    :ok = checkpoint(worker, %{"builder_thread_id" => "builder"})
    send_usage(c, run, "builder", :builder, 100)
    assert get_in(Orchestrator.control_snapshot(c.pid), ["issues", "7", "active", "tokens"]) == 100
    send_usage(c, run, "reviewer-1", :reviewer, 20)
    send(c.pid, {:worker_candidate_ready, "7", candidate(run)})
    assert get_in(Orchestrator.control_snapshot(c.pid), ["issues", "7", "tokens"]) == 120
    stop_worker(c, worker)
    continuation = Map.merge(command("continue_pr_work", 2), %{"work_id" => @work, "expected_head_sha" => @head, "instruction" => "Fix the CI check"})
    assert {:ok, _} = Orchestrator.control_command(continuation, c.pid)
    # Reserve the next run while paused to the scheduler; this fixture never invokes Codex.
    {worker2, run2} = seed_worker(c, false)
    :ok = checkpoint(worker2, %{"builder_thread_id" => "builder"})
    send_usage(c, run2, "builder", :builder, 135)
    snapshot = Orchestrator.control_snapshot(c.pid)
    assert get_in(snapshot, ["issues", "7", "active", "tokens"]) == 35
    assert get_in(snapshot, ["issues", "7", "pr_work", @work, "builder_usage", "total_tokens"]) == 135
    send_usage(c, run2, "reviewer-2", :reviewer, 12)
    snapshot = Orchestrator.control_snapshot(c.pid)
    assert get_in(snapshot, ["issues", "7", "active", "tokens"]) == 47
    assert get_in(snapshot, ["issues", "7", "pr_work", @work, "builder_usage", "total_tokens"]) == 135
  end

  test "failed checkpoint persistence prevents acknowledgement and stops native ownership", c do
    {:ok, _} = Orchestrator.control_command(create(), c.pid)
    {worker, _run} = seed_worker(c)
    monitor = Process.monitor(worker)
    path = c.config.control.state_path
    before = File.read!(path)
    File.rename!(path, path <> ".saved")
    File.mkdir!(path)
    send(worker, {:checkpoint, self(), %{"builder_thread_id" => "builder"}})
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    snapshot = Orchestrator.control_snapshot(c.pid)
    assert is_binary(snapshot["fault"])
    assert get_in(snapshot, ["issues", "7", "pr_work", @work, "builder_thread_id"]) == nil
    assert File.read!(path <> ".saved") == before
    refute_receive {:checkpoint_result, :ok}
  end

  test "publication API authenticates and idempotently records exact reviewed evidence", c do
    {:ok, _} = Orchestrator.control_command(create(), c.pid)
    {worker, run} = seed_worker(c)
    :ok = checkpoint(worker, %{"builder_thread_id" => "builder"})
    send(c.pid, {:worker_candidate_ready, "7", candidate(run)})
    Orchestrator.control_snapshot(c.pid)
    stop_worker(c, worker)
    token = endpoint(c.pid)

    receipt =
      candidate(run)
      |> Map.take(~w(run_id work_id expected_head_sha candidate_sha base_sha branch)a)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"issue_id" => "7", "pr_number" => 18, "pr_url" => "https://github.com/owner/repo/pull/18", "status" => "draft_pr"})

    assert json_response(post(conn("wrong"), "/api/v1/pr-work/publication", receipt), 401)["error"]["code"] == "unauthorized"
    assert json_response(post(conn(token), "/api/v1/pr-work/publication", Map.put(receipt, "extra", 1)), 400)["error"]["code"] == "invalid_publication"
    assert json_response(post(conn(token), "/api/v1/pr-work/publication", receipt), 200)["replayed"] == false
    assert json_response(post(conn(token), "/api/v1/pr-work/publication", receipt), 200)["replayed"] == true
    assert json_response(post(conn(token), "/api/v1/pr-work/publication", %{receipt | "candidate_sha" => @base}), 409)["error"]["code"] == "pr_head_changed"
    snapshot = Orchestrator.control_snapshot(c.pid)
    assert get_in(snapshot, ["issues", "7", "pr_work", @work, "published_head_sha"]) == @head
    assert snapshot["issues"]["7"]["hold"] == "owner_review"
    :sys.replace_state(c.pid, &%{&1 | control_fault: :failed})
    assert json_response(post(conn(token), "/api/v1/pr-work/publication", receipt), 503)["error"]["code"] == "control_unavailable"
  end

  defp create, do: Map.merge(command("create_pr_work", 0), %{"work_id" => @work, "base_sha" => @base, "instruction" => "Implement one PR"})
  defp command(action, revision), do: %{"action" => action, "issue_id" => "7", "expected_revision" => revision, "command_id" => "#{action}-#{revision}"}

  defp candidate(run),
    do: %{
      run_id: run,
      work_id: @work,
      expected_head_sha: nil,
      candidate_sha: @head,
      base_sha: @base,
      branch: "codex/gh-7-#{@work}",
      builder_session_id: "builder-turn",
      reviewer_session_id: "reviewer-turn",
      review: %{candidate_sha: @head, verdict: "approve", findings: []}
    }

  defp seed_worker(c, resume \\ true) do
    owner = c.pid

    {:ok, worker} =
      Task.Supervisor.start_child(c.supervisor, fn ->
        receive do
          {:start, run} -> worker_loop(owner, run)
        end
      end)

    state =
      :sys.replace_state(c.pid, fn state ->
        ledger =
          if resume do
            {:ok, next, _, _} = ControlLedger.command(state.control, Map.put(command("resume", 1), "issue_id", nil))
            next
          else
            %{state.control | data: Map.put(state.control.data, "mode", "running")}
          end

        {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
        # Keep the real polling loop paused; reservations and worker events remain native.
        ledger = %{ledger | data: Map.put(ledger.data, "mode", "paused")}

        entry = %{
          pid: worker,
          ref: Process.monitor(worker),
          run_id: run,
          work_id: @work,
          identifier: c.issue.identifier,
          issue: c.issue,
          session_id: nil,
          codex_total_tokens: 0,
          started_at: DateTime.utc_now(),
          turn_count: 0,
          last_codex_event: nil,
          last_codex_timestamp: nil,
          last_codex_message: nil
        }

        %{state | control: ledger, running: %{"7" => entry}, claimed: MapSet.new(["7"])}
      end)

    run = state.running["7"].run_id
    send(worker, {:start, run})
    {worker, run}
  end

  defp worker_loop(owner, run) do
    receive do
      {:checkpoint, caller, attrs} ->
        send(caller, {:checkpoint_result, Orchestrator.checkpoint_pr_work("7", run, @work, attrs, owner)})
        worker_loop(owner, run)

      :finish ->
        :ok
    end
  end

  defp checkpoint(worker, attrs) do
    send(worker, {:checkpoint, self(), attrs})
    assert_receive {:checkpoint_result, result}, 1_000
    result
  end

  defp stop_worker(c, worker) do
    ref = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    Orchestrator.control_snapshot(c.pid)
  end

  defp send_usage(c, run, thread, role, total) do
    started = %{event: :session_started, timestamp: DateTime.utc_now(), thread_id: thread}
    started = Map.merge(started, %{session_id: thread <> "-turn", worker_role: role})
    send(c.pid, {:codex_worker_update, "7", run, started})

    send(
      c.pid,
      {:codex_worker_update, "7", run,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         worker_role: role,
         payload: %{"method" => "thread/tokenUsage/updated", "params" => %{"tokenUsage" => %{"total" => %{"inputTokens" => total, "outputTokens" => 0, "totalTokens" => total}}}}
       }}
    )
  end

  defp endpoint(owner) do
    previous = Application.get_env(:symphony_elixir, Endpoint, [])
    prior_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    token = String.duplicate("t", 40)
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)
    Application.put_env(:symphony_elixir, Endpoint, Keyword.merge(previous, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: owner))
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous)
      if prior_token, do: System.put_env("SYMPHONY_CONTROL_TOKEN", prior_token), else: System.delete_env("SYMPHONY_CONTROL_TOKEN")
    end)

    token
  end

  defp conn(token), do: %{build_conn() | host: "localhost"} |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
end
