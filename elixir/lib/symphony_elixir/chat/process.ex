defmodule SymphonyElixir.Chat.Process do
  @moduledoc false

  # Management chat exposes no local execution tools. This guardian still owns
  # the App Server child and reaps it when its OTP port closes, including abrupt
  # task termination. No process-name scans, inherited stderr or shell commands.
  @guardian ~S"""
  import os, selectors, signal, subprocess, sys
  child = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL)
  poller = selectors.DefaultSelector()
  poller.register(0, selectors.EVENT_READ)
  poller.register(child.stdout, selectors.EVENT_READ)
  def interrupt(signum, frame):
      raise SystemExit(128 + signum)
  signal.signal(signal.SIGTERM, interrupt)
  signal.signal(signal.SIGINT, interrupt)
  try:
      while True:
          for key, _ in poller.select():
              data = os.read(key.fd, 65536)
              if not data:
                  raise SystemExit(0)
              if key.fd == 0:
                  child.stdin.write(data)
                  child.stdin.flush()
              else:
                  sys.stdout.buffer.write(data)
                  sys.stdout.buffer.flush()
  except (BrokenPipeError, KeyboardInterrupt):
      pass
  finally:
      poller.close()
      child.terminate()
      try:
          child.wait(timeout=0.2)
      except subprocess.TimeoutExpired:
          child.kill()
          child.wait(timeout=2)
  """

  @spec open(String.t(), [String.t()], String.t(), list()) :: port()
  def open(executable, args, workspace, environment) do
    python = System.find_executable("python3") || raise "Python runtime unavailable"

    Port.open({:spawn_executable, python}, [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      args: ["-I", "-u", "-c", @guardian, executable | args],
      cd: workspace,
      env: SymphonyElixir.ProcessGroup.port_environment(environment)
    ])
  end
end
