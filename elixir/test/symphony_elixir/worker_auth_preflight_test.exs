defmodule SymphonyElixir.WorkerAuthPreflightTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Config, PathSafety, WorkerFailure}
  alias SymphonyElixir.Config.Schema

  setup do
    {:ok, root} = PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony-auth-preflight-#{System.unique_integer([:positive])}"))
    workspace = root <> "/issue"
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace}
  end

  test "controlled preflight proves provider access before creating a thread", ctx do
    configure(ctx, "ok")
    assert Config.codex_auth_preflight?()
    assert {:ok, session} = AppServer.start_session(ctx.workspace)
    AppServer.stop_session(session)
    requests = trace(ctx)
    assert Enum.map(requests, & &1["method"]) == ["initialize", "initialized", "account/read", "getAuthStatus", "account/rateLimits/read", "thread/start"]
    assert Enum.at(requests, 2)["params"] == %{"refreshToken" => true}
    assert Enum.at(requests, 3)["params"] == %{"includeToken" => false, "refreshToken" => false}
    assert Enum.at(requests, 4)["params"] == nil
  end

  test "cached account, invalid authentication and missing provider evidence never start work", ctx do
    for mode <-
          ~w(no_account wrong_account wrong_requires_auth malformed_account wrong_auth_method missing_status_auth token_leak empty_limits malformed_limits unauthorized refresh_revoked provider_401 external_missing_method external_invalid_method external_missing_status_auth external_token_leak external_provider_401 external_refresh_callback external_refresh_callback_collision) do
      fixture = fixture(ctx, mode)
      configure(fixture, mode)

      logs =
        capture_log(fn ->
          result = AppServer.start_session(fixture.workspace)
          assert {:error, {:startup_failed, :worker_auth, :worker_auth_required}} = result
        end)

      refute logs =~ "PRIVATE_TOKEN_SENTINEL"
      refute logs =~ "PRIVATE_PROVIDER_SENTINEL"
      refute logs =~ "PRIVATE_CALLBACK_SENTINEL"
      refute Enum.any?(trace(fixture), &(&1["method"] in ["thread/start", "turn/start"]))
      assert_stopped(fixture)
    end
  end

  test "external authentication cannot replace the selected reviewer permission profile", ctx do
    configure(ctx, "external_wrong_profile")
    result = AppServer.start_session(ctx.workspace, profile: :reviewer)
    assert {:error, {:startup_failed, :thread_start, {:permission_profile_mismatch, "symphony-reviewer"}}} = result
    assert_stopped(ctx)
  end

  test "external ChatGPT tokens retain token-free provider checks and both role permissions", ctx do
    for role <- [:builder, :reviewer] do
      fixture = fixture(ctx, "external-#{role}")
      configure(fixture, "external_ok")
      assert {:ok, session} = AppServer.start_session(fixture.workspace, profile: role)
      AppServer.stop_session(session)
      requests = trace(fixture)

      assert Enum.map(requests, & &1["method"]) == ["initialize", "initialized", "account/read", "getAuthStatus", "account/rateLimits/read", "thread/start"]
      assert Enum.at(requests, 2)["params"] == %{"refreshToken" => true}
      assert Enum.at(requests, 3)["params"] == %{"includeToken" => false, "refreshToken" => false}
      assert Enum.at(requests, 4)["params"] == nil
      params = List.last(requests)["params"]
      assert params["config"]["default_permissions"] == "symphony-#{role}"
      assert params["approvalPolicy"] == "never"
      assert params["dynamicTools"] == []
      assert_stopped(fixture)
    end
  end

  test "transient provider or transport failure remains retryable and stops startup", ctx do
    for mode <- ~w(transient provider_429 provider_503 provider_401_body untrusted_401 wrong_rpc_code) do
      fixture = fixture(ctx, mode)
      configure(fixture, mode)
      assert {:error, {:startup_failed, :worker_auth, reason}} = AppServer.start_session(fixture.workspace)
      assert {:response_error, error} = reason
      assert error["code"] in [-32_000, -32_603]
      refute WorkerFailure.authentication_required?(reason)
      refute Enum.any?(trace(fixture), &(&1["method"] in ["thread/start", "turn/start"]))
      assert_stopped(fixture)
    end
  end

  test "dedicated wrapper auth exit statuses require explicit recovery before initialization", ctx do
    for status <- [78, 79] do
      fixture = fixture(ctx, "wrapper-#{status}")
      configure(fixture, "exit_#{status}")
      result = AppServer.start_session(fixture.workspace)
      assert {:error, {:startup_failed, :initialize, :worker_auth_required}} = result
      refute Enum.any?(trace(fixture), &(&1["method"] in ["thread/start", "turn/start"]))
      assert_stopped(fixture)
    end
  end

  test "wrapper exit statuses remain ordinary failures for default or uncontrolled clients", ctx do
    for {controlled, enabled} <- [{true, nil}, {false, true}], status <- [78, 79] do
      fixture = fixture(ctx, "wrapper-#{controlled}-#{status}")
      configure(fixture, "exit_#{status}", controlled: controlled, auth_preflight: enabled)
      result = AppServer.start_session(fixture.workspace)

      if controlled do
        assert {:error, {:startup_failed, :initialize, {:port_exit, ^status}}} = result
      else
        assert {:error, {:port_exit, ^status}} = result
      end

      refute WorkerFailure.authentication_required?(elem(result, 1))
      refute Enum.any?(trace(fixture), &(&1["method"] in ["thread/start", "turn/start"]))
    end
  end

  test "auth ownership loss after a turn starts is terminal and retains reported usage", ctx do
    for status <- [78, 79], role <- [:builder, :reviewer] do
      fixture = fixture(ctx, "mid-turn-#{status}-#{role}")
      configure(fixture, "external_turn_exit_#{status}")
      assert {:ok, session} = AppServer.start_session(fixture.workspace, profile: role)
      messages_key = make_ref()
      Process.put(messages_key, [])
      on_message = fn message -> Process.put(messages_key, [message | Process.get(messages_key)]) end
      issue = %{id: "7", identifier: "GH-7", title: "Fixture task"}

      logs =
        capture_log(fn ->
          assert {:error, :worker_auth_required} = AppServer.run_turn(session, "Fixture turn", issue, on_message: on_message)
        end)

      messages = Process.delete(messages_key)
      assert Enum.any?(messages, &(&1.event == :session_started))
      assert Enum.any?(messages, &(get_in(&1, [:payload, "method"]) == "thread/tokenUsage/updated" and get_in(&1, [:payload, "params", "tokenUsage", "total", "totalTokens"]) == 23))
      assert Enum.any?(messages, &(&1.event == :turn_ended_with_error and &1.reason == :worker_auth_required))
      assert WorkerFailure.authentication_required?(:worker_auth_required)
      refute logs =~ "PRIVATE"
      AppServer.stop_session(session)
      assert_stopped(fixture)
    end
  end

  test "mid-turn reserved exits do not change default or uncontrolled behavior", ctx do
    for {controlled, enabled} <- [{true, nil}, {false, true}], status <- [78, 79] do
      fixture = fixture(ctx, "mid-turn-default-#{controlled}-#{status}")
      configure(fixture, "external_turn_exit_#{status}", controlled: controlled, auth_preflight: enabled)
      assert {:ok, session} = AppServer.start_session(fixture.workspace)
      issue = %{id: "7", identifier: "GH-7", title: "Fixture task"}
      result = AppServer.run_turn(session, "Fixture turn", issue)
      assert {:error, {:port_exit, ^status}} = result
      refute WorkerFailure.authentication_required?(elem(result, 1))
      AppServer.stop_session(session)
      assert_stopped(fixture)
    end
  end

  test "silent provider RPC times out and cleans up its guardian", ctx do
    configure(ctx, "timeout")
    startup = Task.async(fn -> AppServer.start_session(ctx.workspace) end)

    try do
      # Interpreter/guardian startup keeps its normal allowance. The fixture
      # pauses the last successful auth reply so only the silent RPC gets 500ms.
      wait_for_file(ctx.root <> "/auth-ready", 100)
      configure(ctx, "timeout", read_timeout_ms: 500)
      started = System.monotonic_time(:millisecond)
      File.write!(ctx.root <> "/auth-continue", "ready")
      assert {:error, {:startup_failed, :worker_auth, :response_timeout}} = Task.await(startup, 5_000)
      assert Enum.map(trace(ctx), & &1["method"]) == ["initialize", "initialized", "account/read", "getAuthStatus", "account/rateLimits/read"]
      assert_stopped(ctx)
      assert System.monotonic_time(:millisecond) - started < 2_000
    after
      Task.shutdown(startup, :brutal_kill)
    end
  end

  test "opt-in is disabled by default and does not affect uncontrolled clients", ctx do
    for {controlled, enabled} <- [{true, nil}, {false, true}] do
      fixture = fixture(ctx, "#{controlled}")
      configure(fixture, "ok", controlled: controlled, auth_preflight: enabled)
      assert Config.codex_auth_preflight?() == (enabled == true)
      assert {:ok, session} = AppServer.start_session(fixture.workspace)
      AppServer.stop_session(session)
      refute Enum.any?(trace(fixture), &(&1["method"] in ["account/read", "getAuthStatus", "account/rateLimits/read"]))
    end
  end

  test "configuration rejects malformed preflight flags" do
    config = %{"codex" => %{"auth_preflight" => "not-a-boolean"}}
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "auth_preflight"
  end

  defp fixture(ctx, label) do
    root = ctx.root <> "/" <> label
    workspace = root <> "/issue"
    File.mkdir_p!(workspace)
    %{root: root, workspace: workspace}
  end

  defp configure(ctx, mode, opts \\ []) do
    command = server(ctx, mode)
    codex = %{command: command, read_timeout_ms: opts[:read_timeout_ms] || 5_000}
    codex = if Keyword.has_key?(opts, :auth_preflight) and is_nil(opts[:auth_preflight]), do: codex, else: Map.put(codex, :auth_preflight, Keyword.get(opts, :auth_preflight, true))

    settings = %{
      tracker: %{kind: "memory"},
      workspace: %{root: ctx.root},
      codex: codex,
      control: %{enabled: Keyword.get(opts, :controlled, true), state_path: ctx.root <> "/control.json"}
    }

    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(settings) <> "\n---\nTask")
    WorkflowStore.force_reload()
  end

  defp trace(ctx) do
    File.read!(ctx.root <> "/trace") |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp assert_stopped(ctx) do
    pid = File.read!(ctx.root <> "/pid")
    wait_for_exit(pid)
  end

  defp wait_for_file(path, 0), do: assert(File.exists?(path))

  defp wait_for_file(path, attempts) do
    unless File.exists?(path) do
      Process.sleep(50)
      wait_for_file(path, attempts - 1)
    end
  end

  defp wait_for_exit(pid, attempts \\ 40)

  defp wait_for_exit(pid, 0) do
    {_output, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  defp wait_for_exit(pid, attempts) do
    {_output, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)

    if status == 0 do
      Process.sleep(50)
      wait_for_exit(pid, attempts - 1)
    end
  end

  defp server(ctx, mode) do
    path = ctx.root <> "/server.py"

    File.write!(path, """
    #!/usr/bin/env python3
    import json, os, sys, time
    root = #{Jason.encode!(ctx.root)}
    mode = #{Jason.encode!(mode)}
    open(root + '/pid', 'w').write(str(os.getpid()))
    def send(msg): print(json.dumps(msg), flush=True)
    for line in sys.stdin:
        msg = json.loads(line)
        with open(root + '/trace', 'a') as f: f.write(json.dumps(msg) + '\\n')
        method = msg['method']
        if method == 'initialize':
            if mode.startswith('exit_'): sys.exit(int(mode[5:]))
            send({'id': msg['id'], 'result': {}})
        elif method == 'account/read':
            result = {'account': {'type': 'chatgpt'}, 'requiresOpenaiAuth': True}
            if mode == 'no_account': result['account'] = None
            if mode == 'wrong_account': result['account'] = {'type': 'apiKey'}
            if mode == 'wrong_requires_auth': result['requiresOpenaiAuth'] = False
            if mode == 'malformed_account': result = []
            send({'id': msg['id'], 'result': result})
        elif method == 'getAuthStatus':
            if mode == 'timeout':
                open(root + '/auth-ready', 'w').close()
                while not os.path.exists(root + '/auth-continue'): time.sleep(0.01)
            result = {'authMethod': 'chatgpt', 'requiresOpenaiAuth': True, 'authToken': None}
            if mode.startswith('external_'): result['authMethod'] = 'chatgptAuthTokens'
            if mode == 'wrong_auth_method': result['authMethod'] = 'apiKey'
            if mode == 'external_missing_method': del result['authMethod']
            if mode == 'external_invalid_method': result['authMethod'] = 'externalAuth'
            if mode in ('missing_status_auth', 'external_missing_status_auth'): del result['requiresOpenaiAuth']
            if mode in ('token_leak', 'external_token_leak'): result['authToken'] = 'PRIVATE_TOKEN_SENTINEL'
            send({'id': msg['id'], 'result': result})
        elif method == 'account/rateLimits/read':
            if mode == 'timeout': time.sleep(5)
            elif mode in ('external_refresh_callback', 'external_refresh_callback_collision'):
                callback_id = msg['id'] if mode.endswith('_collision') else 'private-refresh'
                send({'id': callback_id, 'method': 'account/chatgptAuthTokens/refresh', 'error': {'message': 'PRIVATE_PROVIDER_SENTINEL'}, 'params': {'reason': 'unauthorized', 'previousAccountId': 'PRIVATE_CALLBACK_SENTINEL', 'accessToken': 'PRIVATE_TOKEN_SENTINEL'}})
            elif mode in ('unauthorized', 'refresh_revoked', 'transient'):
                code = {'unauthorized': 'unauthorized', 'refresh_revoked': 'refresh_token_revoked', 'transient': -32000}[mode]
                send({'id': msg['id'], 'error': {'code': code, 'message': 'PRIVATE_PROVIDER_SENTINEL'}})
            elif mode.startswith('provider_') or mode in ('untrusted_401', 'wrong_rpc_code', 'external_provider_401'):
                status = {'provider_429': '429 Too Many Requests', 'provider_503': '503 Service Unavailable'}.get(mode, '401 Unauthorized')
                message = 'failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: ' + status
                message += '; content-type=application/json; body=PRIVATE_PROVIDER_SENTINEL'
                if mode == 'provider_401_body': message = message.replace('failed: 401 Unauthorized', 'failed: 503 Service Unavailable') + ' 401 Unauthorized'
                if mode == 'untrusted_401': message = 'Task description says 401 Unauthorized'
                code = -32000 if mode == 'wrong_rpc_code' else -32603
                send({'id': msg['id'], 'error': {'code': code, 'message': message}})
            else:
                result = {'rateLimits': {'primary': {'usedPercent': 0}}}
                if mode == 'empty_limits': result['rateLimits'] = {}
                if mode == 'malformed_limits': result = []
                send({'id': msg['id'], 'result': result})
        elif method == 'thread/start':
            profile = msg['params'].get('config', {}).get('default_permissions', 'symphony-builder')
            if mode == 'external_wrong_profile': profile = 'symphony-builder'
            send({'id': msg['id'], 'result': {'thread': {'id': 'auth-verified'}, 'activePermissionProfile': {'id': profile}}})
        elif method == 'turn/start':
            send({'id': msg['id'], 'result': {'turn': {'id': 'auth-turn'}}})
            send({'method': 'turn/started', 'params': {'turn': {'id': 'auth-turn'}}})
            send({'method': 'thread/tokenUsage/updated', 'params': {'tokenUsage': {'total': {'inputTokens': 20, 'outputTokens': 3, 'totalTokens': 23}}}})
            if mode.startswith('external_turn_exit_'): sys.exit(int(mode.rsplit('_', 1)[1]))
    """)

    File.chmod!(path, 0o755)
    path
  end
end
