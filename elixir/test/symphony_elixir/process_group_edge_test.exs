defmodule SymphonyElixir.ProcessGroupEdgeTest do
  use ExUnit.Case

  alias SymphonyElixir.{PathSafety, ProcessGroup}

  setup do
    {:ok, root} =
      PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony-process-edge-#{System.unique_integer([:positive])}"))

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace}
  end

  test "cleanup tolerates invalid handles without masking the original failure" do
    assert :ok = ProcessGroup.close(make_ref())
  end

  test "a quiet running command times out and releases its workspace after cleanup", context do
    started = Path.join(context.workspace, "started")
    command = "touch " <> shell_escape(started) <> "; exec sleep 30"

    assert {:error, :command_timeout} = ProcessGroup.run(command, cd: context.workspace, timeout_ms: 1_000)
    assert File.exists?(started)

    # The guardian retains the workspace lock until its owned child is reaped.
    # A successor must wait for that cleanup instead of inheriting a live child.
    assert {:ok, {"reused\n", 0}} = ProcessGroup.run("echo reused", cd: context.workspace, timeout_ms: 3_000)
  end

  test "verified cleanup uses its recorded endpoint and removes only the owned container", context do
    {command, env, trace} = fixture(context, "matching")
    assert {:ok, {"", 0}} = ProcessGroup.run(command, cd: context.workspace, env: env, timeout_ms: 3_000)
    assert commands(trace) == ["inspect", "rm", "inspect"]
    assert Path.wildcard(Path.join(context.root, ".symphony-process-locks/*.intent")) == []
    assert {:ok, {"reusable\n", 0}} = ProcessGroup.run("echo reusable", cd: context.workspace, timeout_ms: 2_000)
  end

  test "foreign container identity is retained and never removed", context do
    {command, env, trace} = fixture(context, "foreign")
    assert {:ok, {output, status}} = ProcessGroup.run(command, cd: context.workspace, env: env, timeout_ms: 3_000)
    assert status != 0
    assert output =~ "Container ownership mismatch"
    assert commands(trace) == ["inspect"]
    assert_blocked(context)
  end

  test "unknown Docker inspection holds the workspace instead of treating absence as success", context do
    {command, env, trace} = fixture(context, "unavailable")
    assert {:ok, {output, status}} = ProcessGroup.run(command, cd: context.workspace, env: env, timeout_ms: 3_000)
    assert status != 0
    assert output =~ "Docker cleanup inspection failed"
    assert commands(trace) == ["inspect"]
    assert_blocked(context)
  end

  defp assert_blocked(context) do
    assert [_intent] = Path.wildcard(Path.join(context.root, ".symphony-process-locks/*.intent"))
    marker = Path.join(context.workspace, "unexpected-reuse")
    assert {:ok, {output, status}} = ProcessGroup.run("touch " <> shell_escape(marker), cd: context.workspace, timeout_ms: 2_000)
    assert status != 0
    assert output =~ "operator recovery is required"
    refute File.exists?(marker)
  end

  defp commands(trace) do
    trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.map(&Enum.at(&1, 2))
  end

  defp fixture(context, mode) do
    python = System.find_executable("python3")
    bin = Path.join(context.root, "bin")
    File.mkdir_p!(bin)
    docker = Path.join(bin, "docker")
    trace = Path.join(context.root, "docker-calls")
    removed = Path.join(context.root, "removed")

    File.write!(docker, """
    #!#{python}
    import json, os, pathlib, sys
    mode = #{Jason.encode!(mode)}
    trace = pathlib.Path(#{Jason.encode!(trace)})
    removed = pathlib.Path(#{Jason.encode!(removed)})
    assert sys.argv[1:3] == ['--host', 'unix:///fixture-only.sock']
    assert not any(key in os.environ for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_CONFIG'))
    with trace.open('a') as stream:
        stream.write(json.dumps(sys.argv[1:]) + '\\n')
    if sys.argv[3] == 'inspect':
        if mode == 'unavailable':
            print('Cannot connect to fixture daemon', file=sys.stderr)
            sys.exit(1)
        if removed.exists():
            print('Error: No Such Object: fixture', file=sys.stderr)
            sys.exit(1)
        owner = os.environ['SYMPHONY_CONTAINER_OWNER'] if mode == 'matching' else 'foreign-owner'
        print(owner + ' ' + 'a' * 64)
    elif sys.argv[3:5] == ['rm', '--force']:
        assert mode == 'matching' and sys.argv[5] == 'a' * 64
        removed.touch()
    else:
        raise RuntimeError('Unexpected fixture Docker operation')
    """)

    File.chmod!(docker, 0o755)
    child = Path.join(context.root, "container-intent.py")

    File.write!(child, """
    import json, os, pathlib
    cidfile = pathlib.Path(os.environ['SYMPHONY_CONTAINER_CIDFILE'])
    cidfile.write_text('a' * 64)
    pathlib.Path(str(cidfile) + '.intent').write_text(json.dumps({
        'owner': os.environ['SYMPHONY_CONTAINER_OWNER'],
        'docker_host': 'unix:///fixture-only.sock'
    }))
    """)

    env = [
      {~c"PATH", String.to_charlist(bin <> ":" <> System.get_env("PATH", ""))},
      {~c"DOCKER_HOST", ~c"tcp://untrusted.invalid:2375"},
      {~c"DOCKER_CONTEXT", ~c"untrusted"},
      {~c"DOCKER_CONFIG", ~c"/untrusted/config"}
    ]

    {shell_escape(python) <> " -I " <> shell_escape(child), env, trace}
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
