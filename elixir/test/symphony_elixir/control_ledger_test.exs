defmodule SymphonyElixir.ControlLedgerTest do
  use ExUnit.Case
  alias SymphonyElixir.ControlLedger

  defmodule Owner do
    use GenServer
    alias SymphonyElixir.ControlLedger
    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def init({settings, root}), do: ControlLedger.open(settings, root)
    def terminate(_, ledger), do: ControlLedger.close(ledger)
    def handle_call(:snapshot, _, ledger), do: {:reply, ControlLedger.snapshot(ledger), ledger}

    def handle_call({:command, params}, _, ledger) do
      case ControlLedger.command(ledger, params, 5) do
        {:ok, next, reply, replay} -> {:reply, {:ok, reply, replay}, next}
        error -> {:reply, error, ledger}
      end
    end

    def handle_call({:reserve, id}, _, ledger) do
      case ControlLedger.reserve(ledger, id) do
        {:ok, next, run, remaining} -> {:reply, {:ok, run, remaining}, next}
        error -> {:reply, error, ledger}
      end
    end

    def handle_call({:finish, id, run, hold}, _, ledger) do
      case ControlLedger.finish(ledger, id, run, hold) do
        {:ok, next} -> {:reply, :ok, next}
        error -> {:reply, error, ledger}
      end
    end
  end

  setup do
    {:ok, temporary_root} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(temporary_root, "symphony-control-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    settings = %{
      enabled: true,
      state_path: root <> "/control.json",
      initial_mode: "paused",
      max_attempts: 2,
      max_total_runtime_ms: 1_000,
      max_total_tokens: 100
    }

    %{settings: settings, workspace: root <> "/workspaces"}
  end

  defp command(action, revision, id \\ nil, command_id \\ nil) do
    %{"command_id" => command_id || "#{action}-#{revision}", "action" => action, "expected_revision" => revision, "issue_id" => id}
  end

  test "commands persist, replay once and reject stale or conflicting writes", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert %{"mode" => "paused", "revision" => 0} = GenServer.call(pid, :snapshot)
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
    resume = command("resume", 0)
    assert {:ok, %{"revision" => 1}, false} = GenServer.call(pid, {:command, resume})
    assert {:ok, %{"revision" => 1}, true} = GenServer.call(pid, {:command, resume})
    assert {:error, :command_id_conflict} = GenServer.call(pid, {:command, %{resume | "action" => "pause"}})
    assert {:error, :revision_conflict} = GenServer.call(pid, {:command, command("pause", 0)})
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("drain", 1)})
    stop_supervised!(Owner)
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert %{"mode" => "draining", "revision" => 2} = GenServer.call(pid, :snapshot)
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
  end

  test "concurrency overrides survive restart and receipts retain the exact requested limit", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert ControlLedger.effective_concurrency(nil, 5) == 5
    set = Map.put(command("set_concurrency", 0), "limit", 3)
    assert {:ok, %{"limit" => 3, "revision" => 1}, false} = GenServer.call(pid, {:command, set})
    assert {:error, :command_id_conflict} = GenServer.call(pid, {:command, %{set | "limit" => 2}})
    assert {:error, :revision_conflict} = GenServer.call(pid, {:command, Map.put(set, "command_id", "stale")})
    assert {:error, :concurrency_limit_exceeded} = GenServer.call(pid, {:command, Map.put(command("set_concurrency", 1), "limit", 6)})
    ledger = :sys.get_state(pid)
    assert ControlLedger.effective_concurrency(ledger, 5) == 3
    assert ControlLedger.effective_concurrency(ledger, 2) == 2
    stop_supervised!(Owner)
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert %{"concurrency_override" => 3, "revision" => 1} = GenServer.call(pid, :snapshot)
    assert {:ok, %{"limit" => 3}, true} = GenServer.call(pid, {:command, set})
    assert {:ok, %{"limit" => nil}, false} = GenServer.call(pid, {:command, Map.put(command("set_concurrency", 1), "limit", nil)})
    assert %{"concurrency_override" => nil} = GenServer.call(pid, :snapshot)
    assert ControlLedger.effective_concurrency(:sys.get_state(pid), 4) == 4
  end

  test "legacy state loads without override; malformed overrides and settings commands fail closed", ctx do
    legacy = %{"version" => 1, "revision" => 0, "mode" => "paused", "issues" => %{}, "commands" => %{}}
    File.write!(ctx.settings.state_path, Jason.encode!(legacy))
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert ControlLedger.effective_concurrency(:sys.get_state(pid), 5) == 5

    for params <-
          [command("set_concurrency", 0), Map.put(command("set_concurrency", 0, "7"), "limit", 1), Map.put(command("pause", 0), "limit", 1)] ++
            Enum.map([0, -1, "2", 1.5, true], &Map.put(command("set_concurrency", 0), "limit", &1)) do
      assert {:error, :invalid_command} = GenServer.call(pid, {:command, params})
    end

    assert %{"revision" => 0} = GenServer.call(pid, :snapshot)
    stop_supervised!(Owner)

    for invalid <- [0, -1, "2", false, %{}] do
      File.write!(ctx.settings.state_path, Jason.encode!(Map.put(legacy, "concurrency_override", invalid)))
      assert {:error, :invalid_control_state} = ControlLedger.open(ctx.settings, ctx.workspace)
    end
  end

  test "cancel and manual retry preserve total attempt budget and fence stale completions", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert {:ok, _, _} = GenServer.call(pid, {:command, command("resume", 0)})
    assert {:ok, run, _} = GenServer.call(pid, {:reserve, "7"})
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
    assert {:ok, _, _} = GenServer.call(pid, {:command, command("cancel", 1, "7")})
    assert :ok = GenServer.call(pid, {:finish, "7", run, nil})
    assert {:error, :not_admitted} = GenServer.call(pid, {:reserve, "7"})
    assert {:ok, _, _} = GenServer.call(pid, {:command, command("retry", 2, "7")})
    assert {:ok, run2, _} = GenServer.call(pid, {:reserve, "7"})
    assert {:error, :stale_run} = GenServer.call(pid, {:finish, "7", run, nil})
    assert :ok = GenServer.call(pid, {:finish, "7", run2, nil})
    assert {:error, :budget_exhausted} = GenServer.call(pid, {:command, command("retry", 3, "7")})
  end

  test "restart retains interrupted attempt and pauses before dispatch", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    GenServer.call(pid, {:command, command("resume", 0)})
    {:ok, _, _} = GenServer.call(pid, {:reserve, "7"})
    stop_supervised!(Owner)
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert %{"mode" => "paused", "issues" => %{"7" => %{"hold" => "interrupted", "attempts" => 1, "active" => nil}}} = GenServer.call(pid, :snapshot)
  end

  test "live accounting ignores wall-clock rollback and unknown restart consumes reservation", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    GenServer.call(pid, {:command, command("resume", 0)})
    {:ok, run, _} = GenServer.call(pid, {:reserve, "7"})

    :sys.replace_state(pid, fn ledger ->
      data =
        ledger.data
        |> put_in(["issues", "7", "active", "started_at_ms"], System.system_time(:millisecond) + 60_000)
        |> put_in(["issues", "7", "active", "started_monotonic_ms"], System.monotonic_time(:millisecond) - 300)

      %{ledger | data: data}
    end)

    assert :ok = GenServer.call(pid, {:finish, "7", run, nil})
    assert %{"issues" => %{"7" => %{"runtime_ms" => runtime}}} = GenServer.call(pid, :snapshot)
    assert runtime >= 300
    {:ok, _, _} = GenServer.call(pid, {:reserve, "8"})
    stop_supervised!(Owner)
    data = ctx.settings.state_path |> File.read!() |> Jason.decode!() |> put_in(["issues", "8", "active", "runtime_epoch"], "previous-runtime")
    File.write!(ctx.settings.state_path, Jason.encode!(data))
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert %{"issues" => %{"8" => %{"runtime_ms" => 1_000, "hold" => "interrupted"}}} = GenServer.call(pid, :snapshot)
    assert {:error, :budget_exhausted} = GenServer.call(pid, {:command, command("retry", 1, "8")})
  end

  test "second owner rejected; corrupt file and workspace-contained ledger fail closed", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})
    assert {:error, :control_state_locked} = ControlLedger.open(ctx.settings, ctx.workspace)
    assert %{"revision" => 0} = GenServer.call(pid, :snapshot)
    stop_supervised!(Owner)
    File.write!(ctx.settings.state_path, "{broken")
    assert {:error, :invalid_control_state} = ControlLedger.open(ctx.settings, ctx.workspace)
    inside = %{ctx.settings | state_path: ctx.workspace <> "/control.json"}
    assert {:error, :control_state_inside_workspace} = ControlLedger.open(inside, ctx.workspace)
  end

  test "invalid commands and retry of a running issue leave the durable revision unchanged", ctx do
    pid = start_supervised!({Owner, {ctx.settings, ctx.workspace}})

    for params <- [%{}, command("launch", 0), command("cancel", 0), command("pause", 0, "7")] do
      assert {:error, :invalid_command} = GenServer.call(pid, {:command, params})
    end

    assert %{"revision" => 0, "issues" => %{}} = GenServer.call(pid, :snapshot)
    assert {:ok, _, false} = GenServer.call(pid, {:command, command("resume", 0)})
    assert {:ok, run, _} = GenServer.call(pid, {:reserve, "7"})
    assert {:error, :issue_running} = GenServer.call(pid, {:command, command("retry", 1, "7")})
    assert %{"revision" => 1, "issues" => %{"7" => %{"active" => %{"run_id" => ^run}}}} = GenServer.call(pid, :snapshot)
  end

  test "corrupt schema versions, command receipts, issue counters and active reservations fail closed", ctx do
    valid = %{"version" => 1, "revision" => 0, "mode" => "paused", "issues" => %{}, "commands" => %{}}
    issue = %{"attempts" => 0, "runtime_ms" => 0, "tokens" => 0, "hold" => nil, "active" => %{}}

    for data <- [
          %{valid | "version" => 2},
          %{valid | "commands" => %{"bad" => %{}}},
          %{valid | "issues" => %{"7" => %{}}},
          %{valid | "issues" => %{"7" => issue}},
          %{valid | "issues" => %{"7" => %{issue | "tokens" => -1}}}
        ] do
      File.write!(ctx.settings.state_path, Jason.encode!(data))
      assert {:error, :invalid_control_state} = ControlLedger.open(ctx.settings, ctx.workspace)
    end

    File.rm!(ctx.settings.state_path)
    File.mkdir!(ctx.settings.state_path)
    assert {:error, :unreadable_control_state} = ControlLedger.open(ctx.settings, ctx.workspace)
  end

  test "state path, ancestor and lock symlinks cannot redirect ledger writes", ctx do
    root = Path.dirname(ctx.settings.state_path)
    assert {:error, :missing_control_state_path} = ControlLedger.open(%{ctx.settings | state_path: nil}, ctx.workspace)
    File.ln_s!(root, root <> "/alias")
    via_parent = %{ctx.settings | state_path: root <> "/alias/control.json"}
    assert {:error, :control_path_symlink} = ControlLedger.open(via_parent, ctx.workspace)

    for path <- [ctx.settings.state_path, ctx.settings.state_path <> ".lock"] do
      File.ln_s!(root <> "/target", path)
      assert {:error, :control_path_symlink} = ControlLedger.open(ctx.settings, ctx.workspace)
      File.rm!(path)
    end

    refute File.exists?(root <> "/target")
  end

  test "loss of the state directory rejects writes and leaves the last durable receipt intact", ctx do
    parent = Path.join(Path.dirname(ctx.settings.state_path), "state")
    settings = %{ctx.settings | state_path: parent <> "/control.json"}
    {:ok, ledger} = ControlLedger.open(settings, ctx.workspace)
    on_exit(fn -> ControlLedger.close(ledger) end)
    File.rename!(parent, parent <> ".retained")
    assert {:error, {:control_persistence, :enoent}} = ControlLedger.command(ledger, command("resume", 0))
    assert %{"revision" => 0, "mode" => "paused"} = Jason.decode!(File.read!(parent <> ".retained/control.json"))
  end

  test "missing lock runtime and missing handshake fail closed, including an unresponsive lock process", ctx do
    before_path = System.get_env("PATH")
    python = System.find_executable("python3")
    bin = Path.join(Path.dirname(ctx.settings.state_path), "bin")
    File.mkdir!(bin)
    on_exit(fn -> SymphonyElixir.TestSupport.restore_env("PATH", before_path) end)
    System.put_env("PATH", bin)
    assert {:error, :python3_required_for_control_lock} = ControlLedger.open(ctx.settings, ctx.workspace)

    # A helper that never acknowledges the lock and ignores the close request
    # must be disconnected within the handshake plus shutdown deadlines.
    File.write!(bin <> "/python3", "#!#{python}\nimport sys\nsys.stdin.buffer.read()\n")
    File.chmod!(bin <> "/python3", 0o700)
    started = System.monotonic_time(:millisecond)
    assert {:error, :control_lock_timeout} = ControlLedger.open(ctx.settings, ctx.workspace)
    assert System.monotonic_time(:millisecond) - started < 8_000
    refute File.exists?(ctx.settings.state_path)
  end

  test "closing an already exited lock owner is safe" do
    port = Port.open({:spawn_executable, System.find_executable("true")}, [:exit_status])
    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert :ok = ControlLedger.close(%ControlLedger{lock: port})
  end
end
