defmodule SymphonyElixir.DashboardLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Plug.Conn.Query
  alias SymphonyElixir.Specification.Document
  alias SymphonyElixir.Assurance.Store
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
    def handle_call({:board, board}, _from, state), do: {:reply, :ok, %{state | board: board, control: board.control}}

    def handle_call({:authorized_control_command, command, _tracker, authorize}, _from, state) do
      send(state.owner, {:settings_command, command})

      cond do
        not authorize.() ->
          {:reply, {:error, :unauthorized}, state}

        Map.get(state, :command_error) ->
          {:reply, {:error, state.command_error}, state}

        command["expected_revision"] != state.board.control["revision"] ->
          {:reply, {:error, :revision_conflict}, state}

        true ->
          control =
            if command["action"] == "queue_task" do
              id = command["issue_id"]

              context = %{
                tracker_kind: "github",
                tracker_fingerprint: state.control["tracker_fingerprint"],
                repository: "example/fixture",
                required_labels: ["ready"]
              }

              item = SymphonyElixir.TaskRouting.intent(state.control["issues"][id] || %{}, "queue_task", state.control["revision"] + 1, context)
              state.control |> Map.put("revision", state.control["revision"] + 1) |> put_in(["issues", id], item)
            else
              settings = state.board.control["settings"]

              state.board.control
              |> Map.put("revision", state.board.control["revision"] + 1)
              |> put_in(["settings", "concurrency", "effective"], command["limit"] || settings["concurrency"]["default"])
              |> put_in(["settings", "concurrency", "override"], command["limit"])
            end

          board = if command["action"] == "queue_task", do: TaskBoard.refresh_control(state.board, control), else: %{state.board | control: control}
          {:reply, {:ok, %{}}, %{state | board: board, control: control}}
      end
    end
  end

  defmodule UnavailableChatApi do
    def health(_auth), do: {:error, :unavailable}
    def projects(_auth), do: {:error, :unavailable}
    def list(_project, _auth), do: {:error, :unavailable}
  end

  defmodule ThreadsChatApi do
    def projects(_auth) do
      record_read(:projects)
      {:ok, [%{"id" => "github:example/fixture", "label" => "Fixture"}]}
    end

    def list(project, _auth) do
      record_read(:list)
      {:ok, Agent.get(Endpoint.config(:thread_fixture), fn chats -> Enum.filter(Map.values(chats), &(&1["project_id"] == project)) end)}
    end

    def ensure_conversation(project, task, _auth) do
      record_read(:ensure_conversation)

      case Endpoint.config(:navigation_fixture_error) do
        nil -> ensure_fixture_conversation(project, task)
        reason -> {:error, reason}
      end
    end

    defp ensure_fixture_conversation(project, task) do
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

    def ensure_pr_conversation(project, task, session, auth) do
      {:ok, base} = ensure_conversation(project, task, auth)
      id = :crypto.hash(:md5, project <> task <> session) |> Base.encode16(case: :lower)
      chat = Map.merge(base, %{"id" => id, "conversation_role" => "pr", "session_id" => session})
      Agent.update(Endpoint.config(:thread_fixture), &Map.put_new(&1, id, chat))
      __MODULE__.get(project, id, auth)
    end

    def get(project, id, _auth) do
      case Agent.get(Endpoint.config(:thread_fixture), &Map.get(&1, id)) do
        %{"project_id" => ^project} = chat -> {:ok, chat}
        _ -> {:error, :chat_not_found}
      end
    end

    defp record_read(operation) do
      if owner = Endpoint.config(:navigation_fixture_owner), do: send(owner, {:chat_read, operation})
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
      send(state.owner, {:intake_read, project, id})

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

      record = state.records[id] || %{"id" => id, "project_id" => project, "kind" => "board_action", "title" => args["title"] || "Task", "proposals" => [proposal]}
      if Endpoint.config(:intake_revoke_on_prepare, false), do: System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated-token", 4))
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
          decision == "confirm" and proposal["args"]["title"] == "Failed task" -> "failed"
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

  defmodule FixtureDesign do
    def read(project, _auth), do: call(:read, project, %{})
    def save(project, revision, scene, _auth), do: call(:save, project, %{revision: revision, scene: scene})
    def review(project, revision, _auth), do: call(:review, project, %{revision: revision})
    def reviewed(project, ref, _auth), do: call(:reviewed, project, %{ref: ref})
    def source(project, ref, _auth), do: call(:source, project, %{ref: ref})

    defp call(action, project, args) do
      Agent.get_and_update(Endpoint.config(:design_fixture), fn state ->
        send(state.owner, {:design_call, action, project, args})

        if project == state.project do
          operate(action, args, state)
        else
          {{:error, :design_project_mismatch}, state}
        end
      end)
    end

    defp operate(action, args, state) when action in [:save, :review] do
      if args.revision == state.revision do
        change(action, args, state)
      else
        {{:error, :design_revision_conflict}, state}
      end
    end

    defp operate(:read, _args, state), do: {{:ok, summary(state)}, state}

    defp operate(action, args, state) when action in [:reviewed, :source] do
      if state.reviewed["ref"] == args.ref do
        {{:ok, source_data(action, state)}, state}
      else
        {{:error, :design_review_not_found}, state}
      end
    end

    defp change(:save, args, state) do
      state = %{state | draft: args.scene, revision: state.revision + 1}
      {{:ok, summary(state)}, state}
    end

    defp change(:review, _args, state) do
      record = %{"ref" => String.duplicate("a", 64), "document_id" => "fixture-design", "scene" => state.draft}
      state = %{state | reviewed: record, revision: state.revision + 1}
      {{:ok, summary(state)}, state}
    end

    defp source_data(:reviewed, state), do: state.reviewed
    defp source_data(:source, state), do: %{"draft" => state.draft, "reviewed" => state.reviewed, "storage_revision" => state.revision}

    defp summary(state), do: %{"storage_revision" => state.revision, "draft" => state.draft, "reviewed_ref" => state.reviewed["ref"]}
  end

  defmodule FixtureSpecification do
    alias SymphonyElixir.Specification.Store
    def read(project, auth), do: Store.read(project, auth, server())
    def save(project, revision, document, auth), do: Store.save(project, revision, document, auth, server())
    def review(project, revision, auth), do: Store.review(project, revision, auth, server())
    def reviewed(project, ref, auth), do: Store.reviewed(project, ref, auth, server())
    defp server, do: Endpoint.config(:specification_fixture)
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
      control: %{enabled: true, state_path: Workflow.workflow_file_path() <> ".control.json", base_sha: String.duplicate("b", 40)},
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
      "tracker_fingerprint" => Orchestrator.tracker_fingerprint(),
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
    owner = self()
    design_state = %{owner: owner, project: "github:example/fixture", revision: 0, draft: nil, reviewed: %{}}
    design = start_supervised!({Agent, fn -> design_state end}, id: :design_fixture)
    {specification, specification_root} = specification_fixture(context)
    assurance = assurance_fixture(context)
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])

    endpoint_config =
      Keyword.merge(previous_endpoint,
        server: false,
        secret_key_base: String.duplicate("d", 64),
        orchestrator: runtime,
        chat_store: if(context[:threads_fixture], do: ThreadsChatApi, else: UnavailableChatApi),
        thread_fixture: threads,
        navigation_fixture_owner: if(context[:navigation_reads], do: self()),
        task_intake: IntakeApi,
        intake_fixture: intake,
        design_store: FixtureDesign,
        design_fixture: design,
        specification_store: if(context[:specification_fixture], do: FixtureSpecification),
        specification_fixture: specification,
        assurance_store: assurance,
        snapshot_timeout_ms: 100,
        board_read_only: context[:read_only] || false,
        snapshot_loader: if(context[:snapshot_fixture], do: fn -> %{error: %{code: "fixture_snapshot_unavailable"}} end),
        board_loader: fn server, _timeout -> GenServer.call(server, :board) end
      )

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, previous_endpoint) end)
    fixture = %{runtime: runtime, board: board, threads: threads, intake: intake, design: design}

    fixture
    |> Map.put(:assurance, assurance)
    |> Map.merge(%{specification: specification, specification_root: specification_root})
  end

  @tag :project_directory
  test "project navigation links independent boards without changing the selected task owner" do
    {view, _html} = board_view()
    refute has_element?(view, "#project-directory")
    assert has_element?(view, "#board-project-picker #filter-project[placeholder='Current project'][title='Current project']")
    assert has_element?(view, "#board-project-picker [aria-label='Open project selector']")
    refute has_element?(view, "#board-project-picker [aria-multiselectable]")

    links = view |> render() |> Floki.parse_document!() |> Floki.attribute("#task-board-app", "data-project-links") |> hd() |> Jason.decode!()

    assert links == [
             %{"id" => "github:example/fixture", "label" => "Current project", "url" => "http://localhost:8778/"},
             %{"id" => "github:iliazlobin/symphony", "label" => "Symphony", "url" => "http://localhost:8779/"}
           ]

    assert has_element?(view, "#lane-work [data-project='github:example/fixture']")
    refute has_element?(view, ".task-card[data-project='github:iliazlobin/symphony']")
    assert Endpoint.session_options()[:key] == "_symphony_fixture_project"
    conn = get(build_conn(), "/")
    assert Map.has_key?(conn.resp_cookies, "_symphony_fixture_project")
    refute Map.has_key?(conn.resp_cookies, "_symphony_elixir_key")
  end

  test "renders real projected tasks in all lanes with top filters and truthful evidence" do
    {view, html} = board_view()
    assert has_element?(view, "#lane-backlog [data-task-id='github:example/fixture:1']")
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:2']")
    assert has_element?(view, "#lane-in_progress [data-task-id='github:example/fixture:3']")
    assert has_element?(view, "#lane-review [data-task-id='github:example/fixture:4']")
    assert has_element?(view, "#lane-review [data-task-id='github:example/fixture:5']")
    assert has_element?(view, ".board-header .board-location #board-project-picker[phx-update=ignore] #filter-project[role=combobox]")
    refute has_element?(view, "#board-toolbar #filter-project")
    refute has_element?(view, "#project-directory")
    assert has_element?(view, "#filter-project[placeholder='example/fixture']")
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
    refute has_element?(view, "[data-hidden-lanes], [data-visible-lane], [data-hide-lane]")
    refute has_element?(view, ".board-summary button[phx-click=refresh]")
    assert length(Floki.find(Floki.parse_document!(html), ".kanban-lane")) == 5
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

  test "local routing updates cards during a blocked tracker read and stale completion cannot revert it", ctx do
    owner = self()

    configure_board_loaders(fn _, _ ->
      send(owner, {:board_read, self()})
      receive do: ({:complete, result} -> result)
    end)

    :ok = BoardCache.put(BoardCache.scope(ctx.runtime), ctx.board)
    {:ok, view, _html} = live(build_conn(), "/")
    assert_receive {:board_read, reader}
    assert has_element?(view, "#lane-backlog [data-task-id='github:example/fixture:1']")
    scope = Orchestrator.tracker_fingerprint()
    routing = %{"tracker_fingerprint" => scope, "queued" => true, "status" => "pending"}
    control = ctx.board.control |> Map.put("tracker_fingerprint", scope) |> Map.put("revision", 1) |> put_in(["issues", "1"], %{"routing" => routing})
    :sys.replace_state(ctx.runtime, &%{&1 | control: control})

    send(view.pid, :observability_updated)
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:1']")
    refute has_element?(view, "#lane-backlog [data-task-id='github:example/fixture:1']")
    assert {:ok, cached} = BoardCache.get(BoardCache.scope(ctx.runtime))
    assert Enum.find(cached.tasks, &(&1.issue_id == "1")).routing["queued"]

    # This remote read began before the native decision and still lacks its label.
    send(reader, {:complete, ctx.board})
    render_async(view)
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:1']")

    unqueued = control |> Map.put("revision", 2) |> put_in(["issues", "1", "routing", "queued"], false)
    :sys.replace_state(ctx.runtime, &%{&1 | control: unqueued})
    send(view.pid, {:task_intake, :changed})
    assert has_element?(view, "#lane-backlog [data-task-id='github:example/fixture:1']")
    assert_receive {:board_read, next_reader}
    send(next_reader, {:complete, ctx.board})
    render_async(view)
  end

  test "fresh local control faults disable actions without waiting for a tracker refresh", ctx do
    view = authorized_board_view()
    open_task(view, "2")
    assert has_element?(view, ".board-runtime-state", "Controller: Paused")

    faulted = Map.put(ctx.board.control, "fault", "control_persistence")
    :sys.replace_state(ctx.runtime, &%{&1 | control: faulted})
    send(view.pid, :observability_updated)
    assert has_element?(view, ".board-runtime-state", "Execution unavailable")
    assert has_element?(view, "#board-dialog .execution-state", "Status unavailable")
    refute has_element?(view, "#board-dialog button[phx-click=prepare-command]")
    assert has_element?(view, "[data-task-id='github:example/fixture:2']", "Ready fixture")

    :sys.replace_state(ctx.runtime, &%{&1 | control: {:error, :unavailable}})
    send(view.pid, :observability_updated)
    assert has_element?(view, ".board-runtime-state", "Execution unavailable")
    assert has_element?(view, "#board-dialog .execution-state", "Status unavailable")
    refute has_element?(view, "#board-dialog button[phx-click=prepare-command]")
  end

  test "pending GitHub routing is compact on cards and details and hides provider errors", ctx do
    pending = %{"queued" => true, "status" => "pending", "error" => nil}
    board = update_task(ctx.board, "2", &Map.put(&1, :routing, pending))
    :ok = GenServer.call(ctx.runtime, {:board, board})
    {view, _} = board_view()
    selector = "[data-task-id='github:example/fixture:2'] .execution-state .routing-sync"
    assert has_element?(view, selector, "Syncing GitHub")
    open_task(view, "2")
    assert has_element?(view, "#board-dialog .execution-state .routing-sync[title^='Saved locally']", "Syncing GitHub")

    failed = update_task(board, "2", &put_in(&1, [:routing, "error"], "private provider reason"))
    refresh(view, ctx.runtime, failed)
    assert has_element?(view, selector, "GitHub sync retrying")
    assert has_element?(view, "#board-dialog .routing-sync", "GitHub sync retrying")
    refute render(view) =~ "private provider reason"

    synced = update_task(failed, "2", &put_in(&1, [:routing, "status"], "synced"))
    refresh(view, ctx.runtime, synced)
    refute has_element?(view, ".routing-sync")
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
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:2']", "Queued")

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
    assert has_element?(view, "#lane-in_progress [data-task-id='github:example/fixture:3']")
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
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:2']")
    assert has_element?(view, "#board-dialog input[type=password][name=operator_token]")
    view |> element("#close-dialog") |> render_click()
    refute has_element?(view, "#board-dialog")
    assert_patch(view, "/")

    open_task(view, "2")
    assert has_element?(view, "dialog#board-dialog h2[tabindex='-1'][data-dialog-focus]", "Ready fixture")
    assert has_element?(view, "#board-dialog #close-dialog")
    assert has_element?(view, "#task-board-app[data-selected-task='github:example/fixture:2']")
    assert has_element?(view, "#board-dialog", "Acceptance for fixture 2")
    assert has_element?(view, "#lane-in_progress [data-task-id='github:example/fixture:3']")
    render_click(view, "close-dialog")
    refute has_element?(view, "#board-dialog")
    assert has_element?(view, "#task-board-app[data-selected-task='github:example/fixture:2']")
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:2']")
  end

  test "settled candidate execution remains visible on the card and detail without runtime folds", ctx do
    board = execution_board(ctx.board, "4", %{"attempts" => 2, "tokens" => 517_755, "runtime_ms" => 188_700, "hold" => "owner_review", "handoff" => approved_handoff()})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    card = "[data-task-id='github:example/fixture:4']"

    assert has_element?(view, card <> " .execution-summary", "Awaiting your review")
    refute has_element?(view, card <> " .execution-summary .execution-metrics")
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

  test "Backlog details omit unused metrics but retain recorded usage", ctx do
    view = authorized_board_view()
    open_task(view, "1")
    refute has_element?(view, "#board-dialog .execution-metrics")

    board = execution_board(ctx.board, "1", %{"tokens" => 0, "attempts" => 0, "runtime_ms" => 0})
    refresh(view, ctx.runtime, board)
    refute has_element?(view, "#board-dialog .execution-metrics")

    board = execution_board(ctx.board, "1", %{"tokens" => 123, "attempts" => 1})
    refresh(view, ctx.runtime, board)
    assert has_element?(view, "#board-dialog .execution-metrics", "123 / 1M")
    assert has_element?(view, "#board-dialog .execution-metrics", "1 / 2")
    refute has_element?(view, "#board-dialog .execution-metrics dt", "Time")
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

  test "recoverable hold offers retry and an explicit bounded cycle while lifetime limits stay closed", ctx do
    board = execution_board(ctx.board, "2", %{"attempts" => 1, "tokens" => 250_000, "hold" => "interrupted"})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    open_task(view, "2")
    assert has_element?(view, "#board-dialog button[phx-value-action=retry]")
    refute has_element?(view, "#board-dialog button[phx-value-action=cancel]")

    exhausted = execution_board(ctx.board, "2", %{"attempts" => 2, "tokens" => 250_000, "hold" => "interrupted"})
    refresh(view, ctx.runtime, exhausted)
    assert has_element?(view, "#board-dialog .execution-summary", "Attempts limit reached")
    assert has_element?(view, "#board-dialog button[phx-value-action=retry][phx-value-renew_attempts=true]", "Retry cycle")
    refute has_element?(view, "#board-dialog button[phx-value-action=retry]:not([phx-value-renew_attempts])")

    tokens = execution_board(ctx.board, "2", %{"attempts" => 1, "tokens" => 1_000_000, "hold" => "token_budget"})
    refresh(view, ctx.runtime, tokens)
    assert has_element?(view, "#board-dialog .execution-summary", "Token limit reached")
    refute has_element?(view, "#board-dialog button[phx-value-action=retry]")
    refute_received {:settings_command, _}
  end

  test "retry cycle preview confirms the exact bounded renewal and keeps its replay identity", ctx do
    exhausted = execution_board(ctx.board, "2", %{"attempts" => 2, "tokens" => 250_000, "runtime_ms" => 50, "hold" => "interrupted"})
    :ok = GenServer.call(ctx.runtime, {:board, exhausted})
    :sys.replace_state(ctx.runtime, &Map.put(&1, :command_error, :unavailable))
    view = authorized_board_view()
    open_task(view, "2")
    view |> element("#task-detail-operator button[phx-value-renew_attempts=true]") |> render_click()
    assert has_element?(view, "#board-dialog[data-kind=confirm]", "at most 2 attempts")
    assert has_element?(view, "#board-dialog", "Lifetime tokens, runtime and attempt history remain recorded")
    refute_received {:settings_command, _}
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    render_click(view, "confirm-command")
    assert_receive {:settings_command, original}
    assert original["action"] == "retry"
    assert original["issue_id"] == "2"
    assert original["renew_attempts"] == true
    assert original["expected_revision"] == 0
    assert :sys.get_state(view.pid).socket.assigns.pending_command.submitted
    render_async(view)

    # An uncertain response may have committed; the second deliberate click
    # repeats the retained command even after the old cycle no longer appears exhausted.
    committed = execution_board(exhausted, "2", %{"attempts" => 2, "attempt_base" => 2, "tokens" => 250_000, "runtime_ms" => 50, "hold" => "interrupted"})
    refresh(view, ctx.runtime, committed)
    render_click(view, "confirm-command")
    assert_receive {:settings_command, ^original}
    refute_received {:settings_command, _}
  end

  test "retry renewal rejects wrong flags, unrelated actions and changed eligibility without effects", ctx do
    exhausted = execution_board(ctx.board, "2", %{"attempts" => 2, "tokens" => 250_000, "runtime_ms" => 50, "hold" => "interrupted"})
    :ok = GenServer.call(ctx.runtime, {:board, exhausted})
    view = authorized_board_view()

    for flag <- [nil, 1, "yes", %{}, []] do
      render_click(view, "prepare-command", %{"action" => "retry", "id" => "github:example/fixture:2", "renew_attempts" => flag})
      assert is_nil(:sys.get_state(view.pid).socket.assigns.pending_command)
    end

    for action <- ["pause", "cancel", "accept_task"] do
      render_click(view, "prepare-command", %{"action" => action, "id" => "github:example/fixture:2", "renew_attempts" => true})
      assert is_nil(:sys.get_state(view.pid).socket.assigns.pending_command)
    end

    render_click(view, "prepare-command", %{"action" => "retry", "id" => "github:example/fixture:4", "renew_attempts" => "true"})
    assert is_nil(:sys.get_state(view.pid).socket.assigns.pending_command)
    render_click(view, "prepare-command", %{"action" => "retry", "id" => "github:example/fixture:2", "renew_attempts" => true})
    assert :sys.get_state(view.pid).socket.assigns.pending_command.renew_attempts
    token_exhausted = execution_board(exhausted, "2", %{"attempts" => 2, "tokens" => 1_000_000, "runtime_ms" => 50, "hold" => "token_budget"})
    refresh(view, ctx.runtime, token_exhausted)
    render_click(view, "confirm-command")
    refute_received {:settings_command, _}
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0

    render_click(view, "cancel-command")
    recoverable = execution_board(exhausted, "2", %{"attempts" => 1, "tokens" => 250_000, "runtime_ms" => 50, "hold" => "interrupted"})
    refresh(view, ctx.runtime, recoverable)
    render_click(view, "prepare-command", %{"action" => "retry", "id" => "github:example/fixture:2", "renew_attempts" => false})
    render_click(view, "confirm-command")
    assert_receive {:settings_command, legacy}
    refute Map.has_key?(legacy, "renew_attempts")
  end

  test "invalid preparation preserves an existing exact confirmation without dispatching", ctx do
    view = authorized_board_view()
    render_click(view, "prepare-command", %{"action" => "pause"})
    pending = :sys.get_state(view.pid).socket.assigns.pending_command
    assert has_element?(view, "#board-dialog[data-kind=confirm] h2", "pause")

    rejected = [
      %{"action" => "retry", "id" => "github:example/fixture:2", "renew_attempts" => %{}},
      %{"action" => "cancel", "id" => "github:example/fixture:2", "renew_attempts" => "true"},
      %{"action" => "deploy"},
      %{"action" => "retry", "id" => "github:example/fixture:4", "renew_attempts" => true}
    ]

    for params <- rejected do
      render_click(view, "prepare-command", params)
      assert :sys.get_state(view.pid).socket.assigns.pending_command == pending
      assert has_element?(view, "#board-dialog[data-kind=confirm] h2", "pause")
    end

    refute_receive {:settings_command, _}
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    render_click(view, "cancel-command")
    assert is_nil(:sys.get_state(view.pid).socket.assigns.pending_command)
    refute has_element?(view, "#board-dialog")
  end

  test "worker failures show a concise safe reason in cards and details without raw activity", ctx do
    private = "agent exited: {%RuntimeError{message: \"Bearer private-provider-token\"}, [{PrivateWorker, :run, 3, [file: \"private/config.ex\", line: 44]}]}"
    retry = %{issue_id: "2", issue_identifier: "GH-2", attempt: 1, due_at: "2099-01-01T00:00:00Z", error: private}

    board =
      %{ctx.board | runtime: Map.put(ctx.board.runtime, :retrying, [retry])}
      |> execution_board("2", %{"attempts" => 1})
      |> update_task("2", &Map.put(&1, :blocker_reason, private))

    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    card = "[data-task-id='github:example/fixture:2']"
    assert has_element?(view, card <> " .execution-summary", "Retry scheduled")
    assert has_element?(view, card <> " .attention-badge", "Worker failed; inspect service logs")
    refute has_element?(view, card <> " .card-activity")
    open_task(view, "2")
    assert has_element?(view, "#board-dialog .attention-badge", "Worker failed; inspect service logs")

    html = render(view)
    refute html =~ "RuntimeError"
    refute html =~ "private-provider-token"
    refute html =~ "private/config.ex"
    refute_received {:settings_command, _}
  end

  test "worker sign-in hold explains coding recovery independently of project chat and budgets", ctx do
    board = execution_board(ctx.board, "2", %{"attempts" => 1, "tokens" => 10, "runtime_ms" => 50, "hold" => "worker_auth_required"})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:2'] .execution-summary", "Worker sign-in required")
    open_task(view, "2")
    assert has_element?(view, "#board-dialog .execution-note", "coding worker's Codex sign-in")
    assert has_element?(view, "#board-dialog .execution-note", "Project chat remains available")
    assert has_element?(view, "#board-dialog button[phx-value-action=retry]")
    refute has_element?(view, "#board-dialog button[phx-value-action=cancel]")
    refute has_element?(view, "#board-dialog", "Retry scheduled")

    exhausted = execution_board(ctx.board, "2", %{"attempts" => 2, "hold" => "worker_auth_required"})
    refresh(view, ctx.runtime, exhausted)
    assert has_element?(view, "#board-dialog .execution-note", "Attempts limit reached")
    assert has_element?(view, "#board-dialog button[phx-value-action=retry][phx-value-renew_attempts=true]", "Retry cycle")
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
    assert has_element?(view, "#board-dialog .execution-summary", "Awaiting")
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
  test "issue headline searches categories, selects the canonical chat and lists only issues and PRs", ctx do
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
    assert hd(categories) == "work"
    assert List.last(categories) == "backlog"
    chat = with_target(view, "#chat-app")
    render_change(chat, "search-issues", %{"query" => "ready for review"})
    assert has_element?(view, "#issue-options [data-issue-category=review]")
    refute has_element?(view, "#issue-options [data-issue-category=done]")
    render_change(chat, "search-issues", %{"query" => "GH-2"})
    view |> element("#issue-options [data-issue-id='github:example/fixture:2']") |> render_click()
    render(view)
    assert has_element?(view, "#task-board-app[data-selected-task='github:example/fixture:2']")
    refute has_element?(view, "#board-dialog")
    refute has_element?(view, "#issue-switcher .issue-picker-links, #issue-switcher #issue-card-link, #issue-switcher .issue-github-link")
    refute has_element?(view, "#issue-pr-menu .issue-github-link")
    refute has_element?(view, "#issue-pr-menu #issue-card-link")
    refute has_element?(view, "#issue-pr-menu .issue-work-options")
    assert has_element?(view, "#issue-pr-menu summary", "Work All")
    refute has_element?(view, "#issue-pr-menu summary .issue-work-count")
    assert has_element?(view, "article[data-task-id='github:example/fixture:2'] .card-work-status[data-work-count='1'] [data-working-count='1']", "1 working")
    assert has_element?(view, "#operator-scope[data-agent-role=task] .operator-task-state", "Work")
    assert has_element?(view, "#operator-scope [data-working-count='1']", "1 active")
    for n <- 1..4, do: assert(has_element?(view, "#issue-pr-menu a[href='https://github.com/example/fixture/pull/#{n}']", "PR ##{n}"))
    assert has_element?(view, "#issue-pr-menu [data-pr-number='4']", "Merged")
    assert has_element?(view, "#issue-pr-menu [data-pr-number='4'] .work-option-name")
    refute has_element?(view, "#issue-pr-menu .agent-role")
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
    assert has_element?(view, "#issue-pr-menu", "No matching work agents.")
    render_change(chat, "search-prs", %{"query" => "PR #1"})
    assert has_element?(view, "#issue-pr-menu [data-pr-number='1'] [phx-value-id='work:#{work_id}']")
    refute has_element?(view, "#issue-pr-menu [data-pr-number='2']")
    id = :sys.get_state(view.pid).socket.assigns.chat_id
    view |> element("#issue-pr-menu [phx-value-id='work:#{work_id}']") |> render_click()
    refute has_element?(view, "#board-dialog")
    assert has_element?(view, "#issue-pr-menu summary", "PR #1")
    refute has_element?(view, "#issue-pr-menu summary .work-session-state")
    assert has_element?(view, "#operator-scope[data-agent-role=work] #issue-pr-menu summary", "Work")
    refute has_element?(view, "#operator-scope .operator-work-goal")
    refute :sys.get_state(view.pid).socket.assigns.chat_id == id
    assert :sys.get_state(view.pid).socket.assigns.chat_session_id == "work:" <> work_id
    pr_chat = :sys.get_state(view.pid).socket.assigns.chat_id
    view |> element("#pr-session-main") |> render_click()
    assert has_element?(view, "#issue-pr-menu summary", "Work All")
    assert :sys.get_state(view.pid).socket.assigns.chat_id == id
    refute :sys.get_state(view.pid).socket.assigns.chat_id == pr_chat
    view |> element("article[data-task-id='github:example/fixture:2'] .card-work-status a") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.chat_id == pr_chat
    refute has_element?(view, "#board-dialog")
    view |> element("#pr-session-main") |> render_click()
    assert has_element?(view, "#operator-scope[data-agent-role=task]")
    assert :sys.get_state(view.pid).socket.assigns.chat_id == id
    open_task(view, "2")
    assert has_element?(view, "#board-dialog .issue-work-session[data-work-id='#{work_id}']", "Session retained")
    assert has_element?(view, "#board-dialog a", "Ready fixture task agent")
    view |> element("#board-dialog .issue-work-session[data-work-id='#{work_id}'] a[data-phx-link]") |> render_click()
    refute has_element?(view, "#board-dialog")
    assert :sys.get_state(view.pid).socket.assigns.chat_id == pr_chat
    id = :sys.get_state(view.pid).socket.assigns.chat_id
    render_click(chat, "select-issue", %{"id" => "github:other/project:99"})
    assert :sys.get_state(view.pid).socket.assigns.chat_id == id
    assert has_element?(view, ".chat-notice", "not available")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
  end

  @tag :threads_fixture
  test "mini cards cap PRs at three and detail shortcuts select the exact PR chat", ctx do
    prs = for n <- 1..5, do: %{number: n, title: "Change #{n}", url: "https://github.com/example/fixture/pull/#{n}", state: "open"}
    board = update_task(ctx.board, "2", &Map.put(&1, :pull_requests, prs))
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    card = "[data-task-id='github:example/fixture:2']"
    for number <- 1..3, do: assert(has_element?(view, card <> " .card-pr-summary a[href='https://github.com/example/fixture/pull/#{number}']"))
    for number <- 4..5, do: refute(has_element?(view, card <> " a[href='https://github.com/example/fixture/pull/#{number}']"))
    assert has_element?(view, card <> " .card-pr-summary .card-pr-overflow", "… +2")
    view |> element(card <> " .card-pr-summary .card-pr-overflow") |> render_click()
    assert has_element?(view, "#board-dialog [data-pr-number='5']")
    view |> element("#board-dialog [data-pr-number='5'] a[aria-label='Open PR #5 work agent']") |> render_click()
    assert_push_event(view, "focus-chat-session", %{})
    refute has_element?(view, "#board-dialog")
    assert has_element?(view, "#issue-pr-menu summary", "PR #5")
    refute has_element?(view, "#issue-pr-menu summary .work-session-state")
    refute has_element?(view, "#issue-pr-menu summary .issue-work-count")
    refute has_element?(view, "#operator-scope .operator-work-goal")
    assert :sys.get_state(view.pid).socket.assigns.chat_session_id == "pr:5"
    selected = :sys.get_state(view.pid).socket.assigns.chat_id
    path = "/?" <> URI.encode_query(%{"chat_task" => "github:example/fixture:2", "chat_session" => "pr:5"})
    render_patch(view, path)
    assert :sys.get_state(view.pid).socket.assigns.chat_id == selected
    assert has_element?(view, "#pr-session-main")
    view |> element("#pr-session-main") |> render_click()
    assert has_element?(view, "#issue-pr-menu summary", "Work All")
    assert is_nil(:sys.get_state(view.pid).socket.assigns.chat_session_id)
    refute :sys.get_state(view.pid).socket.assigns.chat_id == selected
  end

  @tag :threads_fixture
  test "card dismissal preserves restoration focus in the all-projects view", ctx do
    other = %{id: "github:other/repo", label: "Other", url: nil}
    :ok = GenServer.call(ctx.runtime, {:board, %{ctx.board | projects: ctx.board.projects ++ [other]}})
    view = authorized_board_view()
    open_task(view, "2")
    render_click(view, "close-dialog")
    refute has_element?(view, "#board-dialog")
    refute_push_event(view, "focus-chat-session", %{})
    open_task(view, "2")
    view |> element("#board-dialog .task-reference-links a", "Ready fixture task agent") |> render_click()
    assert_push_event(view, "focus-chat-session", %{})
    refute has_element?(view, "#board-dialog")
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
    refute has_element?(view, other, "Created —")
    refute has_element?(view, other <> " .issue-option-priority")
    assert has_element?(view, other <> " .issue-option-pr-count", "1+ PR")

    render_click(view, "select-task", %{"id" => "github:example/fixture:2"})
    render(view)
    for number <- [7, 8], do: assert(has_element?(view, "#issue-pr-menu [data-pr-number='#{number}']"))
    refute has_element?(view, "#issue-pr-menu [data-pr-number='99']")
    assert has_element?(view, "#issue-pr-menu [phx-value-id='work:#{unpublished_id}']")
    refute has_element?(view, "#issue-pr-menu [phx-value-id='work:#{foreign_id}']")

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
    assert has_element?(view, "#issue-pr-menu summary", "Work All")
    refute has_element?(view, "#issue-options [data-issue-id='github:example/fixture:2'] .issue-option-pr-count")
    assert has_element?(view, "#issue-pr-menu", "No linked pull requests yet.")

    for {status, label, message} <- [
          {"unavailable", "Unavailable", "PR details are unavailable."},
          {"not_loaded", "Not loaded", "PR details have not loaded yet."},
          {"source_missing", "Unavailable", "issue source is missing"},
          {"partial", "Incomplete", "PR details are incomplete."},
          {"not_applicable", "Unavailable", "not available for this tracker"}
        ] do
      refresh(view, ctx.runtime, update_task(board, "2", &%{&1 | github_status: status}))
      assert has_element?(view, "#issue-pr-menu .issue-options-empty", message)
      assert label in ["Unavailable", "Not loaded", "Incomplete"]
      refute has_element?(view, "#issue-options [data-issue-id='github:example/fixture:2'] .issue-option-pr-count")
      assert has_element?(view, "#issue-pr-menu [role=status]", message)
      assert has_element?(view, "#issue-pr-menu summary", "Work All")
      refute has_element?(view, "#issue-pr-menu", "No linked pull requests yet.")
    end

    prs = for n <- 1..2, do: %{number: n, title: "Known PR #{n}", url: "https://github.com/example/fixture/pull/#{n}", state: "open"}
    partial = update_task(board, "2", &%{&1 | github_status: "partial", pull_requests: prs})
    refresh(view, ctx.runtime, partial)
    assert has_element?(view, "#issue-pr-menu summary", "Work All")
    assert has_element?(view, "#issue-pr-menu [role=status]", "PR details are incomplete.")
    for n <- 1..2, do: assert(has_element?(view, "#issue-pr-menu [data-pr-number='#{n}']", "Known PR #{n}"))
    refresh(view, ctx.runtime, update_task(partial, "2", &%{&1 | github_status: "available"}))
    assert has_element?(view, "#issue-pr-menu summary", "Work All")
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
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:2']")
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
    refute has_element?(view, "#board-dialog")
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:2']")
    refute has_element?(view, "#lane-done [data-task-id='github:example/fixture:2']")
    assert render(view) =~ "The agent sends completed work to Review"
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
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:2']")
  end

  test "new task requires operator access instead of redirecting to GitHub" do
    {view, _html} = board_view()
    refute has_element?(view, "#new-task-button")
    render_click(view, "new-task")
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

  test "simple intake creates the exact backlog issue with one explicit submit" do
    view = authorized_board_view()
    render_click(view, "new-task")
    assert has_element?(view, "#board-dialog h2", "New task")
    assert has_element?(view, "#task-intake-form button", "Create task")
    refute has_element?(view, "#task-intake-form", "Preview task")
    refute has_element?(view, "#task-intake-form", "Outcome")
    refute has_element?(view, "#task-intake-form", "Dependencies")
    refute has_element?(view, "#task-intake-panel", "Create a GitHub issue in Backlog")
    refute has_element?(view, "#task-intake-panel button", "Refresh")
    params = intake_fields()
    view |> form("#task-intake-form", task: params) |> render_submit()
    assert_receive {:intake_prepared, id, args}
    assert Regex.match?(~r/\A[a-f0-9]{32}\z/, id)
    assert args["action"] == "create_task"
    assert args["title"] == "Bounded fixture task"
    assert args["body"] == "## Description\n\nA useful result from one small change.\n\nDepends on: #12, #34\n\n## Verification\n\n- Focused checks pass"
    assert_receive {:intake_decided, ^id, "confirm"}
    assert has_element?(view, "#task-action-preview h4", "Bounded fixture task")
    view |> with_target("#task-intake-panel") |> render_submit("create", %{"task" => params})
    refute_receive {:intake_prepared, _, _}
    refute_receive {:intake_decided, _, _}
    assert has_element?(view, "#task-action-preview", "Action completed")
    assert has_element?(view, "#task-action-preview a[href='https://github.com/example/fixture/issues/99']")
    assert has_element?(view, "#task-action-preview .action-receipt", "Created in Backlog without queue labels.")
    refute has_element?(view, "#task-action-preview button[phx-value-decision=confirm]")
    view |> element("#task-action-preview button[phx-click=new-draft]") |> render_click()
    assert has_element?(view, "#task-intake-form input[name='task[title]'][value='']")
    assert render(view |> element("#task-intake-form textarea[name='task[description]']")) =~ "></textarea>"
    assert render(view |> element("#task-intake-form textarea[name='task[verification]']")) =~ "></textarea>"
    refute_receive {:intake_prepared, _, _}
    render_click(view, "close-dialog")
    view = authorized_board_view()
    render_click(view, "new-task")
    view |> element(".intake-history-item[phx-value-id='#{id}']") |> render_click()
    assert has_element?(view, "#task-action-preview", "Action completed")
  end

  test "only the title is required and blank optional details create a backlog task", ctx do
    view = authorized_board_view()
    render_click(view, "new-task")
    assert has_element?(view, "#task-intake-form input[name='task[title]'][required]")
    refute has_element?(view, "#task-intake-form textarea[required]")

    view |> form("#task-intake-form", task: %{"title" => " ", "description" => "", "verification" => ""}) |> render_submit()
    assert has_element?(view, "#task-intake-panel [role=alert]", "Add a title")
    refute_receive {:intake_prepared, _, _}
    refute_receive {:intake_decided, _, _}

    view |> form("#task-intake-form", task: %{"title" => "Investigate slow board loading", "description" => "", "verification" => ""}) |> render_submit()
    assert_receive {:intake_prepared, id, %{"action" => "create_task", "title" => "Investigate slow board loading", "body" => "Depends on: none"}}
    assert_receive {:intake_decided, ^id, "confirm"}
    assert has_element?(view, "#task-action-preview", "Action completed")
    assert GenServer.call(ctx.runtime, :control_snapshot)["mode"] == "paused"
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
  end

  test "explicit backlog drop submits one local routing command without a preview", ctx do
    view = authorized_board_view()
    render_click(view, "move-task", %{"id" => "github:example/fixture:1", "stage" => "work"})
    assert_receive {:settings_command, %{"action" => "queue_task", "issue_id" => "1", "expected_revision" => 0} = command}
    task = Enum.find(ctx.board.tasks, &(&1.issue_id == "1"))
    assert command["expected_updated_at"] == task.updated_at
    assert is_binary(command["command_id"])
    refute has_element?(view, "#task-action-preview, #task-intake-form")
    refute has_element?(view, "#board-dialog")
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:1']")
    assert GenServer.call(ctx.runtime, :control_snapshot)["mode"] == "paused"
    refute_receive {:intake_prepared, _, _}
  end

  test "task detail admission has the same direct guarded flow" do
    view = authorized_board_view()
    open_task(view, "1")
    view |> element("#queue-task-button") |> render_click()
    assert_receive {:settings_command, %{"action" => "queue_task", "issue_id" => "1"}}
    refute has_element?(view, "#task-action-preview, #task-intake-form, #board-dialog")
    refute_receive {:intake_prepared, _, _}
  end

  test "queueing requires sign-in and rejects unavailable or non-backlog tasks" do
    {view, _html} = board_view()
    render_click(view, "move-task", %{"id" => "github:example/fixture:1", "stage" => "ready"})
    assert has_element?(view, "#board-dialog h2", "Settings")
    assert render(view) =~ "Sign in before moving"
    refute_receive {:intake_prepared, _, _}
    view = authorized_board_view()

    for id <- ["github:example/fixture:missing", "github:example/fixture:2", "github:example/fixture:3"] do
      render_click(view, "queue-task", %{"id" => id})
      assert render(view) =~ "select an idle Backlog task"
      refute_receive {:intake_prepared, _, _}
    end
  end

  test "a failed creation preserves its editable description and verification" do
    view = authorized_board_view()
    render_click(view, "new-task")
    params = Map.put(intake_fields(), "title", "Failed task")
    view |> form("#task-intake-form", task: params) |> render_submit()
    assert_receive {:intake_prepared, id, _}
    assert_receive {:intake_decided, ^id, "confirm"}
    assert has_element?(view, "#task-action-preview [role=alert]")
    view |> element("#task-action-preview button[phx-click=new-draft]") |> render_click()
    assert has_element?(view, "#task-intake-form input[name='task[title]'][value='Failed task']")
    assert render(element(view, "#task-intake-form textarea[name='task[description]']")) =~ params["description"]
    assert has_element?(view, "#task-intake-form textarea[name='task[verification]']", params["verification"])
  end

  test "creation rechecks authorization after the durable action is prepared" do
    configured = Application.get_env(:symphony_elixir, Endpoint)
    Endpoint.config_change([{Endpoint, Keyword.put(configured, :intake_revoke_on_prepare, true)}], [])
    view = authorized_board_view()
    render_click(view, "new-task")
    view |> form("#task-intake-form", task: intake_fields()) |> render_submit()
    assert_receive {:intake_prepared, _id, _}
    refute_receive {:intake_decided, _, _}
    refute has_element?(view, "#task-action-preview")
    refute has_element?(view, "#task-intake-form")
    refute has_element?(view, ".intake-history-item")
  end

  test "intake rejects malformed dependencies and extra declarations without creating actions" do
    view = authorized_board_view()
    render_click(view, "new-task")
    view |> form("#task-intake-form", task: Map.put(intake_fields(), "description", "Depends on: #12, #12")) |> render_submit()
    assert render(view) =~ "List each dependency once"
    refute_receive {:intake_prepared, _, _}
    view |> form("#task-intake-form", task: Map.put(intake_fields(), "verification", "Depends on: none")) |> render_submit()
    assert render(view) =~ "Use exactly one line"
    refute_receive {:intake_prepared, _, _}
    refute_receive {:intake_decided, _, _}
  end

  test "uncertain action can only reconcile and is recoverable from recent actions" do
    view = authorized_board_view()
    render_click(view, "new-task")
    view |> form("#task-intake-form", task: Map.put(intake_fields(), "title", "Uncertain task")) |> render_submit()
    assert_receive {:intake_prepared, id, _}
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
    assert_receive {:intake_prepared, id, _}
    assert_receive {:intake_decided, ^id, "confirm"}
    assert has_element?(view, "#task-action-preview h4", "Bounded fixture task")
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated-token", 4))
    send(view.pid, {:chat_updated, id})
    # Settle the parent notification before the component's queued self-update is observed.
    render(view)
    refute has_element?(view, "#task-action-preview")
    refute has_element?(view, ".intake-history-item")
    refute has_element?(view, "#task-intake-form")
    refute_receive {:intake_decided, _, _}
  end

  test "revoked operator access rejects a direct admission", ctx do
    view = authorized_board_view()
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated-token", 4))
    render_click(view, "queue-task", %{"id" => "github:example/fixture:1"})
    assert has_element?(view, "#board-dialog h2", "Settings")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  test "read-only refresh rejects direct queue events", ctx do
    view = authorized_board_view()
    refresh(view, ctx.runtime, Map.put(ctx.board, :read_only, true))
    render_click(view, "queue-task", %{"id" => "github:example/fixture:1"})
    assert render(view) =~ "This board is read-only"
    refute_receive {:settings_command, _}
    refute_receive {:intake_prepared, _, _}
  end

  test "uncertain moves replay the same command while stale rejection requires a fresh gesture", ctx do
    view = authorized_board_view()
    :sys.replace_state(ctx.runtime, &Map.put(&1, :command_error, :unavailable))
    render_click(view, "move-task", %{"id" => "github:example/fixture:1", "stage" => "work"})
    assert_receive {:settings_command, first}
    render_click(view, "move-task", %{"id" => "github:example/fixture:1", "stage" => "work"})
    assert_receive {:settings_command, replay}
    assert replay == first
    assert has_element?(view, "#lane-backlog [data-task-id='github:example/fixture:1']")
    :sys.replace_state(ctx.runtime, &Map.put(&1, :command_error, :revision_conflict))
    render_click(view, "move-task", %{"id" => "github:example/fixture:1", "stage" => "work"})
    assert_receive {:settings_command, ^first}
    assert render(view) =~ "The task changed"
    render_click(view, "move-task", %{"id" => "github:example/fixture:1", "stage" => "work"})
    assert_receive {:settings_command, fresh}
    refute fresh["command_id"] == first["command_id"]
    :sys.replace_state(ctx.runtime, &Map.put(&1, :command_error, :invalid_command))
    render_click(view, "move-task", %{"id" => "github:example/fixture:1", "stage" => "work"})
    assert render(view) =~ "Task could not move to Work"
  end

  test "In progress is scheduler-owned and dropping into it never queues or mutates a task", ctx do
    view = authorized_board_view()

    for issue_id <- ["1", "2", "4"] do
      render_click(view, "move-task", %{"id" => "github:example/fixture:#{issue_id}", "stage" => "in_progress"})
      assert render(view) =~ "In progress shows active workers"
      refute_receive {:settings_command, _}
      refute has_element?(view, "#board-dialog")
    end

    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    assert has_element?(view, "#lane-backlog [data-task-id='github:example/fixture:1']")
    assert has_element?(view, "#lane-work [data-task-id='github:example/fixture:2']")
    assert has_element?(view, "#lane-review [data-task-id='github:example/fixture:4']")
  end

  test "Idea precedes structured Design, keeps board focus and never dispatches", ctx do
    view = authorized_board_view()
    task = "github:example/fixture:2"
    render_patch(view, "/?" <> URI.encode_query(%{"chat_task" => task, "priority" => "P1"}))
    view |> element("#view-idea") |> render_click()
    assert has_element?(view, "#board-view-picker #view-idea:first-child[aria-current=page]")
    assert has_element?(view, "#view-idea + #view-design")
    assert has_element?(view, "#idea-view [data-design-project='github:example/fixture'][phx-hook=DesignWorkspace]")
    assert has_element?(view, "#chat-app[data-design-mode=true]")
    assert :sys.get_state(view.pid).socket.assigns.chat_task_id == task
    view |> element("#view-design") |> render_click()
    assert has_element?(view, "#view-design[aria-current=page]")
    assert has_element?(view, "#design-view")
    refute has_element?(view, "#idea-view, #chat-app, [data-design-project]")
    assert :sys.get_state(view.pid).socket.assigns.chat_task_id == task
    assert :sys.get_state(view.pid).socket.assigns.url_filters == %{"priority" => "P1", "view" => "design"}
    render_click(view, "switch-view", %{"view" => "kanban"})
    assert has_element?(view, "#chat-app[data-design-mode=false]")
    assert has_element?(view, "#lane-work [data-task-id='#{task}'][data-selected=true]")
    assert :sys.get_state(view.pid).socket.assigns.url_filters == %{"priority" => "P1"}
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  test "Settings unlock returns to the current planning view, filters and task", ctx do
    {view, _html} = board_view()
    task = "github:example/fixture:2"

    for mode <- ["idea", "design", "graph", "gantt", "kanban"] do
      filters = %{"project" => "github:example/fixture", "priority" => "P1", "chat_task" => task}
      filters = if mode == "kanban", do: filters, else: Map.put(filters, "view", mode)
      render_patch(view, "/?" <> URI.encode_query(filters))
      render_click(view, "open-settings", %{"tab" => "connections"})
      returned = if mode == "graph", do: Map.put(filters, "graph_anchor", task), else: filters
      expected = "/?" <> URI.encode_query(Map.put(returned, "panel", "settings"))
      assert has_element?(view, "#settings-connections form[action='/operator/session'] input[name=return_to][value='#{expected}']")
      render_click(view, "close-dialog")
      assert :sys.get_state(view.pid).socket.assigns.board_view == mode
      assert :sys.get_state(view.pid).socket.assigns.chat_task_id == task
    end

    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  @tag :specification_fixture
  test "structured Design saves and reviews exact content without chat or task execution", ctx do
    view = authorized_board_view()
    project = "github:example/fixture"
    render_click(view, "switch-view", %{"view" => "design"})
    assert has_element?(view, "#design-view [data-specification-project='#{project}']")
    refute has_element?(view, "#chat-app, [data-design-project], [data-design-canvas]")
    assert Endpoint.config(:chat_store) == UnavailableChatApi
    assert saved_specification(view)["draft"] == nil

    render_click(view, "spec-add-item", %{"project" => project, "section" => "brief"})
    render_click(view, "spec-add-diagram", %{"project" => project, "section" => "brief"})
    draft = :sys.get_state(view.pid).socket.assigns.specification_draft
    [item] = draft["sections"]["brief"]["items"]
    [diagram] = draft["sections"]["brief"]["diagrams"]

    values = %{
      "items" => %{item["id"] => %{"title" => "Discovery scope", "body" => "Find relevant local events."}},
      "diagrams" => %{diagram["id"] => %{"title" => "Discovery flow", "source" => "flowchart TD\n  U[User] --> W[Web client]"}}
    }

    view |> form(".specification-form", values) |> render_change()
    assert has_element?(view, "[data-spec-status]", "Unsaved changes")
    assert saved_specification(view)["storage_revision"] == 0
    refute File.exists?(Path.join(ctx.specification_root, "journal.json"))
    view |> form(".specification-form", values) |> render_submit()
    first = saved_specification(view)
    assert first["storage_revision"] == 1
    assert first["review_count"] == 0
    assert first["draft"]["sections"]["brief"]["items"] == [Map.merge(item, values["items"][item["id"]])]
    assert has_element?(view, "[data-spec-mermaid]", "U[User] --> W[Web client]")

    view |> element("button[phx-click=spec-review]") |> render_click()
    assert has_element?(view, ".specification-review")
    assert saved_specification(view)["review_count"] == 0
    view |> element("button[phx-click=spec-cancel-review]") |> render_click()
    refute has_element?(view, ".specification-review")
    render_click(view, "spec-confirm-review", %{"project" => project, "storage_revision" => "1"})
    assert saved_specification(view)["review_count"] == 0
    view |> element("button[phx-click=spec-review]") |> render_click()
    view |> element("button[phx-click=spec-confirm-review]") |> render_click()
    reviewed = saved_specification(view)
    ref = reviewed["reviewed"]["ref"]
    assert reviewed["storage_revision"] == 2
    assert reviewed["review_count"] == 1

    pending = %{"items" => %{item["id"] => %{"body" => "A later working draft."}}}
    view |> form(".specification-form", pending) |> render_change()
    view |> element("button[phx-click=spec-open-version][phx-value-ref='#{ref}']") |> render_click()
    assert has_element?(view, "[data-spec-status]", "Reviewed version · read-only")
    assert has_element?(view, ".specification-form fieldset[disabled]")
    assert has_element?(view, ".specification-form textarea", "Find relevant local events.")
    render_click(view, "spec-remove-item", %{"project" => project, "section" => "brief", "id" => item["id"]})
    assert saved_specification(view) == reviewed
    view |> element("button[phx-click=spec-return-draft]") |> render_click()
    assert has_element?(view, ".specification-form textarea", "A later working draft.")
    assert has_element?(view, "[data-spec-status]", "Unsaved changes")

    render_click(view, "switch-view", %{"view" => "idea"})
    render_click(view, "switch-view", %{"view" => "design"})
    assert has_element?(view, ".specification-form textarea", "A later working draft.")
    view |> form(".specification-form", pending) |> render_submit()
    view |> element("button[phx-click=spec-review]") |> render_click()
    view |> element("button[phx-click=spec-confirm-review]") |> render_click()
    assert saved_specification(view)["review_count"] == 2
    auth = :sys.get_state(view.pid).socket.assigns.auth
    assert {:ok, %{"specification" => original}} = FixtureSpecification.reviewed(project, ref, auth)
    assert original == first["draft"]
    assert Agent.get(ctx.design, & &1.revision) == 0
    assert :sys.get_state(ctx.intake).records == %{}
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:intake_prepared, _, _}
    refute_receive {:settings_command, _}
  end

  @tag :specification_fixture
  test "browser unused-input markers preserve successive edits and save only specification fields", ctx do
    view = authorized_board_view()
    project = "github:example/fixture"
    render_click(view, "switch-view", %{"view" => "design"})
    render_click(view, "spec-add-item", %{"project" => project, "section" => "brief"})
    render_click(view, "spec-add-diagram", %{"project" => project, "section" => "brief"})
    view |> form(".specification-form") |> render_submit()
    initial = saved_specification(view)
    [item] = initial["draft"]["sections"]["brief"]["items"]
    [diagram] = initial["draft"]["sections"]["brief"]["diagrams"]
    refute has_element?(view, "[data-spec-status]", "Unsaved changes")

    serialized = fn params, target ->
      params |> Map.put("_target", target) |> Query.encode() |> Query.decode()
    end

    first =
      specification_params(view)
      |> put_in(["items", item["id"], "title"], "Discovery scope")
      |> update_in(["items", item["id"]], &Map.merge(&1, %{"_unused_kind" => "", "_unused_body" => ""}))
      |> update_in(["diagrams", diagram["id"]], &Map.merge(&1, %{"_unused_title" => "", "_unused_source" => ""}))
      |> serialized.(["items", item["id"], "title"])

    render_change(view, "spec-edit", first)
    assert has_element?(view, "[data-spec-status]", "Unsaved changes")
    assert has_element?(view, ".specification-form input[name$='[title]'][value='Discovery scope']")
    refute has_element?(view, "#design-view", "This edit no longer matches")
    assert saved_specification(view) == initial

    second =
      specification_params(view)
      |> put_in(["items", item["id"], "body"], "Find relevant local events.")
      |> update_in(["items", item["id"]], &Map.put(&1, "_unused_kind", ""))
      |> update_in(["diagrams", diagram["id"]], &Map.merge(&1, %{"_unused_title" => "", "_unused_source" => ""}))
      |> serialized.(["items", item["id"], "body"])

    render_change(view, "spec-edit", second)

    third =
      specification_params(view)
      |> put_in(["diagrams", diagram["id"], "title"], "Discovery flow")
      |> update_in(["items", item["id"]], &Map.put(&1, "_unused_kind", ""))
      |> update_in(["diagrams", diagram["id"]], &Map.put(&1, "_unused_source", ""))
      |> serialized.(["diagrams", diagram["id"], "title"])

    render_change(view, "spec-edit", third)

    last =
      specification_params(view)
      |> put_in(["diagrams", diagram["id"], "source"], "flowchart TD\nU[User] --> W[Web client]")
      |> update_in(["items", item["id"]], &Map.put(&1, "_unused_kind", ""))
      |> serialized.(["diagrams", diagram["id"], "source"])

    render_change(view, "spec-edit", last)
    render_submit(view, "spec-save", last)
    saved = saved_specification(view)
    assert saved["storage_revision"] == 2
    assert saved["draft"]["sections"]["brief"]["items"] == [Map.merge(item, %{"title" => "Discovery scope", "body" => "Find relevant local events."})]
    assert saved["draft"]["sections"]["brief"]["diagrams"] == [Map.merge(diagram, %{"title" => "Discovery flow", "source" => "flowchart TD\nU[User] --> W[Web client]"})]
    refute File.read!(Path.join(ctx.specification_root, "journal.json")) =~ "_unused_"
    refute has_element?(view, "[data-spec-status]", "Unsaved changes")

    rejected = specification_params(view) |> put_in(["items", item["id"], "_unused_id"], "")
    render_change(view, "spec-edit", rejected)
    assert has_element?(view, "#design-view", "This edit no longer matches")
    assert :sys.get_state(view.pid).socket.assigns.specification_draft == saved["draft"]
    assert saved_specification(view) == saved
  end

  @tag :specification_fixture
  test "specification form context changes sections without clobbering edits or accepting old section events" do
    view = authorized_board_view()
    project = "github:example/fixture"
    render_click(view, "switch-view", %{"view" => "design"})
    render_click(view, "spec-add-item", %{"project" => project, "section" => "brief"})
    render_click(view, "spec-add-diagram", %{"project" => project, "section" => "brief"})
    draft = :sys.get_state(view.pid).socket.assigns.specification_draft
    [item] = draft["sections"]["brief"]["items"]
    [diagram] = draft["sections"]["brief"]["diagrams"]
    brief_form = view |> render() |> Floki.parse_document!() |> Floki.attribute(".specification-form", "id")
    view |> form(".specification-form", %{"items" => %{item["id"] => %{"title" => "Discovery scope"}}}) |> render_change()
    values = %{"diagrams" => %{diagram["id"] => %{"title" => "Discovery flow", "source" => "flowchart TD\nA-->B"}}}
    view |> form(".specification-form", values) |> render_change()
    stale = specification_params(view)
    retained = :sys.get_state(view.pid).socket.assigns.specification_draft
    assert retained["sections"]["brief"]["items"] |> hd() |> Map.fetch!("title") == "Discovery scope"
    assert retained["sections"]["brief"]["diagrams"] |> hd() |> Map.fetch!("title") == "Discovery flow"
    assert retained["sections"]["brief"]["diagrams"] |> hd() |> Map.fetch!("source") == "flowchart TD\nA-->B"

    render_click(view, "spec-section", %{"project" => project, "section" => "architecture"})
    refute view |> render() |> Floki.parse_document!() |> Floki.attribute(".specification-form", "id") == brief_form
    render_change(view, "spec-edit", stale)
    assert :sys.get_state(view.pid).socket.assigns.specification_draft == retained
    assert has_element?(view, "#design-view", "This edit no longer matches the open section")

    render_click(view, "spec-section", %{"project" => project, "section" => "data"})
    render_click(view, "spec-add-item", %{"project" => project, "section" => "data"})
    [entity] = :sys.get_state(view.pid).socket.assigns.specification_draft["sections"]["data"]["items"]
    assert has_element?(view, ".specification-form input[name=section][id][value=data]")
    view |> form(".specification-form", %{"items" => %{entity["id"] => %{"title" => "Event", "body" => "id: UUID"}}}) |> render_submit()
    saved = saved_specification(view)
    assert saved["draft"]["sections"]["brief"] == retained["sections"]["brief"]
    assert saved["draft"]["sections"]["data"]["items"] |> hd() |> Map.fetch!("body") == "id: UUID"
    assert has_element?(view, ".specification-form input[name=storage_revision][id][value='1']")
    render_click(view, "spec-section", %{"project" => project, "section" => "brief"})
    assert view |> render() |> Floki.parse_document!() |> Floki.attribute(".specification-form", "id") == brief_form
    assert has_element?(view, ".specification-form input[name$='[title]'][id][value='Discovery scope']")
    assert has_element?(view, ".specification-form input[name$='[title]'][id][value='Discovery flow']")
    assert has_element?(view, ".specification-form textarea[name$='[source]'][id]", "A-->B")
    render_change(view, "spec-edit", stale)
    assert :sys.get_state(view.pid).socket.assigns.specification_draft == saved["draft"]
  end

  @tag :specification_fixture
  test "a concurrent specification save retains local edits until an explicit reload", ctx do
    view = authorized_board_view()
    project = "github:example/fixture"
    render_click(view, "switch-view", %{"view" => "design"})
    render_click(view, "spec-add-item", %{"project" => project, "section" => "brief"})
    [item] = :sys.get_state(view.pid).socket.assigns.specification_draft["sections"]["brief"]["items"]
    view |> form(".specification-form", %{"items" => %{item["id"] => %{"body" => "Saved proposal."}}}) |> render_submit()
    initial = saved_specification(view)
    view |> form(".specification-form", %{"items" => %{item["id"] => %{"body" => "Unsaved local changes."}}}) |> render_change()
    elsewhere = put_in(initial["draft"], ["sections", "brief", "items", Access.at(0), "body"], "Saved by another browser.")
    auth = :sys.get_state(view.pid).socket.assigns.auth
    assert {:ok, %{"storage_revision" => 2}} = FixtureSpecification.save(project, 1, elsewhere, auth)

    view |> form(".specification-form") |> render_submit()
    assert has_element?(view, "#design-view", "The saved specification changed elsewhere")
    assert has_element?(view, ".specification-form textarea", "Unsaved local changes.")
    assert saved_specification(view)["draft"] == elsewhere
    render_click(view, "switch-view", %{"view" => "idea"})
    render_click(view, "switch-view", %{"view" => "design"})
    assert has_element?(view, ".specification-form textarea", "Unsaved local changes.")
    view |> element("button[phx-click=spec-reload]") |> render_click()
    assert has_element?(view, ".specification-form textarea", "Saved by another browser.")
    assert :sys.get_state(view.pid).socket.assigns.specification_draft == elsewhere
    assert saved_specification(view)["review_count"] == 0
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  test "chat unlock posts the current graph view, filters, selected task and neighborhood", ctx do
    {view, _html} = board_view()

    params = %{
      "view" => "graph",
      "project" => "github:example/fixture",
      "priority" => "P1",
      "chat_task" => "github:example/fixture:2",
      "graph_mode" => "focus",
      "graph_anchor" => "github:example/fixture:2",
      "graph_direction" => "upstream",
      "graph_hops" => "2",
      "graph_query" => "GH-2"
    }

    destination = "/?" <> URI.encode_query(params)
    render_patch(view, destination)
    assert has_element?(view, "#graph-view")
    assert has_element?(view, "#management-chat-dock form[action='/operator/session'] input[name=return_to][value='#{destination}']")
    render_click(view, "graph-options", %{"direction" => "downstream"})
    returned = "/?" <> URI.encode_query(Map.put(params, "graph_direction", "downstream"))
    assert has_element?(view, "#management-chat-dock input[name=return_to][value='#{returned}']")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  @tag :specification_fixture
  test "a failed specification reload preserves unsaved edits and disables writes until storage recovers", ctx do
    view = authorized_board_view()
    project = "github:example/fixture"
    render_click(view, "switch-view", %{"view" => "design"})
    render_click(view, "spec-add-item", %{"project" => project, "section" => "brief"})
    [item] = :sys.get_state(view.pid).socket.assigns.specification_draft["sections"]["brief"]["items"]
    view |> form(".specification-form", %{"items" => %{item["id"] => %{"body" => "Saved project scope."}}}) |> render_submit()
    saved = saved_specification(view)
    view |> form(".specification-form", %{"items" => %{item["id"] => %{"body" => "Unsaved work to preserve."}}}) |> render_change()
    pending = :sys.get_state(view.pid).socket.assigns.specification_draft
    params = specification_params(view)
    bytes = File.read!(Path.join(ctx.specification_root, "journal.json"))

    :ok = stop_supervised(SymphonyElixir.Specification.Store)
    view |> element("button[phx-click=spec-reload]") |> render_click()
    assert has_element?(view, "#design-view", "Your open draft is retained")
    assert has_element?(view, ".specification-form textarea", "Unsaved work to preserve.")
    assert has_element?(view, ".specification-form fieldset[disabled]")
    assert :sys.get_state(view.pid).socket.assigns.specification_draft == pending
    render_submit(view, "spec-save", params)
    assert File.read!(Path.join(ctx.specification_root, "journal.json")) == bytes

    owner = start_supervised!({SymphonyElixir.Specification.Store, specification_opts(ctx.specification_root)})
    configured = Application.get_env(:symphony_elixir, Endpoint)
    Endpoint.config_change([{Endpoint, Keyword.put(configured, :specification_fixture, owner)}], [])
    view |> element("button[phx-click=spec-reload]") |> render_click()
    assert has_element?(view, ".specification-form textarea", "Saved project scope.")
    refute has_element?(view, ".specification-form fieldset[disabled]")
    assert :sys.get_state(view.pid).socket.assigns.specification_draft == saved["draft"]
    assert saved_specification(view) == saved
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  @tag :specification_fixture
  test "forged specification events from other views, projects or revoked sessions never write", ctx do
    view = authorized_board_view()
    project = "github:example/fixture"
    render_click(view, "switch-view", %{"view" => "design"})
    render_click(view, "spec-add-item", %{"project" => project, "section" => "brief"})
    [item] = :sys.get_state(view.pid).socket.assigns.specification_draft["sections"]["brief"]["items"]
    view |> form(".specification-form", %{"items" => %{item["id"] => %{"body" => "Authorized saved draft."}}}) |> render_submit()
    saved = saved_specification(view)
    journal = Path.join(ctx.specification_root, "journal.json")
    bytes = File.read!(journal)
    params = specification_params(view, %{"items" => %{item["id"] => Map.put(item, "body", "Forbidden overwrite.") |> Map.delete("id")}})

    for mode <- ~w(idea kanban graph gantt) do
      render_click(view, "switch-view", %{"view" => mode})
      render_click(view, "spec-add-item", %{"project" => project, "section" => "brief"})
      render_submit(view, "spec-save", params)
      assert File.read!(journal) == bytes
    end

    render_click(view, "switch-view", %{"view" => "design"})
    render_submit(view, "spec-save", Map.put(params, "project", "github:other/project"))
    render_click(view, "spec-add-item", %{"project" => project, "section" => "architecture"})
    render_change(view, "spec-edit", Map.put(params, "document_id", "another-document"))
    render_change(view, "spec-edit", Map.put(params, "storage_revision", "0"))
    assert :sys.get_state(view.pid).socket.assigns.specification_draft == saved["draft"]
    assert File.read!(journal) == bytes
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated", 8))
    render_submit(view, "spec-save", params)
    render_click(view, "spec-add-item", %{"project" => project, "section" => "brief"})
    assert :sys.get_state(view.pid).socket.assigns.specification_draft == saved["draft"]
    assert File.read!(journal) == bytes
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    assert :sys.get_state(ctx.intake).records == %{}
    refute_receive {:settings_command, _}
  end

  @tag :specification_fixture
  @tag read_only: true
  test "read-only Design presents a saved specification without enabling or accepting edits", ctx do
    view = authorized_board_view()
    project = "github:example/fixture"
    auth = :sys.get_state(view.pid).socket.assigns.auth
    document = Document.new(project)
    {:ok, document} = Document.add(document, "brief", "items")
    document = put_in(document, ["sections", "brief", "items", Access.at(0), "body"], "Read-only project scope.")
    assert {:ok, %{"storage_revision" => 1}} = FixtureSpecification.save(project, 0, document, auth)
    journal = Path.join(ctx.specification_root, "journal.json")
    bytes = File.read!(journal)
    render_click(view, "switch-view", %{"view" => "design"})
    assert has_element?(view, ".specification-form textarea", "Read-only project scope.")
    assert has_element?(view, ".specification-form fieldset[disabled]")
    render_submit(view, "spec-save", specification_params(view))
    render_click(view, "spec-add-item", %{"project" => project, "section" => "brief"})
    render_click(view, "spec-confirm-review", %{"project" => project, "storage_revision" => "1"})
    assert File.read!(journal) == bytes
    assert saved_specification(view)["review_count"] == 0
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  @tag :specification_fixture
  @tag :assurance_fixture
  test "a historical graph blocks specification writes even with retained Design selection", ctx do
    view = authorized_board_view()
    project = "github:example/fixture"
    render_click(view, "switch-view", %{"view" => "design"})
    render_click(view, "spec-add-item", %{"project" => project, "section" => "brief"})
    [item] = :sys.get_state(view.pid).socket.assigns.specification_draft["sections"]["brief"]["items"]
    values = %{"items" => %{item["id"] => %{"body" => "Authorized current specification."}}}
    view |> form(".specification-form", values) |> render_submit()
    saved = saved_specification(view)
    params = specification_params(view) |> put_in(["items", item["id"], "body"], "Forbidden historical overwrite.")
    journal = Path.join(ctx.specification_root, "journal.json")
    bytes = File.read!(journal)

    render_click(view, "switch-view", %{"view" => "graph"})
    render_click(view, "open-assurance")
    baseline = assurance_baseline(view)
    render_click(view, "assurance-view-baseline", %{"ref" => baseline["ref"]})
    historical = :sys.get_state(view.pid).socket
    assert historical.assigns.graph_baseline["ref"] == baseline["ref"]
    retained = Phoenix.Component.assign(historical, board_view: "design")

    assert {:noreply, rejected} =
             SymphonyElixirWeb.DashboardLive.handle_event("spec-save", params, retained)

    assert rejected.assigns.specification_notice =~ "sign in to edit its specification"
    assert File.read!(journal) == bytes
    assert saved_specification(view) == saved
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}
  end

  test "legacy canvas Design navigation normalizes to Idea through Settings and unlock without entering task filters", ctx do
    {view, _html} = board_view()

    params = %{
      "project" => "github:example/fixture",
      "view" => "design",
      "priority" => "P1",
      "design_ref" => String.duplicate("a", 64),
      "design_section" => "data",
      "design_item" => "event",
      "design_task" => "github:example/fixture:2"
    }

    legacy_source = "/?" <> URI.encode_query(params)
    params = Map.put(params, "view", "idea")
    source = "/?" <> URI.encode_query(params)
    returned = "/?" <> URI.encode_query(Map.put(params, "panel", "settings"))
    render_patch(view, legacy_source)
    assert has_element?(view, "#idea-view [data-design-project='github:example/fixture']")
    refute has_element?(view, "#design-view")
    assert :sys.get_state(view.pid).socket.assigns.url_filters == Map.take(params, ~w(project view priority))
    render_click(view, "open-settings")
    render_click(view, "settings-tab", %{"tab" => "connections"})
    assert has_element?(view, "#settings-connections input[name=return_to][value='#{returned}']")
    render_click(view, "close-dialog")
    assert_patch(view, source)

    # Sign-in redirects remount through these same query parameters.
    {:ok, remounted, _html} = live(build_conn(), returned)
    render_async(remounted)
    assert has_element?(remounted, "#board-dialog[data-kind=settings]")
    render_click(remounted, "settings-tab", %{"tab" => "connections"})
    assert has_element?(remounted, "#settings-connections input[name=return_to][value='#{returned}']")
    render_click(remounted, "close-dialog")
    assert_patch(remounted, source)
    render_click(view, "board-filters", Map.take(params, ~w(project view priority)))
    assert_patch(view, source)

    render_click(view, "switch-view", %{"view" => "graph"})
    assert_patch(view, "/?" <> URI.encode_query(Map.take(params, ~w(project priority)) |> Map.put("view", "graph")))
    assert :sys.get_state(view.pid).socket.assigns.design_source_context == %{}
    render_patch(view, legacy_source)
    render_click(view, "board-filters", %{"project" => "github:other/project", "view" => "idea"})
    assert_patch(view, "/?" <> URI.encode_query(%{"project" => "github:other/project", "view" => "idea"}))
    assert :sys.get_state(view.pid).socket.assigns.design_source_context == %{}
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:design_call, _, _, _}
    refute_receive {:intake_prepared, _, _}
    refute_receive {:settings_command, _}
  end

  test "malformed or foreign Design source navigation is not retained in Settings", ctx do
    {view, _html} = board_view()
    source = %{"project" => "github:example/fixture", "view" => "design", "design_ref" => String.duplicate("a", 64), "design_section" => "data", "design_item" => "event"}

    for changes <- [%{"design_ref" => "bad"}, %{"design_section" => "outside"}, %{"design_item" => "event/invalid"}] do
      render_patch(view, "/?" <> URI.encode_query(Map.merge(source, changes)))
      assert has_element?(view, "#design-view")
      refute has_element?(view, "#idea-view, #chat-app, [data-design-project]")
      assert :sys.get_state(view.pid).socket.assigns.design_source_context == %{}
      render_click(view, "open-settings")
      render_click(view, "settings-tab", %{"tab" => "connections"})
      expected = "/?" <> URI.encode_query(%{"project" => "github:example/fixture", "view" => "design", "panel" => "settings"})
      assert has_element?(view, "#settings-connections input[name=return_to][value='#{expected}']")
      render_click(view, "close-dialog")
    end

    render_patch(view, "/?" <> URI.encode_query(Map.put(source, "design_task", "github:other/project:2")))
    assert has_element?(view, "#idea-view")
    assert :sys.get_state(view.pid).socket.assigns.board_view == "idea"
    assert :sys.get_state(view.pid).socket.assigns.design_source_context.params == Map.take(source, ~w(design_ref design_section design_item))
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  test "Idea lifecycle retains Design owner replies and opens the exact task preview without executing", ctx do
    view = authorized_board_view()
    project = "github:example/fixture"
    scene = design_scene()
    ref = String.duplicate("a", 64)
    render_click(view, "switch-view", %{"view" => "idea"})
    render_hook(view, "design-load", %{"project" => project})
    assert_reply(view, %{ok: true, data: %{"storage_revision" => 0, "draft" => nil}})
    assert_receive {:design_call, :read, ^project, %{}}
    render_hook(view, "design-save", %{"project" => project, "storage_revision" => 0, "scene" => scene})
    assert_reply(view, %{ok: true, data: %{"storage_revision" => 1, "draft" => ^scene}})
    assert_receive {:design_call, :save, ^project, %{revision: 0, scene: ^scene}}
    render_hook(view, "design-save", %{"project" => project, "storage_revision" => 0, "scene" => scene})
    assert_reply(view, %{ok: false, error: "design_revision_conflict"})
    assert_receive {:design_call, :save, ^project, %{revision: 0, scene: ^scene}}
    render_hook(view, "design-review", %{"project" => project, "storage_revision" => 1})
    assert_reply(view, %{ok: true, data: %{"storage_revision" => 2, "reviewed_ref" => ^ref}})
    assert_receive {:design_call, :review, ^project, %{revision: 1}}
    render_hook(view, "design-reviewed", %{"project" => project, "ref" => ref})
    assert_reply(view, %{ok: true, data: %{"ref" => ^ref, "scene" => ^scene}})
    assert_receive {:design_call, :reviewed, ^project, %{ref: ^ref}}

    canvas_state = Agent.get(ctx.design, & &1)
    render_click(view, "switch-view", %{"view" => "design"})
    render_hook(view, "design-save", %{"project" => project, "storage_revision" => 2, "scene" => scene})
    assert_reply(view, %{ok: false, error: "design_project_mismatch"})
    assert Agent.get(ctx.design, & &1) == canvas_state
    render_click(view, "switch-view", %{"view" => "idea"})
    render_hook(view, "design-reviewed", %{"project" => project, "ref" => ref})
    assert_reply(view, %{ok: true, data: %{"ref" => ^ref, "scene" => ^scene}})
    assert_receive {:design_call, :reviewed, ^project, %{ref: ^ref}}

    params = %{"project" => project, "ref" => ref, "section" => "data", "item" => "event"}
    render_hook(view, "prepare-design-task", params)
    assert_reply(view, %{ok: true})
    assert_receive {:design_call, :source, ^project, %{ref: ^ref}}
    assert_receive {:intake_prepared, id, args}
    assert_receive {:intake_read, ^project, ^id}
    assert args["title"] == "Event"
    assert args["body"] =~ "Design source: #{ref}/fixture-design/data/event"
    assert args["body"] =~ "> Depends on: #99"
    assert has_element?(view, "#board-dialog[data-kind=new_task] .intake-preview-body", "Reviewed design excerpt")
    source_url = "/?" <> URI.encode_query(%{"project" => project, "view" => "idea", "design_ref" => ref, "design_section" => "data", "design_item" => "event"})
    assert has_element?(view, "#task-intake-panel a[href='#{source_url}']", "Reviewed idea")
    refute has_element?(view, "#task-intake-panel .intake-preview-body", "Design source:")
    assert get_in(:sys.get_state(ctx.intake).records[id], ["proposals", Access.at(0), "args", "body"]) == args["body"]
    assert has_element?(view, "#task-intake-panel button[phx-value-decision=confirm]", "Create task")
    refute has_element?(view, "#task-intake-form")
    assert :sys.get_state(view.pid).socket.assigns.intake_record_id == id
    refute_receive {:intake_decided, _, _}
    refute_receive {:settings_command, _}

    render_click(view, "close-dialog")
    render_hook(view, "prepare-design-task", params)
    assert_reply(view, %{ok: true})
    assert_receive {:design_call, :source, ^project, %{ref: ^ref}}
    assert_receive {:intake_prepared, ^id, ^args}
    assert_receive {:intake_read, ^project, ^id}
    render_click(view, "close-dialog")

    :sys.replace_state(ctx.intake, fn state ->
      update_in(state, [:records, id, "proposals"], fn [proposal] ->
        [Map.merge(proposal, %{"status" => "completed", "receipt" => %{"widgets" => [%{"type" => "receipt", "summary" => "Created from this reviewed design"}]}})]
      end)
    end)

    render_hook(view, "prepare-design-task", params)
    assert_reply(view, %{ok: true})
    assert_receive {:design_call, :source, ^project, %{ref: ^ref}}
    assert_receive {:intake_prepared, ^id, ^args}
    assert_receive {:intake_read, ^project, ^id}
    assert has_element?(view, "#task-intake-panel .action-receipt", "Created from this reviewed design")
    refute has_element?(view, "#task-intake-panel button[phx-value-decision=confirm], #task-intake-form")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:intake_decided, _, _}
    refute_receive {:settings_command, _}
  end

  test "Idea canvas events without project return bounded errors and preserve the mounted workspace", ctx do
    view = authorized_board_view()
    render_click(view, "switch-view", %{"view" => "idea"})

    for action <- ~w(design-load design-save design-review design-reviewed prepare-design-task), params <- [%{}, %{"scene" => design_scene()}] do
      render_hook(view, action, params)
      assert_reply(view, %{ok: false, error: "invalid_design_request"})
    end

    assert Agent.get(ctx.design, & &1.revision) == 0
    assert :sys.get_state(ctx.intake).records == %{}
    refute has_element?(view, "#board-dialog")
    refute_receive {:design_call, _, _, _}
    refute_receive {:intake_prepared, _, _}
    refute_receive {:settings_command, _}
    render_hook(view, "design-load", %{"project" => "github:example/fixture"})
    assert_reply(view, %{ok: true, data: %{"storage_revision" => 0, "draft" => nil}})
  end

  test "Design events reject foreign projects, other views and revoked operator identity without owner effects", ctx do
    view = authorized_board_view()
    project = "github:example/fixture"
    actions = ~w(design-load design-save design-review design-reviewed prepare-design-task)
    params = %{"project" => project, "storage_revision" => 0, "scene" => design_scene(), "ref" => String.duplicate("a", 64), "section" => "data", "item" => "event"}

    for mode <- ["kanban", "graph", "gantt", "design"] do
      render_click(view, "switch-view", %{"view" => mode})

      for action <- actions do
        render_hook(view, action, params)
        assert_reply(view, %{ok: false, error: "design_project_mismatch"})
      end
    end

    render_click(view, "switch-view", %{"view" => "idea"})

    for action <- actions do
      render_hook(view, action, Map.put(params, "project", "github:other/project"))
      assert_reply(view, %{ok: false, error: "design_project_mismatch"})
    end

    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated", 8))

    for action <- actions do
      render_hook(view, action, params)
      assert_reply(view, %{ok: false, error: "unauthorized"})
    end

    assert Agent.get(ctx.design, & &1.revision) == 0
    assert :sys.get_state(ctx.intake).records == %{}
    refute has_element?(view, "#board-dialog")
    refute_receive {:design_call, _, _, _}
    refute_receive {:intake_prepared, _, _}
    refute_receive {:settings_command, _}
  end

  @tag read_only: true
  test "read-only Idea never calls canvas storage or task preview owners", ctx do
    view = authorized_board_view()
    render_click(view, "switch-view", %{"view" => "idea"})

    for action <- ~w(design-load design-save design-review design-reviewed prepare-design-task) do
      render_hook(view, action, %{"project" => "github:example/fixture", "storage_revision" => 0, "scene" => design_scene()})
      assert_reply(view, %{ok: false, error: "read_only"})
    end

    assert Agent.get(ctx.design, & &1.revision) == 0
    assert :sys.get_state(ctx.intake).records == %{}
    refute_receive {:design_call, _, _, _}
    refute_receive {:intake_prepared, _, _}
    refute_receive {:settings_command, _}
  end

  @tag :threads_fixture
  test "Details and task conversation link to the same reviewed Idea item without task scope leaking", ctx do
    ref = String.duplicate("a", 64)
    source = "Acceptance\n\nDesign source: #{ref}/fixture-design/data/event"
    board = update_task(ctx.board, "2", &%{&1 | description: source})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    render_patch(view, "/?priority=P1&chat_task=github%3Aexample%2Ffixture%3A2&task=github%3Aexample%2Ffixture%3A2")

    params = %{
      "priority" => "P1",
      "project" => "github:example/fixture",
      "view" => "idea",
      "design_ref" => ref,
      "design_section" => "data",
      "design_item" => "event",
      "design_task" => "github:example/fixture:2"
    }

    source_path = "/?" <> URI.encode_query(params)
    assert has_element?(view, "#board-dialog a[href='#{source_path}']", "Idea source")
    refute has_element?(view, "#board-dialog .markdown-content", "Design source:")
    assert :sys.get_state(view.pid).socket.assigns.selected.description == source
    assert has_element?(view, "#selected-task-context a[href='#{source_path}']", "Idea source")
    view |> element("#selected-task-context a", "Idea source") |> render_click()
    assert_patch(view, source_path)
    assert has_element?(view, "#task-board-app[data-board-view=idea]")
    refute has_element?(view, "#board-dialog, #selected-task-context")
    assert :sys.get_state(view.pid).socket.assigns.url_filters == Map.take(params, ~w(priority project view))
    render_click(view, "switch-view", %{"view" => "graph"})
    assert_patch(view, "/?" <> URI.encode_query(Map.take(params, ~w(priority project)) |> Map.put("view", "graph")))
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  @tag :threads_fixture
  test "project overview and selected-task context guide planning without execution", ctx do
    view = authorized_board_view()
    refute has_element?(view, "#selected-task-navigation")
    assert has_element?(view, "#project-state-overview [data-status-filter=in_progress]", "Running")
    assert has_element?(view, "#project-state-overview [data-status-filter=attention]", "Needs attention")

    filters = %{"project" => "github:example/fixture", "priority" => "P1"}
    render_click(view, "board-filters", Map.put(filters, "status", "in_progress"))
    assert :sys.get_state(view.pid).socket.assigns.url_filters == Map.put(filters, "status", "in_progress")
    render_click(view, "select-task", %{"id" => "github:example/fixture:3"})
    assert has_element?(view, "#selected-task-context h2", "Running fixture")
    assert has_element?(view, "#task-chat-operator", "Running")
    assert has_element?(view, "#selected-task-navigation a", "Details")
    view |> element("#selected-task-context button[phx-click=open-task]") |> render_click()
    assert has_element?(view, "#board-dialog[data-kind=task] #task-detail-operator")
    assert has_element?(view, "#management-chat-dock #task-chat-operator")

    view |> element("#settings-button") |> render_click()
    assert has_element?(view, "#board-dialog[data-kind=settings]")
    assert :sys.get_state(view.pid).socket.assigns.chat_task_id == "github:example/fixture:3"
    render_click(view, "close-dialog")
    render_click(view, "switch-view", %{"view" => "design"})
    refute has_element?(view, "#project-state-overview, #selected-task-context, #selected-task-navigation")
    assert has_element?(view, ".board-summary[hidden]")
    render_click(view, "switch-view", %{"view" => "graph"})
    assert has_element?(view, "#selected-task-context h2", "Running fixture")
    assert :sys.get_state(view.pid).socket.assigns.chat_task_id == "github:example/fixture:3"
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  @tag :threads_fixture
  test "closing task details keeps each planning view and its selected conversation", ctx do
    work_id = String.duplicate("c", 32)
    work = %{"id" => work_id, "issue_id" => "2", "phase" => "building", "instruction" => "Retained correction", "builder_thread_id" => "retained-thread"}
    board = update_task(ctx.board, "2", &%{&1 | ledger: %{"pr_work" => %{work_id => work}}})
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    task = "github:example/fixture:2"

    for mode <- ["graph", "gantt"] do
      filters = %{"view" => mode, "project" => "github:example/fixture", "priority" => "P1"}

      params =
        Map.merge(filters, %{
          "chat_task" => task,
          "task" => task,
          "chat_session" => "work:" <> work_id,
          "design_ref" => "other-design",
          "design_section" => "data",
          "design_item" => "old-entity",
          "design_task" => "old-task"
        })

      render_patch(view, "/?" <> URI.encode_query(params))
      assert has_element?(view, "#board-dialog[data-kind=task]")
      assert :sys.get_state(view.pid).socket.assigns.board_view == mode
      render_click(view, "close-dialog")
      refute has_element?(view, "#board-dialog")
      socket = :sys.get_state(view.pid).socket
      assert socket.assigns.board_view == mode
      assert socket.assigns.chat_task_id == task
      assert socket.assigns.chat_session_id == "work:" <> work_id
      assert socket.assigns.url_filters == filters
      assert is_nil(socket.assigns.linked_task)
      assert has_element?(view, "#selected-task-context h2", "Ready fixture")
    end

    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  @tag :threads_fixture
  test "task recovery discussion binds the task composer and never submits or executes", ctx do
    view = authorized_board_view()
    task = "github:example/fixture:2"
    render_patch(view, "/?" <> URI.encode_query(%{"chat_task" => task, "chat_session" => "work:stale"}))
    render_click(view, "operator-question", %{"id" => task, "prompt" => "Launch everything"})
    assert_push_event(view, "task-chat-prompt", %{task_id: ^task, project_id: "github:example/fixture", prompt: prompt})
    assert prompt =~ "Read-only: inspect GH-2"
    refute prompt =~ "Launch everything"
    socket = :sys.get_state(view.pid).socket
    assert socket.assigns.chat_task_id == task
    assert is_nil(socket.assigns.chat_session_id)
    refute has_element?(view, "#board-dialog")
    assert has_element?(view, "#chat-app[data-task-id='#{task}']")
    chats = Agent.get(Endpoint.config(:thread_fixture), & &1)
    assert Enum.all?(Map.values(chats), &(&1["messages"] == []))
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}

    render_click(view, "operator-question", %{"id" => "unknown"})
    refute_push_event(view, "task-chat-prompt", %{})
    render_click(view, "switch-view", %{"view" => "design"})
    render_click(view, "operator-question", %{"id" => task})
    refute_push_event(view, "task-chat-prompt", %{})
  end

  test "planning views share task focus, filters and links without dispatch", ctx do
    view = authorized_board_view()
    filters = %{"project" => "github:example/fixture", "priority" => "P1"}
    render_patch(view, "/?" <> URI.encode_query(Map.put(filters, "chat_task", "github:example/fixture:2")))

    assert has_element?(view, "#board-project-picker + #board-view-picker")
    assert has_element?(view, "[data-mobile-filter-toggle][aria-expanded=false][aria-controls=board-filter-panel]")
    assert has_element?(view, "#view-kanban[aria-current=page]")
    assert has_element?(view, ".board-summary #selected-task-navigation[data-selected-task-id='github:example/fixture:2'] [data-task-navigation-label]", "GH-2")
    assert has_element?(view, "#selected-task-navigation [data-board-view-link=graph][data-board-view-task='github:example/fixture:2']")
    assert has_element?(view, "#selected-task-navigation [data-board-view-link=gantt]")
    refute has_element?(view, "#selected-task-navigation [data-board-view-link=kanban]")
    refute has_element?(view, "#workflow-graph-button, #new-task-button, .lane-add")

    view |> element("#selected-task-navigation [data-board-view-link=graph]") |> render_click()
    assert has_element?(view, "#task-board-app[data-board-view=graph]")
    assert has_element?(view, "#graph-view #workflow-graph")
    refute has_element?(view, ".plan-inspector")
    refute has_element?(view, "#selected-task-navigation [data-board-view-link=graph]")
    assert has_element?(view, "#selected-task-navigation [data-board-view-link=kanban]")
    assert has_element?(view, "#selected-task-navigation [data-board-view-link=gantt]")
    refute has_element?(view, "#kanban-view .task-card")
    assert has_element?(view, "#task-board-app[data-task-catalog]")
    refute has_element?(view, "#board-dialog")
    assert :sys.get_state(view.pid).socket.assigns.chat_task_id == "github:example/fixture:2"
    assert :sys.get_state(view.pid).socket.assigns.url_filters == Map.put(filters, "view", "graph")

    view |> element("#selected-task-navigation [data-board-view-link=gantt]") |> render_click()
    assert has_element?(view, "#task-board-app[data-board-view=gantt]")
    assert has_element?(view, "#gantt-view")
    refute has_element?(view, ".plan-inspector, #selected-task-navigation [data-board-view-link=gantt]")
    assert has_element?(view, "#selected-task-navigation [data-board-view-link=graph]")
    assert has_element?(view, "#selected-task-navigation [data-board-view-link=kanban]")
    assert :sys.get_state(view.pid).socket.assigns.chat_task_id == "github:example/fixture:2"
    render_click(view, "switch-view", %{"view" => "kanban", "id" => "github:example/fixture:2"})
    assert has_element?(view, "#view-kanban[aria-current=page]")
    refute has_element?(view, "#kanban-view[hidden]")
    assert :sys.get_state(view.pid).socket.assigns.url_filters == filters
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_receive {:settings_command, _}
  end

  @tag :threads_fixture
  @tag :navigation_reads
  test "planning selection reuses board and project activity while refreshes remain authoritative", ctx do
    owner = self()

    configure_board_loaders(
      fn server, _ ->
        send(owner, :board_read)
        GenServer.call(server, :board)
      end,
      fn ->
        send(owner, :snapshot_read)
        ctx.board.runtime
      end
    )

    :ok = BoardCache.put(BoardCache.scope(ctx.runtime), ctx.board)
    view = authorized_board_view()

    # Isolate navigation reads from unrelated runtime broadcasts.
    :sys.replace_state(view.pid, fn state ->
      :ok = Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "observability:dashboard")
      state
    end)

    render_click(view, "switch-view", %{"view" => "graph"})
    assert_push_event(view, "focus-plan-task", %{id: nil, view: "graph"})
    render(view)
    drain_navigation_reads()

    for id <- ["1", "2", "3", "2"] do
      task_id = "github:example/fixture:#{id}"
      render_click(view, "select-plan-task", %{"id" => task_id})
      assert :sys.get_state(view.pid).socket.assigns.chat_task_id == task_id
      assert_receive {:chat_read, :ensure_conversation}
      refute_push_event(view, "focus-plan-task", %{id: ^task_id, view: "graph"})
      refute_push_event(view, "focus-chat-session", %{})
    end

    render_patch(view, "/?" <> URI.encode_query(%{"view" => "gantt", "chat_task" => "github:example/fixture:2"}))
    assert_push_event(view, "focus-plan-task", %{id: "github:example/fixture:2", view: "gantt"})
    refute_received {:chat_read, :projects}
    refute_received {:chat_read, :list}
    refute_received :board_read
    refute_received :snapshot_read
    assert :sys.get_state(view.pid).socket.assigns.board == ctx.board
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0

    # Both live list notifications and the periodic/explicit refresh retain
    # their reads; only navigation is removed from the refresh path.
    send(view.pid, {:chat_list_updated, "github:example/fixture"})
    render(view)
    assert_receive {:chat_read, :list}
    drain_navigation_reads()

    send(view.pid, :refresh_board)
    render_async(view)
    assert_receive :board_read
    assert_receive {:chat_read, :list}
    drain_navigation_reads()

    render_click(view, "refresh")
    render_async(view)
    assert_receive :board_read
    assert_receive {:chat_read, :list}
    refute_received :snapshot_read

    revision = :sys.get_state(view.pid).socket.assigns.payload_revision
    send(view.pid, :observability_updated)
    render(view)
    assert_receive :snapshot_read
    assert :sys.get_state(view.pid).socket.assigns.payload_revision == revision + 1
  end

  @tag :assurance_fixture
  @tag :threads_fixture
  test "coverage forms persist scope, link current tasks and compare a read-only graph baseline", ctx do
    view = authorized_board_view()
    task_id = "github:example/fixture:2"
    render_click(view, "select-plan-task", %{"id" => task_id})
    view |> element("#coverage-button") |> render_click()
    assert has_element?(view, "#board-dialog[data-kind=assurance] #assurance-workspace")

    view
    |> form("form[phx-submit=assurance-save-requirement]", %{"title" => "Reject expired tokens", "kind" => "functional"})
    |> render_submit()

    requirement = hd(assurance_snapshot(view)["draft"]["requirements"])

    view
    |> form("form[phx-submit=assurance-save-criterion]", %{"text" => "An expired token leaves the password unchanged", "required_checks" => "token-expiry\nsecurity"})
    |> render_submit()

    criterion = hd(hd(assurance_snapshot(view)["draft"]["requirements"])["criteria"])
    view |> element("form[phx-submit=assurance-link-task]") |> render_submit()
    linked = hd(assurance_snapshot(view)["draft"]["task_links"])
    assert linked["task_id"] == task_id
    assert linked["task_revision"] == SymphonyElixirWeb.AssuranceObservations.revision(Enum.find(ctx.board.tasks, &(&1.id == task_id)))
    refute linked["task_revision"] == "browser-supplied"
    assert has_element?(view, ".assurance-state", "Unverified")

    assurance_submit(view, "save-requirement", %{"requirement_id" => requirement["id"], "title" => "Reject expired tokens safely", "kind" => "nonfunctional"})

    assurance_submit(view, "save-criterion", %{
      "requirement_id" => requirement["id"],
      "criterion_id" => criterion["id"],
      "text" => "Expired tokens leave both password and sessions unchanged",
      "required_checks" => "token-expiry\nsecurity"
    })

    render_click(view, "assurance-gaps", %{"only" => "true"})
    assert :sys.get_state(view.pid).socket.assigns.assurance_gaps
    render_click(view, "assurance-tab", %{"tab" => "versions"})
    view |> element("form[phx-submit=assurance-save-baseline]") |> render_submit()
    baseline = assurance_snapshot(view)["reviewed"]
    assert is_map(baseline["graph_snapshot"])
    assert baseline["document"]["task_links"] == [linked]

    changed = changed_graph_title(ctx.board, "2", "Ready fixture revised")
    refresh(view, ctx.runtime, changed)
    render_click(view, "assurance-compare", %{"ref" => baseline["ref"]})
    difference = :sys.get_state(view.pid).socket.assigns.assurance_difference
    assert ("task:" <> task_id) in difference["graph"]["nodes"]["changed"]
    assert has_element?(view, ".assurance-difference", "graph.nodes")

    render_click(view, "assurance-view-baseline", %{"ref" => baseline["ref"]})
    assert has_element?(view, "#task-board-app[data-board-view=graph]")
    assert has_element?(view, ".graph-version-notice", "Status is from this snapshot")
    assert has_element?(view, "#workflow-graph[data-graph-historical=true]")
    assert has_element?(view, "#workflow-graph[data-projection-key^='#{baseline["ref"]}|']")
    refute has_element?(view, "#kanban-view .task-card")
    assert has_element?(view, "[data-plan-task-id='#{task_id}'] .plan-node-title", "Ready fixture")
    refute has_element?(view, "[data-plan-task-id='#{task_id}'] .plan-node-title", "Ready fixture revised")
    render_click(view, "select-plan-task", %{"id" => "github:example/fixture:1"})
    assert :sys.get_state(view.pid).socket.assigns.chat_task_id == task_id
    assert :sys.get_state(view.pid).socket.assigns.graph_history_task == "github:example/fixture:1"

    before = :sys.get_state(ctx.assurance).journal
    assurance_submit(view, "remove-requirement", %{"id" => requirement["id"]})
    assert :sys.get_state(ctx.assurance).journal == before
    render_click(view, "open-card", %{"id" => task_id})
    refute has_element?(view, "#board-dialog[data-kind=task]")

    render_click(view, "live-graph")
    refute has_element?(view, ".graph-version-notice")
    assert has_element?(view, "#workflow-graph[data-graph-historical=false]")
    assert is_nil(:sys.get_state(view.pid).socket.assigns.graph_baseline)
    assert has_element?(view, "[data-plan-task-id='#{task_id}'] .plan-node-title", "Ready fixture revised")
    render_click(view, "open-assurance")
    render_click(view, "assurance-tab", %{"tab" => "requirements"})
    assurance_submit(view, "unlink-task", %{"task_id" => task_id, "criterion_id" => criterion["id"]})
    assurance_submit(view, "remove-criterion", %{"requirement_id" => requirement["id"], "id" => criterion["id"]})
    assurance_submit(view, "remove-requirement", %{"id" => requirement["id"]})
    assert assurance_snapshot(view)["draft"]["requirements"] == []
    assert assurance_snapshot(view)["draft"]["task_links"] == []
    assert {:ok, ^baseline} = Store.reviewed("github:example/fixture", baseline["ref"], live_auth(view), ctx.assurance)
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    assert Enum.all?(Map.values(Agent.get(ctx.threads, & &1)), &(&1["messages"] == []))
    refute_received {:settings_command, _}
    refute_received {:intake_prepared, _, _}
    refute_received {:intake_decided, _, _}
  end

  @tag :assurance_fixture
  test "coverage rejects competing revisions, historical edits and unauthenticated writes", ctx do
    view = authorized_board_view()
    render_click(view, "open-assurance")
    assurance_submit(view, "save-requirement", %{"title" => "Original outcome", "kind" => "functional"})
    saved = assurance_snapshot(view)
    requirement = hd(saved["draft"]["requirements"])
    competing = put_in(saved["draft"], ["requirements", Access.at(0), "title"], "Concurrent outcome")
    assert {:ok, latest} = Store.save("github:example/fixture", saved["storage_revision"], competing, live_auth(view), ctx.assurance)

    render_submit(view, "assurance-save-requirement", %{
      "storage_revision" => to_string(saved["storage_revision"]),
      "requirement_id" => requirement["id"],
      "title" => "Stale overwrite",
      "kind" => "functional"
    })

    assert has_element?(view, ".assurance-error", "another session")
    assert assurance_snapshot(view)["draft"] == competing
    assert assurance_snapshot(view)["storage_revision"] == latest["storage_revision"]

    assurance_submit(view, "save-criterion", %{"requirement_id" => requirement["id"], "text" => "A request is rejected", "required_checks" => "rejection"})
    assurance_submit(view, "save-baseline", %{})
    baseline = assurance_snapshot(view)["reviewed"]
    render_click(view, "assurance-select-baseline", %{"ref" => baseline["ref"]})
    before = :sys.get_state(ctx.assurance).journal
    refute has_element?(view, "form[phx-submit=assurance-save-requirement]")
    assurance_submit(view, "remove-requirement", %{"id" => requirement["id"]})
    assert :sys.get_state(ctx.assurance).journal == before

    {unauthorized, _} = board_view()
    refute has_element?(unauthorized, "#coverage-button")
    render_click(unauthorized, "open-assurance")
    render_submit(unauthorized, "assurance-save-requirement", %{"storage_revision" => to_string(before["storage_revision"]), "title" => "Forged outcome", "kind" => "functional"})
    assert has_element?(unauthorized, ".assurance-error", "cannot edit")
    assert :sys.get_state(ctx.assurance).journal == before

    render_click(view, "assurance-select-baseline", %{"ref" => ""})
    readonly = Map.put(ctx.board, :read_only, true)
    refresh(view, ctx.runtime, readonly)
    assurance_submit(view, "remove-requirement", %{"id" => requirement["id"]})
    assert :sys.get_state(ctx.assurance).journal == before
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}
    refute_received {:intake_prepared, _, _}
  end

  @tag :assurance_fixture
  test "prerequisite annotation forms persist metadata without changing source edges or dispatch", ctx do
    source = Enum.map(issues(), fn issue -> if issue.id == "1", do: %{issue | description: "Consumes an agreed contract\nDepends on: #2"}, else: issue end)
    board = TaskBoard.project(source, ctx.board.runtime, ctx.board.control, Config.settings!())
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    task = "github:example/fixture:1"
    prerequisite = "github:example/fixture:2"
    render_click(view, "select-plan-task", %{"id" => task})
    render_click(view, "open-assurance")
    assert has_element?(view, "form[phx-submit=assurance-save-dependency]")
    view |> form("form[phx-submit=assurance-save-dependency]", %{"reason" => "Consumers need an agreed interface", "output" => "Reviewed API contract"}) |> render_submit()

    assert assurance_snapshot(view)["draft"]["dependencies"] == [
             %{"task_id" => task, "depends_on" => prerequisite, "reason" => "Consumers need an agreed interface", "output" => "Reviewed API contract", "reviewed_ref" => nil}
           ]

    assert :sys.get_state(view.pid).socket.assigns.board.workflow_graph == board.workflow_graph
    view |> element("[phx-click=assurance-remove-dependency]") |> render_click()
    assert assurance_snapshot(view)["draft"]["dependencies"] == []
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    assert GenServer.call(ctx.runtime, :board).workflow_graph == board.workflow_graph
    refute_received {:settings_command, _}
    refute_received {:intake_prepared, _, _}
  end

  @tag :assurance_fixture
  @tag :threads_fixture
  test "graph groups reset cleanly and global search explicitly focuses a task outside filters" do
    view = authorized_board_view()
    render_click(view, "switch-view", %{"view" => "graph", "filters" => %{"q" => "Backlog"}})
    render_click(view, "graph-options", %{"mode" => "overview"})
    group = hd(:sys.get_state(view.pid).socket.assigns.graph_index.groups["milestone"].nodes)["id"]
    render_click(view, "graph-options", %{"mode" => "tasks", "group" => group})
    view |> form("form[phx-change=graph-options]", %{"group_by" => "task_kind"}) |> render_change()
    options = :sys.get_state(view.pid).socket.assigns.graph_options
    assert options["group_by"] == "task_kind"
    refute options["group"]
    assert has_element?(view, "[data-plan-task-id='github:example/fixture:1']")

    view |> form("form[phx-submit=graph-search]", %{"query" => "Ready fixture"}) |> render_submit()
    task_id = "github:example/fixture:2"
    assert has_element?(view, "[data-graph-search-result][phx-value-id='#{task_id}']", "Outside filters")
    view |> element("[data-graph-search-result][phx-value-id='#{task_id}']") |> render_click()
    assert_push_event(view, "focus-plan-task", %{id: ^task_id, view: "graph"})
    assert :sys.get_state(view.pid).socket.assigns.chat_task_id == task_id
    assert :sys.get_state(view.pid).socket.assigns.url_filters["q"] == "Backlog"
    assert :sys.get_state(view.pid).socket.assigns.graph_options["mode"] == "focus"
    assert has_element?(view, "[data-plan-task-id='#{task_id}'][data-filtered=true]")
    refute has_element?(view, "#kanban-view .task-card")
    catalog = view |> element("#task-board-app") |> render() |> Floki.parse_fragment!() |> Floki.attribute("data-task-catalog") |> hd() |> Jason.decode!()
    assert Enum.map(catalog, & &1["taskId"]) |> Enum.sort() == Enum.map(1..5, &"github:example/fixture:#{&1}")
    refute_received {:settings_command, _}
  end

  @tag :assurance_fixture
  @tag :threads_fixture
  test "task selections reuse the indexed graph without assurance store calls and source failures invalidate it", ctx do
    view = authorized_board_view()
    render_click(view, "switch-view", %{"view" => "graph"})
    owner = self()

    :sys.replace_state(view.pid, fn state ->
      :ok = Phoenix.PubSub.unsubscribe(SymphonyElixir.PubSub, "observability:dashboard")
      Process.put(:assurance_fixture_graph_index, state.socket.assigns.graph_index)
      state
    end)

    assert :erlang.trace(ctx.assurance, true, [:receive, {:tracer, self()}]) == 1

    for id <- ~w(1 2 3 2) do
      render_click(view, "select-plan-task", %{"id" => "github:example/fixture:#{id}"})

      :sys.replace_state(view.pid, fn state ->
        send(owner, {:graph_index_reused, :erts_debug.same(Process.get(:assurance_fixture_graph_index), state.socket.assigns.graph_index)})
        state
      end)

      assert_receive {:graph_index_reused, true}
    end

    refute_receive {:trace, _, :receive, {:"$gen_call", _, _}}, 20
    assert :erlang.trace(ctx.assurance, false, [:receive]) == 1
    first = :sys.get_state(view.pid).socket.assigns.graph_index_key
    refresh(view, ctx.runtime, Map.put(ctx.board, :source_error, "Tracker unavailable"))
    current = :sys.get_state(view.pid).socket.assigns
    refute current.graph_index_key == first
    refute current.graph_index.available
    assert has_element?(view, "#workflow-graph .board-warning")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}
  end

  @tag :assurance_fixture
  @tag :threads_fixture
  test "focused selection retains its anchor and layout until explicitly refocused", ctx do
    source = Enum.map(issues(), fn issue -> if issue.id == "1", do: %{issue | description: "Consumes a contract\nDepends on: #2"}, else: issue end)
    board = TaskBoard.project(source, ctx.board.runtime, ctx.board.control, Config.settings!())
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    first = "github:example/fixture:1"
    second = "github:example/fixture:2"
    render_click(view, "switch-view", %{"view" => "graph", "id" => first})
    assert :sys.get_state(view.pid).socket.assigns.graph_options["anchor"] == first
    positions = graph_positions(view)
    render_click(view, "select-plan-task", %{"id" => second})
    assert :sys.get_state(view.pid).socket.assigns.chat_task_id == second
    assert :sys.get_state(view.pid).socket.assigns.graph_options["anchor"] == first
    assert graph_positions(view) == positions
    render_click(view, "graph-options", %{"mode" => "focus"})
    assert :sys.get_state(view.pid).socket.assigns.graph_options["anchor"] == second
    render_click(view, "select-plan-task", %{"id" => first, "focus" => "true"})
    assert :sys.get_state(view.pid).socket.assigns.graph_options["anchor"] == first
    assert_push_event(view, "focus-plan-task", %{id: ^first, view: "graph"})
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}
  end

  defp graph_positions(view) do
    view
    |> element("#workflow-graph")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("[data-plan-node]")
    |> Enum.map(fn node -> {Floki.attribute(node, "data-node-id"), Floki.attribute(node, "transform")} end)
  end

  @tag :assurance_fixture
  @tag :threads_fixture
  test "historical search reveals tasks outside a large overview without changing current chat", ctx do
    board = large_assurance_board(ctx.board, 100)
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    current_task = "github:example/fixture:2"
    historical_task = "github:example/fixture:100"
    render_click(view, "select-plan-task", %{"id" => current_task})
    render_click(view, "open-assurance")
    baseline = assurance_baseline(view)
    render_click(view, "assurance-view-baseline", %{"ref" => baseline["ref"]})
    render_click(view, "graph-options", %{"mode" => "overview", "page" => "2"})
    refute has_element?(view, "[data-plan-task-id='#{historical_task}']")
    view |> form("form[phx-submit=graph-search]", %{"query" => "Historical task 100"}) |> render_submit()
    view |> element("[data-graph-search-result][phx-value-id='#{historical_task}']") |> render_click()

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.graph_options["mode"] == "focus"
    assert assigns.graph_options["page"] == 0
    assert is_nil(assigns.graph_options["query"])
    assert assigns.graph_history_task == historical_task
    assert assigns.chat_task_id == current_task
    assert_push_event(view, "focus-plan-task", %{id: ^historical_task, view: "graph"})
    assert has_element?(view, "#workflow-graph[data-graph-historical=true]")
    assert has_element?(view, "[data-plan-task-id='#{historical_task}'][data-selected=true]")
    assert has_element?(view, "#selected-task-navigation[data-selected-task-id='#{current_task}']")
    assert view |> element("#workflow-graph") |> render() |> Floki.parse_fragment!() |> Floki.find("[data-plan-node]") |> length() <= 80
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}
  end

  @tag :assurance_fixture
  test "expired cached source cannot be treated as a current graph comparison", ctx do
    view = authorized_board_view()
    render_click(view, "open-assurance")
    baseline = assurance_baseline(view)
    stale = Map.put(ctx.board, :generated_at, DateTime.utc_now() |> DateTime.add(-121, :second) |> DateTime.to_iso8601())
    refresh(view, ctx.runtime, stale)
    render_click(view, "assurance-tab", %{"tab" => "versions"})
    render_click(view, "assurance-compare", %{"ref" => baseline["ref"]})
    assert :sys.get_state(view.pid).socket.assigns.assurance_difference["graph_unavailable"]
    assert has_element?(view, ".assurance-difference", "comparison unavailable")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
  end

  @tag :assurance_fixture
  test "source failure makes graph comparison unavailable while preserving scope differences", ctx do
    view = authorized_board_view()
    render_click(view, "open-assurance")
    baseline = assurance_baseline(view)
    requirement = hd(assurance_snapshot(view)["draft"]["requirements"])
    assurance_submit(view, "save-requirement", %{"requirement_id" => requirement["id"], "title" => "Changed agreed scope", "kind" => "functional"})
    refresh(view, ctx.runtime, Map.put(ctx.board, :source_error, "Tracker unavailable"))
    render_click(view, "assurance-tab", %{"tab" => "versions"})
    render_click(view, "assurance-compare", %{"ref" => baseline["ref"]})
    difference = :sys.get_state(view.pid).socket.assigns.assurance_difference
    assert requirement["id"] in difference["requirements"]["changed"]
    assert difference["graph"] == %{}
    assert difference["graph_unavailable"] == true
    assert has_element?(view, ".assurance-difference", requirement["id"])
    assert has_element?(view, ".assurance-difference", "unavailable")
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}
  end

  @tag :assurance_fixture
  test "read-only source clears previously verified criterion and graph badges", ctx do
    board = reviewed_assurance_board(ctx.board)
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    seed_verified_assurance(view)
    assert has_element?(view, ".assurance-criterion", "Current evidence passed")
    assert get_in(:sys.get_state(view.pid).socket.assigns.board, [:assurance, "tasks", "github:example/fixture:2", "status"]) == "verified"
    before = :sys.get_state(ctx.assurance).journal
    readonly = board |> changed_graph_title("2", "Changed read-only task") |> Map.put(:read_only, true)
    refresh(view, ctx.runtime, readonly)
    assert_assurance_unavailable(view)
    assert :sys.get_state(ctx.assurance).journal == before
    refute_received {:settings_command, _}
  end

  @tag :assurance_fixture
  test "expired identity clears previously verified criterion and graph badges", ctx do
    board = reviewed_assurance_board(ctx.board)
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    seed_verified_assurance(view)
    assert has_element?(view, ".assurance-criterion", "Current evidence passed")
    before = :sys.get_state(ctx.assurance).journal
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated-token", 4))
    refresh(view, ctx.runtime, changed_graph_title(board, "2", "Changed unauthorized task"))
    assert_assurance_unavailable(view)
    assert :sys.get_state(ctx.assurance).journal == before
    refute_received {:settings_command, _}
  end

  defp assurance_baseline(view) do
    assurance_submit(view, "save-requirement", %{"title" => "Agreed scope", "kind" => "functional"})
    requirement = hd(assurance_snapshot(view)["draft"]["requirements"])
    assurance_submit(view, "save-criterion", %{"requirement_id" => requirement["id"], "text" => "An observable outcome", "required_checks" => "scope"})
    assurance_submit(view, "save-baseline", %{})
    assurance_snapshot(view)["reviewed"]
  end

  defp large_assurance_board(board, count) do
    source = hd(issues())

    extra =
      for n <- 6..count do
        id = to_string(n)
        %{source | id: id, identifier: "GH-" <> id, title: "Historical task " <> id, url: "https://github.com/example/fixture/issues/" <> id}
      end

    TaskBoard.project(issues() ++ extra, board.runtime, board.control, Config.settings!())
  end

  defp reviewed_assurance_board(board) do
    sha = String.duplicate("a", 40)
    base = String.duplicate("b", 40)

    work = %{
      "id" => "work",
      "head_sha" => sha,
      "base_sha" => base,
      "phase" => "owner_review",
      "goal_revision" => 1,
      "publication" => %{"pr_number" => 7, "pr_url" => "https://github.com/example/fixture/pull/7"},
      "handoff" => %{
        "work_id" => "work",
        "candidate_sha" => sha,
        "base_sha" => base,
        "goal_revision" => 1,
        "run_id" => "run",
        "review" => %{"candidate_sha" => sha, "verdict" => "approve", "findings" => []},
        "checks" => []
      }
    }

    board
    |> update_task("2", &Map.put(&1, :ledger, %{"pr_work" => %{"work" => work}}))
    |> update_task("2", &Map.put(&1, :github_status, "available"))
    |> update_task("2", &Map.put(&1, :pull_requests, [%{number: 7, url: "https://github.com/example/fixture/pull/7", head_sha: sha}]))
    |> put_in([:control, "issues", "2"], %{"pr_work" => %{"work" => work}})
  end

  defp seed_verified_assurance(view) do
    render_click(view, "select-plan-task", %{"id" => "github:example/fixture:2"})
    render_click(view, "open-assurance")
    assurance_submit(view, "save-requirement", %{"title" => "Approved change", "kind" => "functional"})
    requirement = hd(assurance_snapshot(view)["draft"]["requirements"])
    assurance_submit(view, "save-criterion", %{"requirement_id" => requirement["id"], "text" => "The candidate has independent approval", "required_checks" => "independent-review"})
    criterion = hd(hd(assurance_snapshot(view)["draft"]["requirements"])["criteria"])
    assurance_submit(view, "link-task", %{"task_id" => "github:example/fixture:2", "criterion_id" => criterion["id"]})
    assurance_submit(view, "save-baseline", %{})
  end

  defp assert_assurance_unavailable(view) do
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.assurance_projection == %{}
    for key <- [:assurance, :assurance_observations, :assurance_evidence, :assurance_baselines], do: refute(Map.has_key?(assigns.board, key))
    refute has_element?(view, ".assurance-criterion", "Current evidence passed")
    render_click(view, "switch-view", %{"view" => "graph"})
    refute has_element?(view, "[data-coverage-status=verified]")
  end

  defp assurance_fixture(%{assurance_fixture: true}) do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.join(Path.dirname(Workflow.workflow_file_path()), "assurance-live"))
    on_exit(fn -> File.rm_rf(root) end)
    store = start_supervised!({Store, name: nil, state_dir: root, project: "github:example/fixture", scope: fn -> "live-fixture" end})
    assert is_nil(:sys.get_state(store).fault)
    store
  end

  defp assurance_fixture(_context), do: nil
  defp assurance_snapshot(view), do: :sys.get_state(view.pid).socket.assigns.assurance_snapshot
  defp live_auth(view), do: :sys.get_state(view.pid).socket.assigns.auth

  defp assurance_submit(view, action, fields) do
    revision = assurance_snapshot(view)["storage_revision"] || 0
    render_submit(view, "assurance-" <> action, Map.put(fields, "storage_revision", to_string(revision)))
  end

  defp changed_graph_title(board, id, title) do
    task_id = "github:example/fixture:" <> id
    nodes = Enum.map(board.workflow_graph["nodes"], fn node -> if node["task_id"] == task_id, do: Map.put(node, "title", title), else: node end)
    board |> update_task(id, &Map.put(&1, :title, title)) |> Map.put(:workflow_graph, Map.put(board.workflow_graph, "nodes", nodes))
  end

  defp drain_navigation_reads do
    receive do
      {:chat_read, _} -> drain_navigation_reads()
      :board_read -> drain_navigation_reads()
      :snapshot_read -> drain_navigation_reads()
    after
      0 -> :ok
    end
  end

  @tag :threads_fixture
  @tag :navigation_reads
  test "cached project metadata cannot bypass a removed project or expired identity" do
    view = authorized_board_view()
    render_click(view, "select-plan-task", %{"id" => "github:example/fixture:1"})
    assert :sys.get_state(view.pid).socket.assigns.chat_id
    drain_navigation_reads()

    configured = Application.get_env(:symphony_elixir, Endpoint)
    updates = Keyword.put(configured, :navigation_fixture_error, :unknown_project)
    Application.put_env(:symphony_elixir, Endpoint, updates)
    Endpoint.config_change([{Endpoint, updates}], [])

    render_click(view, "select-plan-task", %{"id" => "github:example/fixture:2"})
    assert_receive {:chat_read, :ensure_conversation}
    assert has_element?(view, ".chat-notice", "not available in the selected project")
    refute has_element?(view, ".message-body", "Fixture")
    refute_received {:chat_read, :projects}
    refute_received {:chat_read, :list}

    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated-token", 4))
    render_click(view, "select-plan-task", %{"id" => "github:example/fixture:3"})
    assert has_element?(view, ".chat-login", "Unlock chat")
    refute_received {:chat_read, :ensure_conversation}
  end

  test "plan selection acknowledges the canonical task after accepting or rejecting an ID" do
    view = authorized_board_view()
    socket = :sys.get_state(view.pid).socket
    task_id = "github:example/fixture:2"

    assert {:reply, %{selected_task_id: ^task_id}, selected} =
             SymphonyElixirWeb.DashboardLive.handle_event("select-plan-task", %{"id" => task_id}, socket)

    assert {:reply, %{selected_task_id: ^task_id}, _} =
             SymphonyElixirWeb.DashboardLive.handle_event("select-plan-task", %{"id" => "github:other/project:99"}, selected)

    assert {:reply, %{selected_task_id: ^task_id}, _} = SymphonyElixirWeb.DashboardLive.handle_event("select-plan-task", %{}, selected)

    retained = Phoenix.Component.assign(selected, chat_session_id: "work:current", chat_id: "retained-conversation")

    assert {:reply, %{selected_task_id: ^task_id}, ^retained} =
             SymphonyElixirWeb.DashboardLive.handle_event("select-plan-task", %{"id" => "github:other/project:99"}, retained)
  end

  test "graph refresh preserves focus and title details return to the same view" do
    view = authorized_board_view()
    render_click(view, "switch-view", %{"view" => "graph", "id" => "github:example/fixture:1"})
    render_click(view, "open-card", %{"id" => "github:example/fixture:1"})
    assert has_element?(view, "#board-dialog[data-kind=task]")
    assert has_element?(view, "#graph-view #workflow-graph")
    view |> element("#close-dialog") |> render_click()
    assert has_element?(view, "#task-board-app[data-board-view=graph][data-selected-task='github:example/fixture:1']")
    send(view.pid, :refresh_board)
    render_async(view)
    assert has_element?(view, "#graph-view #workflow-graph")
    refute has_element?(view, "#board-dialog")
  end

  test "card dependency indicators link to a focused graph and malformed view is ignored" do
    view = authorized_board_view()
    assert has_element?(view, "[data-task-id='github:example/fixture:1'] .card-dependencies a[aria-label*='prerequisites']")
    view |> element("[data-task-id='github:example/fixture:1'] .card-dependencies a[title='Prerequisites · open graph']") |> render_click()
    assert has_element?(view, "#task-board-app[data-board-view=graph][data-selected-task='github:example/fixture:1']")
    render_patch(view, "/?view=untrusted")
    assert has_element?(view, "#task-board-app[data-board-view=kanban]")
    refute :sys.get_state(view.pid).socket.assigns.url_filters["view"]
  end

  test "filter changes preserve the planning view and narrow its rows" do
    view = authorized_board_view()
    render_click(view, "switch-view", %{"view" => "gantt"})
    render_click(view, "board-filters", %{"project" => "github:example/fixture", "q" => "no matching title"})
    assert has_element?(view, "#task-board-app[data-board-view=gantt]")
    assert :sys.get_state(view.pid).socket.assigns.url_filters["view"] == "gantt"
    assert has_element?(view, "#gantt-view", "No matching tasks")
  end

  @tag :threads_fixture
  test "work selection focuses its task dependencies and keeps its session across views", ctx do
    work_id = String.duplicate("a", 32)
    task_id = "github:example/fixture:2"
    node_id = "work:github:example/fixture:" <> work_id
    work = %{"id" => work_id, "issue_id" => "2", "phase" => "building", "instruction" => "Address checks", "builder_thread_id" => "retained-thread"}
    board = update_task(ctx.board, "2", &%{&1 | ledger: %{"pr_work" => %{work_id => work}}})
    graph = board.workflow_graph
    node = %{"id" => node_id, "type" => "work", "work_id" => work_id, "task_id" => task_id, "title" => "Address checks", "phase" => "building"}
    edge = %{"id" => "task-work", "type" => "contains", "source" => "task:" <> task_id, "target" => node_id}
    board = %{board | workflow_graph: %{graph | "nodes" => graph["nodes"] ++ [node], "edges" => graph["edges"] ++ [edge]}}
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    render_click(view, "switch-view", %{"view" => "graph", "id" => task_id})
    assert_push_event(view, "focus-plan-task", %{id: ^task_id, view: "graph"})
    render_click(view, "select-plan-task", %{"id" => task_id, "work_id" => work_id})
    assert :sys.get_state(view.pid).socket.assigns.chat_session_id == "work:" <> work_id
    refute_push_event(view, "focus-chat-session", %{})
    refute_push_event(view, "focus-plan-task", %{id: ^task_id, view: "graph"})
    assert has_element?(view, ".plan-node[data-node-id='task:#{task_id}'][data-selected=true]")
    refute has_element?(view, ".plan-node[data-node-id='#{node_id}'], #plan-agents-panel, [data-canvas-mode]")
    assert has_element?(view, "#workflow-graph[data-plan-mode=dependencies]")
    view |> element("#view-gantt") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.chat_session_id == "work:" <> work_id
    view |> element("#view-graph") |> render_click()
    assert has_element?(view, ".plan-node[data-node-id='task:#{task_id}'][data-selected=true]")
    refute has_element?(view, ".plan-node[data-node-id='#{node_id}']")
    render_click(view, "select-plan-task", %{"id" => task_id, "work_id" => String.duplicate("b", 32)})
    assert :sys.get_state(view.pid).socket.assigns.chat_session_id == "work:" <> work_id
    render_click(view, "select-plan-task", %{"id" => task_id})
    assert is_nil(:sys.get_state(view.pid).socket.assigns.chat_session_id)
    assert has_element?(view, ".plan-node[data-node-id='task:#{task_id}'][data-selected=true]")
    refute_receive {:settings_command, _}
  end

  test "view switching accepts the current filter draft before its debounced patch" do
    view = authorized_board_view()
    render_click(view, "switch-view", %{"view" => "graph", "filters" => %{"q" => "Backlog", "status" => "backlog"}})
    assert :sys.get_state(view.pid).socket.assigns.url_filters == %{"view" => "graph", "q" => "Backlog", "status" => "backlog"}
    assert has_element?(view, "#graph-view [data-plan-task-id='github:example/fixture:1']")
    refute has_element?(view, "#graph-view [data-plan-task-id='github:example/fixture:2']")
  end

  test "calendar drafts retain validated browser values without native control changes", ctx do
    view = authorized_board_view()
    before_control = GenServer.call(ctx.runtime, :control_snapshot)
    before_tasks = :sys.get_state(view.pid).socket.assigns.board.tasks
    anchor = Date.utc_today() |> Date.add(5) |> Date.to_iso8601()
    id = "github:example/fixture:1"
    other = "github:example/fixture:2"

    render_click(view, "change-calendar-plan", %{"anchor_on" => anchor, "durations" => %{id => 3, other => 365}})
    assert :sys.get_state(view.pid).socket.assigns.calendar_plan == %{"anchor_on" => anchor, "durations" => %{id => 3, other => 365}}
    render_click(view, "switch-view", %{"view" => "gantt", "id" => id})
    assert has_element?(view, "[data-calendar-anchor][value='#{anchor}']")
    assert has_element?(view, "[data-calendar-duration][data-calendar-task-id='#{id}'][value='3']")
    render_click(view, "switch-view", %{"view" => "graph", "id" => id})
    render_click(view, "switch-view", %{"view" => "gantt", "id" => id})
    assert has_element?(view, "[data-calendar-duration][data-calendar-task-id='#{id}'][value='3']")
    assert :sys.get_state(view.pid).socket.assigns.board.tasks == before_tasks
    assert GenServer.call(ctx.runtime, :control_snapshot) == before_control
    refute_received {:settings_command, _}
  end

  test "calendar draft validation rejects foreign durations and malformed or unbounded input", ctx do
    view = authorized_board_view()
    before_control = GenServer.call(ctx.runtime, :control_snapshot)
    known = "github:example/fixture:1"

    durations = %{
      known => 2,
      "github:example/fixture:2" => 0,
      "github:example/fixture:3" => 366,
      "github:example/fixture:4" => "2",
      "github:example/fixture:5" => 1.5,
      "github:example/other:1" => 4,
      "github:example/fixture:999" => 4
    }

    render_click(view, "change-calendar-plan", %{"anchor_on" => "not-a-date", "durations" => durations})
    assert :sys.get_state(view.pid).socket.assigns.calendar_plan == %{"anchor_on" => nil, "durations" => %{known => 2}}

    for anchor <- ["2026-99-99", Date.to_iso8601(Date.add(Date.utc_today(), 366)), Date.to_iso8601(Date.add(Date.utc_today(), -366)), nil, 1] do
      render_click(view, "change-calendar-plan", %{"anchor_on" => anchor, "durations" => []})
      assert :sys.get_state(view.pid).socket.assigns.calendar_plan == %{"anchor_on" => nil, "durations" => %{}}
    end

    for days <- [-1, nil, true] do
      render_click(view, "change-calendar-plan", %{"durations" => %{known => days}})
      assert :sys.get_state(view.pid).socket.assigns.calendar_plan["durations"] == %{}
    end

    for offset <- [-365, 365] do
      anchor = Date.to_iso8601(Date.add(Date.utc_today(), offset))
      render_click(view, "change-calendar-plan", %{"anchor_on" => anchor, "durations" => "invalid"})
      assert :sys.get_state(view.pid).socket.assigns.calendar_plan == %{"anchor_on" => anchor, "durations" => %{}}
    end

    socket = :sys.get_state(view.pid).socket
    assert {:noreply, ^socket} = SymphonyElixirWeb.DashboardLive.handle_event("change-calendar-plan", [], socket)
    assert GenServer.call(ctx.runtime, :control_snapshot) == before_control
    refute_received {:settings_command, _}
  end

  test "task intent and routing labels do not appear as subject tags", ctx do
    board = update_task(ctx.board, "1", &Map.put(&1, :labels, ["kind:testing", "category:performance", "symphony:ready", "priority:p1", "work:operations", "ready"]))
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    card = element(view, "[data-task-id='github:example/fixture:1']") |> render()
    assert card =~ "category:performance"
    refute card =~ "kind:testing"
    refute card =~ "symphony:ready"
    refute card =~ "work:operations"
    refute card =~ "priority:p1"
  end

  test "oversized submitted values cannot become shortened proposals" do
    view = authorized_board_view()
    render_click(view, "new-task")
    params = Map.put(intake_fields(), "description", String.duplicate("z", 4001))
    view |> form("#task-intake-form", task: params) |> render_submit()
    assert render(view) =~ "Description exceeds the 4000-byte limit"
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

  test "automatic intake history updates include other submissions without replacing a draft" do
    view = authorized_board_view()
    render_click(view, "new-task")
    view |> form("#task-intake-form", task: Map.put(intake_fields(), "title", "My draft")) |> render_change()
    other_id = String.duplicate("b", 32)
    {:ok, args} = SymphonyElixir.TaskDraft.action_args(Map.put(intake_fields(), "title", "Other window task"))
    {:ok, _} = IntakeApi.prepare("github:example/fixture", other_id, args, %{})
    send(view.pid, :refresh_board)
    render_async(view)
    assert has_element?(view, ".intake-history-item", "Other window task")
    assert has_element?(view, "#task-intake-form input[value='My draft']")
    refute has_element?(view, "#task-action-preview")
    {:ok, _} = IntakeApi.decide("github:example/fixture", other_id, "confirm", %{})
    send(view.pid, {:chat_list_updated, "github:example/fixture"})
    render(view)
    assert has_element?(view, ".intake-history-item[phx-value-id='#{other_id}']", "completed")
    assert has_element?(view, "#task-intake-form input[value='My draft']")
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
    expected = Enum.map_join(["design-canvas.js", "design-sync.js", "dashboard.js"], "\n", &File.read!("priv/static/" <> &1))
    assert response(conn, 200) == expected
    assert conn.resp_body =~ "SymphonyDesignCanvas"
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

  test "task kinds appear as classifications and persist in filter URLs without dispatch", ctx do
    board = update_task(ctx.board, "2", &(&1 |> Map.put(:labels, ["kind:testing"]) |> Map.put(:task_kind, "testing")))
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    assert has_element?(view, "#filter-kind[role=combobox][aria-label='Kind filter']")
    assert has_element?(view, "article[data-task-id='github:example/fixture:2'][data-kind=testing] .card-task-kind", "Testing")
    refute has_element?(view, "button[phx-click=start-deployment]")
    render_click(view, "board-filters", %{"project" => "github:example/fixture", "kind" => "testing", "status" => "work"})
    assert_patch(view, "/?" <> URI.encode_query(%{"project" => "github:example/fixture", "kind" => "testing", "status" => "work"}))
    view |> element("article[data-task-id='github:example/fixture:2'] .card-title") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.url_filters["kind"] == "testing"
    assert has_element?(view, "#board-dialog")
    refute_received {:settings_command, _}
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
    assert length(Floki.find(card_html, card <> " .card-pull-requests > .pull-request-evidence")) == 3

    assert has_element?(view, card <> " .card-pull-requests > [data-pr-number='10']")
    refute has_element?(view, card <> " .card-pr-overflow")
    refute has_element?(view, card <> " .card-more-links")
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
    refute has_element?(view, ".board-warning", "PR checks could not be read")
    assert has_element?(view, ".board-sync-note[title='PR checks could not be read']", "Some PR details unavailable")
    assert has_element?(view, "[data-task-id='github:example/fixture:2'] .pull-request-checks", "CI: Unknown")
    assert has_element?(view, "[data-task-id='github:example/fixture:2'] .pull-request-checks", "GitHub review: Unknown")
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
          {"prepare-command", %{"action" => "accept_task", "id" => "github:example/fixture:4"}},
          {"move-task", %{"id" => "github:example/fixture:4", "stage" => "done"}},
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

  @tag :assurance_fixture
  test "historical graph URLs clear pending commands and reject a retained forged confirmation", ctx do
    :ok = GenServer.call(ctx.runtime, {:board, settings_board(ctx.board)})
    view = authorized_board_view()
    render_click(view, "open-assurance")
    baseline = assurance_baseline(view)
    render_click(view, "switch-view", %{"view" => "graph"})
    render_click(view, "open-settings")
    render_submit(view, "save-concurrency", %{"limit" => "2"})
    pending = :sys.get_state(view.pid).socket.assigns.pending_command
    assert pending.action == "set_concurrency"
    assert pending.revision == 0
    assert has_element?(view, "#board-dialog button[phx-click=confirm-command]")

    render_patch(view, "/?" <> URI.encode_query(%{"view" => "graph", "baseline" => baseline["ref"]}))
    historical = :sys.get_state(view.pid).socket
    assert historical.assigns.graph_baseline["ref"] == baseline["ref"]
    assert is_nil(historical.assigns.pending_command)
    refute has_element?(view, "#board-dialog button[phx-click=confirm-command]")

    retained = Phoenix.Component.assign(historical, pending_command: pending, dialog: :confirm)

    assert {:noreply, rejected} =
             SymphonyElixirWeb.DashboardLive.handle_event("confirm-command", %{}, retained)

    assert is_nil(rejected.assigns.pending_command)
    assert is_nil(rejected.assigns.dialog)
    assert rejected.assigns.notice =~ "This board is read-only"
    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}

    for {event, params} <- [
          {"new-task", %{}},
          {"prepare-command", %{"action" => "pause"}},
          {"save-concurrency", %{"limit" => "1"}}
        ] do
      render_click(view, event, params)
      assert render(view) =~ "This board is read-only"
    end

    assert GenServer.call(ctx.runtime, :control_snapshot)["revision"] == 0
    refute_received {:settings_command, _}
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

  test "dropping Review into Done submits directly with exact evidence", ctx do
    board = settings_board(ctx.board)
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    render_click(view, "move-task", %{"id" => "github:example/fixture:4", "stage" => "done"})
    refute has_element?(view, "#board-dialog")
    assert_receive {:settings_command, command}
    assert command["action"] == "accept_task"
    assert command["issue_id"] == "4"
    assert command["expected_candidate_sha"] == String.duplicate("a", 40)
    assert command["expected_updated_at"] == "2026-09-14T11:00:00Z"
    assert command["expected_revision"] == 0
    assert render(view) =~ "Accepted. This issue is Done."
    render_click(view, "confirm-command")
    refute_receive {:settings_command, _}
  end

  test "Accept button submits directly and closes only the task details", ctx do
    :ok = GenServer.call(ctx.runtime, {:board, settings_board(ctx.board)})
    view = authorized_board_view()
    open_task(view, "4")
    view |> element("#board-dialog button[phx-value-action=accept_task]") |> render_click()
    assert_receive {:settings_command, %{"action" => "accept_task", "issue_id" => "4"}}
    refute has_element?(view, "#board-dialog")
    assert render(view) =~ "Accepted. This issue is Done."
    assert has_element?(view, ".task-card[data-task-id='github:example/fixture:4'][aria-current=true]")
  end

  test "uncertain acceptance replays the same request and stale evidence needs a fresh human click", ctx do
    board = settings_board(ctx.board)
    :ok = GenServer.call(ctx.runtime, {:board, board})
    :sys.replace_state(ctx.runtime, &Map.put(&1, :command_error, :unavailable))
    view = authorized_board_view()
    open_task(view, "4")
    view |> element("#board-dialog button[phx-value-action=accept_task]") |> render_click()
    assert_receive {:settings_command, original}
    assert render(view) =~ "Acceptance could not be confirmed"
    refute has_element?(view, "[phx-click=confirm-command]")
    render_async(view)
    render_click(view, "close-dialog")
    newer = put_in(board.control["revision"], 1)
    refresh(view, ctx.runtime, newer)
    :sys.replace_state(ctx.runtime, &Map.delete(&1, :command_error))
    render_click(view, "move-task", %{"id" => "github:example/fixture:4", "stage" => "done"})
    assert_receive {:settings_command, ^original}
    assert render(view) =~ "Review its updated details"
    render_async(view)
    render_click(view, "move-task", %{"id" => "github:example/fixture:4", "stage" => "done"})
    assert_receive {:settings_command, fresh}
    assert fresh["expected_revision"] == 1
    refute fresh["command_id"] == original["command_id"]
  end

  test "unavailable acceptance eligibility remains Review and unauthorized acceptance never dispatches", ctx do
    :ok = GenServer.call(ctx.runtime, {:board, settings_board(ctx.board)})
    :sys.replace_state(ctx.runtime, &Map.put(&1, :command_error, :task_not_reviewable))
    view = authorized_board_view()
    render_click(view, "move-task", %{"id" => "github:example/fixture:4", "stage" => "done"})
    assert_receive {:settings_command, _}
    assert render(view) =~ "task_not_reviewable"
    refute render(view) =~ "Accepted. This issue is Done."
    assert has_element?(view, "#lane-review .task-card[data-task-id='github:example/fixture:4']")
    {unauthorized, _} = board_view()
    render_click(unauthorized, "move-task", %{"id" => "github:example/fixture:4", "stage" => "done"})
    assert render(unauthorized) =~ "Sign in"
    refute_receive {:settings_command, _}
  end

  test "return to Work includes human corrections and only submits after confirmation", ctx do
    board = settings_board(ctx.board)
    :ok = GenServer.call(ctx.runtime, {:board, board})
    view = authorized_board_view()
    render_click(view, "move-task", %{"id" => "github:example/fixture:4", "stage" => "work"})
    assert has_element?(view, "#task-rework-form textarea[aria-label=Corrections]")
    render_submit(view, "prepare-rework", %{"rework" => %{"work_id" => "new", "instruction" => "Fix the README example"}})
    assert has_element?(view, "#board-dialog .rework-preview", "Fix the README example")
    refute_receive {:settings_command, _}
    render_click(view, "confirm-command")
    assert_receive {:settings_command, command}
    assert command["action"] == "create_pr_work"
    assert command["instruction"] == "Fix the README example"
    assert command["issue_id"] == "4"
    assert command["feedback"] == []
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

  defp design_scene do
    %{
      "document_id" => "fixture-design",
      "boards" => %{
        "data" => %{
          "elements" => [
            %{"id" => "event-node", "isDeleted" => false, "customData" => %{"symphony" => %{"id" => "event", "role" => "node", "kind" => "entity"}}},
            %{"id" => "event-title", "isDeleted" => false, "text" => "Event", "customData" => %{"symphony" => %{"id" => "event", "role" => "title"}}},
            %{"id" => "event-body", "isDeleted" => false, "originalText" => "id: UUID\nDepends on: #99", "customData" => %{"symphony" => %{"id" => "event", "role" => "body"}}}
          ]
        }
      }
    }
  end

  defp specification_fixture(%{specification_fixture: true}) do
    path = Path.join(System.tmp_dir!(), "symphony-live-specification-#{System.unique_integer([:positive])}")
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(path)
    owner = start_supervised!({SymphonyElixir.Specification.Store, specification_opts(root)})
    on_exit(fn -> File.rm_rf(root) end)
    {owner, root}
  end

  defp specification_fixture(_context), do: {nil, nil}

  defp specification_opts(root) do
    [name: nil, state_dir: root, project: "github:example/fixture", scope: fn -> %{"fixture" => "live-specification"} end, authorize: &BrowserAuth.authorized?/1]
  end

  defp saved_specification(view) do
    auth = :sys.get_state(view.pid).socket.assigns.auth
    {:ok, saved} = FixtureSpecification.read("github:example/fixture", auth)
    saved
  end

  defp specification_params(view, changes \\ %{}) do
    assigns = :sys.get_state(view.pid).socket.assigns
    draft = assigns.specification_draft
    section = assigns.specification_section
    part = draft["sections"][section]

    %{
      "project" => draft["project"],
      "document_id" => draft["document_id"],
      "section" => section,
      "storage_revision" => Integer.to_string(assigns.specification_state["storage_revision"]),
      "items" => Map.new(part["items"], fn item -> {item["id"], Map.take(item, ~w(kind title body))} end),
      "diagrams" => Map.new(part["diagrams"], fn diagram -> {diagram["id"], Map.take(diagram, ~w(title source))} end)
    }
    |> Map.merge(changes)
  end

  defp intake_fields do
    %{"title" => "Bounded fixture task", "description" => "A useful result from one small change.\n\nDepends on: #12, #34", "verification" => "- Focused checks pass"}
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

  defp update_task(board, id, update), do: %{board | tasks: Enum.map(board.tasks, fn task -> if task.issue_id == id, do: updated_task(task, update), else: task end)}

  defp updated_task(task, update) do
    next = update.(task)
    Map.put(next, :lane, if(next.stage in ["ready", "running"], do: "work", else: next.stage))
  end

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

