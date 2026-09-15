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
    %{pid: pid, issue: issue, supervisor: supervisor}
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
