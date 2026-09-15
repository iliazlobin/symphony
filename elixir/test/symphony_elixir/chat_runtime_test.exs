defmodule SymphonyElixir.Chat.RuntimeTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Chat.Runtime

  setup do
    root = Path.join(System.tmp_dir!(), "chat-runtime-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    opts = %{
      executable: Path.expand("../fixtures/chat_app_server.py", __DIR__),
      codex_home: home,
      workspace: workspace,
      text: "List work",
      instructions: "Manage this project.",
      timeout_ms: 5_000,
      tools: [%{"name" => "symphony_status", "description" => "Read status", "inputSchema" => %{"type" => "object", "properties" => %{}}}]
    }

    %{opts: opts}
  end

  defp run(opts, mode, tool \\ fn _, _ -> %{"tasks" => []} end) do
    File.write!(Path.join(opts.codex_home, "fixture-mode"), mode)
    owner = self()
    Runtime.run(opts, &send(owner, {:event, &1}), tool)
  end

  test "streams split JSONL and dynamic tools and resumes native thread history", %{opts: opts} do
    assert {:ok, %{thread_id: "thread-1", status: :completed}} = run(opts, "split")
    assert_received {:event, {:thread, "thread-1"}}
    assert_received {:event, {:delta, "Current "}}
    assert_received {:event, {:delta, "tasks"}}
    assert_received {:event, {:usage, %{"last" => %{"totalTokens" => 10}}}}
    assert {:ok, %{status: :completed}} = run(Map.put(opts, :thread_id, "thread-1"), "split")
    requests = File.read!(Path.join(opts.codex_home, "requests.jsonl"))
    assert requests =~ "thread/resume"
    assert requests =~ "symphony_status"
    refute requests =~ "private diagnostic secret"
  end

  test "native compaction is a status event, not a transcript message", %{opts: opts} do
    assert {:ok, _} = run(opts, "compact")
    assert_received {:event, {:status, "Updating conversation context"}}
  end

  test "interrupt reaches the active turn and returns its acknowledged outcome", %{opts: opts} do
    File.write!(Path.join(opts.codex_home, "fixture-mode"), "interrupt")
    owner = self()
    task = Task.async(fn -> Runtime.run(opts, &send(owner, {:event, &1}), fn _, _ -> %{} end) end)
    assert_receive {:event, {:delta, "Working"}}, 5_000
    send(task.pid, :interrupt)
    assert {:ok, %{status: :interrupted}} = Task.await(task)
    assert File.read!(Path.join(opts.codex_home, "requests.jsonl")) =~ "turn/interrupt"
  end

  for {mode, expected} <- [
        {"old", :unsupported_runtime_version},
        {"unsafe", :unsafe_runtime_configuration},
        {"auth", :authentication_required},
        {"missing", :model_unavailable},
        {"reject", :request_rejected},
        {"malformed", :protocol_error},
        {"exit", :runtime_exited},
        {"approval", :unsupported_server_request},
        {"builtin", :forbidden_tool},
        {"wrong-thread", :thread_mismatch},
        {"forbidden", :forbidden_tool},
        {"failed", :turn_failed}
      ] do
    test "fails closed for #{mode} without leaking provider diagnostics", %{opts: opts} do
      assert {:error, unquote(expected)} = run(opts, unquote(mode))
    end
  end

  test "deadline terminates an unresponsive child", %{opts: opts} do
    assert {:error, :runtime_timeout} = run(%{opts | timeout_ms: 300}, "hang")
    assert_child_stopped(opts)
  end

  test "tool exceptions become bounded sanitized tool errors", %{opts: opts} do
    assert {:ok, _} = run(opts, "split", fn _, _ -> raise "private credential diagnostic" end)
    requests = File.read!(Path.join(opts.codex_home, "requests.jsonl"))
    assert requests =~ "tool_failed"
    refute requests =~ "private credential diagnostic"
  end

  test "requires dedicated instruction-free state and an empty non-repository workspace", %{opts: opts} do
    File.write!(Path.join(opts.codex_home, "config.toml"), "")
    assert {:error, :dedicated_home_required} = run(opts, "split")
    File.rm!(Path.join(opts.codex_home, "config.toml"))
    File.write!(Path.join(opts.workspace, "AGENTS.md"), "untrusted")
    assert {:error, :empty_workspace_required} = run(opts, "split")
  end

  test "rejects accidental coding tool exposure and missing runtime paths", %{opts: opts} do
    assert {:error, :invalid_tools} = run(%{opts | tools: [%{"name" => "exec_command"}]}, "split")
    assert {:error, :runtime_path_unavailable} = run(%{opts | executable: "/missing"}, "split")
    assert {:error, :invalid_runtime_options} = run(%{opts | executable: "codex"}, "split")
    assert {:error, :invalid_runtime_options} = run(%{opts | text: ""}, "split")
    assert Runtime.model() == "gpt-6-astra"
    assert Runtime.supported_version() == "0.154.0"
  end

  test "guardian reaps an unresponsive child after abrupt owner termination", %{opts: opts} do
    File.write!(Path.join(opts.codex_home, "fixture-mode"), "hang")
    owner = self()
    {pid, monitor} = spawn_monitor(fn -> Runtime.run(opts, &send(owner, {:event, &1}), fn _, _ -> %{} end) end)
    assert_receive {:event, {:thread, "thread-1"}}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert_child_stopped(opts)
  end

  test "interrupt during a host tool cancels the tool task and interrupts the native turn", %{opts: opts} do
    File.write!(Path.join(opts.codex_home, "fixture-mode"), "split")
    owner = self()

    task =
      Task.async(fn ->
        Runtime.run(opts, &send(owner, {:event, &1}), fn _, _ ->
          send(owner, :tool_entered)
          Process.sleep(30_000)
          %{}
        end)
      end)

    assert_receive :tool_entered, 5_000
    send(task.pid, :interrupt)
    assert {:ok, %{status: :interrupted}} = Task.await(task)
    assert_child_stopped(opts)
  end

  defp assert_child_stopped(opts) do
    pid = opts.codex_home |> Path.join("child-pid") |> File.read!()

    stopped =
      Enum.reduce_while(1..100, false, fn _, _ ->
        case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
          {_, 0} ->
            Process.sleep(10)
            {:cont, false}

          _ ->
            {:halt, true}
        end
      end)

    assert stopped, "owned App Server child was not reaped"
  end
end
