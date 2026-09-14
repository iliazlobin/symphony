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

  test "explicit no-dependency declaration admits without tracker reads" do
    candidate = issue("1", "Outcome\r\nDepends on: none\r\nAcceptance")

    assert [%Issue{dispatchable: true, blocked_by: []}] =
             Admission.evaluate([candidate], fn _ -> flunk("no dependencies must not read GitHub") end)
  end

  test "missing, malformed, ambiguous, duplicate and self declarations fail closed" do
    invalid = [
      nil,
      "No dependencies",
      "Depends on: NONE",
      " Depends on: none",
      "Depends on: none ",
      "Depends on: #2,#3",
      "Depends on: #0",
      "Depends on: #02",
      "Depends on: octo/other#2",
      "Depends on: https://github.com/octo/other/issues/2",
      "Depends on: #1",
      "Depends on: #2, #2",
      "Depends on: none\nDepends on: #2",
      "Depends on: none\ndepends on: #2",
      "Depends on: " <> Enum.map_join(2..22, ", ", &"##{&1}")
    ]

    for description <- invalid do
      assert [held] = Admission.evaluate([issue("1", description)], fn _ -> flunk("invalid declaration must not read") end)
      refute held.dispatchable, inspect(description)
      assert is_binary(held.native_ref["admission_reason"])
    end
  end

  test "dependency reads are deduplicated and never traverse dependency descriptions" do
    candidates = [issue("1", "Depends on: #2, #3"), issue("4", "Depends on: #2")]

    [first, second] =
      Admission.evaluate(candidates, fn ids ->
        send(self(), {:dependency_read, ids})
        {:ok, [issue("2", "Depends on: #1", "closed"), issue("3", nil, "closed")]}
      end)

    assert first.dispatchable
    assert second.dispatchable
    assert_received {:dependency_read, ["2", "3"]}
    refute_received {:dependency_read, _}
  end

  test "open, missing, unknown-state, foreign-repository and pull-request dependencies hold" do
    candidate = issue("1", "Depends on: #2")

    invalid_dependencies = [
      [],
      [issue("2", nil, "open")],
      [issue("2", nil, "unknown")],
      [%{issue("2", nil, "closed") | native_ref: %{"repo" => "octo/other"}}],
      [%{issue("2", nil, "closed") | dispatchable: false}]
    ]

    for dependencies <- invalid_dependencies do
      assert [held] = Admission.evaluate([candidate], fn ["2"] -> {:ok, dependencies} end)
      refute held.dispatchable
      assert [%{id: "2"}] = held.blocked_by
      assert held.native_ref["admission_reason"] =~ "visible, closed issues"
    end
  end

  test "read errors and malformed payloads hold dependents without exposing error details" do
    candidates = [issue("1", "Depends on: #2"), issue("3", "Depends on: none")]

    for response <- [{:error, "secret upstream detail"}, {:ok, ["malformed"]}, :unexpected] do
      assert [held, independent] = Admission.evaluate(candidates, fn ["2"] -> response end)
      refute held.dispatchable
      assert held.native_ref["admission_reason"] =~ "tracker access recovers"
      refute held.native_ref["admission_reason"] =~ "secret"
      assert independent.dispatchable
    end
  end

  test "a non-dispatchable candidate cannot be promoted by a valid declaration" do
    candidate = %{issue("1", "Depends on: none") | dispatchable: false}
    assert [held] = Admission.evaluate([candidate], fn _ -> flunk("no read") end)
    refute held.dispatchable
  end

  test "candidate and ID refresh paths recheck dependencies, including reopen and read failure" do
    write_controlled_workflow!(true)
    candidate = issue("1", "Depends on: #2")
    Process.put(:github_admission_candidates, {:ok, [candidate]})
    Process.put(:github_admission_ids, %{"1" => candidate, "2" => issue("2", nil, "open")})

    assert {:ok, [held]} = Adapter.fetch_issues_by_states(["open"])
    refute held.dispatchable

    Process.put(:github_admission_ids, %{"1" => candidate, "2" => issue("2", nil, "closed")})
    assert {:ok, [admitted]} = Adapter.fetch_issues_by_ids(["1"])
    assert admitted.dispatchable

    Process.put(:github_admission_ids, %{"1" => candidate, "2" => issue("2", nil, "open")})
    assert {:ok, [held_again]} = Adapter.fetch_issues_by_ids(["1"])
    refute held_again.dispatchable

    Process.put(:github_admission_ids, {:error, :timeout})
    assert {:ok, [unavailable]} = Adapter.fetch_issues_by_states(["open"])
    refute unavailable.dispatchable
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
