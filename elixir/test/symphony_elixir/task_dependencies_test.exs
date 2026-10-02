defmodule SymphonyElixir.TaskDependenciesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{IssueAcceptance, TaskDependencies, TaskIdentity, TaskRouting}
  alias SymphonyElixir.Tracker.Issue

  @sha String.duplicate("a", 40)
  @tracker %{
    kind: "github",
    provider: %{"repo" => "example/tasks", "token" => "fixture"},
    project_slug: nil,
    required_labels: [],
    active_states: ["open"],
    terminal_states: ["closed"]
  }

  test "typed explicit prerequisites retain reasons and compatibility without deriving anything from priority" do
    assert {:ok, records} = TaskDependencies.parse("Title\r\nDepends on: #2 (design: reviewed contract), #3 (technical), #4 (process), #5\r\nEnd", "1")
    assert Enum.map(records, & &1["kind"]) == ~w(design technical process delivery)
    assert hd(records)["reason"] == "reviewed contract"
    assert TaskDependencies.valid_records?(records)
    assert Enum.all?(records, & &1["blocking"])
    assert {:ok, []} = TaskDependencies.parse("Depends on: none", "1")
    assert {:ok, []} = TaskDependencies.parse("Depends on: none")

    for text <- [
          nil,
          "No dependencies",
          " Depends on: none",
          "Depends on: none ",
          "Depends on: #02",
          "Depends on: #1",
          "Depends on: #2, #2 (design)",
          "Depends on: #2 (priority)",
          "Depends on: #2 (technical: a, b)",
          "Depends on: none\nDepends on: #2",
          "Depends on: " <> Enum.map_join(2..22, ", ", &("#" <> to_string(&1)))
        ] do
      assert {:error, _} = TaskDependencies.parse(text, "1")
    end

    refute TaskDependencies.valid_records?(false)
    refute TaskDependencies.valid_records?([%{}])
    refute TaskDependencies.valid_records?([false])
    refute TaskDependencies.valid_records?([hd(records), hd(records)])
    refute TaskDependencies.valid_records?([Map.put(hd(records), "blocking", false)])
  end

  test "only current project human acceptance satisfies a prerequisite, including an open tracker issue" do
    candidate = issue("1", "Depends on: #2 (technical: required schema)")
    closed = issue("2", "Depends on: none", "closed")
    assert [held, independent] = TaskDependencies.evaluate([candidate, closed], %{}, @tracker)
    refute held.dispatchable
    assert independent.dispatchable
    assert [%{id: "2", state: "awaiting_acceptance", kind: "technical"}] = held.blocked_by

    control = %{"issues" => %{"2" => accepted()}, "tracker_issues" => %{}}
    assert TaskDependencies.gate(candidate, control, @tracker).dispatchable
    changed_credentials = put_in(@tracker, [:provider, "token"], "rotated")
    assert TaskDependencies.gate(candidate, control, changed_credentials).dispatchable
    foreign = put_in(@tracker, [:provider, "repo"], "example/other")
    refute TaskDependencies.gate(candidate, control, foreign).dispatchable
    refute TaskDependencies.gate(candidate, put_in(control, ["issues", "2", "active"], %{"run_id" => "unknown"}), @tracker).dispatchable
    refute TaskDependencies.gate(candidate, put_in(control, ["issues", "2", "handoff", "candidate_sha"], String.duplicate("b", 40)), @tracker).dispatchable
    refute TaskDependencies.gate(%{candidate | dispatchable: false}, control, @tracker).dispatchable
    refute TaskDependencies.gate(%{candidate | native_ref: %{"repo" => "other/repo"}}, control, @tracker).dispatchable
  end

  test "missing and cyclic prerequisites remain blocked from the same bounded local owner snapshot" do
    a = issue("1", "Depends on: #2 (design)")
    b = issue("2", "Depends on: #3 (technical)")
    c = issue("3", "Depends on: #1 (process)")
    observations = Map.new([b, c], &{&1.id, TaskRouting.observation(&1, @tracker)})
    control = %{"tracker_issues" => observations, "issues" => %{"2" => accepted(), "3" => accepted()}}
    result = TaskDependencies.gate(a, control, @tracker)
    refute result.dispatchable
    assert result.native_ref["admission_reason"] =~ "cycle"
    assert TaskDependencies.cycle_nodes(TaskDependencies.records(control, [a], @tracker)) == MapSet.new(~w(1 2 3))
    assert TaskDependencies.cycle_nodes(%{"1" => %{"dependencies" => [%{"issue_id" => "1"}]}}) == MapSet.new(["1"])

    foreign = put_in(control, ["tracker_issues", "2", "repository"], "example/other")
    refute Map.has_key?(TaskDependencies.records(foreign, [a], @tracker), "2")
    assert TaskDependencies.gate(issue("5", "Depends on: #99"), control, @tracker).blocked_by != []
    invalid = TaskDependencies.gate(issue("6", "No declaration"), control, @tracker)
    refute invalid.dispatchable
    assert invalid.native_ref["admission_reason"] =~ "Depends on:"
    assert [%Issue{dispatchable: false}] = TaskDependencies.prepare([issue("6", "No declaration")])
    assert TaskDependencies.records(control, [issue("2", "No declaration")], @tracker) |> Map.has_key?("2") == false
    assert TaskDependencies.prepare([a]) |> hd() |> Map.fetch!(:dependencies) != []
    disabled = %{a | dispatchable: false}
    assert TaskDependencies.prepare([disabled]) == [disabled]
  end

  test "stable identity excludes credentials and operational labels" do
    assert TaskIdentity.project_id(@tracker) == "github:example/tasks"
    assert TaskIdentity.project_id(%{kind: "linear", provider: %{}, project_slug: "board"}) == "linear:board"
    assert TaskIdentity.project_id(%{kind: nil, provider: nil, project_slug: nil}) == "tracker:configured-project"
    assert TaskIdentity.project_id(%{kind: "other", provider: %{"project_id" => "p"}, project_slug: nil}) == "other:p"
    assert TaskIdentity.project_id(%{kind: "other", provider: %{"project" => "p"}, project_slug: nil}) == "other:p"
  end

  defp accepted do
    verified = %{id: "2", state: "open", updated_at: "2026-10-01T10:00:00Z", terminal: true}

    params = %{
      "issue_id" => "2",
      "command_id" => "accept",
      "expected_revision" => 0,
      "expected_candidate_sha" => @sha,
      "expected_updated_at" => verified.updated_at,
      "expected_tracker_state" => verified.state
    }

    context = %{
      tracker_fingerprint: TaskRouting.fingerprint(@tracker),
      project_id: TaskIdentity.project_id(@tracker),
      acceptance_issue: verified
    }

    {:ok, item} = IssueAcceptance.accept(%{"handoff" => %{"candidate_sha" => @sha}}, params, context)
    item
  end

  defp issue(id, description, state \\ "open"),
    do: %Issue{
      id: id,
      identifier: "GH-" <> id,
      title: "Task " <> id,
      description: description,
      state: state,
      native_ref: %{"repo" => "example/tasks"},
      dispatchable: true,
      updated_at: ~U[2026-10-01 10:00:00Z]
    }
end
