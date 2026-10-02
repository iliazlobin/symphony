defmodule SymphonyElixir.AcceptanceRecoveryTest do
  use ExUnit.Case

  alias Mix.Tasks.Acceptance.RecoverLegacy
  alias SymphonyElixir.{ControlLedger, IssueAcceptance, PathSafety}
  import ExUnit.CaptureIO

  @project "github:iliazlobin/events-concierge"
  @legacy "verified-legacy-fingerprint"
  @updated "2026-09-23T18:40:00Z"

  setup do
    {:ok, temporary} = PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(temporary, "symphony-acceptance-recovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    path = root <> "/control.json"

    issues = Map.new(["6", "11"], &{&1, legacy_issue(&1)})
    observed = Map.new(["6", "11"], &{&1, observation(&1)})

    data = %{
      "version" => 1,
      "revision" => 105,
      "mode" => "running",
      "issues" => issues,
      "commands" => %{"historical" => %{"fingerprint" => "command-fingerprint", "result" => %{"revision" => 73}}},
      "tracker_issues" => observed,
      "concurrency_override" => 2
    }

    bytes = Jason.encode!(data, pretty: true)
    File.write!(path, bytes)

    %{
      path: path,
      root: root,
      workspace: root <> "/workspaces",
      backup: root <> "/before-recovery.json",
      data: data,
      bytes: bytes,
      request: %{project_id: @project, tracker_fingerprint: @legacy, expected_revision: 105, issue_ids: ["6", "11"]}
    }
  end

  test "dry run validates bounded evidence and leaves original bytes and state unchanged", c do
    assert {:ok, %{changed_ids: ["6", "11"], already_upgraded_ids: []}} =
             ControlLedger.recover_legacy_acceptance(c.path, c.workspace, c.request)

    assert File.read!(c.path) == c.bytes
    refute File.exists?(c.backup)
  end

  test "apply backs up exact bytes, preserves all decisions and budgets, survives restart and replays without writing", c do
    assert {:ok, %{changed_ids: ["6", "11"]}} = recover(c, apply: true, backup_path: c.backup)
    assert File.read!(c.backup) == c.bytes
    assert Bitwise.band(File.stat!(c.backup).mode, 0o777) == 0o600
    updated = Jason.decode!(File.read!(c.path))

    for id <- ["6", "11"] do
      item = updated["issues"][id]
      assert item["acceptance"]["project_id"] == @project
      assert Map.delete(item["acceptance"], "project_id") == c.data["issues"][id]["acceptance"]
      assert Map.delete(item, "acceptance") == Map.delete(c.data["issues"][id], "acceptance")
      assert IssueAcceptance.accepted_in_scope?(item, @project, "rotated-config")
    end

    assert Map.delete(updated, "issues") == Map.delete(c.data, "issues")
    settings = settings(c)
    assert {:ok, ledger} = ControlLedger.open(settings, c.workspace)
    assert ledger.data == updated
    ControlLedger.close(ledger)
    bytes = File.read!(c.path)
    assert {:ok, %{changed_ids: [], already_upgraded_ids: ["6", "11"]}} = recover(c, apply: true, backup_path: c.backup)
    assert File.read!(c.path) == bytes
    assert File.read!(c.backup) == c.bytes
  end

  test "mismatched evidence rejects the whole batch without backup or partial upgrades", c do
    for data <- [
          put_in(c.data, ["tracker_issues", "11", "repository"], "other/repo"),
          put_in(c.data, ["tracker_issues", "11", "updated_at"], "2026-09-24T18:40:00Z"),
          put_in(c.data, ["issues", "11", "handoff", "review", "candidate_sha"], String.duplicate("f", 40)),
          put_in(c.data, ["issues", "11", "acceptance", "project_id"], "github:other/repo"),
          put_in(c.data, ["issues", "11", "hold"], "owner_review")
        ] do
      bytes = Jason.encode!(data)
      File.write!(c.path, bytes)
      assert {:error, :acceptance_migration_mismatch} = recover(c, apply: true, backup_path: c.backup)
      assert File.read!(c.path) == bytes
      refute File.exists?(c.backup)
    end

    File.write!(c.path, c.bytes)
    assert {:error, :acceptance_migration_mismatch} = recover(%{c | request: %{c.request | tracker_fingerprint: "foreign"}})
    assert {:error, :acceptance_migration_mismatch} = recover(%{c | request: %{c.request | issue_ids: ["6", "12"]}})
  end

  test "stale revision and any active reservation fail without startup recovery", c do
    assert {:error, :revision_conflict} = recover(%{c | request: %{c.request | expected_revision: 104}})
    data = put_in(c.data, ["issues", "11", "active"], %{"run_id" => "in-flight", "started_at_ms" => 0, "tokens" => 7})
    bytes = Jason.encode!(data)
    File.write!(c.path, bytes)
    assert {:error, :recovery_requires_idle_ledger} = recover(c, apply: true, backup_path: c.backup)
    assert File.read!(c.path) == bytes
    refute File.exists?(c.backup)
  end

  test "the native ledger owner lock fences dry run and apply", c do
    settings = settings(c)
    assert {:ok, ledger} = ControlLedger.open(settings, c.workspace)

    try do
      bytes = File.read!(c.path)
      assert {:error, :control_state_locked} = recover(c)
      assert {:error, :control_state_locked} = recover(c, apply: true, backup_path: c.backup)
      assert File.read!(c.path) == bytes
      refute File.exists?(c.backup)
    after
      ControlLedger.close(ledger)
    end
  end

  test "missing, symlinked, malformed and incorrectly bound state fails closed", c do
    assert {:error, :invalid_recovery_path} = recover(%{c | path: c.root <> "/missing/control.json"})
    refute File.exists?(c.root <> "/missing")
    assert {:error, :control_state_inside_workspace} = recover(%{c | workspace: c.root})
    link = c.root <> "/alias.json"
    File.ln_s!(c.path, link)
    assert {:error, :invalid_recovery_path} = recover(%{c | path: link})

    for data <- ["{", Jason.encode!(%{}), Jason.encode!(put_in(c.data, ["tracker_issues", "11", "id"], "6"))] do
      File.write!(c.path, data)
      assert {:error, :invalid_control_state} = recover(c)
      assert File.read!(c.path) == data
    end

    File.write!(c.path, String.duplicate(" ", 10_000_001))
    assert {:error, :unreadable_control_state} = recover(c)
  end

  test "backup errors block persistence and never overwrite evidence", c do
    File.write!(c.backup, "existing evidence")
    assert {:error, :eexist} = recover(c, apply: true, backup_path: c.backup)
    assert File.read!(c.backup) == "existing evidence"
    assert File.read!(c.path) == c.bytes
    assert {:error, :control_state_inside_workspace} = recover(c, apply: true, backup_path: c.workspace <> "/backup.json")
    assert File.read!(c.path) == c.bytes
    File.rm!(c.backup)
    File.ln_s!(c.path, c.backup)
    assert {:error, :control_path_symlink} = recover(c, apply: true, backup_path: c.backup)
    assert File.read!(c.path) == c.bytes
  end

  test "invalid or unbounded requests fail before touching state", c do
    for request <- [
          %{c.request | issue_ids: []},
          %{c.request | issue_ids: nil},
          %{c.request | issue_ids: ["6", "6"]},
          %{c.request | issue_ids: Enum.map(1..21, &to_string/1)},
          %{c.request | issue_ids: ["0"]},
          %{c.request | issue_ids: [6]},
          %{c.request | project_id: nil},
          %{c.request | project_id: "linear:repo"},
          %{c.request | tracker_fingerprint: ""},
          %{c.request | expected_revision: -1}
        ] do
      assert {:error, :invalid_acceptance_recovery} = recover(%{c | request: request})
    end

    assert {:error, :invalid_acceptance_recovery} = recover(c, apply: true)
    assert {:error, :invalid_acceptance_recovery} = recover(c, apply: "yes")
    assert File.read!(c.path) == c.bytes
  end

  test "CLI parses explicit IDs, prints only IDs and requires valid options", c do
    output = capture_io(fn -> RecoverLegacy.run(args(c)) end)
    assert output =~ "Dry run: changed issue IDs [6, 11]"
    refute output =~ @legacy
    refute output =~ @project
    refute output =~ c.path
    assert File.read!(c.path) == c.bytes

    output = capture_io(fn -> RecoverLegacy.run(args(c) ++ ["--apply", "--backup", c.backup]) end)
    assert output =~ "Applied: changed issue IDs [6, 11]"
    assert capture_io(fn -> RecoverLegacy.run(["--help"]) end) =~ "Stop all project engines"

    for invalid <- [["--unexpected", @legacy], ["positional"], [], args(c) ++ ["--issue", "6"]] do
      error = assert_raise Mix.Error, fn -> RecoverLegacy.run(invalid) end
      refute Exception.message(error) =~ @legacy
      refute Exception.message(error) =~ @project
    end

    invalid_path_args = args(c) |> List.replace_at(3, c.path <> "/private-detail")
    error = assert_raise Mix.Error, fn -> RecoverLegacy.run(invalid_path_args) end
    assert Exception.message(error) =~ "state_io_failed"
    refute Exception.message(error) =~ c.path
    refute Exception.message(error) =~ "private-detail"
  end

  test "bare subprocess CLI ignores invalid live configuration and scrubs every inherited lock environment variable", c do
    binary_dir = c.root <> "/bin"
    File.mkdir_p!(binary_dir)
    real_python = System.find_executable("python3")
    report = c.root <> "/lock-environment.json"
    python = binary_dir <> "/python3"

    File.write!(python, """
    #!#{real_python}
    import json, os, sys
    with open(#{Jason.encode!(report)}, 'w') as output:
        json.dump(sorted(os.environ), output)
    os.execv(#{Jason.encode!(real_python)}, [#{Jason.encode!(real_python)}] + sys.argv[1:])
    """)

    File.chmod!(python, 0o700)
    source = Path.expand("../..", __DIR__)
    workflow = Path.join(source, "WORKFLOW.md")

    script = """
    SymphonyElixir.Workflow.set_workflow_file_path(#{inspect(workflow)})
    {:error, :missing_linear_api_token} = SymphonyElixir.Config.settings()
    Mix.Tasks.Acceptance.RecoverLegacy.run(System.argv())
    nil = Process.whereis(SymphonyElixir.Orchestrator)
    nil = Process.whereis(SymphonyElixir.WorkflowStore)
    """

    environment = [
      "-i",
      "PATH=#{binary_dir}:#{System.get_env("PATH")}",
      "HOME=#{System.user_home!()}",
      "MIX_HOME=#{System.get_env("MIX_HOME")}",
      "MIX_ENV=test",
      "TMPDIR=#{System.tmp_dir!()}",
      "ERL_FLAGS=+S 2:2",
      "PRIVATE_LOCK_TEST_TOKEN=must-not-reach-lock",
      "PYTHONPATH=#{c.root}/untrusted-modules"
    ]

    mix = System.find_executable("mix")
    {output, status} = System.cmd("env", environment ++ [mix, "run", "--no-start", "-e", script, "--" | args(c)], cd: source, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "Dry run: changed issue IDs [6, 11]"
    assert File.read!(c.path) == c.bytes
    refute File.exists?(c.backup)
    assert Jason.decode!(File.read!(report)) -- ["LC_CTYPE", "__CF_USER_TEXT_ENCODING"] == []
  end

  defp recover(c, opts \\ []), do: ControlLedger.recover_legacy_acceptance(c.path, c.workspace, c.request, opts)

  defp settings(c) do
    %{state_path: c.path, initial_mode: "paused", max_attempts: 2, max_total_runtime_ms: 100_000, max_total_tokens: 1_000}
  end

  defp args(c) do
    ["--state", c.path, "--workspace-root", c.workspace, "--project", @project, "--legacy-fingerprint", @legacy, "--revision", "105", "--issue", "6", "--issue", "11"]
  end

  defp legacy_issue(id) do
    sha = String.duplicate(if(id == "6", do: "a", else: "b"), 40)

    %{
      "attempts" => 2,
      "attempt_base" => 1,
      "runtime_ms" => 1_000,
      "tokens" => 800,
      "hold" => "accepted",
      "active" => nil,
      "handoff" => %{"candidate_sha" => sha, "review" => %{"candidate_sha" => sha}},
      "acceptance" => %{
        "command_id" => "original-#{id}",
        "tracker_fingerprint" => @legacy,
        "candidate_sha" => sha,
        "tracker_state" => "open",
        "issue_updated_at" => @updated,
        "accepted_at" => "2026-09-23T18:49:54Z"
      }
    }
  end

  defp observation(id), do: %{"id" => id, "repository" => "iliazlobin/events-concierge", "tracker_fingerprint" => "current", "state" => "open", "updated_at" => @updated, "dispatchable" => false}
end
