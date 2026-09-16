defmodule SymphonyElixir.ProcessGroup do
  @moduledoc """
  Owns a local command's original process group until its port closes.

  The small Python guardian holds a host-owned workspace lock through cleanup,
  sends TERM then KILL to that group, and reaps its direct child. Descendants that
  start new process groups or sessions are outside this boundary. Real Codex pipe
  commands do this: tools/probe_cancellation.py demonstrates the limitation. A
  container PID namespace is required before unattended worker activation.
  No machine-wide process matching is used.
  """

  @guardian ~S"""
  import fcntl, glob, json, os, pathlib, re, select, selectors, shutil, signal, subprocess, sys, time, uuid
  selector = selectors.DefaultSelector()
  selector.register(0, selectors.EVENT_READ)
  lock_fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
  pending = []
  while True:
      try:
          fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
          break
      except BlockingIOError:
          for key, events in selector.select(0.05):
              data = os.read(0, 65536)
              if not data:
                  sys.exit(0)
              pending.append(data)
  if glob.glob(sys.argv[1] + '.*.cid.intent'):
      raise RuntimeError('Workspace has an unverified container cleanup; operator recovery is required')
  owner = uuid.uuid4().hex
  cidfile = pathlib.Path(sys.argv[1] + '.' + owner + '.cid')
  intent = pathlib.Path(str(cidfile) + '.intent')
  os.environ['SYMPHONY_CONTAINER_CIDFILE'] = str(cidfile)
  os.environ['SYMPHONY_CONTAINER_OWNER'] = owner

  def remove_owned_container():
      if not intent.exists():
          return
      docker = shutil.which('docker')
      if not docker:
          raise RuntimeError('Cannot verify container cleanup: Docker CLI unavailable')
      recorded = json.loads(intent.read_text())
      endpoint = recorded.get('docker_host', '')
      if recorded.get('owner') != owner or not endpoint.startswith('unix:///') or any(c in endpoint for c in ('\n', '\r', '\0')):
          raise RuntimeError('Invalid container cleanup identity; workspace remains blocked')
      docker_command = [docker, '--host', endpoint]
      docker_env = {key: value for key, value in os.environ.items() if key not in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_CONFIG')}
      name = 'symphony-' + owner
      template = '{{index .Config.Labels "com.openai.symphony.owner"}} {{.Id}}'
      def inspect(target):
          result = subprocess.run(docker_command + ['inspect', '--format', template, target], env=docker_env, capture_output=True, text=True, timeout=15)
          if result.returncode == 0:
              return result.stdout.strip().split()
          if 'no such object:' in result.stderr.lower() or 'no such container:' in result.stderr.lower():
              return None
          raise RuntimeError('Docker cleanup inspection failed; workspace remains blocked: ' + result.stderr[-1000:])
      target = name
      if cidfile.exists():
          target = cidfile.read_text().strip()
          if not re.fullmatch('[a-f0-9]{64}', target):
              raise RuntimeError('Invalid recorded container ID; workspace remains blocked')
      identity = inspect(target)
      if identity is None and not cidfile.exists():
          raise RuntimeError('Container creation did not settle; retaining cleanup intent for operator recovery')
      if identity is not None:
          if len(identity) != 2 or identity[0] != owner or not re.fullmatch('[a-f0-9]{64}', identity[1]):
              raise RuntimeError('Container ownership mismatch; refusing removal')
          result = subprocess.run(docker_command + ['rm', '--force', identity[1]], env=docker_env, capture_output=True, text=True, timeout=20)
          if result.returncode != 0 or inspect(identity[1]) is not None:
              raise RuntimeError('Container removal was not verified; workspace remains blocked')
      cidfile.unlink(missing_ok=True)
      intent.unlink()

  if not hasattr(select, 'kqueue') and not hasattr(os, 'waitid'):
      raise RuntimeError('Cannot observe owned child exit without reaping on this platform')
  child = subprocess.Popen(sys.argv[2:], stdin=subprocess.PIPE, start_new_session=True)
  exit_queue = None
  exit_observed = False
  def child_exited():
      global exit_observed
      if not exit_observed:
          if exit_queue is not None:
              exit_observed = bool(exit_queue.control(None, 1, 0))
          else:
              exit_observed = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
      return exit_observed
  def interrupted(signum, frame):
      raise SystemExit(128 + signum)
  signal.signal(signal.SIGTERM, interrupted)
  signal.signal(signal.SIGINT, interrupted)
  status = 1
  try:
      # Keep the leader unreaped (and its numeric identity unavailable for reuse)
      # until both group signals complete. No descendant discovery is involved.
      if hasattr(select, 'kqueue'):
          exit_queue = select.kqueue()
          try:
              exit_queue.control([select.kevent(child.pid, filter=select.KQ_FILTER_PROC,
                                  flags=select.KQ_EV_ADD, fflags=select.KQ_NOTE_EXIT)], 0, 0)
          except ProcessLookupError:
              # A fast child can already be a zombie before event registration.
              # We still own it and have not called wait/poll to release its PID.
              exit_observed = True
      for data in pending:
          child.stdin.write(data)
      child.stdin.flush()
      while not child_exited():
          for key, events in selector.select(0.1):
              data = os.read(0, 65536)
              if not data:
                  raise SystemExit(0)
              child.stdin.write(data)
              child.stdin.flush()
  except (BrokenPipeError, KeyboardInterrupt):
      pass
  finally:
      selector.close()
      try:
          for sig in (signal.SIGTERM, signal.SIGKILL):
              try:
                  os.killpg(child.pid, sig)
              except ProcessLookupError:
                  pass
              except PermissionError:
                  if not child_exited():
                      raise
              if sig == signal.SIGTERM:
                  time.sleep(0.2)
          status = child.wait(timeout=2)
      finally:
          if exit_queue is not None:
              exit_queue.close()
          remove_owned_container()
          os.close(lock_fd)
  sys.exit(status if status >= 0 else 128 - status)
  """

  @spec open(String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def open(command, opts \\ []) do
    case System.find_executable("python3") do
      nil ->
        {:error, :process_guardian_python_not_found}

      python ->
        workspace = Keyword.fetch!(opts, :cd) |> Path.expand()
        lock_root = Path.join(Path.dirname(workspace), ".symphony-process-locks")
        File.mkdir_p!(lock_root)
        lock_name = :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower)
        lock_path = Path.join(lock_root, lock_name <> ".lock")

        port_opts = [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-I", "-u", "-c", @guardian, lock_path, "/bin/sh", "-c", command],
          cd: workspace,
          env: port_environment(Keyword.get(opts, :env, []))
        ]

        port_opts = if opts[:line], do: port_opts ++ [line: opts[:line]], else: port_opts
        {:ok, Port.open({:spawn_executable, python}, port_opts)}
    end
  end

  @doc "Removes browser identity credentials before a port or its descendants start."
  @spec port_environment(list()) :: list()
  def port_environment(environment \\ []) do
    names = SymphonyElixir.Config.browser_auth_secret_environment_names()
    Enum.reject(environment, fn {name, _value} -> to_string(name) in names end) ++ Enum.map(names, &{String.to_charlist(&1), false})
  end

  @spec command_environment(list()) :: list()
  def command_environment(environment \\ []) do
    environment
    |> port_environment()
    |> Enum.map(fn
      {name, value} when value in [false, nil] -> {to_string(name), nil}
      {name, value} -> {to_string(name), to_string(value)}
    end)
  end

  @doc "Removes browser credentials that a login profile may have reintroduced."
  @spec shell_command(String.t()) :: String.t()
  def shell_command(command) do
    names = SymphonyElixir.Config.browser_auth_secret_environment_names()
    "unset " <> Enum.join(names, " ") <> " && " <> command
  end

  @spec run(String.t(), keyword()) :: {:ok, {String.t(), integer()}} | {:error, term()}
  def run(command, opts) do
    with {:ok, port} <- open(command, opts) do
      try do
        collect(port, System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout_ms), "")
      after
        close(port)
      end
    end
  end

  @spec close(port()) :: :ok
  def close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp collect(port, deadline, output) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    if remaining == 0 do
      {:error, :command_timeout}
    else
      receive_output(port, deadline, output, remaining)
    end
  end

  defp receive_output(port, deadline, output, remaining) do
    receive do
      {^port, {:data, data}} ->
        if byte_size(output) + byte_size(data) > 1_048_576 do
          {:error, :command_output_limit}
        else
          collect(port, deadline, output <> data)
        end

      {^port, {:exit_status, status}} ->
        {:ok, {output, status}}
    after
      remaining -> {:error, :command_timeout}
    end
  end
end
