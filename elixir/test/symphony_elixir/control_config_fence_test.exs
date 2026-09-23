defmodule SymphonyElixir.ControlConfigFenceTest do
  use SymphonyElixir.TestSupport

  @base String.duplicate("b", 40)
  @head String.duplicate("a", 40)
  @updated ~U[2026-09-23 10:00:00Z]

  defmodule ReloadingGitHub do
    def fetch_issues_by_ids(_ids), do: Application.fetch_env!(:symphony_elixir, :control_fence_fetch).()
    def fetch_issues_by_states(_states), do: {:ok, []}
  end

  setup do
    {:ok, temporary} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(temporary, "symphony-control-fence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow = Path.join(root, "WORKFLOW.md")

    config = %{
      tracker: %{
        kind: "github",
        provider: %{repo: "owner/repo", token: "test-token"},
        active_states: ["open"],
        terminal_states: ["closed"],
        required_labels: []
      },
      workspace: %{root: root <> "/workspaces"},
      polling: %{interval_ms: 60_000},
      observability: %{dashboard_enabled: false},
      control: %{
        enabled: true,
        state_path: root <> "/control.json",
        initial_mode: "paused",
        base_sha: @base,
        max_attempts: 2,
        max_total_runtime_ms: 60_000,
        max_total_tokens: 100
      }
    }

    write_config(workflow, config)
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, ReloadingGitHub)
    task_supervisor = start_supervised!({Task.Supervisor, []})
    name = Module.concat(__MODULE__, "Owner#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: task_supervisor})

    issue = %Issue{
      id: "7",
      identifier: "GH-7",
      title: "Config fence",
      state: "open",
      description: "Depends on: none",
      dispatchable: true,
      updated_at: @updated,
      native_ref: %{"repo" => "owner/repo"}
    }

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :github_client_module)

      Application.delete_env(:symphony_elixir, :control_fence_fetch)
      File.rm_rf(root)
    end)

    %{pid: pid, config: config, workflow: workflow, issue: issue}
  end

  test "disabling controls during acceptance verification cannot persist acceptance", c do
    :sys.replace_state(c.pid, fn state ->
      issue = %{"attempts" => 1, "tokens" => 23, "runtime_ms" => 100, "active" => nil, "hold" => "owner_review", "handoff" => %{"candidate_sha" => @head}}
      %{state | control: %{state.control | data: put_in(state.control.data, ["issues", "7"], issue)}}
    end)

    reload_on_fetch(c, put_in(c.config, [:control, :enabled], false))

    command = %{
      "action" => "accept_task",
      "issue_id" => "7",
      "command_id" => "accept-after-disable",
      "expected_revision" => 0,
      "expected_candidate_sha" => @head,
      "expected_updated_at" => DateTime.to_iso8601(@updated),
      "expected_tracker_state" => "open"
    }

    assert_control_fenced(c, command)
    assert :sys.get_state(c.pid).control.data["issues"]["7"]["acceptance"] == nil
  end

  test "changing the ledger path during PR work verification cannot queue new work", c do
    reload_on_fetch(c, put_in(c.config, [:control, :state_path], c.config.control.state_path <> ".new"))

    command = %{
      "action" => "create_pr_work",
      "issue_id" => "7",
      "command_id" => "create-after-ledger-change",
      "expected_revision" => 0,
      "work_id" => String.duplicate("a", 32),
      "instruction" => "Apply the confirmed correction",
      "base_sha" => @base
    }

    assert_control_fenced(c, command)
    assert :sys.get_state(c.pid).control.data["issues"]["7"] == nil
    refute File.exists?(c.config.control.state_path <> ".new")
  end

  defp reload_on_fetch(c, changed) do
    Application.put_env(:symphony_elixir, :control_fence_fetch, fn ->
      write_config(c.workflow, changed)
      {:ok, [c.issue]}
    end)
  end

  defp assert_control_fenced(c, command) do
    before = File.read!(c.config.control.state_path)
    assert {:error, :control_unavailable} = Orchestrator.control_command(command, c.pid)
    state = :sys.get_state(c.pid)
    assert state.control_fault == ":control_configuration_changed_restart_required"
    assert state.control.data["revision"] == 0
    assert state.control.data["commands"] == %{}
    assert File.read!(c.config.control.state_path) == before
  end

  defp write_config(path, config) do
    File.write!(path, "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    Workflow.set_workflow_file_path(path)
    assert :ok = WorkflowStore.force_reload()
  end
end
