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

  test "a Design-first thread retains the full catalog without granting Design turn writes", %{opts: opts} do
    write_tool = %{"name" => "symphony_propose_action", "description" => "Prepare an action", "inputSchema" => %{"type" => "object", "properties" => %{}}}
    full_catalog = opts.tools ++ [write_tool]
    design = opts |> Map.put(:thread_tools, full_catalog) |> Map.put(:view_context, %{"version" => 1, "project_id" => "github:test/repo", "mode" => "design"})
    owner = self()

    callback = fn name, _args ->
      send(owner, {:catalog_tool, name})
      %{"observed" => name}
    end

    assert {:ok, %{thread_id: "thread-1"}} = run(design, "split", callback)
    assert_received {:catalog_tool, "symphony_status"}
    ordinary = design |> Map.put(:thread_id, "thread-1") |> Map.put(:tools, full_catalog) |> Map.put(:view_context, nil)
    assert {:ok, %{thread_id: "thread-1"}} = run(ordinary, "retained-write", callback)
    assert_received {:catalog_tool, "symphony_propose_action"}

    assert {:error, :forbidden_tool} = run(Map.put(design, :thread_id, "thread-1"), "retained-write", callback)
    refute_received {:catalog_tool, "symphony_propose_action"}
    requests = requests(Path.join(opts.codex_home, "requests.jsonl"))
    assert [initial] = Enum.filter(requests, &(&1["method"] == "thread/start"))
    assert Enum.map(initial["params"]["dynamicTools"], & &1["name"]) == ~w(symphony_status symphony_propose_action)
    assert length(Enum.filter(requests, &(&1["method"] == "thread/resume"))) == 2
  end

  test "every native turn records its own view snapshot including unavailable context on resume", %{opts: opts} do
    snapshot = %{"version" => 1, "project_id" => "github:test/repo", "selected_task_id" => "github:test/repo:1"}
    assert {:ok, _} = run(Map.put(opts, :view_context, snapshot), "split")
    resumed = opts |> Map.put(:thread_id, "thread-1") |> Map.put(:view_context, nil)
    assert {:ok, _} = run(resumed, "split")
    requests = opts.codex_home |> Path.join("requests.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    turns = Enum.filter(requests, &(&1["method"] == "turn/start"))
    assert [shared, disabled] = Enum.map(turns, &get_in(&1, ["params", "input", Access.at(1), "text"]))
    assert shared =~ "github:test/repo:1"
    assert disabled =~ ~s("context_status":"unavailable")
    refute disabled =~ "github:test/repo:1"
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
        {"unsafe-code-host", :unsafe_runtime_configuration},
        {"unsafe-tool-routing", :unsafe_runtime_configuration},
        {"auth", :authentication_required},
        {"missing", :model_unavailable},
        {"reject", :request_rejected},
        {"malformed", :protocol_error},
        {"exit", :runtime_exited},
        {"approval", :unsupported_server_request},
        {"builtin", :forbidden_tool},
        {"wrong-thread", :thread_mismatch},
        {"forbidden", :forbidden_tool},
        {"failed", :turn_failed},
        {"startup-request", :unsupported_server_request},
        {"startup-tool", :forbidden_tool},
        {"wrong-response-id", :protocol_error},
        {"non-object-result", :protocol_error},
        {"config-non-map", :unsafe_runtime_configuration},
        {"unsafe-model", :unsafe_thread_configuration},
        {"unsafe-approval", :unsafe_thread_configuration},
        {"unsafe-sandbox", :unsafe_thread_configuration},
        {"unsafe-instructions", :unsafe_thread_configuration},
        {"thread-empty", :protocol_error},
        {"turn-empty", :protocol_error},
        {"turn-blank", :protocol_error},
        {"completion-shape", :protocol_error},
        {"completion-wrong-thread", :thread_mismatch},
        {"completion-wrong-turn", :thread_mismatch},
        {"turn-started-foreign", :thread_mismatch},
        {"turn-started-noid", :thread_mismatch},
        {"turn-started-swapped", :thread_mismatch},
        {"model-error", :model_error}
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

  test "rejects malformed and duplicate dynamic tool shapes without launching a process", %{opts: opts} do
    [valid] = opts.tools

    for key <- [:tools, :thread_tools], tools <- [nil, %{}, [nil], [valid, valid], [%{valid | "inputSchema" => []}], [Map.put(valid, "type", "shell")]] do
      assert {:error, :invalid_tools} = run(Map.put(opts, key, tools), "split")
    end

    refute File.exists?(Path.join(opts.codex_home, "child-pid"))
  end

  test "invalid or mismatched native thread identity cannot resume another history", %{opts: opts} do
    assert {:error, :invalid_runtime_options} = run(Map.put(opts, :thread_id, 42), "split")
    File.write!(Path.join(opts.codex_home, "native-thread"), "previous-thread")
    assert {:error, :thread_mismatch} = run(Map.put(opts, :thread_id, "previous-thread"), "resume-mismatch")
  end

  test "model discovery follows pages but stops a looping pagination cursor", %{opts: opts} do
    assert {:ok, _} = run(opts, "model-second-page")
    requests_path = Path.join(opts.codex_home, "requests.jsonl")
    assert Enum.count(requests(requests_path), &(&1["method"] == "model/list")) == 2
    File.write!(requests_path, "")
    assert {:error, :model_unavailable} = run(opts, "model-pages")
    assert Enum.count(requests(requests_path), &(&1["method"] == "model/list")) == 20
    assert_child_stopped(opts)
  end

  test "benign startup and turn notifications do not lose correlated RPC replies", %{opts: opts} do
    assert {:ok, _} = run(opts, "startup-notification")
    assert {:ok, _} = run(opts, "turn-started")
    assert_received {:event, {:delta, "Current "}}
    assert_received {:event, {:delta, "tasks"}}
    assert {:ok, _} = run(opts, "model-retry")
    assert_received {:event, {:status, "Reconnecting to the model"}}
  end

  test "tool bad returns and throws become sanitized protocol responses", %{opts: opts} do
    for tool <- [fn _, _ -> nil end, fn _, _ -> throw("private credential diagnostic") end] do
      assert {:ok, _} = run(opts, "split", tool)
    end

    output = File.read!(Path.join(opts.codex_home, "requests.jsonl"))
    assert output =~ "tool_failed"
    refute output =~ "private credential diagnostic"
  end

  test "a timed-out management tool is terminated before returning its failure", %{opts: opts} do
    owner = self()

    tool = fn _, _ ->
      send(owner, {:tool_task, self()})
      receive do: (:finish -> %{})
    end

    assert {:error, :tool_timeout} = run(%{opts | timeout_ms: 2_500}, "split", tool)
    assert_received {:tool_task, task}
    refute Process.alive?(task)
    assert_child_stopped(opts)
  end

  test "an interrupt before the turn exists does not submit an unscoped control request", %{opts: opts} do
    send(self(), :interrupt)
    assert {:error, :interrupted_before_turn} = run(opts, "split")
  end

  test "repeated interrupts do not issue duplicate controls and lack of completion stays uncertain", %{opts: opts} do
    File.write!(Path.join(opts.codex_home, "fixture-mode"), "interrupt-repeat")
    owner = self()
    task = Task.async(fn -> Runtime.run(opts, &send(owner, {:event, &1}), fn _, _ -> %{} end) end)
    assert_receive {:event, {:delta, "Working"}}, 5_000
    send(task.pid, :interrupt)
    assert_receive {:event, {:delta, "Stopping"}}, 5_000
    send(task.pid, :interrupt)
    assert {:error, :interrupt_timeout} = Task.await(task, 5_000)
    calls = requests(Path.join(opts.codex_home, "requests.jsonl"))
    assert Enum.count(calls, &(&1["method"] == "turn/interrupt")) == 1
    assert_child_stopped(opts)
  end

  test "event-consumer failure shuts down the child without leaking its diagnostic", %{opts: opts} do
    File.write!(Path.join(opts.codex_home, "fixture-mode"), "split")
    assert {:error, :runtime_unavailable} = Runtime.run(opts, fn _event -> raise "private callback failure" end, fn _, _ -> %{} end)
    assert_child_stopped(opts)
  end

  test "cleanup safely handles an already-closed owned transport", %{opts: opts} do
    File.write!(Path.join(opts.codex_home, "fixture-mode"), "split")

    emit = fn {:thread, _id} ->
      {:links, links} = Process.info(self(), :links)
      port = Enum.find(links, &is_port/1)
      assert is_port(port)
      Port.close(port)
    end

    assert {:error, :runtime_unavailable} = Runtime.run(opts, emit, fn _, _ -> %{} end)
    assert_child_stopped(opts)
  end

  defp requests(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

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
