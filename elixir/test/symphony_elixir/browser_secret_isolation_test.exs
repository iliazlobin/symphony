defmodule SymphonyElixir.BrowserSecretIsolationTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Chat.Persistence

  alias SymphonyElixir.{PathSafety, ProcessGroup, SSH}

  @secret "SYMP_TEST_BROWSER_CLIENT_SECRET"
  @client "SYMP_TEST_BROWSER_CLIENT_ID"
  @public "SYMP_TEST_BROWSER_PUBLIC_VALUE"
  @chat_secret "SYMP_TEST_CHAT_API_KEY"
  @chat_reserved "OPENROUTER_API_KEY"
  @reserved ["SYMPHONY_GOOGLE_CLIENT_ID", "SYMPHONY_GOOGLE_CLIENT_SECRET"]
  @workspace ~w(SYMPHONY_WORKSPACE_SECRET SYMPHONY_WORKSPACE_AUTH_SOCKET SYMPHONY_WORKSPACE_ENGINE_SOCKET SYMPHONY_WORKSPACE_PROJECT SYMPHONY_WORKSPACE_ORIGIN)

  setup do
    {:ok, root} = PathSafety.canonicalize(Path.dirname(Workflow.workflow_file_path()))
    workspace = Path.join(root, "workspaces/task")
    File.mkdir_p!(workspace)

    previous = Map.new([@secret, @client, @public, @chat_secret, @chat_reserved, "PATH"] ++ @reserved ++ @workspace, &{&1, System.get_env(&1)})
    System.put_env(@secret, "fixture-secret")
    System.put_env(@client, "fixture-client")
    System.put_env(@public, "visible")
    System.put_env(@chat_secret, "fixture-chat-key")
    System.put_env(@chat_reserved, "fixture-default-chat-key")
    Enum.each(@reserved ++ @workspace, &System.put_env(&1, "fixture-reserved"))
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)

    config = %{
      "tracker" => %{"kind" => "memory"},
      "chat" => %{"api_key" => "$" <> @chat_secret},
      "workspace" => %{"root" => Path.join(root, "workspaces")},
      "browser_auth" => %{"provider" => "google", "client_secret" => "$" <> @secret, "client_id" => "$" <> @client}
    }

    configure(config)
    %{root: root, workspace: workspace, config: config}
  end

  test "configured references are removed from guardian descendants even if options attempt to restore them", ctx do
    assert MapSet.new(Config.browser_auth_secret_environment_names()) == MapSet.new([@secret, @client] ++ @reserved)
    env = [{String.to_charlist(@secret), ~c"override-secret"}, {String.to_charlist(@client), ~c"override-client"}]

    assert {:ok, {"unset:unset:visible\n", 0}} =
             ProcessGroup.run(environment_probe(), cd: ctx.workspace, env: env, timeout_ms: 3_000)

    assert System.get_env(@secret) == "fixture-secret"
    assert System.get_env(@client) == "fixture-client"
  end

  test "chat credentials are excluded from ports, hooks and option overrides without clearing backend credentials", ctx do
    assert MapSet.new(Config.process_secret_environment_names()) == MapSet.new([@secret, @client, @chat_secret, @chat_reserved] ++ @reserved ++ @workspace)
    env = Enum.map([@chat_secret, @chat_reserved], &{String.to_charlist(&1), ~c"attempted-override"})
    probe = "printf '%s:%s:%s\\n' \"${#{@chat_secret}-unset}\" \"${#{@chat_reserved}-unset}\" \"$#{@public}\""
    assert {:ok, {"unset:unset:visible\n", 0}} = ProcessGroup.run(probe, cd: ctx.workspace, env: env, timeout_ms: 3_000)
    trace = Path.join(ctx.root, "chat-hook-env")
    configure(Map.put(ctx.config, "hooks", %{"before_run" => probe <> " > " <> quote_shell(trace)}))
    assert :ok = Workspace.run_before_run_hook(ctx.workspace, "TASK-1")
    assert File.read!(trace) == "unset:unset:visible\n"
    assert System.get_env(@chat_secret) == "fixture-chat-key"
    assert System.get_env(@chat_reserved) == "fixture-default-chat-key"
  end

  test "reserved launcher credentials stay private without Google settings and across workflow reloads", ctx do
    probe = "printf '%s:%s\\n' \"${SYMPHONY_GOOGLE_CLIENT_ID-unset}\" \"${SYMPHONY_GOOGLE_CLIENT_SECRET-unset}\""
    env = Enum.map(@reserved, &{String.to_charlist(&1), ~c"attempted-override"})

    for config <- [ctx.config, Map.delete(ctx.config, "browser_auth"), Map.put(ctx.config, "browser_auth", %{"provider" => "local_token"})] do
      configure(config)
      assert {:ok, {"unset:unset\n", 0}} = ProcessGroup.run(probe, cd: ctx.workspace, env: env, timeout_ms: 3_000)
      assert System.get_env("SYMPHONY_GOOGLE_CLIENT_SECRET") == "fixture-reserved"
    end
  end

  test "unmanaged workspace hooks cannot inherit browser credentials", ctx do
    trace = Path.join(ctx.root, "hook-env")
    configure(Map.put(ctx.config, "hooks", %{"before_run" => environment_probe() <> " > " <> quote_shell(trace)}))

    assert :ok = Workspace.run_before_run_hook(ctx.workspace, "TASK-1")
    assert File.read!(trace) == "unset:unset:visible\n"
  end

  test "unmanaged Codex startup strips inherited and login-profile browser credentials", ctx do
    python = System.find_executable("python3")
    trace = Path.join(ctx.root, "codex-env.json")
    executable = Path.join(ctx.root, "fake-codex")

    File.write!(executable, """
    #!#{python}
    import json, os, pathlib, sys
    pathlib.Path(#{Jason.encode!(trace)}).write_text(json.dumps({
        "secret_present": #{@secret |> Jason.encode!()} in os.environ,
        "client_present": #{@client |> Jason.encode!()} in os.environ,
        "chat_present": #{@chat_secret |> Jason.encode!()} in os.environ,
        "openrouter_present": #{@chat_reserved |> Jason.encode!()} in os.environ,
        "public": os.environ.get(#{Jason.encode!(@public)})
    }))
    for line in sys.stdin:
        request = json.loads(line)
        if "id" in request:
            result = {"thread": {"id": "fixture-thread"}} if request["method"] == "thread/start" else {}
            print(json.dumps({"id": request["id"], "result": result}), flush=True)
    """)

    File.chmod!(executable, 0o755)
    # Model the credentials being exported by a login shell's profile before it
    # evaluates the command, without touching the user's shell files or HOME.
    install_binary(ctx.root, "bash", """
    export #{@secret}=profile-secret #{@client}=profile-client #{@chat_secret}=profile-chat #{@chat_reserved}=profile-default-chat
    exec /bin/sh -c "$2"
    """)

    configure(Map.put(ctx.config, "codex", %{"command" => quote_shell(executable)}))
    assert {:ok, session} = AppServer.start_session(ctx.workspace)
    AppServer.stop_session(session)
    assert Jason.decode!(File.read!(trace)) == %{"secret_present" => false, "client_present" => false, "chat_present" => false, "openrouter_present" => false, "public" => "visible"}
  end

  test "SSH command and port strip local credentials and clear remote login-shell exports", ctx do
    install_binary(ctx.root, "ssh", """
    #{environment_probe()}
    export #{@secret}=remote-profile-secret #{@client}=remote-profile-client
    for last do :; done
    eval "$last"
    """)

    env = [{@secret, "override-secret"}]
    expected = "unset:unset:visible\nunset:unset:visible\n"
    assert {:ok, {^expected, 0}} = SSH.run("fixture", environment_probe(), env: env, stderr_to_stdout: true)
    assert {:ok, port} = SSH.start_port("fixture", environment_probe(), env: [{String.to_charlist(@secret), ~c"override-secret"}])
    assert collect(port, "") == {expected, 0}
  end

  test "chat process cannot inherit or explicitly restore browser credentials", ctx do
    executable = Path.join(ctx.root, "chat-fixture")
    File.write!(executable, "#!/bin/sh\n" <> environment_probe() <> "\n")
    File.chmod!(executable, 0o755)
    port = SymphonyElixir.Chat.Process.open(executable, [], ctx.workspace, [{String.to_charlist(@secret), ~c"override-secret"}])
    assert collect(port, "") == {"unset:unset:visible\n", 0}
  end

  test "control and conversation lock processes do not retain browser credentials", ctx do
    python = System.find_executable("python3")
    trace = Path.join(ctx.root, "lock-environments")

    install_binary(ctx.root, "python3", """
    #{environment_probe()} >> #{quote_shell(trace)}
    exec #{quote_shell(python)} "$@"
    """)

    settings = %{enabled: true, state_path: Path.join(ctx.root, "control.json"), initial_mode: "paused", max_attempts: 2, max_total_runtime_ms: 1_000, max_total_tokens: 100}
    assert {:ok, ledger} = SymphonyElixir.ControlLedger.open(settings, Path.dirname(ctx.workspace))

    try do
      assert {:ok, storage, %{}} = Persistence.open(Path.join(ctx.root, "chat-state"))

      try do
        assert File.read!(trace) == "unset:unset:visible\nunset:unset:visible\n"
      after
        Persistence.close(storage)
      end
    after
      SymphonyElixir.ControlLedger.close(ledger)
    end
  end

  test "environment names cannot inject shell syntax and literal client IDs are not secret references", ctx do
    configure(
      ctx.config
      |> Map.put("browser_auth", %{"provider" => "local_token", "client_id" => "public-client", "client_secret" => "$bad; injected"})
      |> Map.put("chat", %{})
    )

    assert Config.browser_auth_secret_environment_names() == @reserved
    names = Enum.join(@reserved ++ [@chat_reserved] ++ @workspace, " ")
    assert ProcessGroup.shell_command("printf ok") == "unset " <> names <> " && printf ok"

    assert ProcessGroup.command_environment([{"PUBLIC", "ok"}, {"REMOVED", false}]) ==
             [{"PUBLIC", "ok"}, {"REMOVED", nil}] ++ Enum.map(@reserved ++ [@chat_reserved] ++ @workspace, &{&1, nil})
  end

  test "workspace cookie key and private broker paths never enter worker descendants", ctx do
    env = Enum.map(@workspace, &{String.to_charlist(&1), ~c"attempted-override"})
    arguments = Enum.map_join(@workspace, " ", &"\"${#{&1}-unset}\"")
    probe = "printf '%s\\n' " <> arguments
    assert {:ok, {output, 0}} = ProcessGroup.run(probe, cd: ctx.workspace, env: env, timeout_ms: 3_000)
    assert String.split(output, "\n", trim: true) == List.duplicate("unset", length(@workspace))
    assert System.get_env("SYMPHONY_WORKSPACE_SECRET") == "fixture-reserved"
  end

  defp configure(config) do
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    assert :ok = WorkflowStore.force_reload()
  end

  defp environment_probe do
    "printf '%s:%s:%s\\n' \"${#{@secret}-unset}\" \"${#{@client}-unset}\" \"$#{@public}\""
  end

  defp install_binary(root, name, body) do
    directory = Path.join(root, "bin")
    File.mkdir_p!(directory)
    path = Path.join(directory, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    System.put_env("PATH", directory <> ":" <> System.get_env("PATH", ""))
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, data}} -> collect(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      5_000 ->
        ProcessGroup.close(port)
        flunk("Fixture subprocess did not finish")
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
