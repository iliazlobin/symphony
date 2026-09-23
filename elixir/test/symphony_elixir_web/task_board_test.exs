defmodule SymphonyElixirWeb.TaskBoardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.TaskBoard

  defmodule ReadOnlyRuntime do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])
    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      send(state[:owner], :runtime_read)
      snapshot = Keyword.get(state, :snapshot, %{running: [], retrying: [], blocked: [], codex_totals: %{}, rate_limits: nil})
      {:reply, snapshot, state}
    end

    def handle_call(:control_snapshot, _from, state) do
      send(state[:owner], :control_read)
      {:reply, state[:control] || %{"enabled" => true, "issues" => %{}}, state}
    end
  end

  defmodule ReadOnlyGitHub do
    def fetch_issues_by_states(states) do
      {owner, result} = Application.fetch_env!(:symphony_elixir, :task_board_test_source)
      send(owner, {:tracker_read, states, self()})

      case result do
        :wait -> receive do: (:finish -> {:ok, []})
        :raise -> raise "private credentials must not be rendered"
        :throw -> throw(:source_failed)
        {:perform, fun} -> fun.()
        other -> other
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    previous_enrichment = Application.get_env(:symphony_elixir, :github_board_request)
    Application.put_env(:symphony_elixir, :github_client_module, ReadOnlyGitHub)
    Application.put_env(:symphony_elixir, :github_board_request, fn _, _, _, _, _ -> {:error, :unavailable} end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :github_client_module)

      Application.delete_env(:symphony_elixir, :task_board_test_source)

      if previous_enrichment,
        do: Application.put_env(:symphony_elixir, :github_board_request, previous_enrichment),
        else: Application.delete_env(:symphony_elixir, :github_board_request)
    end)

    :ok
  end

  test "board retains issue filter metadata and defaults for missing tracker rows" do
    milestone = %{id: "3", title: "Release one", state: "open", url: "https://github.com/example/repo/milestone/3"}
    assigned = issue("1", milestone: milestone, assignee_id: "octocat", assignees: ["octocat", "reviewer"])
    control = %{"issues" => %{"3" => %{"hold" => "cancelled"}}}
    board = TaskBoard.project([assigned, issue("2")], %{}, control, settings())

    assert task(board.tasks, "1").milestone == milestone
    assert task(board.tasks, "1").assignees == ["octocat", "reviewer"]
    assert task(board.tasks, "1").stage == "ready"

    for id <- ["2", "3"] do
      assert task(board.tasks, id).milestone == nil
      assert task(board.tasks, id).assignees == []
    end

    assert task(board.tasks, "3").source_missing
  end

  test "raw GitHub backlog remains visible, dependencies gate Ready, and PRs are excluded" do
    backlog = issue("1", labels: [], description: nil)
    ready = issue("2")
    waiting = issue("3", description: "Depends on: #1")
    invalid = issue("4", description: "Do the work")
    pr = issue("5", dispatchable: false)
    tasks = TaskBoard.project([backlog, ready, waiting, invalid, pr, ready], %{}, %{}, settings()).tasks

    assert Enum.map(tasks, & &1.issue_id) == ["1", "2", "3", "4"]
    assert task(tasks, "1").stage == "backlog"
    assert task(tasks, "1").attention == nil
    assert task(tasks, "2").stage == "ready"
    assert task(tasks, "3").stage == "ready"
    assert task(tasks, "3").lane == "work"
    assert task(tasks, "3").attention =~ "Dependencies must be visible"
    assert task(tasks, "4").attention =~ "Depends on:"

    tasks = TaskBoard.project([%{backlog | state: "closed"}, waiting], %{}, %{}, settings()).tasks
    assert task(tasks, "3").stage == "ready"
  end

  test "running wins over retry and closure; a review verdict never fabricates completion" do
    runtime = %{running: [activity("1")], retrying: [activity("1"), activity("2")], blocked: [activity("3")]}
    handoff = %{"candidate_sha" => String.duplicate("a", 40), "review" => %{"verdict" => "request_changes"}}
    control = %{"issues" => %{"4" => %{"hold" => "owner_review", "handoff" => handoff}}}
    issues = [issue("1", state: "closed"), issue("2"), issue("3"), issue("4")]
    tasks = TaskBoard.project(issues, runtime, control, settings()).tasks

    assert task(tasks, "1").stage == "running"
    assert task(tasks, "1").runtime.status == "running"
    assert task(tasks, "2").stage == "ready"
    assert task(tasks, "2").attention == "Retry scheduled"
    assert task(tasks, "3").attention == "Worker needs input"
    assert task(tasks, "4").stage == "review"
    assert task(tasks, "4").handoff == handoff
    assert task(tasks, "4").completion_evidence == nil
  end

  test "durable holds and orphan execution records survive missing tracker rows" do
    control = %{
      "issues" => %{
        "1" => %{"hold" => "cancelled"},
        "2" => %{"hold" => "interrupted"},
        "3" => %{"hold" => "token_budget"},
        "4" => %{"hold" => "owner_review", "handoff" => %{}},
        "5" => %{"hold" => "owner_review"}
      }
    }

    board = TaskBoard.project([issue("1"), issue("2")], %{running: [activity("6")]}, control, settings())
    assert length(board.tasks) == 6
    assert task(board.tasks, "1").stage == "backlog"
    assert task(board.tasks, "1").attention == "Cancelled execution"
    assert task(board.tasks, "2").attention == "Interrupted execution"
    assert task(board.tasks, "3").attention == "Token budget"
    assert task(board.tasks, "4").stage == "review"
    assert task(board.tasks, "4").source_missing
    assert task(board.tasks, "5").stage == "backlog"
    assert task(board.tasks, "6").stage == "running"
    assert task(board.tasks, "6").url == "https://github.com/example/repo/issues/6"
    refute task(board.tasks, "1").source_missing
    assert Enum.all?(board.tasks, &(&1.stage != "done"))
  end

  test "terminal tracker state awaits native human acceptance in controlled mode" do
    date = ~U[2026-09-14 10:00:00Z]
    closed = issue("1", state: "closed", created_at: date, updated_at: date, priority: 2)
    board = TaskBoard.project([closed], %{}, %{}, settings())
    [card] = board.tasks
    assert card.stage == "review"
    assert card.lane == "review"
    assert card.attention == "Awaiting your acceptance"
    assert card.completion_evidence =~ "your acceptance is still required"
    assert card.created_at == "2026-09-14T10:00:00Z"
    assert card.updated_at == card.created_at
    assert card.priority == 2
    assert card.id == "github:example/repo:1"
    assert board.projects == [%{id: "github:example/repo", label: "example/repo", url: "https://github.com/example/repo"}]

    uncontrolled = put_in(settings(), [:control, :enabled], false)
    [running] = TaskBoard.project([closed], %{running: [activity("1")]}, %{}, uncontrolled).tasks
    assert running.stage == "running"
    [card] = TaskBoard.project([closed], %{}, %{}, uncontrolled).tasks
    assert card.stage == "done"
    assert card.completion_evidence =~ "Tracker marked this issue closed"
  end

  test "only explicit scoped acceptance completes a controlled task" do
    tracker = settings().tracker
    fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(tracker)) |> Base.url_encode64(padding: false)

    acceptance = %{
      "command_id" => "accept-1",
      "tracker_fingerprint" => fingerprint,
      "candidate_sha" => nil,
      "tracker_state" => "closed",
      "issue_updated_at" => "2026-09-14T10:00:00Z",
      "accepted_at" => "2026-09-14T11:00:00Z"
    }

    ledger = %{"hold" => "accepted", "acceptance" => acceptance}
    [card] = TaskBoard.project([issue("1", state: "closed")], %{}, %{"issues" => %{"1" => ledger}}, settings()).tasks
    assert card.stage == "done"
    assert card.lane == "done"
    assert card.attention == nil
    assert card.acceptance == acceptance

    remote_settings = put_in(settings(), [:control, :enabled], false)
    remote_control = %{"enabled" => true, "tracker_fingerprint" => fingerprint, "issues" => %{"1" => ledger}}
    [remote_card] = TaskBoard.project([issue("1", state: "closed")], %{}, remote_control, remote_settings).tasks
    assert remote_card.stage == "done"
    assert remote_card.acceptance == acceptance
    remote_board = TaskBoard.project([issue("1", state: "closed")], %{}, %{remote_control | "issues" => %{}}, remote_settings)
    [remote_review] = remote_board.tasks
    assert remote_review.stage == "review"
    assert card.completion_evidence =~ "Accepted by you"

    foreign = put_in(ledger, ["acceptance", "tracker_fingerprint"], "other-project")
    [card] = TaskBoard.project([issue("1", state: "closed")], %{}, %{"issues" => %{"1" => foreign}}, settings()).tasks
    assert card.stage == "review"
    assert card.acceptance == nil

    [card] = TaskBoard.project([issue("1")], %{running: [activity("1")]}, %{}, settings()).tasks
    assert card.stage == "running"
    assert card.lane == "work"
  end

  test "a durable reservation without a running worker is explicitly uncertain" do
    control = %{"issues" => %{"1" => %{"active" => %{"run_id" => "reserved"}}}}
    board = TaskBoard.project([issue("1")], %{}, control, settings())
    assert task(board.tasks, "1").attention == "Execution reservation needs reconciliation"
    refute task(board.tasks, "1").stage == "running"

    board = TaskBoard.project([issue("1")], %{running: [activity("1")]}, control, settings())
    assert task(board.tasks, "1").attention == nil
    assert task(board.tasks, "1").stage == "running"
  end

  test "uncontrolled and non-GitHub projections preserve tracker routing without GitHub admission" do
    settings = put_in(settings(), [:control, :enabled], false)
    assert [card] = TaskBoard.project([issue("1", description: nil)], %{}, %{}, settings).tasks
    assert card.stage == "ready"

    settings = %{settings | tracker: %{settings.tracker | kind: "memory", provider: %{}, project_slug: "team"}}
    board = TaskBoard.project([issue("1", dispatchable: false)], %{blocked: [activity("2")]}, %{}, settings)
    assert task(board.tasks, "1").stage == "backlog"
    assert board.projects == [%{id: "memory:team", label: "team", url: nil}]
    assert task(board.tasks, "2").source_missing
  end

  test "load fetches all GitHub states and durable holds with no mutation calls" do
    configure_workflow()
    name = start_runtime(%{"enabled" => true, "issues" => %{"7" => %{"hold" => "interrupted"}}})
    Application.put_env(:symphony_elixir, :task_board_test_source, {self(), {:ok, [issue("1", labels: [])]}})
    board = TaskBoard.load(name, 500)

    assert_receive {:tracker_read, ["open", "closed"], _pid}
    assert_receive :runtime_read
    assert_receive :control_read
    assert board.source_error == nil
    assert board.runtime_error == nil
    assert task(board.tasks, "1").stage == "backlog"
    assert task(board.tasks, "7").hold == "interrupted"
  end

  test "non-GitHub ledger-only issues keep their native identity without fabricated provider links" do
    settings = put_in(settings(), [:tracker], %{settings().tracker | kind: "memory", provider: %{}, project_slug: "team"})
    control = %{"issues" => %{"task-7" => %{"hold" => "interrupted"}}}
    board = TaskBoard.project([], %{}, control, settings)

    assert [card] = board.tasks
    assert card.id == "memory:team:task-7"
    assert card.identifier == "task-7"
    assert card.title == "task-7"
    assert card.source_missing
    assert card.url == nil
    assert card.stage == "backlog"
    assert card.attention == "Interrupted execution"
    assert card.completion_evidence == nil
  end

  test "missing startup configuration yields an explicit unavailable board without attempting reads" do
    configure_workflow()
    name = start_runtime()
    existing_path = Workflow.workflow_file_path()
    store_was_running = is_pid(Process.whereis(WorkflowStore))
    if store_was_running, do: Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    try do
      Workflow.set_workflow_file_path(Path.join(Path.dirname(existing_path), "MISSING_WORKFLOW.md"))
      assert {:error, _reason} = Config.settings()

      for board <- [TaskBoard.load(name, 100), TaskBoard.from_runtime(%{running: [activity("1")]})] do
        assert board.source_error == "Workflow configuration unavailable."
        assert board.tasks == []
        assert board.projects == []
        assert board.runtime == %{}
        assert board.control == %{}
        assert board.runtime_error == nil
      end

      refute_received {:tracker_read, _, _}
      refute_received :runtime_read
      refute_received :control_read
    after
      Workflow.set_workflow_file_path(existing_path)
      if store_was_running, do: Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    end
  end

  test "tracker failure and malformed results report incomplete data without leaking errors" do
    configure_workflow()
    name = start_runtime()

    for result <- [{:error, :rate_limited}, {:ok, [:malformed]}, :raise, :throw] do
      Application.put_env(:symphony_elixir, :task_board_test_source, {self(), result})
      board = TaskBoard.load(name, 500)
      assert is_binary(board.source_error)
      refute board.source_error =~ "credentials"
      assert board.tasks == []
      assert board.runtime_error == nil
    end
  end

  test "a durable control fault retains its evidence but cannot render as healthy execution" do
    configure_workflow()

    control = %{
      "enabled" => true,
      "revision" => 7,
      "mode" => "running",
      "fault" => "private control failure containing credentials",
      "issues" => %{"7" => %{"hold" => "interrupted"}}
    }

    name = start_runtime(control)
    Application.put_env(:symphony_elixir, :task_board_test_source, {self(), {:ok, [issue("7")]}})
    board = TaskBoard.load(name, 500)
    assert board.control == control
    assert board.source_error == nil
    assert board.runtime_error == "Execution unavailable. Durable controls require recovery."
    refute board.runtime_error =~ control["fault"]
    assert task(board.tasks, "7").hold == "interrupted"
  end

  test "control error maps and failed replies stay explicit without exposing private details" do
    configure_workflow()
    name = start_runtime()
    Application.put_env(:symphony_elixir, :task_board_test_source, {self(), {:ok, []}})
    sensitive = "private control failure containing credentials"

    for result <- [%{"error" => sensitive}, %{error: sensitive}, {:error, sensitive}, :unavailable] do
      :sys.replace_state(name, &Keyword.put(&1, :control, result))
      board = TaskBoard.load(name, 500)
      assert board.source_error == nil
      assert board.runtime_error == "Durable controls unavailable. Task holds may be stale."
      refute board.runtime_error =~ sensitive
      assert board.control == if(is_map(result), do: result, else: %{"error" => "unavailable"})
    end
  end

  test "tracker timeout kills its read and leaves runtime and durable state observable" do
    configure_workflow()
    name = start_runtime()
    Application.put_env(:symphony_elixir, :task_board_test_source, {self(), :wait})
    board = TaskBoard.load(name, 100)

    assert_receive {:tracker_read, ["open", "closed"], reader}
    refute Process.alive?(reader)
    assert board.source_error =~ "Tracker unavailable"
    assert board.runtime_error == nil
    assert board.control["enabled"]
  end

  test "repository mismatch and tracker reload reject mixed-project results" do
    configure_workflow()
    name = start_runtime()
    foreign_issue = issue("1", native_ref: %{"repo" => "other/repo"})
    Application.put_env(:symphony_elixir, :task_board_test_source, {self(), {:ok, [foreign_issue]}})
    board = TaskBoard.load(name, 500)
    assert board.source_error == "Tracker returned invalid issue data."
    assert board.tasks == []

    reload = fn ->
      configure_workflow(false, "memory")
      {:ok, [issue("1")]}
    end

    Application.put_env(:symphony_elixir, :task_board_test_source, {self(), {:perform, reload}})
    board = TaskBoard.load(name, 500)
    assert board.source_error =~ "Tracker configuration changed"
    assert board.tasks == []
  end

  test "runtime failure is explicit and cannot be mistaken for a complete idle board" do
    configure_workflow()
    Application.put_env(:symphony_elixir, :task_board_test_source, {self(), {:ok, [issue("1")]}})
    board = TaskBoard.load(:task_board_missing_runtime, 100)
    assert board.source_error == nil
    assert board.runtime_error =~ "Runtime unavailable"
    assert board.runtime.error.code == "snapshot_unavailable"
    assert board.control == %{"error" => "unavailable"}
  end

  test "malformed runtime snapshots preserve tracker metadata and durable holds with unknown activity" do
    configure_workflow()
    control = %{"enabled" => true, "issues" => %{"1" => %{"hold" => "interrupted"}}}
    name = start_runtime(control)
    Application.put_env(:symphony_elixir, :task_board_test_source, {self(), {:ok, [issue("1", title: "Retained tracker title")]}})

    for snapshot <- [%{private: "credentials must not be rendered"}, :malformed] do
      :sys.replace_state(name, &Keyword.put(&1, :snapshot, snapshot))
      board = TaskBoard.load(name, 500)

      assert board.source_error == nil
      assert board.runtime_error == "Runtime unavailable. Task activity may be stale."
      assert board.runtime == %{}
      assert board.control == control
      assert [card] = board.tasks
      assert card.title == "Retained tracker title"
      assert card.hold == "interrupted"
      assert card.runtime == nil
      refute card.stage == "running"
    end
  end

  test "disabled controls use upstream read-only mode without querying the control ledger" do
    configure_workflow(false, "memory")
    name = start_runtime()
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("1"), issue("2", state: "closed")])
    board = TaskBoard.load(name, 500)
    assert length(board.tasks) == 2
    assert board.control == %{"enabled" => false}
    assert board.source_error == nil
    assert_receive :runtime_read
    refute_receive :control_read
  end

  test "initial runtime projection explicitly reports tracker metadata as loading" do
    configure_workflow()
    board = TaskBoard.from_runtime(%{running: [activity("1")]})
    assert board.source_error == "Tracker issues are loading."
    assert [card] = board.tasks
    assert card.source_missing
    assert card.stage == "running"
  end

  test "execution and blocker evidence retain actual reason and safe canonical links" do
    runtime = %{blocked: [Map.put(activity("1"), :error, "Worker needs input: choose the deployment region")], retrying: [Map.put(activity("2"), :error, "Rate limit; retry at the recorded deadline")]}
    control = %{"issues" => %{"3" => %{"hold" => "token_budget"}, "4" => %{"active" => %{}}}}
    issues = [issue("1", url: "https://evil.example/steal"), issue("2"), issue("3"), issue("4"), issue("5")]
    board = TaskBoard.project(issues, runtime, control, settings())
    assert task(board.tasks, "1").blocker_reason =~ "choose the deployment region"
    assert task(board.tasks, "1").execution_status == "blocked"
    assert task(board.tasks, "2").blocker_reason =~ "Rate limit"
    assert task(board.tasks, "3").blocker_reason == "Token budget"
    assert task(board.tasks, "3").execution_status == "held"
    assert task(board.tasks, "4").execution_status == "unknown"
    assert task(board.tasks, "5").execution_status == "idle"
    assert task(board.tasks, "1").url == "https://github.com/example/repo/issues/1"

    assert task(board.tasks, "1").links == [
             %{kind: "issue", label: "GitHub issue", url: "https://github.com/example/repo/issues/1"},
             %{kind: "repository", label: "Repository", url: "https://github.com/example/repo"}
           ]

    assert Enum.all?(board.tasks, &(&1.pull_requests == []))
  end

  test "enrichment failure and tracker reload preserve issue data with separate uncertainty" do
    configure_workflow()
    name = start_runtime()
    Application.put_env(:symphony_elixir, :task_board_test_source, {self(), {:ok, [issue("1")]}})
    board = TaskBoard.load(name, 500)
    assert board.source_error == nil
    assert board.enrichment_error =~ "PR evidence unavailable"
    assert [card] = board.tasks
    assert card.github_status == "unavailable"

    Application.put_env(:symphony_elixir, :github_board_request, fn _, _, _, _, _ ->
      configure_workflow(false, "memory")
      {:error, :unavailable}
    end)

    assert TaskBoard.load(name, 500).source_error =~ "configuration changed"
  end

  test "unsafe provider URLs and unknown issue identifiers cannot become clickable GitHub paths" do
    settings = settings()
    enterprise = put_in(settings, [:tracker, :provider, "api_url"], "https://enterprise.example/api")
    assert [card] = TaskBoard.project([issue("1")], %{}, %{}, enterprise).tasks
    assert card.links == []
    assert [card] = TaskBoard.project([issue("../other")], %{}, %{}, settings).tasks
    assert card.url == nil
    memory = put_in(settings, [:tracker, :kind], "memory")

    for url <- ["javascript:alert(1)", "https://user:secret@host/path", nil] do
      assert [card] = TaskBoard.project([issue("1", url: url)], %{}, %{}, memory).tasks
      assert card.url == nil
    end
  end

  defp task(tasks, id), do: Enum.find(tasks, &(&1.issue_id == id))

  defp issue(id, attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: id,
          identifier: "GH-#{id}",
          title: "Issue #{id}",
          state: "open",
          description: "Depends on: none",
          labels: ["ready"],
          dispatchable: true,
          native_ref: %{"repo" => "example/repo"},
          url: "https://github.com/example/repo/issues/#{id}"
        ],
        attrs
      )
    )
  end

  defp activity(id), do: %{issue_id: id, issue_identifier: "GH-#{id}", issue_url: "https://github.com/example/repo/issues/#{id}"}

  defp settings do
    %{
      tracker: %{
        kind: "github",
        provider: %{"repo" => "example/repo"},
        project_slug: nil,
        active_states: ["open"],
        terminal_states: ["closed"],
        required_labels: ["ready"]
      },
      control: %{enabled: true}
    }
  end

  defp configure_workflow(control_enabled \\ true, kind \\ "github") do
    config = %{
      tracker: %{
        kind: kind,
        provider: %{repo: "example/repo", token: "test-token"},
        active_states: ["open"],
        terminal_states: ["closed"],
        required_labels: ["ready"]
      },
      control: %{enabled: control_enabled, state_path: Workflow.workflow_file_path() <> ".control.json"},
      observability: %{dashboard_enabled: false}
    }

    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    assert :ok = WorkflowStore.force_reload()
  end

  defp start_runtime(control \\ nil) do
    name = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({ReadOnlyRuntime, name: name, owner: self(), control: control})
    name
  end
end
