defmodule SymphonyElixir.DashboardLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.{Endpoint, Presenter, TaskBoard}
  @endpoint Endpoint

  # Explicit fixture server: real OTP calls and LiveView transport, no coding
  # workers, tracker network requests or production service state.
  defmodule FixtureRuntime do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: state.name)
    def init(state), do: {:ok, state}
    def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}
    def handle_call(:control_snapshot, _from, state), do: {:reply, state.control, state}
    def handle_call(:board, _from, state), do: {:reply, state.board, state}
    def handle_call({:board, board}, _from, state), do: {:reply, :ok, %{state | board: board}}
  end

  setup do
    config = %{
      tracker: %{
        kind: "github",
        provider: %{repo: "example/fixture", token: "fixture-token"},
        active_states: ["open"],
        terminal_states: ["closed"],
        required_labels: ["ready"]
      },
      control: %{enabled: true, state_path: Workflow.workflow_file_path() <> ".control.json"},
      observability: %{dashboard_enabled: false}
    }

    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nFixture only")
    assert :ok = WorkflowStore.force_reload()

    control = %{
      "enabled" => true,
      "mode" => "paused",
      "revision" => 0,
      "fault" => nil,
      "issues" => %{"4" => %{"hold" => "owner_review", "handoff" => %{"candidate_sha" => String.duplicate("a", 40), "review" => %{"verdict" => "request_changes"}}}}
    }

    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({FixtureRuntime, %{name: runtime, snapshot: snapshot(), control: control, board: nil}})
    board = TaskBoard.project(issues(), Presenter.state_payload(runtime, 100), control, Config.settings!())
    :ok = GenServer.call(runtime, {:board, board})
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])

    endpoint_config =
      Keyword.merge(previous_endpoint,
        server: false,
        secret_key_base: String.duplicate("d", 64),
        orchestrator: runtime,
        snapshot_timeout_ms: 100,
        board_loader: fn server, _timeout -> GenServer.call(server, :board) end
      )

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, previous_endpoint) end)
    %{runtime: runtime, board: board}
  end

  test "renders real projected tasks in all lanes with top filters and truthful evidence" do
    {view, html} = board_view()
    assert has_element?(view, "#lane-backlog [data-task-id='github:example/fixture:1']")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']")
    assert has_element?(view, "#lane-running [data-task-id='github:example/fixture:3']")
    assert has_element?(view, "#lane-review [data-task-id='github:example/fixture:4']")
    assert has_element?(view, "#lane-done [data-task-id='github:example/fixture:5']")
    assert has_element?(view, "#filter-project[role=combobox]")
    assert has_element?(view, "#filter-status[role=combobox]")
    assert has_element?(view, "#filter-priority[role=combobox]")
    assert has_element?(view, "select[aria-label='Sort cards']")
    assert html =~ "Manual order is a browser preference"
    assert html =~ "Candidate needs review"
    refute html =~ "Proposed UI"
    refute has_element?(view, "aside")
    refute has_element?(view, "#board-dialog")
  end

  test "settings and task details are native dialogs over the retained board" do
    {view, _html} = board_view()
    view |> element("#settings-button") |> render_click()
    assert has_element?(view, "dialog#board-dialog[phx-hook=BoardDialog] h2", "Settings")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']")
    assert has_element?(view, "#board-dialog input[type=password][name=operator_token]")
    view |> element("#close-dialog") |> render_click()
    refute has_element?(view, "#board-dialog")
    assert_patch(view, "/")

    open_task(view, "2")
    assert has_element?(view, "dialog#board-dialog h2", "Ready fixture")
    assert has_element?(view, "#board-dialog", "Acceptance for fixture 2")
    assert has_element?(view, "#lane-running [data-task-id='github:example/fixture:3']")
    render_click(view, "close-dialog")
    refute has_element?(view, "#board-dialog")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']")
  end

  test "selected task details refresh with the board and close when the task disappears", ctx do
    {view, _html} = board_view()
    open_task(view, "2")
    changed = update_task(ctx.board, "2", &%{&1 | title: "Fresh task title", description: "Updated acceptance", stage: "review", attention: "New candidate needs review"})
    refresh(view, ctx.runtime, changed)
    assert has_element?(view, "#board-dialog h2", "Fresh task title")
    assert has_element?(view, "#board-dialog", "Updated acceptance")
    assert has_element?(view, "#lane-review [data-task-id='github:example/fixture:2']")

    refresh(view, ctx.runtime, %{changed | tasks: Enum.reject(changed.tasks, &(&1.issue_id == "2"))})
    refute has_element?(view, "#board-dialog")
    assert render(view) =~ "Task no longer available"
  end

  test "source failures retain complete task metadata and the selected popup", ctx do
    {view, _html} = board_view()
    open_task(view, "2")
    incomplete = update_task(ctx.board, "2", &%{&1 | title: "Incomplete metadata", stage: "backlog"})
    incomplete = %{incomplete | source_error: "Tracker unavailable", generated_at: "2099-01-01T00:00:00Z"}
    refresh(view, ctx.runtime, incomplete)
    assert has_element?(view, "#board-dialog h2", "Ready fixture")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']")
    assert render(view) =~ "Tracker unavailable"
    refute render(view) =~ "Incomplete metadata"
    refute render(view) =~ "2099-01-01T00:00:00Z"
  end

  test "unknown task actions and cross-lane moves cannot fabricate completion" do
    {view, _html} = board_view()
    render_click(view, "open-task", %{"id" => "github:example/fixture:missing"})
    assert render(view) =~ "no longer in the current board"
    refute has_element?(view, "#board-dialog")
    render_click(view, "move-task", %{"id" => "github:example/fixture:missing", "stage" => "done"})
    assert render(view) =~ "Task unavailable"
    render_click(view, "move-task", %{"id" => "github:example/fixture:2", "stage" => "done"})
    assert has_element?(view, "#board-dialog h2", "Ready fixture")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']")
    refute has_element?(view, "#lane-done [data-task-id='github:example/fixture:2']")
    assert render(view) =~ "Stages follow confirmed work"
  end

  test "unauthorized commands route to Settings and confirmation does not mutate the board", ctx do
    {view, _html} = board_view()
    render_click(view, "prepare-command", %{"action" => "pause"})
    assert has_element?(view, "#board-dialog h2", "Settings")
    assert render(view) =~ "Unlock local operator controls"
    render_click(view, "confirm-command")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    render_click(view, "prepare-command", %{"action" => "deploy"})
    assert render(view) =~ "Unsupported action"
    render_click(view, "prepare-command", %{"action" => "cancel", "id" => "missing"})
    assert render(view) =~ "Unsupported action"
    render_click(view, "move-task", %{"id" => "github:example/fixture:2", "stage" => "backlog"})
    assert has_element?(view, "#board-dialog h2", "Settings")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']")
  end

  test "new task dialog links to canonical GitHub intake without faking an issue" do
    {view, _html} = board_view()
    view |> element("#new-task-button") |> render_click()
    assert has_element?(view, "#board-dialog h2", "New task")
    assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/issues/new']")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']")
    assert render(view) =~ "saving an issue alone does not start a worker"
  end

  test "tracker titles and descriptions remain text and unsafe links are not clickable", ctx do
    changed = update_task(ctx.board, "1", &%{&1 | title: "<script>window.bad=1</script>", description: "<img src=x onerror=alert(1)>", url: "javascript:alert(1)"})
    :ok = GenServer.call(ctx.runtime, {:board, changed})
    {view, _html} = board_view()
    open_task(view, "1")
    html = render(view)
    assert html =~ "&lt;script&gt;window.bad=1&lt;/script&gt;"
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute has_element?(view, "#board-dialog script")
    refute has_element?(view, "a[href^='javascript:']")
    refute has_element?(view, "#board-dialog img")
  end

  test "versioned board JavaScript is embedded and served through its route" do
    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ ~r|/dashboard\.js\?v=[0-9a-f]{12}|
    conn = get(build_conn(), "/dashboard.js")
    assert response(conn, 200) == File.read!("priv/static/dashboard.js")
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/javascript; charset=utf-8"]
    assert conn.resp_body =~ "BoardDialog"
    assert conn.resp_body =~ "TaskBoard"
  end

  defp board_view do
    {:ok, view, _html} = live(build_conn(), "/")
    {view, render_async(view)}
  end

  defp open_task(view, id), do: render_click(view, "open-task", %{"id" => "github:example/fixture:" <> id})

  defp refresh(view, runtime, board) do
    :ok = GenServer.call(runtime, {:board, board})
    render_click(view, "refresh")
    render_async(view)
  end

  defp update_task(board, id, update), do: %{board | tasks: Enum.map(board.tasks, fn task -> if task.issue_id == id, do: update.(task), else: task end)}

  defp issues do
    for {id, title, state, labels} <- [
          {"1", "Backlog fixture", "open", []},
          {"2", "Ready fixture", "open", ["ready"]},
          {"3", "Running fixture", "open", ["ready"]},
          {"4", "Review fixture", "open", ["ready"]},
          {"5", "Closed fixture", "closed", []}
        ] do
      %Issue{
        id: id,
        identifier: "GH-" <> id,
        title: title,
        state: state,
        labels: labels,
        description: "Acceptance for fixture #{id}\nDepends on: none",
        native_ref: %{"repo" => "example/fixture"},
        url: "https://github.com/example/fixture/issues/" <> id,
        dispatchable: true,
        priority: 2,
        created_at: ~U[2026-09-14 10:00:00Z],
        updated_at: ~U[2026-09-14 11:00:00Z]
      }
    end
  end

  defp snapshot do
    %{
      running: [
        %{
          issue_id: "3",
          identifier: "GH-3",
          issue_url: "https://github.com/example/fixture/issues/3",
          state: "open",
          session_id: "fixture-session",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: "Fixture worker progress",
          last_codex_timestamp: ~U[2026-09-14 11:00:00Z],
          started_at: ~U[2026-09-14 10:00:00Z],
          codex_input_tokens: 1,
          codex_output_tokens: 2,
          codex_total_tokens: 3
        }
      ],
      retrying: [],
      blocked: [],
      codex_totals: %{total_tokens: 3, seconds_running: 1},
      rate_limits: nil
    }
  end
end
