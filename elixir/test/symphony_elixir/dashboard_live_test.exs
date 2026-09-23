defmodule SymphonyElixir.DashboardLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.{BoardCache, BrowserAuth, Endpoint, Presenter, TaskBoard}
  @endpoint Endpoint

  # Explicit fixture server: real OTP calls and LiveView transport, no coding
  # workers, tracker network requests or production service state.
  defmodule FixtureRuntime do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: state.name)
    def init(state), do: {:ok, state}
    def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}
    def handle_call({:snapshot, snapshot}, _from, state), do: {:reply, :ok, %{state | snapshot: snapshot}}
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
    def projects(_auth), do: {:error, :unavailable}
    def list(_project, _auth), do: {:error, :unavailable}
  end

  defmodule ThreadsChatApi do
    def projects(_auth), do: {:ok, [%{"id" => "github:example/fixture", "label" => "Fixture"}]}

    def list(project, _auth) do
      {:ok, Agent.get(Endpoint.config(:thread_fixture), fn chats -> Enum.filter(Map.values(chats), &(&1["project_id"] == project)) end)}
    end

    def ensure_conversation(project, task, _auth) do
      id = :crypto.hash(:md5, project <> (task || "main")) |> Base.encode16(case: :lower)

      chat =
        Agent.get_and_update(Endpoint.config(:thread_fixture), fn chats ->
          chat =
            Map.get(chats, id, %{
              "id" => id,
              "project_id" => project,
              "task_id" => task,
              "conversation_role" => if(task, do: "task", else: "main"),
              "title" => if(task, do: "Task chat", else: "Main chat"),
              "status" => "idle",
              "queued_count" => 0,
              "queue_paused" => false,
              "queue" => [],
              "archived" => false,
              "messages" => [],
              "proposals" => [],
              "context" => [],
              "error" => nil,
              "activity" => nil,
              "updated_at" => "2026-09-22T12:00:00Z"
            })

          {chat, Map.put(chats, id, chat)}
        end)

      {:ok, chat}
    end

    def get(project, id, _auth) do
      case Agent.get(Endpoint.config(:thread_fixture), &Map.get(&1, id)) do
        %{"project_id" => ^project} = chat -> {:ok, chat}
        _ -> {:error, :chat_not_found}
      end
    end
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
    threads = start_supervised!({Agent, fn -> %{} end})
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])

    endpoint_config =
      Keyword.merge(previous_endpoint,
        server: false,
        secret_key_base: String.duplicate("d", 64),
        orchestrator: runtime,
        chat_store: if(context[:threads_fixture], do: ThreadsChatApi, else: UnavailableChatApi),
        thread_fixture: threads,
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
    %{runtime: runtime, board: board, threads: threads}
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
    for key <- ~w(milestone label assignee), do: assert(has_element?(view, "#board-filter-panel #filter-#{key}[role=combobox]"))
    assert has_element?(view, ".task-card[data-labels][data-milestone][data-assignees]")
    assert has_element?(view, "select[aria-label='Sort cards']")
    assert html =~ "Manual order is a browser preference"
    assert html =~ "Changes requested"
    refute html =~ "Proposed UI"
    assert has_element?(view, "#management-chat-dock")
    refute has_element?(view, "#board-dialog")
  end

  test "reload renders the last complete board before a blocked refresh and skips synchronous snapshot IO", ctx do
    owner = self()

    configure_board_loaders(
      fn _, _ ->
        send(owner, {:board_read, self()})

        receive do
          {:complete, result} -> result
          :crash -> exit(:fixture_failure)
        end
      end,
      fn ->
        send(owner, :snapshot_read)
        ctx.board.runtime
      end
    )

    {:ok, first, cold} = live(build_conn(), "/")
    refute cold =~ "Backlog fixture"
    assert_receive {:board_read, reader}
    assert_received :snapshot_read
    assert_received :snapshot_read
    send(reader, {:complete, ctx.board})
    assert render_async(first) =~ "Backlog fixture"
    GenServer.stop(first.pid)

    # Static HTML already contains cards, without a websocket or external read.
    http = get(build_conn(), "/")
    assert html_response(http, 200) =~ "Backlog fixture"
    refute_received :snapshot_read

    {:ok, second, warm} = live(build_conn(), "/?task=github%3Aexample%2Ffixture%3A2")
    assert_receive {:board_read, reader}
    assert warm =~ "Backlog fixture"
    assert warm =~ "refreshing…"
    refute warm =~ "Tracker issues are loading"
    assert has_element?(second, "#board-dialog h2", "Ready fixture")
    refute_received :snapshot_read

    updated = update_task(ctx.board, "2", &%{&1 | title: "Fresh after reload"})
    send(reader, {:complete, updated})
    assert render_async(second) =~ "Fresh after reload"
    assert {:ok, ^updated} = BoardCache.get(BoardCache.scope(ctx.runtime))

    render_click(second, "refresh")
    assert_receive {:board_read, reader}
    send(reader, {:complete, %{updated | tasks: [], source_error: "Tracker unavailable"}})
    assert render_async(second) =~ "Fresh after reload"
    assert {:ok, ^updated} = BoardCache.get(BoardCache.scope(ctx.runtime))

    render_click(second, "refresh")
    assert_receive {:board_read, reader}
    send(reader, :crash)
    assert render_async(second) =~ "Board refresh failed"
    assert {:ok, ^updated} = BoardCache.get(BoardCache.scope(ctx.runtime))
    assert html_response(get(build_conn(), "/"), 200) =~ "Fresh after reload"
  end

  test "a configuration switch discards pending results and cached cards before loading the new scope", ctx do
    owner = self()

    configure_board_loaders(fn _, _ ->
      send(owner, {:board_read, self()})

      receive do
        {:complete, result} -> result
      end
    end)

    :ok = BoardCache.put(BoardCache.scope(ctx.runtime), ctx.board)
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Backlog fixture"
    assert_receive {:board_read, old_reader}

    configured = Application.get_env(:symphony_elixir, Endpoint)
    Endpoint.config_change([{Endpoint, Keyword.put(configured, :board_read_only, true)}], [])
    refute html_response(get(build_conn(), "/"), 200) =~ "Backlog fixture"
    send(old_reader, {:complete, ctx.board})
    assert_receive {:board_read, current_reader}
    refute render(view) =~ "Backlog fixture"
    assert :miss = BoardCache.get(BoardCache.scope(ctx.runtime))

    fresh = ctx.board |> Map.put(:tasks, []) |> Map.put(:read_only, true)
    send(current_reader, {:complete, fresh})
    refute render_async(view) =~ "Backlog fixture"
    assert {:ok, ^fresh} = BoardCache.get(BoardCache.scope(ctx.runtime))
  end

  test "configuration changes during a cold snapshot cannot relabel old runtime tasks", ctx do
    configure_board_loaders(fn _, _ -> ctx.board end, fn ->
      configured = Application.get_env(:symphony_elixir, Endpoint)
      Endpoint.config_change([{Endpoint, Keyword.put(configured, :board_read_only, true)}], [])
      ctx.board.runtime
    end)

    html = html_response(get(build_conn(), "/"), 200)
    assert Floki.find(html, "article[data-task-id]") == []
  end

  test "a slow board result cannot overwrite a newer worker update", ctx do
    owner = self()

    configure_board_loaders(fn _, _ ->
      send(owner, {:board_read, self()})

      receive do
        :complete -> ctx.board
      end
    end)

    :ok = BoardCache.put(BoardCache.scope(ctx.runtime), ctx.board)
    {:ok, view, _html} = live(build_conn(), "/")
    assert_receive {:board_read, reader}
    newer = %{snapshot() | running: [], codex_totals: %{total_tokens: 1234, seconds_running: 42}}
    :ok = GenServer.call(ctx.runtime, {:snapshot, newer})
    send(view.pid, :observability_updated)
    render(view)
    payload = :sys.get_state(view.pid).socket.assigns.payload
    assert payload.running == []
    assert payload.codex_totals.total_tokens == 1234
    send(reader, :complete)
    render_async(view)
    assert :sys.get_state(view.pid).socket.assigns.payload == payload
  end

  defp configure_board_loaders(loader, snapshot_loader \\ nil) do
    configured = Application.get_env(:symphony_elixir, Endpoint)
    updates = Keyword.merge(configured, board_loader: loader, snapshot_loader: snapshot_loader)
    Application.put_env(:symphony_elixir, Endpoint, updates)
    Endpoint.config_change([{Endpoint, updates}], [])
  end

  test "paused Ready tasks explain the dispatch gate and open Execution settings without resuming", ctx do
    view = authorized_board_view()
    before = GenServer.call(ctx.runtime, :control_snapshot)
    assert has_element?(view, "#board-dispatch-guidance", "Execution is paused")
    assert has_element?(view, "#board-dispatch-guidance", "Ready tasks will not start")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']", "Queued")

    render_click(view, "open-settings")
    render_click(view, "settings-tab", %{"tab" => "connections"})
    render_click(view, "close-dialog")
    view |> element("#board-dispatch-guidance button") |> render_click()
    assert has_element?(view, "#settings-execution:not([hidden])", "Controller: Paused")
    assert has_element?(view, "#settings-connections[hidden]")
    refute has_element?(view, "#board-dialog button[phx-click=confirm-command]")

    render_click(view, "close-dialog")
    open_task(view, "2")
    assert has_element?(view, "#task-dispatch-guidance", "existing holds and limits still apply")
    view |> element("#task-dispatch-guidance button") |> render_click()
    assert has_element?(view, "#settings-execution:not([hidden])")
    assert GenServer.call(ctx.runtime, :control_snapshot) == before
    refute_received {:settings_command, _}
  end

  test "dispatch guidance follows controller mode and disappears when no Ready tasks remain", ctx do
    {view, _} = board_view()
    draining = %{ctx.board | control: Map.put(ctx.board.control, "mode", "draining")}
    refresh(view, ctx.runtime, draining)
    assert has_element?(view, "#board-dispatch-guidance", "Execution is draining")
    assert has_element?(view, "#board-dispatch-guidance", "Active work can finish")
    assert has_element?(view, "#lane-running [data-task-id='github:example/fixture:3']")
    open_task(view, "3")
    refute has_element?(view, "#task-dispatch-guidance")

    refresh(view, ctx.runtime, %{ctx.board | control: Map.put(ctx.board.control, "mode", "running")})
    refute has_element?(view, "#board-dispatch-guidance")
    refute has_element?(view, "#task-dispatch-guidance")

    refresh(view, ctx.runtime, %{ctx.board | tasks: Enum.reject(ctx.board.tasks, &(&1.stage == "ready"))})
    refute has_element?(view, "#board-dispatch-guidance")
  end

  @tag snapshot_fixture: true
  test "unavailable or disabled controls suppress stale dispatch guidance", ctx do
    {view, _} = board_view()
    open_task(view, "2")

    for board <- [
          %{ctx.board | runtime_error: "Controller unavailable"},
          %{ctx.board | runtime: %{error: %{code: "controller_unavailable"}}},
          %{ctx.board | source_error: "Tracker unavailable"},
          %{ctx.board | control: Map.put(ctx.board.control, "enabled", false)},
          %{ctx.board | control: Map.put(ctx.board.control, "fault", "Ledger recovery required")},
          %{ctx.board | control: Map.put(ctx.board.control, "error", "unavailable")},
          %{ctx.board | control: Map.put(ctx.board.control, :error, "unavailable")},
          %{ctx.board | control: Map.delete(ctx.board.control, "revision")}
        ] do
      refresh(view, ctx.runtime, board)
      refute has_element?(view, "#board-dispatch-guidance")
      refute has_element?(view, "#task-dispatch-guidance")
    end

    refresh(view, ctx.runtime, ctx.board)
    assert has_element?(view, "#board-dispatch-guidance", "Execution is paused")
    assert has_element?(view, "#task-dispatch-guidance", "Execution is paused")
  end

  @tag read_only: true
  test "read-only dispatch guidance opens inspection without execution actions", ctx do
    {view, _} = board_view()
    assert has_element?(view, "#board-dispatch-guidance", "Execution is paused")
    view |> element("#board-dispatch-guidance button") |> render_click()
    assert has_element?(view, "#settings-execution:not([hidden])", "This board is read-only")
    refute has_element?(view, "#board-dialog button[phx-click=prepare-command]")
    refute has_element?(view, "#board-dialog button[phx-click=confirm-command]")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}
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
    assert has_element?(view, "#task-board-app[data-selected-task='github:example/fixture:2']")
    assert has_element?(view, "#lane-ready [data-task-id='github:example/fixture:2']")
  end

  test "settled candidate execution remains visible on the card and detail without runtime folds", ctx do
    board = execution_board(ctx.board, "4", %{"attempts" => 2, "tokens" => 517_755, "runtime_ms" => 188_700, "hold" => "owner_review", "handoff" => approved_handoff()})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    card = "[data-task-id='github:example/fixture:4']"

    assert has_element?(view, card <> " .execution-summary", "Awaiting your review")
    assert has_element?(view, card <> " .execution-summary dd[title='Tokens: 517,755 used; limit 1,000,000']", "518k / 1M")
    assert has_element?(view, card <> " .execution-summary dd[title='Time: 188,700 ms used; limit 3,600,000 ms']", "3m 8s / 1h 0m")
    assert has_element?(view, card <> " .execution-summary", "2 / 2")
    refute has_element?(view, card <> " .execution-summary details")

    open_task(view, "4")
    assert has_element?(view, "#board-dialog .execution-summary", "Awaiting your review")
    assert has_element?(view, "#board-dialog .execution-summary dd[title='Tokens: 517,755 used; limit 1,000,000']", "518k / 1M")
    assert has_element?(view, "#board-dialog .execution-summary", "2 / 2")
    assert has_element?(view, "#board-dialog .candidate-review h3", "Agent review")
    assert has_element?(view, "#board-dialog .candidate-review", "Approved")
    assert has_element?(view, "#board-dialog .candidate-review code[title='#{String.duplicate("a", 40)}']", "aaaaaaa")
    candidate_text = view |> element("#board-dialog .candidate-review") |> render() |> Floki.parse_fragment!() |> Floki.text()
    refute candidate_text =~ String.duplicate("a", 40)
    refute has_element?(view, "#board-dialog .candidate-review details, #board-dialog .candidate-review pre")
    refute has_element?(view, "#board-dialog summary", "Runtime details")
    refute has_element?(view, "#board-dialog button[phx-value-action=cancel]")
    refute has_element?(view, "#board-dialog button[phx-value-action=retry]")
    refute has_element?(view, "#board-dialog .execution-summary", "Unavailable")
  end

  test "agent review keeps reviewer findings without repeating historical builder notes or raw handoff JSON", ctx do
    sha = String.duplicate("a", 40)

    handoff = %{
      "candidate_sha" => sha,
      "summary" => "Builder completed the requested update",
      "checks" => [
        %{"name" => "Unit tests", "result" => "passed", "details" => "All passed"},
        %{"name" => "Independent review", "result" => "not_run", "details" => "Review pending after builder handoff"}
      ],
      "limitations" => ["Candidate not published at builder handoff"],
      "review" => %{
        "candidate_sha" => sha,
        "verdict" => "request_changes",
        "summary" => "Handle interrupted retries before publishing",
        "findings" => [
          %{"severity" => "high", "path" => "lib/retry.ex", "line" => 42, "description" => "The interrupted attempt remains active"},
          %{"severity" => "medium", "path" => "<script>bad</script>", "line" => nil, "description" => "Missing coverage for cancellation"}
        ]
      }
    }

    board = execution_board(ctx.board, "4", %{"hold" => "owner_review", "handoff" => handoff})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    {view, _} = board_view()
    open_task(view, "4")
    review = "#board-dialog .candidate-review"
    assert has_element?(view, review, "Changes requested")
    assert has_element?(view, review, "Handle interrupted retries before publishing")
    assert has_element?(view, review <> " .candidate-findings", "lib/retry.ex:42")
    assert has_element?(view, review <> " .candidate-findings", "The interrupted attempt remains active")
    assert has_element?(view, review <> " .candidate-findings", "Missing coverage for cancellation")
    refute has_element?(view, review, "Review pending after builder handoff")
    refute has_element?(view, review, "Candidate not published at builder handoff")
    refute has_element?(view, review <> " details, " <> review <> " pre, " <> review <> " script")
  end

  test "agent review keeps a blocked reason when the reviewer has no findings", ctx do
    handoff = put_in(approved_handoff(), ["review"], %{"candidate_sha" => String.duplicate("a", 40), "verdict" => "blocked", "summary" => "Repository access failed before review", "findings" => []})
    board = execution_board(ctx.board, "4", %{"hold" => "owner_review", "handoff" => handoff})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    {view, _} = board_view()
    open_task(view, "4")
    assert has_element?(view, "#board-dialog .candidate-review", "Blocked")
    assert has_element?(view, "#board-dialog .candidate-review", "Repository access failed before review")
    refute has_element?(view, "#board-dialog .candidate-review details, #board-dialog .candidate-review pre")
  end

  test "a single agent review links only an exact candidate and reviewer SHA present on a linked PR", ctx do
    sha = String.duplicate("a", 40)
    other_sha = String.duplicate("b", 40)

    prs = [
      %{number: 12, title: "Reviewed change", url: "https://github.com/example/fixture/pull/12", head_sha: sha},
      %{number: 11, title: "Same candidate", url: "https://github.com/example/fixture/pull/11", head_sha: sha},
      %{number: 10, title: "Newer change", url: "https://github.com/example/fixture/pull/10", head_sha: other_sha}
    ]

    board =
      ctx.board
      |> execution_board("4", %{"hold" => "owner_review", "handoff" => approved_handoff()})
      |> update_task("4", &Map.put(&1, :pull_requests, prs))

    :ok = GenServer.call(ctx.runtime, {:board, board})
    {view, _} = board_view()
    open_task(view, "4")
    assert length(Floki.find(Floki.parse_document!(render(view)), "#board-dialog .candidate-review")) == 1
    assert has_element?(view, "#board-dialog .candidate-review a[href='https://github.com/example/fixture/commit/#{sha}'][title='#{sha}']", "aaaaaaa")
    refute has_element?(view, "#board-dialog .pull-request-evidence .candidate-review")

    mismatched_review = put_in(approved_handoff(), ["review", "candidate_sha"], other_sha)
    changed = update_task(board, "4", &Map.put(&1, :handoff, mismatched_review))
    refresh(view, ctx.runtime, changed)
    assert has_element?(view, "#board-dialog .candidate-review code[title='#{sha}']", "aaaaaaa")
    refute has_element?(view, "#board-dialog .candidate-review a")

    different_heads = update_task(board, "4", &Map.put(&1, :pull_requests, Enum.map(prs, fn pr -> %{pr | head_sha: other_sha} end)))
    refresh(view, ctx.runtime, different_heads)
    assert has_element?(view, "#board-dialog .candidate-review code[title='#{sha}']", "aaaaaaa")
    refute has_element?(view, "#board-dialog .candidate-review a")
  end

  test "recoverable hold offers retry but exhausted limits explain why another attempt is unavailable", ctx do
    board = execution_board(ctx.board, "2", %{"attempts" => 1, "tokens" => 250_000, "hold" => "interrupted"})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    open_task(view, "2")
    assert has_element?(view, "#board-dialog button[phx-value-action=retry]")
    refute has_element?(view, "#board-dialog button[phx-value-action=cancel]")

    exhausted = execution_board(ctx.board, "2", %{"attempts" => 2, "tokens" => 250_000, "hold" => "interrupted"})
    refresh(view, ctx.runtime, exhausted)
    assert has_element?(view, "#board-dialog .execution-summary", "Attempts limit reached")
    refute has_element?(view, "#board-dialog button[phx-value-action=retry]")

    tokens = execution_board(ctx.board, "2", %{"attempts" => 1, "tokens" => 1_000_000, "hold" => "token_budget"})
    refresh(view, ctx.runtime, tokens)
    assert has_element?(view, "#board-dialog .execution-summary", "Token limit reached")
    refute has_element?(view, "#board-dialog button[phx-value-action=retry]")
    refute_received {:settings_command, _}
  end

  test "settled owner review takes precedence over a lingering continuation retry timer", ctx do
    retry = %{issue_id: "4", issue_identifier: "GH-4", attempt: 1, due_at: "2099-01-01T00:00:00Z", error: nil}
    runtime_board = %{ctx.board | runtime: Map.put(ctx.board.runtime, :retrying, [retry])}

    ledger = %{
      "attempts" => 2,
      "tokens" => 517_755,
      "runtime_ms" => 188_700,
      "hold" => "owner_review",
      "handoff" => approved_handoff()
    }

    board = execution_board(runtime_board, "4", ledger)
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    assert has_element?(view, "[data-task-id='github:example/fixture:4'] .execution-summary", "Awaiting your review")

    open_task(view, "4")
    assert has_element?(view, "#board-dialog .execution-summary", "Awaiting your review")
    assert has_element?(view, "#board-dialog .candidate-review h3", "Agent review")
    assert has_element?(view, "#board-dialog", "Documented the unit-test command")
    refute has_element?(view, "#board-dialog .execution-summary", "Retry scheduled")
    refute has_element?(view, "#board-dialog button[phx-value-action=cancel]")
    refute has_element?(view, "#board-dialog button[phx-value-action=retry]")
    refute_received {:settings_command, _}
  end

  test "active execution offers cancellation without retry or retained review claims", ctx do
    started_at = DateTime.add(DateTime.utc_now(), -12, :second)
    runtime = put_in(ctx.board.runtime, [:running, Access.at(0), :started_at], DateTime.to_iso8601(started_at))

    board =
      execution_board(%{ctx.board | runtime: runtime}, "3", %{
        "attempts" => 2,
        "tokens" => 100,
        "runtime_ms" => 1_500,
        "active" => %{"run_id" => "current-run", "tokens" => 23},
        "handoff" => approved_handoff()
      })

    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    open_task(view, "3")
    assert has_element?(view, "#board-dialog .execution-summary", "Running")
    assert has_element?(view, "#board-dialog .execution-summary", "123")
    html = view |> element("#board-dialog .execution-summary dd[title^='Time:']") |> render()
    [title] = html |> Floki.parse_fragment!() |> Floki.attribute("dd", "title")
    assert [_, recorded] = Regex.run(~r/^Time: ([\d,]+) ms used; limit 3,600,000 ms$/, title)
    elapsed = recorded |> String.replace(",", "") |> String.to_integer()
    assert elapsed >= 13_500
    assert elapsed <= DateTime.diff(DateTime.utc_now(), started_at, :millisecond) + 1_500
    assert has_element?(view, "#board-dialog button[phx-value-action=cancel]")
    refute has_element?(view, "#board-dialog button[phx-value-action=retry]")
    refute has_element?(view, "#board-dialog .execution-summary", "Awaiting your review")
    refute has_element?(view, "#board-dialog .candidate-review")
  end

  test "closed tasks and unavailable execution suppress task mutations while preserving usage", ctx do
    board = execution_board(ctx.board, "5", %{"attempts" => 1, "tokens" => 125_000, "hold" => "interrupted"})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    open_task(view, "5")
    assert has_element?(view, "#board-dialog .execution-summary", "Done")
    assert has_element?(view, "#board-dialog .execution-summary", "125k / 1M")
    refute has_element?(view, "#board-dialog button[phx-value-action=cancel]")
    refute has_element?(view, "#board-dialog button[phx-value-action=retry]")

    recoverable = execution_board(ctx.board, "2", %{"attempts" => 1, "tokens" => 125_000, "hold" => "interrupted"})
    refresh(view, ctx.runtime, recoverable)
    open_task(view, "2")
    assert has_element?(view, "#board-dialog button[phx-value-action=retry]")
    refresh(view, ctx.runtime, %{recoverable | runtime_error: "Controller unavailable"})
    assert has_element?(view, "#board-dialog .execution-summary", "unavailable")
    assert has_element?(view, "#board-dialog .execution-summary", "125k / 1M")
    refute has_element?(view, "#board-dialog button[phx-value-action=cancel]")
    refute has_element?(view, "#board-dialog button[phx-value-action=retry]")
  end

  @tag read_only: true
  test "read-only execution summary retains settled metrics and never offers mutations", ctx do
    board = execution_board(ctx.board, "2", %{"attempts" => 1, "tokens" => 125_000, "hold" => "interrupted"})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    open_task(view, "2")
    assert has_element?(view, "#board-dialog .execution-summary", "125k / 1M")
    refute has_element?(view, "#board-dialog button[phx-value-action=cancel]")
    refute has_element?(view, "#board-dialog button[phx-value-action=retry]")
    refute has_element?(view, "#board-dialog .execution-summary details")
  end

  test "forged candidate retry cannot prepare or submit a command even with budget remaining", ctx do
    board = execution_board(ctx.board, "4", %{"attempts" => 1, "tokens" => 100_000, "hold" => "owner_review", "handoff" => approved_handoff()})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    open_task(view, "4")
    render_click(view, "prepare-command", %{"action" => "retry", "id" => "github:example/fixture:4"})
    refute has_element?(view, "#board-dialog button[phx-click=confirm-command]")
    render_click(view, "confirm-command")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}
  end

  @tag :threads_fixture
  test "issue headline searches categories, selects the canonical chat and links its card and all PRs", ctx do
    prs =
      for n <- 1..4, do: %{number: n, title: "Change #{n}", url: "https://github.com/example/fixture/pull/#{n}", state: if(n == 4, do: "merged", else: "open"), checks: "success", review: "approved"}

    work_id = String.duplicate("a", 32)

    work = %{
      "id" => work_id,
      "issue_id" => "2",
      "phase" => "building",
      "instruction" => "Address PR checks",
      "builder_thread_id" => "retained-thread",
      "publication" => %{"pr_number" => 1, "pr_url" => "https://github.com/example/fixture/pull/1"}
    }

    board = %{ctx.board | tasks: Enum.map(ctx.board.tasks, fn task -> if task.issue_id == "2", do: %{task | pull_requests: prs, ledger: %{"pr_work" => %{work_id => work}}}, else: task end)}
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    assert has_element?(view, "#issue-switcher #issue-search[role=combobox][aria-autocomplete=list]")
    categories = view |> element("#issue-options") |> render() |> Floki.parse_fragment!() |> Floki.find("[data-issue-category]") |> Enum.map(&(Floki.attribute(&1, "data-issue-category") |> hd()))
    assert hd(categories) == "running"
    assert List.last(categories) == "done"
    chat = with_target(view, "#chat-app")
    render_change(chat, "search-issues", %{"query" => "ready for review"})
    assert has_element?(view, "#issue-options [data-issue-category=review]")
    refute has_element?(view, "#issue-options [data-issue-category=done]")
    render_change(chat, "search-issues", %{"query" => "GH-2"})
    view |> element("#issue-options [data-issue-id='github:example/fixture:2']") |> render_click()
    render(view)
    assert has_element?(view, "#task-board-app[data-selected-task='github:example/fixture:2']")
    refute has_element?(view, "#board-dialog")
    assert has_element?(view, "#issue-switcher a[href='https://github.com/example/fixture/issues/2'][target=_blank]", "GH-2")
    refute has_element?(view, "#issue-pr-menu .issue-github-link")
    refute has_element?(view, "#issue-pr-menu #issue-card-link")
    refute has_element?(view, "#issue-pr-menu .issue-work-options")
    assert has_element?(view, "#issue-pr-menu summary", "4")
    for n <- 1..4, do: assert(has_element?(view, "#issue-pr-menu a[href='https://github.com/example/fixture/pull/#{n}']", "PR ##{n}"))
    assert has_element?(view, "#issue-pr-menu [data-pr-number='4']", "Merged")
    assert has_element?(view, ".issue-chat-identity > details:first-child#issue-pr-menu")
    refute has_element?(view, "#main-chat-button")
    refute has_element?(view, ".embedded-chat .chat-session-tabs")
    assert has_element?(view, "#issue-pr-search[type=search]")
    selected_chat = :sys.get_state(view.pid).socket.assigns.chat_id
    view |> form(".issue-pr-search", %{"query" => "merged"}) |> render_submit()
    assert has_element?(view, "#issue-pr-menu [data-pr-number='4']")
    refute has_element?(view, "#issue-pr-menu [data-pr-number='1']")
    assert has_element?(view, "#task-board-app[data-selected-task='github:example/fixture:2']")
    assert :sys.get_state(view.pid).socket.assigns.chat_id == selected_chat
    refute has_element?(view, "#board-dialog")
    render_change(chat, "search-prs", %{"query" => "merged"})
    assert has_element?(view, "#issue-pr-menu [data-pr-number='4']")
    refute has_element?(view, "#issue-pr-menu [data-pr-number='1']")
    render_change(chat, "search-prs", %{"query" => "#2 SUCCESS"})
    assert has_element?(view, "#issue-pr-menu [data-pr-number='2']")
    refute has_element?(view, "#issue-pr-menu [data-pr-number='4']")
    render_change(chat, "search-prs", %{"query" => "not-a-real-pr"})
    assert has_element?(view, "#issue-pr-menu", "No matching pull requests.")
    render_change(chat, "search-prs", %{"query" => "PR #1"})
    assert has_element?(view, "#issue-pr-menu [data-pr-number='1'] [phx-value-id='#{work_id}']")
    refute has_element?(view, "#issue-pr-menu [data-pr-number='2']")
    id = :sys.get_state(view.pid).socket.assigns.chat_id
    view |> element("#issue-pr-menu [phx-value-id='#{work_id}']") |> render_click()
    assert has_element?(view, "#board-dialog .issue-work-session[data-work-id='#{work_id}']", "Address PR checks")
    assert has_element?(view, "#board-dialog .issue-work-session[data-work-id='#{work_id}']", "Session retained")
    refute has_element?(view, "#session-outputs-content")
    assert has_element?(view, "#session-chat-content:not([hidden])")
    assert :sys.get_state(view.pid).socket.assigns.chat_id == id
    view |> element("#issue-card-link") |> render_click()
    assert has_element?(view, "#board-dialog h2", "Ready fixture")
    id = :sys.get_state(view.pid).socket.assigns.chat_id
    render_click(chat, "select-issue", %{"id" => "github:other/project:99"})
    assert :sys.get_state(view.pid).socket.assigns.chat_id == id
    assert has_element?(view, ".chat-notice", "not available")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
  end

  @tag :threads_fixture
  test "issue picker shows compact metadata and the PR selector follows only the selected issue", ctx do
    prs = for number <- [7, 8], do: %{number: number, title: "Task change #{number}", url: "https://github.com/example/fixture/pull/#{number}", state: "open"}
    unpublished_id = String.duplicate("b", 32)
    foreign_id = String.duplicate("c", 32)

    works = %{
      unpublished_id => %{"id" => unpublished_id, "issue_id" => "2", "phase" => "queued"},
      foreign_id => %{"id" => foreign_id, "issue_id" => "3", "publication" => %{"pr_number" => 7, "pr_url" => "https://github.com/example/fixture/pull/7"}}
    }

    other_pr = %{number: 99, title: "Another issue's PR", state: "merged"}

    board =
      ctx.board
      |> update_task("2", fn task ->
        %{task | created_at: "2026-09-22T21:27:05Z", priority: 2, github_status: "available", pull_requests: prs, ledger: %{"pr_work" => works}}
      end)
      |> update_task("3", fn task ->
        %{task | created_at: nil, priority: nil, github_status: "unavailable", pull_requests: [other_pr]}
      end)

    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    row = "#issue-options [data-issue-id='github:example/fixture:2']"
    assert has_element?(view, row <> " time[datetime='2026-09-22T21:27:05Z']", "Created Sep 22")
    assert has_element?(view, row <> " .issue-option-priority", "P2")
    assert has_element?(view, row <> " .issue-option-pr-count", "2 PRs")
    other = "#issue-options [data-issue-id='github:example/fixture:3']"
    assert has_element?(view, other, "Created —")
    assert has_element?(view, other, "Priority —")
    assert has_element?(view, other <> " .issue-option-pr-count", "1+ PR")

    render_click(view, "select-task", %{"id" => "github:example/fixture:2"})
    render(view)
    for number <- [7, 8], do: assert(has_element?(view, "#issue-pr-menu [data-pr-number='#{number}']"))
    refute has_element?(view, "#issue-pr-menu [data-pr-number='99']")
    refute has_element?(view, "#issue-pr-menu [phx-value-id='#{unpublished_id}']")
    refute has_element?(view, "#issue-pr-menu [phx-value-id='#{foreign_id}']")

    render_click(view, "select-task", %{"id" => "github:example/fixture:3"})
    render(view)
    assert has_element?(view, "#issue-pr-menu [data-pr-number='99']")
    refute has_element?(view, "#issue-pr-menu [data-pr-number='7']")
  end

  @tag :threads_fixture
  test "issue PR menu distinguishes unavailable and partial evidence from verified empty", ctx do
    board = update_task(ctx.board, "2", &%{&1 | github_status: "available", pull_requests: []})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    render_click(view, "select-task", %{"id" => "github:example/fixture:2"})
    render(view)
    assert has_element?(view, "#issue-pr-menu summary", "Pull requests 0")
    assert has_element?(view, "#issue-options [data-issue-id='github:example/fixture:2'] .issue-option-pr-count", "0 PRs")
    assert has_element?(view, "#issue-pr-menu", "No linked pull requests yet.")

    for {status, label, message} <- [
          {"unavailable", "Unavailable", "PR details are unavailable."},
          {"not_loaded", "Not loaded", "PR details have not loaded yet."},
          {"source_missing", "Unavailable", "issue source is missing"},
          {"partial", "Incomplete", "PR details are incomplete."},
          {"not_applicable", "Unavailable", "not available for this tracker"}
        ] do
      refresh(view, ctx.runtime, update_task(board, "2", &%{&1 | github_status: status}))
      assert has_element?(view, "#issue-pr-menu summary", label)
      assert has_element?(view, "#issue-options [data-issue-id='github:example/fixture:2'] .issue-option-pr-count", "PRs —")
      assert has_element?(view, "#issue-pr-menu [role=status]", message)
      refute has_element?(view, "#issue-pr-menu summary", "Pull requests 0")
      refute has_element?(view, "#issue-pr-menu", "No linked pull requests yet.")
    end

    prs = for n <- 1..2, do: %{number: n, title: "Known PR #{n}", url: "https://github.com/example/fixture/pull/#{n}", state: "open"}
    partial = update_task(board, "2", &%{&1 | github_status: "partial", pull_requests: prs})
    refresh(view, ctx.runtime, partial)
    assert has_element?(view, "#issue-pr-menu summary", "2 shown")
    assert has_element?(view, "#issue-pr-menu [role=status]", "PR details are incomplete.")
    for n <- 1..2, do: assert(has_element?(view, "#issue-pr-menu [data-pr-number='#{n}']", "Known PR #{n}"))
    refresh(view, ctx.runtime, update_task(partial, "2", &%{&1 | github_status: "available"}))
    assert has_element?(view, "#issue-pr-menu summary", "Pull requests 2")
    refute has_element?(view, "#issue-pr-menu [role=status]")
  end

  @tag :threads_fixture
  test "card selection switches canonical chat without details and preserves board filters", ctx do
    view = authorized_board_view()

    filters = %{
      "project" => "github:example/fixture",
      "q" => "fixture",
      "sort" => "updated",
      "milestone" => Jason.encode!(["milestone:github:example/fixture:7"]),
      "label" => Jason.encode!(["label:bug, urgent"]),
      "assignee" => Jason.encode!(["assignee:octocat"])
    }

    render_patch(view, "/?" <> URI.encode_query(filters))
    render_click(view, "select-task", %{"id" => "github:example/fixture:2"})
    selected_path = "/?" <> URI.encode_query(Map.put(filters, "chat_task", "github:example/fixture:2"))
    assert_patch(view, selected_path)
    render(view)
    first = :sys.get_state(view.pid).socket.assigns.chat_id
    assert is_binary(first)
    refute has_element?(view, "#board-dialog")
    assert has_element?(view, "article[data-task-id='github:example/fixture:2'][tabindex='0'][aria-current='true']")
    assert has_element?(view, "#management-chat-dock", "Ready fixture")

    render_click(view, "select-task", %{"id" => "github:example/fixture:2"})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.chat_id == first
    title_path = "/?" <> URI.encode_query(Map.put(filters, "task", "github:example/fixture:2"))
    assert has_element?(view, "a.card-title[href='#{title_path}'][data-phx-link=patch]", "Ready fixture")
    view |> element("[data-task-id='github:example/fixture:2'] .card-title") |> render_click()
    assert has_element?(view, "#board-dialog h2", "Ready fixture")
    assert :sys.get_state(view.pid).socket.assigns.chat_id == first

    render_click(view, "select-task", %{"id" => "github:example/fixture:4"})
    render(view)
    second = :sys.get_state(view.pid).socket.assigns.chat_id
    assert is_binary(second) and second != first
    refute has_element?(view, "#board-dialog")
    refute has_element?(view, "article[data-task-id='github:example/fixture:2'][aria-current]")
    assert has_element?(view, "article[data-task-id='github:example/fixture:4'][aria-current='true']")
    assert :sys.get_state(view.pid).socket.assigns.url_filters == filters
    assert :sys.get_state(view.pid).socket.assigns.selected == nil
    assert :sys.get_state(view.pid).socket.assigns.pending_command == nil

    for id <- ["missing", "github:other/project:2"] do
      render_click(view, "select-task", %{"id" => id})
      assert :sys.get_state(view.pid).socket.assigns.chat_id == second
    end

    render_patch(view, selected_path)
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.chat_id == first
    refute has_element?(view, "#board-dialog")
    assert map_size(Agent.get(ctx.threads, & &1)) == 3
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}
  end

  @tag read_only: true
  test "selection-only links restore without details on reload and allow read-only card selection", ctx do
    path = "/?chat_task=github%3Aexample%2Ffixture%3A2"
    {:ok, view, _html} = live(build_conn(), path)
    render_async(view)
    assert has_element?(view, "article[data-task-id='github:example/fixture:2'][data-selected=true]")
    refute has_element?(view, "#board-dialog")
    render_click(view, "select-task", %{"id" => "github:example/fixture:4"})
    assert has_element?(view, "article[data-task-id='github:example/fixture:4'][data-selected=true]")
    refute has_element?(view, "#board-dialog")
    refresh(view, ctx.runtime, %{ctx.board | tasks: Enum.reject(ctx.board.tasks, &(&1.issue_id == "4"))})
    refute has_element?(view, "article[data-selected=true]")
    refute has_element?(view, "#board-dialog")
  end

  @tag :threads_fixture
  test "the dock is permanent and card chats retain their identity after closing details", ctx do
    view = authorized_board_view()
    assert has_element?(view, "#management-chat-dock")
    refute has_element?(view, "button[aria-label='Close chat']")
    refute has_element?(view, "#new-chat-button")
    render(view)
    main = :sys.get_state(view.pid).socket.assigns.chat_id
    assert is_binary(main)

    open_task(view, "2")
    render(view)
    first = :sys.get_state(view.pid).socket.assigns.chat_id
    refute first == main
    assert has_element?(view, "#task-board-app[data-selected-task='github:example/fixture:2']")
    assert has_element?(view, "#board-dialog[data-nonmodal=true]")
    render_click(view, "close-dialog")
    assert has_element?(view, "#management-chat-dock")
    assert :sys.get_state(view.pid).socket.assigns.chat_id == first
    refute has_element?(view, "#board-dialog")

    open_task(view, "4")
    render(view)
    second = :sys.get_state(view.pid).socket.assigns.chat_id
    refute second == first
    open_task(view, "2")
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.chat_id == first
    assert map_size(Agent.get(ctx.threads, & &1)) == 3
    send(view.pid, {:chat_panel, :main})
    render(view)
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.chat_id == main
    refute has_element?(view, "#board-dialog")
    send(view.pid, {:chat_panel, :close})
    assert has_element?(view, "#management-chat-dock")
  end

  @tag :threads_fixture
  test "card indicators follow their own chat while a different chat is selected", ctx do
    view = authorized_board_view()
    open_task(view, "2")
    render(view)
    task_chat = :sys.get_state(view.pid).socket.assigns.chat_id
    open_task(view, "4")
    render(view)
    Agent.update(ctx.threads, fn chats -> Map.update!(chats, task_chat, &Map.merge(&1, %{"status" => "running", "queued_count" => 2})) end)
    send(view.pid, {:chat_list_updated, "github:example/fixture"})
    render(view)
    assert has_element?(view, "[data-task-id='github:example/fixture:2'] .card-chat-status", "Chat processing")
    assert has_element?(view, "[data-task-id='github:example/fixture:2'] .card-chat-status", "2 queued")
    refute has_element?(view, "[data-task-id='github:example/fixture:4'] .card-chat-status")
    Agent.update(ctx.threads, fn chats -> Map.update!(chats, task_chat, &Map.merge(&1, %{"status" => "idle", "display_status" => "action"})) end)
    send(view.pid, {:chat_list_updated, "github:example/fixture"})
    render(view)
    assert has_element?(view, "[data-task-id='github:example/fixture:2'] .card-chat-status", "Chat processing")
    Agent.update(ctx.threads, fn chats -> Map.update!(chats, task_chat, &Map.merge(&1, %{"status" => "interrupted", "display_status" => "queue_paused", "queue_paused" => true})) end)
    send(view.pid, {:chat_list_updated, "github:example/fixture"})
    render(view)
    assert has_element?(view, "[data-task-id='github:example/fixture:2'] .card-chat-status", "2 queued · paused")
    refute has_element?(view, "[data-task-id='github:example/fixture:2'] .card-chat-processing")
    Agent.update(ctx.threads, fn chats -> Map.update!(chats, task_chat, &Map.put(&1, "queued_count", 0)) end)
    send(view.pid, {:chat_list_updated, "github:example/fixture"})
    render(view)
    refute has_element?(view, "[data-task-id='github:example/fixture:2'] .card-chat-status")
    Agent.update(ctx.threads, fn chats -> Map.update!(chats, task_chat, &Map.put(&1, "queued_count", 2)) end)
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("revoked", 8))
    send(view.pid, {:chat_list_updated, "github:example/fixture"})
    render(view)
    refute has_element?(view, ".card-chat-status")
  end

  @tag read_only: true
  test "right chat preserves the selected card and filters without enabling the preview runtime" do
    {view, _html} = board_view()
    render_click(view, "board-filters", %{"project" => "github:example/fixture", "status" => "ready"})
    open_task(view, "2")
    assert has_element?(view, "#management-chat-dock #chat-app.embedded-chat")
    assert has_element?(view, "#board-dialog[data-nonmodal=true]", "Ready fixture")
    assert has_element?(view, "#management-chat-dock", "Chat is unavailable in this read-only view")
    refute has_element?(view, "#management-chat-dock input[name=operator_token]")
    refute has_element?(view, "#chat-composer")

    render_click(view, "close-dialog")
    assert has_element?(view, "#management-chat-dock")
    refute has_element?(view, "#board-dialog")
    refute has_element?(view, "button[aria-label='Close chat']")
    assert has_element?(view, "#management-chat-dock")
    assert has_element?(view, "#task-board-app[data-url-filters*='ready']")
  end

  @tag read_only: true
  test "view context is bounded to current project cards and selected task comes from the server" do
    {view, _html} = board_view()
    open_task(view, "2")

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
    assert render(view) =~ "Sign in and refresh execution status"
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
    assert_patch(view, "/?" <> URI.encode_query(params |> Map.delete("task") |> Map.put("chat_task", params["task"])))
    refute has_element?(view, "#board-dialog")
    render_patch(view, "/?project=other&task=github%3Aexample%2Ffixture%3A2")
    refute has_element?(view, "#board-dialog")
    assert render(view) =~ "not available in this project board"
  end

  test "filter updates create reproducible board URLs and discard malformed filter values" do
    {view, _} = board_view()
    render_click(view, "board-filters", %{"project" => "github:example/fixture", "status" => "running", "q" => "Fixture", "sort" => "updated", "priority" => %{"bad" => "shape"}})
    assert_patch(view, "/?" <> URI.encode_query(%{"project" => "github:example/fixture", "status" => "running", "q" => "Fixture", "sort" => "updated"}))
    assert has_element?(view, "#management-chat-dock")
    refute has_element?(view, "#open-chat-button")
    assert has_element?(view, "#task-board-app[data-chat-project='github:example/fixture']")
  end

  test "cards and popups distinguish tracker, execution, blocker and verified PR evidence", ctx do
    candidate = "https://github.com/example/fixture/commit/" <> String.duplicate("b", 40)

    prs = [
      %{
        number: 12,
        title: "Fix retries",
        url: "https://github.com/example/fixture/pull/12",
        state: "open",
        draft: true,
        review: "CHANGES_REQUESTED",
        checks: "failure",
        mergeable: "conflicting",
        check_details_status: "available",
        check_total: 1,
        check_runs: [%{name: "Retry tests", status: "completed", conclusion: "failure"}]
      },
      %{
        number: 11,
        title: "Initial fix",
        url: "https://github.com/example/fixture/pull/11",
        state: "merged",
        draft: false,
        review: "APPROVED",
        checks: "success",
        check_details_status: "available",
        check_total: 2,
        check_runs: [%{name: "Unit tests", status: "completed", conclusion: "success"}, %{name: "Lint", status: "completed", conclusion: "success"}]
      },
      %{
        number: 10,
        title: "Additional fix",
        url: "https://github.com/example/fixture/pull/10",
        state: "open",
        draft: false,
        review: "REVIEW_REQUIRED",
        checks: "pending",
        mergeable: "mergeable",
        check_details_status: "available",
        check_total: 1,
        check_runs: [%{name: "Integration tests", status: "in_progress"}]
      }
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
    assert has_element?(view, card, "Queued · paused")
    assert has_element?(view, card, "Review changes before retrying")
    assert has_element?(view, card <> " a[href='https://github.com/example/fixture/pull/12']", "PR #12")
    assert has_element?(view, card <> " .card-pr-summary a[href='https://github.com/example/fixture/pull/12/checks'][target='_blank']", "1 failed")
    assert has_element?(view, card <> " .card-pr-summary a[href='https://github.com/example/fixture/pull/11/checks'][rel='noopener noreferrer']", "2 passed")
    assert has_element?(view, card <> " [data-pr-number='12']", "Draft")
    assert has_element?(view, card <> " [data-pr-number='12']", "GitHub review: Changes requested")
    assert has_element?(view, card <> " [data-pr-number='12'] a[href='https://github.com/example/fixture/pull/12/checks']", "1 failed")
    refute has_element?(view, card <> " [data-pr-number='12']", "passed")
    assert has_element?(view, card <> " [data-pr-number='11']", "Merged")
    assert has_element?(view, card <> " [data-pr-number='11']", "GitHub review: Approved")
    assert has_element?(view, card <> " [data-pr-number='11'] a[href='https://github.com/example/fixture/pull/11/checks']", "2 passed")
    refute has_element?(view, card <> " [data-pr-number='11']", "failed")
    card_html = Floki.parse_document!(render(view))
    assert length(Floki.find(card_html, card <> " .card-pull-requests > .pull-request-evidence")) == 2

    for preview <- [".card-pr-summary", ".card-pull-requests"] do
      assert has_element?(view, card <> " " <> preview <> " > details > [data-pr-number='10']")
      assert length(Floki.find(card_html, card <> " " <> preview <> " > details > .pull-request-evidence")) == 1
    end

    assert has_element?(view, card <> " .card-pr-summary details summary", "More pull requests (1)")
    refute has_element?(view, card <> " [phx-click=open-task]")
    assert has_element?(view, card <> " .card-reference-links a[href='https://github.com/example/fixture']", "Repository")
    assert has_element?(view, card <> " .card-reference-links a[href='#{candidate}']", "Verified candidate")
    assert has_element?(view, card <> " .card-reference-links a[href='https://github.com/example/fixture/pull/12/checks']", "PR #12 checks")
    assert has_element?(view, card <> " .card-bottom time[datetime='2026-09-14T11:00:00Z']", "Updated Sep 14")
    assert has_element?(view, ".status-badge-live", "Live updates connected")
    view |> element(card <> " .card-title") |> render_click()
    assert has_element?(view, "#board-dialog h3", "Pull requests")
    assert has_element?(view, "#board-dialog h3 .section-count", "3")
    assert length(Floki.find(Floki.parse_document!(render(view)), "#board-dialog .pull-request-evidence")) == 3
    assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/pull/10']", "Additional fix")
    assert has_element?(view, "#board-dialog a[href='#{candidate}']", "Verified candidate")
    assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/issues/2']")
    assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/pull/12']", "Fix retries")
    refute has_element?(view, "#board-dialog .task-reference-links a[href='https://github.com/example/fixture/pull/12']")
    refute has_element?(view, "#board-dialog .task-reference-links a[href='https://github.com/example/fixture/pull/12/checks']")
    assert has_element?(view, "#board-dialog [data-pr-number='12']", "GitHub review: Changes requested")
    assert has_element?(view, "#board-dialog [data-pr-number='12']", "Merge conflicts")
    assert has_element?(view, "#board-dialog [data-pr-number='12'] a[href='https://github.com/example/fixture/pull/12/checks']", "1 failed")
    assert has_element?(view, "#board-dialog [data-pr-number='11']", "GitHub review: Approved")
    assert has_element?(view, "#board-dialog [data-pr-number='11'] a[href='https://github.com/example/fixture/pull/11/checks']", "2 passed")
    assert has_element?(view, "#board-dialog [data-pr-number='10']", "GitHub review: Review required")
    assert has_element?(view, "#board-dialog [data-pr-number='10']", "No merge conflicts")
    assert has_element?(view, "#board-dialog [data-pr-number='10'] a[href='https://github.com/example/fixture/pull/10/checks']", "1 running")
    refute has_element?(view, "#board-dialog [data-pr-number='10']", "passed")
    refute has_element?(view, ".pull-request-evidence details, .ci-jobs, .ci-job, .ci-workflow")
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

  test "GitHub cards and popups link directly to compact CI counts without inline job lists", ctx do
    sha = String.duplicate("c", 40)
    run = "https://github.com/example/fixture/actions/runs/42"

    job = %{
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
    assert has_element?(view, card <> " a[href='https://github.com/example/fixture/commit/#{sha}'][title='codex/task → integration · #{sha}']", "ccccccc")
    assert has_element?(view, card <> " a[href='https://github.com/example/fixture/pull/7/files']", "1 file")
    assert has_element?(view, card <> " .pull-request-checks", "GitHub review: No decision")
    assert has_element?(view, card <> " a[href='https://github.com/example/fixture/pull/7/checks'][title='2 checks · 1 running, 1 passed']", "CI: Pending · 1 running, 1 passed")
    refute has_element?(view, card <> " details")

    open_task(view, "2")
    assert has_element?(view, "#board-dialog .pull-request-metadata a[title='codex/task → integration · #{sha}']", "ccccccc")
    assert has_element?(view, "#board-dialog .pull-request-checks", "No merge conflicts")
    assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/pull/7/checks'][title='2 checks · 1 running, 1 passed']", "CI: Pending · 1 running, 1 passed")
    refute has_element?(view, ".pull-request-evidence details, .ci-jobs, .ci-job, .ci-workflow")
    refute has_element?(view, "a[href^='#{run}']")
    refute has_element?(view, "#board-dialog", "Unit tests")
    refute has_element?(view, "#board-dialog", "Browser checks")
    refute render(view) =~ "Total duration"
  end

  test "partial, stale and unsafe CI details cannot imply complete passing checks", ctx do
    job = %{name: "<script>bad</script>", status: "completed", conclusion: "failure", duration_ms: -1, url: "javascript:alert(1)", run_url: "data:text/html,bad"}
    pr = %{number: 8, title: "Partial CI", url: "https://github.com/example/fixture/pull/8", checks: "failure", check_details_status: "partial", check_total: 9, check_runs: [job]}
    board = update_task(ctx.board, "2", &Map.put(&1, :pull_requests, [pr]))
    :ok = GenServer.call(ctx.runtime, {:board, board})
    {view, _} = board_view()
    open_task(view, "2")
    assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/pull/8/checks']", "CI: Failure · 1 failed")
    assert has_element?(view, "#board-dialog .ci-note", "Incomplete check details: 1 of 9 checks · 1 failed")
    refute has_element?(view, "#board-dialog script, #board-dialog .ci-job, #board-dialog .ci-workflow")
    refute has_element?(view, "a[href^='javascript:'], a[href^='data:']")

    passing_sample = %{pr | check_runs: [%{job | conclusion: "success"}]}

    for checks <- ["failure", "pending"] do
      sampled = %{passing_sample | checks: checks}
      refresh(view, ctx.runtime, update_task(board, "2", &Map.put(&1, :pull_requests, [sampled])))
      assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/pull/8/checks']", "CI: #{String.capitalize(checks)} · 1 passed")
      assert has_element?(view, "#board-dialog .ci-note", "Incomplete check details: 1 of 9 checks · 1 passed")
      assert has_element?(view, "[data-task-id='github:example/fixture:2'] .compact-ci", "CI: #{String.capitalize(checks)} · 1 passed")
    end

    for {status, warning} <- [{"stale", "older commit"}, {"unavailable", "Individual check details unavailable"}] do
      for checks <- ["success", "failure", "pending", "error", "expected"] do
        missing_details = %{pr | check_details_status: status, checks: checks}
        refresh(view, ctx.runtime, update_task(board, "2", &Map.put(&1, :pull_requests, [missing_details])))
        label = "CI: #{String.capitalize(checks)} · details #{status}"
        assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/pull/8/checks']", label)
        assert has_element?(view, "[data-task-id='github:example/fixture:2'] .compact-ci", label)
        assert has_element?(view, "#board-dialog .ci-note", warning)
        refute has_element?(view, "#board-dialog [data-pr-number='8']", "1 failed")
      end

      unknown = %{pr | check_details_status: status, checks: "unknown"}
      refresh(view, ctx.runtime, update_task(board, "2", &Map.put(&1, :pull_requests, [unknown])))
      assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/pull/8/checks']", "CI: #{String.capitalize(status)}")
      assert has_element?(view, "#board-dialog .ci-note", warning)
      refute has_element?(view, "#board-dialog [data-pr-number='8']", "1 failed")
    end

    for {checks, label} <- [{"expected", "Expected · no checks"}, {"unknown", "No checks"}] do
      no_jobs = %{pr | check_details_status: "available", check_total: 0, check_runs: [], checks: checks}
      refresh(view, ctx.runtime, update_task(board, "2", &Map.put(&1, :pull_requests, [no_jobs])))
      assert has_element?(view, "#board-dialog a[href='https://github.com/example/fixture/pull/8/checks']", "CI: #{label}")
      assert has_element?(view, "[data-task-id='github:example/fixture:2'] .compact-ci", "CI: #{label}")
      refute has_element?(view, "#board-dialog [data-pr-number='8']", "1 failed")
    end
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
    assert has_element?(view, "#board-dialog .candidate-review", "Changes requested")
    refute has_element?(view, "#board-dialog details summary", "Handoff details")
    refute has_element?(view, "#board-dialog .candidate-review pre")
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

  defp execution_board(board, id, values) do
    ledger = Map.merge(%{"attempts" => 0, "tokens" => 0, "runtime_ms" => 0, "active" => nil, "hold" => nil}, values)

    control =
      board.control
      |> put_in(["issues", id], ledger)
      |> Map.put("settings", %{"budgets" => %{"max_attempts" => 2, "max_total_runtime_ms" => 3_600_000, "max_total_tokens" => 1_000_000}})

    TaskBoard.project(issues(), board.runtime, control, Config.settings!())
  end

  defp approved_handoff do
    sha = String.duplicate("a", 40)
    %{"candidate_sha" => sha, "summary" => "Documented the unit-test command", "review" => %{"candidate_sha" => sha, "verdict" => "approve", "findings" => []}}
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
