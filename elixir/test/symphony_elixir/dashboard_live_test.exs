defmodule SymphonyElixir.DashboardLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.{BrowserAuth, Endpoint, Presenter, TaskBoard}
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

    def handle_call({:authorized_control_command, command, _tracker, authorize}, _from, state) do
      send(state.owner, {:settings_command, command})

      cond do
        not authorize.() ->
          {:reply, {:error, :unauthorized}, state}

        command["expected_revision"] != state.board.control["revision"] ->
          {:reply, {:error, :revision_conflict}, state}

        true ->
          settings = state.board.control["settings"]

          control =
            state.board.control
            |> Map.put("revision", state.board.control["revision"] + 1)
            |> put_in(["settings", "concurrency", "effective"], command["limit"] || settings["concurrency"]["default"])
            |> put_in(["settings", "concurrency", "override"], command["limit"])

          {:reply, {:ok, %{}}, %{state | board: %{state.board | control: control}, control: control}}
      end
    end
  end

  defmodule UnavailableChatApi do
    def health(_auth), do: {:error, :unavailable}
  end

  defmodule ThreadsChatApi do
    def projects(_auth), do: {:ok, [%{"id" => "github:example/fixture", "label" => "Fixture"}]}
    def list(_project, _auth), do: {:ok, []}
  end

  defmodule IntakeApi do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, %{owner: owner, records: %{}}}

    def list(project, _auth) do
      if Endpoint.config(:intake_fixture_error, false), do: {:error, :chat_storage_unavailable}, else: call({:list, project})
    end

    def get(project, id, _auth), do: call({:get, project, id})
    def prepare(project, id, args, _auth), do: call({:prepare, project, id, args})
    def decide(project, id, decision, _auth), do: call({:decide, project, id, decision})
    defp call(message), do: GenServer.call(Endpoint.config(:intake_fixture), message)

    def handle_call({:list, project}, _from, state), do: {:reply, {:ok, Enum.filter(Map.values(state.records), &(&1["project_id"] == project))}, state}

    def handle_call({:get, project, id}, _from, state) do
      result =
        case state.records[id] do
          %{"project_id" => ^project} = record -> {:ok, record}
          _ -> {:error, :not_found}
        end

      {:reply, result, state}
    end

    def handle_call({:prepare, project, id, args}, _from, state) do
      send(state.owner, {:intake_prepared, id, args})
      proposal = %{"id" => id, "action" => args["action"], "args" => Map.delete(args, "action"), "status" => "pending", "expected_updated_at" => nil}

      proposal =
        if args["action"] == "queue_task",
          do: Map.merge(proposal, %{"queue_labels" => ["ready"], "queue_unheld" => true, "task_title" => "Fresh queue task title", "task_description" => "Current scope and acceptance"}),
          else: proposal

      record = %{"id" => id, "project_id" => project, "kind" => "board_action", "title" => args["title"] || "Task", "proposals" => [proposal]}
      {:reply, {:ok, record}, put_in(state, [:records, id], record)}
    end

    def handle_call({:decide, _project, id, decision}, _from, state) do
      send(state.owner, {:intake_decided, id, decision})
      record = state.records[id]
      [proposal] = record["proposals"]

      status =
        cond do
          decision == "cancel" -> "cancelled"
          decision == "confirm" and proposal["args"]["title"] == "Uncertain task" -> "unknown"
          true -> "completed"
        end

      proposal =
        Map.merge(proposal, %{
          "status" => status,
          "receipt" => %{
            "widgets" => [
              %{
                "type" => "receipt",
                "summary" => "Created in Backlog without queue labels.",
                "url" => "/?project=github%3Aexample%2Ffixture&task=github%3Aexample%2Ffixture%3A99",
                "task_id" => "github:example/fixture:99"
              }
            ]
          }
        })

      record = Map.put(record, "proposals", [proposal])
      {:reply, {:ok, record}, put_in(state, [:records, id], record)}
    end
  end

  setup context do
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

    config =
      if context[:project_directory] do
        Map.put(config, :server, %{
          session_cookie: "_symphony_fixture_project",
          project_links: [
            %{id: "github:example/fixture", label: "Current project", url: "http://localhost:8778/"},
            %{id: "github:iliazlobin/symphony", label: "Symphony", url: "http://localhost:8779/"}
          ]
        })
      else
        config
      end

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
    fixture = %{name: runtime, snapshot: snapshot(), control: control, board: nil, owner: self()}
    start_supervised!({FixtureRuntime, fixture})
    board = TaskBoard.project(issues(), Presenter.state_payload(runtime, 100), control, Config.settings!())
    :ok = GenServer.call(runtime, {:board, board})
    intake = start_supervised!({IntakeApi, self()})
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])

    endpoint_config =
      Keyword.merge(previous_endpoint,
        server: false,
        secret_key_base: String.duplicate("d", 64),
        orchestrator: runtime,
        chat_store: if(context[:threads_fixture], do: ThreadsChatApi, else: UnavailableChatApi),
        task_intake: IntakeApi,
        intake_fixture: intake,
        snapshot_timeout_ms: 100,
        board_read_only: context[:read_only] || false,
        snapshot_loader: if(context[:snapshot_fixture], do: fn -> %{error: %{code: "fixture_snapshot_unavailable"}} end),
        board_loader: fn server, _timeout -> GenServer.call(server, :board) end
      )

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, previous_endpoint) end)
    %{runtime: runtime, board: board}
  end

  @tag :project_directory
  test "project navigation links independent boards without changing the selected task owner" do
    {view, _html} = board_view()
    assert has_element?(view, "#project-directory a[href='http://localhost:8778/'][aria-current=page]", "Current project")
    assert has_element?(view, "#project-directory a[href='http://localhost:8779/']", "Symphony")
    refute has_element?(view, "#project-directory a[href='http://localhost:8779/'][aria-current]")
    refute has_element?(view, "#project-directory a[data-phx-link]")
    assert has_element?(view, "#lane-ready [data-project='github:example/fixture']")
    refute has_element?(view, ".task-card[data-project='github:iliazlobin/symphony']")
    assert Endpoint.session_options()[:key] == "_symphony_fixture_project"
    conn = get(build_conn(), "/")
    assert Map.has_key?(conn.resp_cookies, "_symphony_fixture_project")
    refute Map.has_key?(conn.resp_cookies, "_symphony_elixir_key")
  end

  test "renders real projected tasks in all lanes with top filters and truthful evidence" do
    {view, html} = board_view()
    assert has_element?(view, "#lane-backlog [data-task-id='github:example/fixture:1']")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']")
    assert has_element?(view, "#lane-running [data-task-id='github:example/fixture:3']")
    assert has_element?(view, "#lane-review [data-task-id='github:example/fixture:4']")
    assert has_element?(view, "#lane-done [data-task-id='github:example/fixture:5']")
    assert has_element?(view, ".board-header .board-location #board-project-picker[phx-update=ignore] #filter-project[role=combobox]")
    refute has_element?(view, "#board-toolbar #filter-project")
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
    assert has_element?(view, "#task-board-app[data-selected-task='github:example/fixture:2']")
    assert has_element?(view, "#board-dialog", "Acceptance for fixture 2")
    assert has_element?(view, "#lane-running [data-task-id='github:example/fixture:3']")
    render_click(view, "close-dialog")
    refute has_element?(view, "#board-dialog")
    refute has_element?(view, "#task-board-app[data-selected-task]")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']")
  end

  @tag :threads_fixture
  test "closing the dock through URL or button releases project subscriptions and reopening restores them" do
    view = authorized_board_view()
    topic = "chat_project:github:example/fixture"
    subscribed = fn -> Enum.any?(Registry.lookup(SymphonyElixir.PubSub, topic), &(elem(&1, 0) == view.pid)) end
    render_click(view, "open-chat")
    assert has_element?(view, "#chat-thread-list:not([hidden])")
    assert subscribed.()
    render_patch(view, "/")
    refute has_element?(view, "#management-chat-dock")
    refute subscribed.()
    send(view.pid, {:chat_list_updated, "github:example/fixture"})
    refute has_element?(view, "#management-chat-dock")
    render_click(view, "open-chat")
    assert has_element?(view, "#chat-thread-list:not([hidden])")
    assert subscribed.()
    view |> element("button[aria-label='Close chat']") |> render_click()
    refute has_element?(view, "#management-chat-dock")
    refute subscribed.()
    send(view.pid, {:chat_panel, :project_subscription, "github:example/fixture"})
    refute has_element?(view, "#management-chat-dock")
    refute subscribed.()
  end

  @tag read_only: true
  test "right chat preserves the selected card and filters without enabling the preview runtime" do
    {view, _html} = board_view()
    render_click(view, "board-filters", %{"project" => "github:example/fixture", "status" => "ready"})
    open_task(view, "2")
    render_click(view, "open-chat")
    assert has_element?(view, "#management-chat-dock #chat-app.embedded-chat")
    assert has_element?(view, "#board-dialog[data-nonmodal=true]", "Ready fixture")
    assert has_element?(view, "#management-chat-dock", "Chat is unavailable in this read-only view")
    refute has_element?(view, "#management-chat-dock input[name=operator_token]")
    refute has_element?(view, "#chat-composer")

    render_click(view, "close-dialog")
    assert has_element?(view, "#management-chat-dock")
    refute has_element?(view, "#board-dialog")
    view |> element("button[aria-label='Close chat']") |> render_click()
    refute has_element?(view, "#management-chat-dock")
    assert has_element?(view, "#task-board-app[data-url-filters*='ready']")
  end

  @tag read_only: true
  test "view context is bounded to current project cards and selected task comes from the server" do
    {view, _html} = board_view()
    open_task(view, "2")
    render_click(view, "open-chat")

    context = %{
      "version" => 1,
      "project_id" => "github:example/fixture",
      "visible_task_ids" => ["github:example/fixture:2"],
      "viewport_task_ids" => [],
      "selected_task_id" => "github:example/fixture:1"
    }

    render_click(view, "board-view-context", context)
    assert :sys.get_state(view.pid).socket.assigns.view_context["selected_task_id"] == "github:example/fixture:2"

    render_click(view, "board-view-context", Map.put(context, "visible_task_ids", ["github:example/fixture:unknown"]))
    assert is_nil(:sys.get_state(view.pid).socket.assigns.view_context)
    render_click(view, "board-view-context", Map.put(context, "project_id", "github:example/other"))
    assert is_nil(:sys.get_state(view.pid).socket.assigns.view_context)
  end

  @tag read_only: true
  test "chat references retain the dock and reject external or other project destinations" do
    {view, _html} = board_view()
    render_click(view, "open-chat")
    send(view.pid, {:chat_panel, :board_link, "/?project=github%3Aexample%2Ffixture&status=review&task=github%3Aexample%2Ffixture%3A4"})
    assert render(view) =~ "Review fixture"
    assert has_element?(view, "#management-chat-dock")
    assert has_element?(view, "#board-dialog[data-nonmodal=true]")
    send(view.pid, {:chat_panel, :board_link, "https://example.com/?project=github%3Aexample%2Ffixture"})
    assert render(view) =~ "does not belong to this project board"
    send(view.pid, {:chat_panel, :board_link, "/?project=github%3Aexample%2Fother"})
    assert render(view) =~ "does not belong to this project board"
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
    assert render(view) =~ "Running, Review and Done follow confirmed work"
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

  test "new task requires operator access instead of redirecting to GitHub" do
    {view, _html} = board_view()
    view |> element("#new-task-button") |> render_click()
    assert has_element?(view, "#board-dialog h2", "Settings")
    assert render(view) =~ "Sign in before creating"
    refute has_element?(view, "#task-intake-form")
    refute_receive {:intake_prepared, _, _}
  end

  test "initial task history failures remain visible without discarding the form" do
    configured = Application.get_env(:symphony_elixir, Endpoint)
    Endpoint.config_change([{Endpoint, Keyword.put(configured, :intake_fixture_error, true)}], [])
    view = authorized_board_view()
    render_click(view, "new-task")
    assert has_element?(view, "#task-intake-panel [role=alert]", "Task action storage is unavailable")
    assert has_element?(view, "#task-intake-form")
    refute_receive {:intake_prepared, _, _}
  end

  test "structured intake previews exact backlog issue and requires confirmation" do
    view = authorized_board_view()
    render_click(view, "new-task")
    assert has_element?(view, "#board-dialog h2", "New task")
    assert has_element?(view, "#task-intake-form input[name='task[dependencies]'][value=none]")
    params = intake_fields()
    view |> form("#task-intake-form", task: params) |> render_submit()
    assert_receive {:intake_prepared, id, args}
    assert Regex.match?(~r/\A[a-f0-9]{32}\z/, id)
    assert args["action"] == "create_task"
    assert args["title"] == "Bounded fixture task"
    assert args["body"] == "## Outcome\n\nA useful result\n\n## Scope\n\nOne small change\n\n## Acceptance checks\n\n- Focused checks pass\n\nDepends on: #12, #34"
    assert has_element?(view, "#task-action-preview", "Will create a backlog issue without queue labels")
    refute has_element?(view, "#task-action-preview", "Task created")
    assert has_element?(view, "#task-action-preview h4", "Bounded fixture task")
    refute_receive {:intake_decided, _, _}
    view |> element("#task-action-preview button[phx-value-decision=confirm]") |> render_click()
    assert_receive {:intake_decided, ^id, "confirm"}
    assert has_element?(view, "#task-action-preview", "Action completed")
    assert has_element?(view, "#task-action-preview a[href='https://github.com/example/fixture/issues/99']")
    assert has_element?(view, "#task-action-preview .action-receipt", "Created in Backlog without queue labels.")
    refute has_element?(view, "#task-action-preview button[phx-value-decision=confirm]")
    view |> element("#task-action-preview button[phx-click=new-draft]") |> render_click()
    assert has_element?(view, "#task-intake-form input[name='task[title]'][value='']")
    assert has_element?(view, "#task-intake-form input[name='task[dependencies]'][value='none']")
    assert render(view |> element("#task-intake-form textarea[name='task[outcome]']")) =~ "></textarea>"
    assert render(view |> element("#task-intake-form textarea[name='task[scope]']")) =~ "></textarea>"
    assert render(view |> element("#task-intake-form textarea[name='task[acceptance]']")) =~ "></textarea>"
    refute_receive {:intake_prepared, _, _}
    render_click(view, "close-dialog")
    view = authorized_board_view()
    render_click(view, "new-task")
    view |> element(".intake-history-item[phx-value-id='#{id}']") |> render_click()
    assert has_element?(view, "#task-action-preview", "Action completed")
  end

  test "fresh backlog drag opens a queue preview and only confirmation submits it", ctx do
    view = authorized_board_view()
    render_click(view, "move-task", %{"id" => "github:example/fixture:1", "stage" => "ready"})
    assert_receive {:intake_prepared, id, %{"action" => "queue_task", "task_id" => "1"}}
    assert has_element?(view, "#board-dialog h2", "Move task to Ready")
    assert has_element?(view, "#task-action-preview h4", "Fresh queue task title")
    assert has_element?(view, "#task-action-preview", "Current scope and acceptance")
    refute has_element?(view, "#task-action-preview h4", "Backlog fixture")
    assert has_element?(view, "#task-action-preview", "Add queue labels: ready")
    assert has_element?(view, "#task-action-preview", "A paused controller stays paused")
    assert has_element?(view, "#lane-backlog [data-task-id='github:example/fixture:1']")
    refute has_element?(view, "#task-intake-form")
    refute_receive {:intake_decided, _, _}
    view |> element("#task-action-preview button[phx-value-decision=confirm]") |> render_click()
    assert_receive {:intake_decided, ^id, "confirm"}
    assert has_element?(view, "#task-action-preview", "Action completed")
    assert GenServer.call(ctx.runtime, :control_snapshot)["mode"] == "paused"
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refresh(view, ctx.runtime, update_task(ctx.board, "1", &%{&1 | stage: "ready"}))
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:1']")
    assert has_element?(view, "#task-action-preview", "Action completed")
  end

  test "task detail queue button supports cancellation and reopening without submitting a change" do
    view = authorized_board_view()
    open_task(view, "1")
    view |> element("#queue-task-button") |> render_click()
    assert_receive {:intake_prepared, id, %{"action" => "queue_task"}}
    view |> element("#task-action-preview button[phx-value-decision=cancel]") |> render_click()
    assert_receive {:intake_decided, ^id, "cancel"}
    assert has_element?(view, "#task-action-preview", "Action cancelled")
    view |> element("button[phx-click=preview-queue]") |> render_click()
    assert_receive {:intake_prepared, next_id, %{"action" => "queue_task"}}
    assert next_id != id
    render_click(view, "close-dialog")
    render_click(view, "new-task")
    assert has_element?(view, "#task-action-preview h3", "Queue task")
    assert has_element?(view, "#task-action-preview button[phx-value-decision=confirm]", "Queue task")
    refute_receive {:intake_prepared, _, _}
    view |> element("#task-action-preview button[phx-value-decision=cancel]") |> render_click()
    assert_receive {:intake_decided, ^next_id, "cancel"}
    refute_receive {:intake_decided, _, "confirm"}
  end

  test "queueing requires sign-in and rejects unavailable or non-backlog tasks" do
    {view, _html} = board_view()
    render_click(view, "move-task", %{"id" => "github:example/fixture:1", "stage" => "ready"})
    assert has_element?(view, "#board-dialog h2", "Settings")
    assert render(view) =~ "Sign in before queueing"
    refute_receive {:intake_prepared, _, _}
    view = authorized_board_view()

    for id <- ["github:example/fixture:missing", "github:example/fixture:2", "github:example/fixture:3"] do
      render_click(view, "queue-task", %{"id" => id})
      assert render(view) =~ "select an idle Backlog task"
      refute_receive {:intake_prepared, _, _}
    end
  end

  test "cancelled preview keeps the editable task draft" do
    view = authorized_board_view()
    render_click(view, "new-task")
    view |> form("#task-intake-form", task: intake_fields()) |> render_submit()
    assert_receive {:intake_prepared, id, _}
    view |> element("#task-action-preview button[phx-value-decision=cancel]") |> render_click()
    assert_receive {:intake_decided, ^id, "cancel"}
    view |> element("#task-action-preview button[phx-click=new-draft]") |> render_click()
    assert has_element?(view, "#task-intake-form input[name='task[title]'][value='Bounded fixture task']")
    assert has_element?(view, "#task-intake-form textarea[name='task[outcome]']", "A useful result")
    assert has_element?(view, "#task-intake-form textarea[name='task[scope]']", "One small change")
    assert has_element?(view, "#task-intake-form textarea[name='task[acceptance]']", "- Focused checks pass")
    assert has_element?(view, "#task-intake-form input[name='task[dependencies]'][value='#12, #34']")
    refute_receive {:intake_decided, _, "confirm"}
  end

  test "intake rejects malformed dependencies and extra declarations without creating proposals" do
    view = authorized_board_view()
    render_click(view, "new-task")
    view |> form("#task-intake-form", task: Map.put(intake_fields(), "dependencies", "#12, #12")) |> render_submit()
    assert render(view) =~ "List each dependency once"
    refute_receive {:intake_prepared, _, _}
    view |> form("#task-intake-form", task: Map.put(intake_fields(), "scope", "Depends on: none")) |> render_submit()
    assert render(view) =~ "Use the Dependencies field"
    refute_receive {:intake_prepared, _, _}
  end

  test "uncertain action can only reconcile and is recoverable from recent actions" do
    view = authorized_board_view()
    render_click(view, "new-task")
    view |> form("#task-intake-form", task: Map.put(intake_fields(), "title", "Uncertain task")) |> render_submit()
    assert_receive {:intake_prepared, id, _}
    view |> element("#task-action-preview button[phx-value-decision=confirm]") |> render_click()
    assert_receive {:intake_decided, ^id, "confirm"}
    assert has_element?(view, "#task-action-preview", "outcome is uncertain")
    refute has_element?(view, "#task-action-preview button[phx-value-decision=confirm]")
    refute has_element?(view, "#task-action-preview button[phx-click=new-draft]")
    render_click(view, "close-dialog")
    render_click(view, "new-task")
    view |> element(".intake-history-item[phx-value-id='#{id}']") |> render_click()
    view |> element("#task-action-preview button[phx-value-decision=reconcile]") |> render_click()
    assert_receive {:intake_decided, ^id, "reconcile"}
    assert has_element?(view, "#task-action-preview", "Action completed")
  end

  test "revoked operator access clears private preview and history on action update" do
    view = authorized_board_view()
    render_click(view, "new-task")
    view |> form("#task-intake-form", task: intake_fields()) |> render_submit()
    assert_receive {:intake_prepared, _id, _}
    assert has_element?(view, "#task-action-preview h4", "Bounded fixture task")
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated-token", 4))
    view |> element("#task-action-preview button[phx-value-decision=confirm]") |> render_click()
    refute has_element?(view, "#task-action-preview")
    refute has_element?(view, ".intake-history-item")
    refute has_element?(view, "#task-intake-form")
    refute_receive {:intake_decided, _, _}
  end

  test "revoked operator access prevents a prepared queue action and removes its fresh scope" do
    view = authorized_board_view()
    render_click(view, "queue-task", %{"id" => "github:example/fixture:1"})
    assert_receive {:intake_prepared, _id, _}
    assert has_element?(view, "#task-action-preview", "Current scope and acceptance")
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated-token", 4))
    view |> element("#task-action-preview button[phx-value-decision=confirm]") |> render_click()
    refute has_element?(view, "#task-action-preview")
    refute has_element?(view, ".intake-history-item")
    refute has_element?(view, "#task-intake-panel", "Current scope and acceptance")
    refute_receive {:intake_decided, _, _}
  end

  test "read-only refresh removes a pending queue preview and rejects further queue events", ctx do
    view = authorized_board_view()
    render_click(view, "queue-task", %{"id" => "github:example/fixture:1"})
    assert_receive {:intake_prepared, _id, _}
    refresh(view, ctx.runtime, Map.put(ctx.board, :read_only, true))
    refute has_element?(view, "#task-action-preview")
    refute has_element?(view, ".intake-history-item")
    render_click(view, "queue-task", %{"id" => "github:example/fixture:1"})
    assert render(view) =~ "This board is read-only"
    refute_receive {:intake_decided, _, _}
    refute_receive {:intake_prepared, _, _}
  end

  test "oversized submitted values cannot become shortened proposals" do
    view = authorized_board_view()
    render_click(view, "new-task")
    params = Map.put(intake_fields(), "scope", String.duplicate("z", 4001))
    view |> form("#task-intake-form", task: params) |> render_submit()
    assert render(view) =~ "Scope exceeds the 4000-byte limit"
    refute has_element?(view, "#task-action-preview")
    refute_receive {:intake_prepared, _, _}
  end

  test "background refresh preserves draft and project selection discards it", ctx do
    view = authorized_board_view()
    open_task(view, "2")
    render_click(view, "new-task")
    view |> form("#task-intake-form", task: Map.put(intake_fields(), "title", "My draft ")) |> render_change()
    refresh(view, ctx.runtime, ctx.board)
    assert has_element?(view, "#task-intake-form input[value='My draft ']")
    render_click(view, "board-filters", %{"project" => "github:example/other"})
    refute has_element?(view, "#task-intake-form")
    render_click(view, "new-task")
    assert render(view) =~ "Select one project"
    refute has_element?(view, "#task-intake-form")
  end

  test "tracker titles remain text and descriptions cannot inject HTML or unsafe links", ctx do
    changed = update_task(ctx.board, "1", &%{&1 | title: "<script>window.bad=1</script>", description: "<img src=x onerror=alert(1)>", url: "javascript:alert(1)"})
    :ok = GenServer.call(ctx.runtime, {:board, changed})
    {view, _html} = board_view()
    open_task(view, "1")
    html = render(view)
    assert html =~ "&lt;script&gt;window.bad=1&lt;/script&gt;"
    refute has_element?(view, "#board-dialog script")
    refute has_element?(view, "a[href^='javascript:']")
    refute has_element?(view, "#board-dialog img")
  end

  test "task popup renders and refreshes Markdown acceptance and source links", ctx do
    body = "## Outcome\n\n- **Verify** the change\n- Read `README.md`\n\n[Draft PR](https://github.com/example/fixture/pull/7)"
    changed = update_task(ctx.board, "2", &%{&1 | description: body})
    :ok = GenServer.call(ctx.runtime, {:board, changed})
    {view, _} = board_view()
    open_task(view, "2")
    assert has_element?(view, "#board-dialog .markdown-content h2", "Outcome")
    assert has_element?(view, "#board-dialog .markdown-content li strong", "Verify")
    assert has_element?(view, "#board-dialog .markdown-content code", "README.md")
    assert has_element?(view, "#board-dialog .markdown-content a[href='https://github.com/example/fixture/pull/7'][target='_blank']", "Draft PR")

    refresh(view, ctx.runtime, update_task(changed, "2", &%{&1 | description: "## Updated acceptance"}))
    assert has_element?(view, "#board-dialog .markdown-content h2", "Updated acceptance")
    refute has_element?(view, "#board-dialog .markdown-content a")
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

  test "chat references open a task popup with project filters and preserve them on close" do
    params = %{"project" => "github:example/fixture", "status" => "ready", "q" => "Ready", "sort" => "priority", "task" => "github:example/fixture:2"}
    {:ok, view, _} = live(build_conn(), "/?" <> URI.encode_query(params))
    render_async(view)
    assert has_element?(view, "#board-dialog h2", "Ready fixture")
    assert has_element?(view, "#task-board-app[data-url-filters]")
    render_click(view, "close-dialog")
    assert_patch(view, "/?" <> URI.encode_query(Map.delete(params, "task")))
    refute has_element?(view, "#board-dialog")
    render_patch(view, "/?project=other&task=github%3Aexample%2Ffixture%3A2")
    refute has_element?(view, "#board-dialog")
    assert render(view) =~ "not available in this project board"
  end

  test "filter updates create reproducible board URLs and discard malformed filter values" do
    {view, _} = board_view()
    render_click(view, "board-filters", %{"project" => "github:example/fixture", "status" => "running", "q" => "Fixture", "sort" => "updated", "priority" => %{"bad" => "shape"}})
    assert_patch(view, "/?" <> URI.encode_query(%{"project" => "github:example/fixture", "status" => "running", "q" => "Fixture", "sort" => "updated"}))
    assert has_element?(view, "#open-chat-button[phx-click=open-chat]")
    assert has_element?(view, "#task-board-app[data-chat-project='github:example/fixture']")
  end

  test "cards and popups distinguish tracker, execution, blocker and verified PR evidence", ctx do
    candidate = "https://github.com/example/fixture/commit/" <> String.duplicate("b", 40)

    prs = [
      %{number: 12, title: "Fix retries", url: "https://github.com/example/fixture/pull/12", state: "open", draft: true, review: "CHANGES_REQUESTED", checks: "failure"},
      %{number: 11, title: "Initial fix", url: "https://github.com/example/fixture/pull/11", state: "merged", draft: false, review: "APPROVED", checks: "success"},
      %{number: 10, title: "Additional fix", url: "https://github.com/example/fixture/pull/10", state: "open", draft: false, review: "REVIEW_REQUIRED", checks: "failure"}
    ]

    board =
      update_task(
        ctx.board,
        "2",
        &Map.merge(&1, %{
          execution_status: "paused",
          blocker_reason: "Review changes before retrying",
          pull_requests: prs,
          links: [
            %{kind: "repository", label: "Repository", url: "https://github.com/example/fixture"},
            %{kind: "commit", label: "Verified candidate", url: candidate},
            %{kind: "pull_request", label: "Linked PR", url: "https://github.com/example/fixture/pull/12"},
            %{kind: "checks", label: "PR #12 checks", url: "https://github.com/example/fixture/pull/12/checks"}
          ]
        })
      )

    board = Map.merge(board, %{data_mode: "Live GitHub", context_links: [%{label: "Issues", url: "https://github.com/example/fixture/issues"}]})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    {view, _} = board_view()
    card = "[data-task-id='github:example/fixture:2']"
    assert has_element?(view, "#board-context", "Live GitHub")
    assert has_element?(view, ".board-source-state", "GitHub checked")
    assert has_element?(view, ".board-runtime-state", "Controller: Paused · 1 active")
    assert has_element?(view, "#board-context a[href='https://github.com/example/fixture/issues']")
    assert has_element?(view, card, "Issue: Open")
    assert has_element?(view, card, "Execution: Paused")
    assert has_element?(view, card, "Review changes before retrying")
    assert has_element?(view, card <> " a[href='https://github.com/example/fixture/pull/12']", "PR #12")
    assert has_element?(view, card, "Draft")
    assert has_element?(view, card, "GitHub review: Changes requested")
    assert has_element?(view, card, "CI: Failure")
    assert has_element?(view, card, "Merged")
    assert has_element?(view, card <> " .card-pr-summary button", "View all 3 pull requests")
    assert has_element?(view, card <> " .card-reference-links a[href='https://github.com/example/fixture']", "Repository")
    assert has_element?(view, card <> " .card-reference-links a[href='#{candidate}']", "Verified candidate")
    assert has_element?(view, card <> " .card-reference-links a[href='https://github.com/example/fixture/pull/12/checks']", "PR #12 checks")
    assert has_element?(view, card <> " .card-bottom time[datetime='2026-09-14T11:00:00Z']", "Updated Sep 14")
    assert has_element?(view, ".status-badge-live", "Live updates connected")
    view |> element(card <> " .card-pr-summary button") |> render_click()
    assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/pull/10']", "Additional fix")
    assert has_element?(view, "#board-dialog a[href='#{candidate}']", "Verified candidate")
    assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/issues/2']")
    assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/pull/12']", "Fix retries")
    assert has_element?(view, "#board-dialog .task-reference-links a[href='https://github.com/example/fixture/pull/12']", "Linked PR")
    assert has_element?(view, "#board-dialog", "CI: Success")
  end

  test "source, runtime and enrichment failures stay explicit without inventing PR checks", ctx do
    changed = update_task(ctx.board, "2", &Map.put(&1, :pull_requests, [%{number: 8, title: "Pending", url: "https://github.com/example/fixture/pull/8", state: "open"}]))
    :ok = GenServer.call(ctx.runtime, {:board, changed})
    {view, _} = board_view()
    assert has_element?(view, ".pull-request-checks", "GitHub review: Unknown")
    assert has_element?(view, ".pull-request-checks", "CI: Unknown")
    incomplete = Map.merge(changed, %{source_error: "GitHub rate limit", runtime_error: "Runtime endpoint unavailable", enrichment_error: "PR checks could not be read"})
    refresh(view, ctx.runtime, incomplete)
    assert has_element?(view, ".board-source-state[data-unavailable=true]", "GitHub unavailable")
    assert has_element?(view, ".board-runtime-state[data-unavailable=true]", "Execution unavailable")
    assert has_element?(view, ".board-warning", "PR checks could not be read")
    assert has_element?(view, "[data-task-id='github:example/fixture:2']", "Ready fixture")
    refute has_element?(view, ".board-runtime-state", "Paused")
  end

  test "GitHub cards show revision and CI summary with individual jobs in the popup", ctx do
    sha = String.duplicate("c", 40)
    run = "https://github.com/example/fixture/actions/runs/42"

    job = %{
      # Concurrent jobs share a workflow; their durations must not be summed.
      name: "Unit tests",
      status: "completed",
      conclusion: "success",
      duration_ms: 145_000,
      url: run <> "/job/1",
      workflow_name: "CI",
      run_url: run,
      run_number: 24,
      run_event: "pull_request"
    }

    pending = %{job | name: "Browser checks", status: "in_progress", conclusion: "unknown", duration_ms: nil, url: run <> "/job/2"}

    pr = %{
      number: 7,
      title: "Candidate",
      url: "https://github.com/example/fixture/pull/7",
      state: "open",
      draft: true,
      review: "no_decision",
      checks: "pending",
      head_sha: sha,
      head_ref: "codex/task",
      base_ref: "integration",
      author: "builder",
      additions: 3,
      deletions: 0,
      changed_files: 1,
      mergeable: "mergeable",
      check_details_status: "available",
      check_total: 2,
      check_runs: [job, pending]
    }

    :ok = GenServer.call(ctx.runtime, {:board, update_task(ctx.board, "2", &Map.put(&1, :pull_requests, [pr]))})
    {view, _} = board_view()
    card = "[data-task-id='github:example/fixture:2']"
    assert has_element?(view, card <> " .pull-request-revision", "codex/task")
    assert has_element?(view, card <> " a[href='https://github.com/example/fixture/commit/#{sha}']", "ccccccc")
    assert has_element?(view, card <> " a[href='https://github.com/example/fixture/pull/7/files']", "1 file")
    assert has_element?(view, card <> " .pull-request-checks", "GitHub review: No decision")
    assert has_element?(view, card <> " .ci-details summary", "2 checks · 1 running, 1 passed")
    refute has_element?(view, card <> " .ci-details[open]")

    open_task(view, "2")
    assert has_element?(view, "#board-dialog .ci-details[open]")
    assert has_element?(view, "#board-dialog .pull-request-revision", "integration")
    assert has_element?(view, "#board-dialog .pull-request-metadata", "By builder")
    assert has_element?(view, "#board-dialog .pull-request-checks", "No merge conflicts")
    assert has_element?(view, "#board-dialog .ci-job a[href='#{run}/job/1']", "Unit tests")
    assert has_element?(view, "#board-dialog .ci-job-status", "2m 25s")
    assert has_element?(view, "#board-dialog .ci-job-status", "In progress")
    assert has_element?(view, "#board-dialog .ci-workflow a[href='#{run}']", "CI #24")
    assert length(Floki.find(Floki.parse_document!(render(view)), "#board-dialog .ci-workflow")) == 1
    refute render(view) =~ "Total duration"
  end

  test "partial, stale and unsafe CI details cannot imply complete passing checks", ctx do
    job = %{name: "<script>bad</script>", status: "completed", conclusion: "failure", duration_ms: -1, url: "javascript:alert(1)", run_url: "data:text/html,bad"}
    pr = %{number: 8, title: "Partial CI", url: "https://github.com/example/fixture/pull/8", check_details_status: "partial", check_total: 9, check_runs: [job]}
    board = update_task(ctx.board, "2", &Map.put(&1, :pull_requests, [pr]))
    :ok = GenServer.call(ctx.runtime, {:board, board})
    {view, _} = board_view()
    open_task(view, "2")
    assert has_element?(view, "#board-dialog .ci-details summary", "1 of 9 checks · 1 failed")
    assert has_element?(view, "#board-dialog .ci-note", "this list is incomplete")
    assert has_element?(view, "#board-dialog .ci-job-heading", "<script>bad</script>")
    refute has_element?(view, "#board-dialog script, #board-dialog .ci-job a, #board-dialog .ci-workflow a")

    stale = %{pr | check_details_status: "stale"}
    refresh(view, ctx.runtime, update_task(board, "2", &Map.put(&1, :pull_requests, [stale])))
    assert has_element?(view, "#board-dialog .ci-note", "older commit")
    refute has_element?(view, "#board-dialog .ci-job")
  end

  test "all supplied evidence links reject unsafe URLs and a bare candidate SHA creates no link", ctx do
    changed =
      update_task(
        ctx.board,
        "4",
        &Map.merge(&1, %{
          links: [%{kind: "candidate", label: "Unsafe candidate", url: "javascript:alert(1)"}, %{kind: "repo", label: "Bad repo", url: "https://safe.example\\@evil.example"}],
          pull_requests: [%{number: 9, title: "<script>bad()</script>", url: "//evil.example/pr/9", state: "open"}]
        })
      )

    changed = Map.put(changed, :context_links, [%{label: "Unsafe context", url: "data:text/html,bad"}])
    :ok = GenServer.call(ctx.runtime, {:board, changed})
    {view, _} = board_view()
    open_task(view, "4")
    assert has_element?(view, "#board-dialog", "Worker review: Request changes")
    assert has_element?(view, "#board-dialog details summary", "Handoff details")
    refute has_element?(view, "a[href^='javascript:']")
    refute has_element?(view, "a[href^='data:']")
    refute has_element?(view, "a[href^='//']")
    refute has_element?(view, "a[href*='evil.example']")
    refute has_element?(view, "a[href*='/commit/']")
    refute has_element?(view, "#board-dialog script")
  end

  @tag read_only: true, snapshot_fixture: true
  test "configured read-only mode applies before async data and rejects every mutation event", ctx do
    html = html_response(get(build_conn(), "/"), 200)
    refute html =~ "id=\"new-task-button\""
    assert html =~ "fixture_snapshot_unavailable"
    {view, _} = board_view()
    refute has_element?(view, "#new-task-button")
    refute has_element?(view, ".move-select")
    assert has_element?(view, ".task-card[draggable=false]")
    render_click(view, "open-settings")
    refute has_element?(view, "#board-dialog input[name=operator_token]")
    refute has_element?(view, "#board-dialog form[action='/operator/session/logout']")
    refute has_element?(view, "#board-dialog button[phx-click=prepare-command]")

    for {event, params} <- [
          {"new-task", %{}},
          {"queue-task", %{"id" => "github:example/fixture:1"}},
          {"prepare-command", %{"action" => "pause"}},
          {"move-task", %{"id" => "github:example/fixture:2", "stage" => "backlog"}},
          {"confirm-command", %{}},
          {"save-concurrency", %{"limit" => "1"}},
          {"reset-concurrency", %{}}
        ] do
      render_click(view, event, params)
      assert render(view) =~ "This board is read-only"
    end

    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    open_task(view, "2")
    refute has_element?(view, "#board-dialog button[phx-click=prepare-command]")
    assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/issues/2']")
  end

  test "a board becoming read-only rejects an already prepared authorized command", ctx do
    previous_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    token = String.duplicate("readonly-transition", 3)
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)
    on_exit(fn -> restore_env("SYMPHONY_CONTROL_TOKEN", previous_token) end)
    conn = %{build_conn() | host: "localhost"}
    {:ok, marker} = BrowserAuth.authenticate(conn, token)
    conn = Plug.Test.init_test_session(conn, %{BrowserAuth.session_key() => marker})
    {:ok, view, _} = live(conn, "/")
    render_async(view)
    open_task(view, "2")
    render_click(view, "prepare-command", %{"action" => "pause"})
    refresh(view, ctx.runtime, ctx.board)
    assert has_element?(view, "#board-dialog button[phx-click=confirm-command]")
    board = Map.merge(ctx.board, %{read_only: true, source_note: "Chat is unavailable in this view."})
    refresh(view, ctx.runtime, board)
    assert has_element?(view, ".board-source-note", "Chat is unavailable")
    refute has_element?(view, "#board-dialog button[phx-click=confirm-command]")
    render_click(view, "confirm-command")
    assert render(view) =~ "This board is read-only"
    refute has_element?(view, "#board-dialog")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
  end

  @tag snapshot_fixture: true
  test "standalone board refreshes runtime activity and totals through outage and recovery", ctx do
    {view, _} = board_view()
    refute render(view) =~ "fixture_snapshot_unavailable"
    assert has_element?(view, ".board-runtime-state", "Controller: Paused · 1 active")

    payload =
      ctx.board.runtime
      |> put_in([:running, Access.at(0), :last_message], "Fresh worker activity")
      |> put_in([:codex_totals, :total_tokens], 321)

    fresh = %{ctx.board | runtime: payload}
    refresh(view, ctx.runtime, fresh)
    assert has_element?(view, "[data-task-id='github:example/fixture:3'] .card-activity", "Fresh worker activity")
    render_click(view, "open-settings")
    assert has_element?(view, "#board-dialog", "Total tokens: 321")

    unavailable = %{fresh | runtime: %{error: %{code: "controller_unavailable"}}, runtime_error: "Controller activity unavailable"}
    refresh(view, ctx.runtime, unavailable)
    assert has_element?(view, ".board-runtime-state", "Execution unavailable")
    assert has_element?(view, ".board-source-state", "Last-known cards")
    refute has_element?(view, ".board-source-state", "GitHub checked")
    assert has_element?(view, ".board-warning", "controller_unavailable")
    assert has_element?(view, "#board-dialog", "Total tokens: Unavailable")
    assert has_element?(view, "[data-task-id='github:example/fixture:3']", "Running fixture")

    recovered =
      payload
      |> put_in([:running, Access.at(0), :last_message], "Recovered worker activity")
      |> put_in([:codex_totals, :total_tokens], 654)

    refresh(view, ctx.runtime, %{fresh | runtime: recovered})
    assert has_element?(view, ".board-runtime-state", "Controller: Paused · 1 active")
    assert has_element?(view, "[data-task-id='github:example/fixture:3'] .card-activity", "Recovered worker activity")
    assert has_element?(view, "#board-dialog", "Total tokens: 654")
    refute has_element?(view, ".board-warning", "controller_unavailable")

    idle = %{fresh | runtime: Map.put(recovered, :running, []), control: Map.put(fresh.control, "mode", "running")}
    refresh(view, ctx.runtime, idle)
    assert has_element?(view, ".board-runtime-state", "Controller: Running · 0 active")
    refresh(view, ctx.runtime, %{idle | runtime: Map.delete(idle.runtime, :running)})
    assert has_element?(view, ".board-runtime-state", "Controller: Running · active unknown")
    refute has_element?(view, ".board-runtime-state", "0 active")
  end

  test "settings separates scope, preserves edits across refresh and confirms exact concurrency", ctx do
    board = settings_board(ctx.board)
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    render_click(view, "open-settings")
    assert has_element?(view, "#settings-execution:not([hidden])")
    assert has_element?(view, "#settings-ai[hidden]")
    assert has_element?(view, "#concurrency-settings input[value='5'][max='5']")
    render_change(view, "edit-concurrency", %{"limit" => "2"})
    refresh(view, ctx.runtime, board)
    assert has_element?(view, "#concurrency-settings input[value='2']")
    render_click(view, "settings-tab", %{"tab" => "ai"})
    assert has_element?(view, "#settings-ai:not([hidden])")
    assert has_element?(view, "#settings-ai", "current project board view accompanies each message automatically")
    refute has_element?(view, "#chat-preferences")
    render_click(view, "settings-tab", %{"tab" => "untrusted"})
    assert has_element?(view, "#settings-ai:not([hidden])")
    render_click(view, "settings-tab", %{"tab" => "execution"})
    render_submit(view, "save-concurrency", %{"limit" => "2"})
    assert has_element?(view, "#board-dialog", "Allow at most 2 concurrent tasks")
    render_click(view, "cancel-command")
    assert has_element?(view, "#concurrency-settings input[value='2']")
    refute_received {:settings_command, _}
    render_submit(view, "save-concurrency", %{"limit" => "2"})
    render_click(view, "confirm-command")
    render_async(view)
    assert_received {:settings_command, %{"action" => "set_concurrency", "limit" => 2, "expected_revision" => 0}}
    assert has_element?(view, "#concurrency-settings input[value='2']")
    assert render(view) =~ "Concurrency saved"
    render_click(view, "reset-concurrency")
    assert has_element?(view, "#board-dialog", "Restore the workflow concurrency default")
    render_click(view, "confirm-command")
    render_async(view)
    assert_received {:settings_command, %{"limit" => nil, "expected_revision" => 1}}
    assert has_element?(view, "#concurrency-settings input[value='5']")
  end

  test "settings rejects malformed, above-ceiling and stale edits without fabricating success", ctx do
    board = settings_board(ctx.board)
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    render_click(view, "open-settings")

    for limit <- ["0", "6", "-1", "2.5", "2junk", String.duplicate("9", 20)] do
      render_submit(view, "save-concurrency", %{"limit" => limit})
      refute has_element?(view, "[phx-click=confirm-command]")
    end

    refute_received {:settings_command, _}
    render_submit(view, "save-concurrency", %{"limit" => "2"})
    newer = put_in(board.control["revision"], 1)
    refresh(view, ctx.runtime, newer)
    render_click(view, "confirm-command")
    render_async(view)
    assert_received {:settings_command, %{"expected_revision" => 0, "command_id" => id}}
    assert render(view) =~ "State changed"
    refute render(view) =~ "Concurrency saved"
    render_click(view, "confirm-command")
    render_async(view)
    assert_received {:settings_command, %{"command_id" => ^id}}
    render_click(view, "cancel-command")
    refresh(view, ctx.runtime, %{newer | runtime_error: "Disconnected"})
    refute has_element?(view, "#concurrency-settings")
    render_submit(view, "save-concurrency", %{"limit" => "2"})
    refute has_element?(view, "[phx-click=confirm-command]")
    refute_received {:settings_command, _}
  end

  test "unknown settings stay unknown and unsafe project links remain inert", ctx do
    board = %{ctx.board | projects: [%{id: "github:example/fixture", label: "Fixture", url: "javascript:alert(1)"}]}
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    render_click(view, "open-settings")
    refute has_element?(view, "#concurrency-settings")
    assert has_element?(view, "#settings-execution", "Not reported")
    refute has_element?(view, "a[href^='javascript:']")
    render_click(view, "refresh-settings")
    render_async(view)
    assert has_element?(view, "#settings-connections", "Service unavailable")
    assert has_element?(view, "#settings-connections", "Not checked · verify through a chat turn")
    render_click(view, "reset-concurrency")
    refute has_element?(view, "[phx-click=confirm-command]")
  end

  defp settings_board(board) do
    put_in(board.control["settings"], %{
      "concurrency" => %{"effective" => 5, "default" => 5, "ceiling" => 5, "override" => nil},
      "budgets" => %{"max_attempts" => 3, "max_total_runtime_ms" => 3_600_000, "max_total_tokens" => 200_000}
    })
  end

  defp intake_fields do
    %{"title" => "Bounded fixture task", "outcome" => "A useful result", "scope" => "One small change", "acceptance" => "- Focused checks pass", "dependencies" => "#12, #34"}
  end

  defp authorized_board_view do
    previous = System.get_env("SYMPHONY_CONTROL_TOKEN")
    token = String.duplicate("settings-fixture", 3)
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)
    on_exit(fn -> restore_env("SYMPHONY_CONTROL_TOKEN", previous) end)
    conn = %{build_conn() | host: "localhost"}
    {:ok, marker} = BrowserAuth.authenticate(conn, token)
    conn = Plug.Test.init_test_session(conn, %{BrowserAuth.session_key() => marker})
    {:ok, view, _} = live(conn, "/")
    render_async(view)
    view
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
