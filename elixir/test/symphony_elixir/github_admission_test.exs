defmodule SymphonyElixir.GitHub.AdmissionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{Adapter, Admission}

  defmodule FakeClient do
    def fetch_issues_by_states(states) do
      send(self(), {:candidate_read, states})
      Process.get(:github_admission_candidates, {:ok, []})
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:id_read, ids})

      case Process.get(:github_admission_ids, %{}) do
        {:error, reason} -> {:error, reason}
        records -> {:ok, Enum.flat_map(ids, fn id -> if records[id], do: [records[id]], else: [] end)}
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, FakeClient)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :github_client_module, previous)
      else
        Application.delete_env(:symphony_elixir, :github_client_module)
      end
    end)

    :ok
  end

  test "declaration compatibility keeps legacy IDs and accepts typed reasons" do
    assert {:ok, []} = Admission.validate_declaration("Outcome\r\nDepends on: none\r\nAcceptance")
    assert {:ok, ["2", "3"]} = Admission.validate_declaration("Depends on: #2, #3 (technical: required schema)", "1")
    assert {:error, _} = Admission.validate_declaration("Depends on: #1", "1")
    assert {:error, _} = Admission.validate_declaration(nil)
  end

  test "controlled adapter validates declarations without remote dependency round trips" do
    write_controlled_workflow!(true)
    candidate = issue("1", "Depends on: #2 (design: approved baseline)")
    Process.put(:github_admission_candidates, {:ok, [candidate]})
    Process.put(:github_admission_ids, %{"1" => candidate})

    assert {:ok, [prepared]} = Adapter.fetch_issues_by_states(["open"])
    assert prepared.dispatchable
    assert [%{"issue_id" => "2", "kind" => "design", "reason" => "approved baseline"}] = prepared.dependencies
    refute_received {:id_read, _}

    assert {:ok, [^prepared]} = Adapter.fetch_issues_by_ids(["1"])
    assert_received {:id_read, ["1"]}
    refute_received {:id_read, _}

    Process.put(:github_admission_candidates, {:ok, [issue("1", "No declaration")]})
    assert {:ok, [invalid]} = Adapter.fetch_issues_by_states(["open"])
    refute invalid.dispatchable
    assert invalid.native_ref["admission_reason"] =~ "Depends on:"

    Process.put(:github_admission_ids, {:error, :timeout})
    assert {:error, :timeout} = Adapter.fetch_issues_by_ids(["1"])
  end

  test "disabled control preserves upstream dispatch and does not read dependencies" do
    write_controlled_workflow!(false)
    candidate = issue("1", nil)
    Process.put(:github_admission_candidates, {:ok, [candidate]})
    Process.put(:github_admission_ids, %{"1" => candidate})

    assert {:ok, [^candidate]} = Adapter.fetch_issues_by_states(["open"])
    refute_received {:id_read, _}
    assert {:ok, [^candidate]} = Adapter.fetch_issues_by_ids(["1"])
    assert_received {:id_read, ["1"]}
    refute_received {:id_read, _}
  end

  defp issue(id, description, state \\ "open") do
    %Issue{
      id: id,
      identifier: "GH-#{id}",
      title: "Task #{id}",
      description: description,
      state: state,
      native_ref: %{"repo" => "octo/repo"},
      dispatchable: true
    }
  end

  defp write_controlled_workflow!(enabled) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      provider:
        repo: octo/repo
        token: test-token
      active_states: [open]
      terminal_states: [closed]
    control:
      enabled: #{enabled}
      state_path: /tmp/symphony-github-admission-test-control.json
    ---
    Implement the scoped task.
    """)

    assert :ok = WorkflowStore.force_reload()
  end
end
