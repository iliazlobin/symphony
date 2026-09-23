defmodule SymphonyElixir.Chat.ToolsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Chat.{Artifacts, Tools}
  alias SymphonyElixir.Chat.GitHub, as: ChatGitHub
  alias SymphonyElixir.GitHub.Admission
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.PathSafety
  alias SymphonyElixirWeb.{BoardActions, BrowserAuth, TaskBoard}

  @proposal_id "c63f2004-17cf-4f50-bae7-e1368b8d046a"

  defmodule Board do
    def load(_owner, _timeout) do
      case Application.fetch_env!(:symphony_elixir, :chat_test_board) do
        fun when is_function(fun, 0) -> fun.()
        board -> board
      end
    end
  end

  defmodule Owner do
    def tracker_action_guarded(fingerprint, revision, issue_id, callback, _owner) do
      send(Application.fetch_env!(:symphony_elixir, :chat_test_owner), {:guarded_edit, fingerprint, revision, issue_id})

      case Application.get_env(:symphony_elixir, :chat_test_guard_result, :execute) do
        :execute -> callback.()
        result -> result
      end
    end

    def tracker_action_guarded(fingerprint, revision, issue_id, callback, owner, :queue_unheld) do
      send(Application.fetch_env!(:symphony_elixir, :chat_test_owner), :guarded_unheld_queue)
      tracker_action_guarded(fingerprint, revision, issue_id, callback, owner)
    end

    def control_receipt_guarded(command, fingerprint, _owner) do
      send(Application.fetch_env!(:symphony_elixir, :chat_test_owner), {:receipt_read, command, fingerprint})
      Application.get_env(:symphony_elixir, :chat_test_receipt, {:error, :command_not_found})
    end
  end

  defmodule CommandOwner do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    @impl true
    def init(test_pid), do: {:ok, test_pid}
    @impl true
    def handle_call({:authorized_control_command, command, fingerprint, authorize}, _from, test_pid) do
      send(test_pid, {:native_command, command, fingerprint, authorize.()})
      {:reply, Application.get_env(:symphony_elixir, :chat_test_command, {:ok, %{"revision" => 4}}), test_pid}
    end
  end

  setup do
    adapters = [:chat_board_module, :chat_github_request, :chat_tracker_owner]

    keys =
      adapters ++ [:chat_test_board, :chat_test_owner, :chat_test_guard_result, :chat_test_receipt, :chat_test_command]

    previous = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    previous_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    token = String.duplicate("t", 40)
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)
    {:ok, canonical_root} = PathSafety.canonicalize(Path.dirname(Workflow.workflow_file_path()))

    tracker = %{kind: "github", provider: %{repo: "example/repo", token: "private-token"}, required_labels: ["ready"]}

    config = %{
      tracker: Map.merge(tracker, %{active_states: ["open"], terminal_states: ["closed"]}),
      control: %{enabled: true, state_path: Path.join(canonical_root, "control.json"), initial_mode: "paused"},
      polling: %{interval_ms: 60_000},
      observability: %{dashboard_enabled: false}
    }

    configure(config)
    marker = %{"fingerprint" => :crypto.mac(:hmac, :sha256, token, "symphony-browser-operator-v1") |> Base.url_encode64(padding: false), "issued_at" => System.system_time(:second)}
    fingerprint = Orchestrator.tracker_fingerprint()
    auth = %{marker: marker, host: "localhost", peer_ip: {127, 0, 0, 1}, tracker_fingerprint: fingerprint}
    context = %{project_id: "github:example/repo", tracker_fingerprint: fingerprint, auth: auth}

    board =
      TaskBoard.project(
        [issue("1"), issue("2", title: "Earlier task", updated_at: ~U[2026-09-14 10:00:00Z], priority: 2)],
        %{},
        %{"enabled" => true, "revision" => 3, "mode" => "paused", "issues" => %{}},
        Config.settings!()
      )

    Application.put_env(:symphony_elixir, :chat_board_module, Board)
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    Application.put_env(:symphony_elixir, :chat_tracker_owner, Owner)
    Application.put_env(:symphony_elixir, :chat_test_owner, self())

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> if is_nil(value), do: Application.delete_env(:symphony_elixir, key), else: Application.put_env(:symphony_elixir, key, value) end)
      restore_env("SYMPHONY_CONTROL_TOKEN", previous_token)
    end)

    %{context: context, config: config, board: board}
  end

  test "tool schemas expose only bounded project actions, no shell or arbitrary URLs" do
    specs = Tools.specs()

    assert Enum.map(specs, & &1["name"]) ==
             ~w(symphony_agent_graph symphony_delegate symphony_report symphony_set_goal symphony_view_context symphony_project_status symphony_search_tasks symphony_pr_session symphony_task_details symphony_read_project_document symphony_propose_action)

    assert Enum.all?(specs, &(&1["inputSchema"]["additionalProperties"] == false))
    refute Jason.encode!(specs) =~ "github_api"
  end

  test "PR chat resolves its immutable worker and sends only exact-session commands", ctx do
    id = String.duplicate("a", 32)

    put_pr_work(ctx, id, %{
      "phase" => "owner_review",
      "instruction" => "Implement feature",
      "head_sha" => String.duplicate("b", 40),
      "handoff" => %{"summary" => "Validation complete", "review" => %{"verdict" => "approve"}}
    })

    owner = start_supervised!({CommandOwner, self()})
    context = Map.merge(ctx.context, %{task_id: "github:example/repo:1", session_id: "work:" <> id, orchestrator: owner})
    assert {:ok, %{"work_id" => ^id, "work" => %{"result" => "Validation complete"}}} = Tools.call("symphony_pr_session", %{}, context)
    assert {:error, :pr_session_scope_mismatch} = Tools.call("symphony_pr_session", %{"task_id" => "2"}, context)
    proposal = propose(context, %{"action" => "continue_pr_work", "task_id" => "1", "work_id" => id, "body" => "Fix the failing check and report your validation"})
    assert {:ok, _} = Tools.confirm(proposal, context)
    assert_receive {:native_command, command, _, true}
    assert command["work_id"] == id
    assert command["instruction"] == "Fix the failing check and report your validation"
    assert command["expected_head_sha"] == String.duplicate("b", 40)

    for args <- [
          %{"action" => "continue_pr_work", "task_id" => "1", "work_id" => String.duplicate("c", 32), "body" => "Wrong worker"},
          %{"action" => "cancel", "task_id" => "2"},
          %{"action" => "edit_task", "task_id" => "1", "title" => "Change issue"},
          %{"action" => "pause"},
          %{"action" => "create_pr_work", "task_id" => "1", "body" => "Another PR"}
        ] do
      assert {:error, :pr_session_scope_mismatch} = Tools.call("symphony_propose_action", args, context)
    end

    refute_receive {:native_command, _, _, _}
  end

  test "PR chat rechecks selected work before confirming cancel or retry", ctx do
    id = String.duplicate("a", 32)
    put_pr_work(ctx, id, %{"phase" => "paused"})
    owner = start_supervised!({CommandOwner, self()})
    context = Map.merge(ctx.context, %{task_id: "github:example/repo:1", session_id: "work:" <> id, orchestrator: owner})

    for action <- ["cancel", "retry"] do
      board = Application.fetch_env!(:symphony_elixir, :chat_test_board)
      Application.put_env(:symphony_elixir, :chat_test_board, put_in(board, [:tasks, Access.at(0), :ledger, "selected_work_id"], id))
      proposal = propose(context, %{"action" => action, "task_id" => "1"})
      Application.put_env(:symphony_elixir, :chat_test_board, put_in(board, [:tasks, Access.at(0), :ledger, "selected_work_id"], String.duplicate("c", 32)))
      assert {:error, :pr_session_scope_mismatch} = Tools.confirm(proposal, context)
      assert {:error, :pr_session_scope_mismatch} = Tools.call("symphony_propose_action", %{"action" => action, "task_id" => "1"}, context)
    end

    refute_receive {:native_command, _, _, _}
  end

  test "attributed external PR chats allow discussion without adopting a coding agent", ctx do
    pr = %{number: 7, title: "External PR", url: "https://github.com/example/repo/pull/7", state: "open"}
    board = put_in(ctx.board, [:tasks, Access.at(0), :pull_requests], [pr])
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    context = Map.merge(ctx.context, %{task_id: "github:example/repo:1", session_id: "pr:7"})
    assert {:ok, %{"work_id" => nil, "pr_number" => 7}} = Tools.call("symphony_pr_session", %{}, context)
    assert {:error, :pr_session_read_only} = Tools.call("symphony_propose_action", %{"action" => "cancel", "task_id" => "1"}, context)
    assert {:error, :pr_session_unavailable} = Tools.resolve_session(context.task_id, "pr:99", context)
    missing_session = %{context | session_id: "pr:99"}
    assert {:error, :pr_session_unavailable} = Tools.call("symphony_propose_action", %{"action" => "cancel", "task_id" => "1"}, missing_session)
    Application.put_env(:symphony_elixir, :chat_test_board, %{board | source_error: "Unavailable"})
    assert {:error, :board_unavailable} = Tools.resolve_session(context.task_id, "pr:7", context)
  end

  test "GitHub priority labels produce a single consistent board priority" do
    base = %{"number" => 1, "title" => "Task", "state" => "open"}

    for {labels, priority} <- [
          {[], nil},
          {["priority:p1"], 1},
          {[%{"name" => "PRIORITY:P2"}], 2},
          {["priority:p3"], 3},
          {["priority:p4", "other"], 4},
          {["priority:p0"], nil},
          {["priority:p1", "priority:p2"], nil},
          {["priority:p1", "priority:p1"], 1}
        ] do
      issue = GitHubClient.normalize_issue_for_test(Map.put(base, "labels", labels), "example/repo")
      assert issue.priority == priority
    end
  end

  test "project auth is required for every read, including expired and foreign chat sessions", ctx do
    foreign = %{ctx.context | project_id: "github:other/repo"}
    invalid_contexts = [%{}, %{ctx.context | auth: %{}}, foreign, %{ctx.context | tracker_fingerprint: "foreign"}]

    for invalid <- invalid_contexts do
      assert {:error, _} = Tools.call("symphony_project_status", %{}, invalid)
    end

    auth = put_in(ctx.context.auth, [:marker, "issued_at"], System.system_time(:second) - 28_800)
    assert {:error, :unauthorized} = Tools.call("symphony_project_status", %{}, %{ctx.context | auth: auth})
    assert BrowserAuth.authorized?(ctx.context.auth)
  end

  test "unknown, malformed, oversized and injected authority arguments are rejected", ctx do
    assert {:error, :unknown_tool} = Tools.call("shell", %{}, ctx.context)
    assert {:error, :invalid_arguments} = Tools.call("symphony_project_status", nil, ctx.context)

    for args <- [
          %{"project_id" => "other"},
          %{"q" => String.duplicate("x", 201)},
          %{"q" => <<255>>},
          %{"q" => <<0>>},
          %{"limit" => 0},
          %{"limit" => 51},
          %{"limit" => "3"},
          %{"status" => "merged"},
          %{"sort" => "sql"}
        ] do
      assert {:error, :invalid_arguments} = Tools.call("symphony_search_tasks", args, ctx.context)
    end

    assert {:error, :invalid_arguments} = Tools.call("symphony_task_details", %{}, ctx.context)
  end

  test "project status preserves freshness errors and bounded blocker information", ctx do
    board = put_in(ctx.board, [:tasks, Access.at(0), :attention], "Needs review")
    board = %{board | source_error: "Tracker unavailable", runtime_error: "Runtime unavailable"}
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    assert {:ok, %{"widgets" => [%{"type" => "status"} = status]}} = Tools.call("symphony_project_status", %{}, ctx.context)
    assert status["source_error"] == "Tracker unavailable"
    assert status["counts"] == %{"ready" => 2}
    assert length(status["blockers"]) == 1
    refute Jason.encode!(status) =~ "private-token"
    assert {:error, :board_unavailable} = Tools.call("symphony_search_tasks", %{}, ctx.context)
  end

  test "search widgets link exact filters and cards within the immutable project", ctx do
    assert {:ok, %{"widgets" => [widget]}} = Tools.call("symphony_search_tasks", %{"q" => "Earlier", "status" => "ready", "sort" => "priority", "limit" => 1}, ctx.context)
    assert widget["total"] == 1
    assert [task] = widget["tasks"]
    assert task["issue_id"] == "2"
    assert task["url"] == "/?project=github%3Aexample%2Frepo&task=github%3Aexample%2Frepo%3A2"
    assert URI.decode_query(URI.parse(widget["url"]).query) == %{"project" => ctx.context.project_id, "q" => "Earlier", "status" => "ready", "sort" => "priority"}

    for sort <- ~w(title oldest updated priority) do
      assert {:ok, %{"widgets" => [%{"tasks" => tasks}]}} = Tools.call("symphony_search_tasks", %{"sort" => sort}, ctx.context)
      assert length(tasks) == 2
    end

    assert {:ok, _} = Tools.call("symphony_search_tasks", %{}, ctx.context)
  end

  test "priority and attention filter widgets match the linked board semantics", ctx do
    board = put_in(ctx.board, [:tasks, Access.at(1), :attention], "Needs input")
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    args = %{"priority" => "P2", "status" => "attention", "sort" => "oldest"}
    assert {:ok, %{"widgets" => [widget]}} = Tools.call("symphony_search_tasks", args, ctx.context)
    assert [%{"issue_id" => "2"}] = widget["tasks"]
    assert URI.decode_query(URI.parse(widget["url"]).query)["priority"] == "P2"
    assert {:ok, %{"widgets" => [%{"total" => 0}]}} = Tools.call("symphony_search_tasks", %{"q" => "Depends on"}, ctx.context)
  end

  test "details reject foreign same-number IDs and missing tracker records", ctx do
    for id <- ["github:other/repo:1", "../1", "https://github.com/other/repo/issues/1", "999"] do
      assert {:error, :task_not_found} = Tools.call("symphony_task_details", %{"task_id" => id}, ctx.context)
    end

    for id <- ["1", "GH-1", "github:example/repo:1"] do
      assert {:ok, %{"widgets" => [%{"task" => task}]}} = Tools.call("symphony_task_details", %{"task_id" => id}, ctx.context)
      assert task["description"] =~ "Depends on: none"
      assert task["labels"] == ["ready"]
    end

    board = put_in(ctx.board, [:tasks, Access.at(0), :source_missing], true)
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    assert {:error, :task_not_found} = Tools.call("symphony_task_details", %{"task_id" => "1"}, ctx.context)
  end

  test "project changes during reads and foreign board rows fail closed", ctx do
    for board <- [:malformed, %{ctx.board | tasks: [%{hd(ctx.board.tasks) | project: "github:foreign/repo"}]}] do
      Application.put_env(:symphony_elixir, :chat_test_board, board)
      assert {:error, _} = Tools.call("symphony_project_status", %{}, ctx.context)
    end

    Application.put_env(:symphony_elixir, :chat_test_board, fn ->
      configure(put_in(ctx.config, [:tracker, :provider, :repo], "other/repo"))
      ctx.board
    end)

    assert {:error, :unauthorized} = Tools.call("symphony_project_status", %{}, ctx.context)
  end

  test "unexpected adapter failures return a scrubbed result", ctx do
    for fun <- [fn -> raise "secret" end, fn -> throw("secret") end] do
      Application.put_env(:symphony_elixir, :chat_test_board, fun)
      assert {:error, :tool_unavailable} = Tools.call("symphony_project_status", %{}, ctx.context)
    end
  end

  test "view context refreshes selected and visible tasks without trusting browser facts", ctx do
    snapshot = %{
      "version" => 1,
      "project_id" => ctx.context.project_id,
      "selected_task_id" => "github:example/repo:1",
      "visible_task_ids" => ["github:example/repo:2", "github:example/repo:99"],
      "viewport_task_ids" => ["github:example/repo:2"],
      "captured_at" => "2026-09-15T09:00:00Z",
      "truncated" => true
    }

    board = put_in(ctx.board, [:tasks, Access.at(0), :title], "Updated after the screen snapshot")
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    context = Map.put(ctx.context, :view_context, snapshot)
    assert {:ok, result} = Tools.call("symphony_view_context", %{}, context)
    assert Enum.map(result["current_tasks"], & &1["issue_id"]) == ["1", "2"]
    assert hd(result["current_tasks"])["title"] == "Updated after the screen snapshot"
    assert result["snapshot"]["selected_task_id"] == snapshot["selected_task_id"]
    assert result["missing_task_ids"] == ["github:example/repo:99"]
    assert Enum.any?(result["warnings"], &String.contains?(&1, "truncated"))
    assert result["checked_at"] == board.generated_at
    assert {:error, :invalid_arguments} = Tools.call("symphony_view_context", %{"project_id" => "other"}, context)
    assert {:error, :invalid_view_context} = Tools.call("symphony_view_context", %{}, Map.put(ctx.context, :view_context, %{snapshot | "project_id" => "other"}))
    assert {:error, :unauthorized} = Tools.call("symphony_view_context", %{}, %{context | auth: %{}})
  end

  test "an absent board snapshot does not load a board or reuse earlier context", ctx do
    Application.put_env(:symphony_elixir, :chat_test_board, fn -> flunk("an absent snapshot loaded board") end)
    assert {:ok, %{"context_status" => "unavailable", "snapshot" => nil, "current_tasks" => []}} = Tools.call("symphony_view_context", %{}, ctx.context)
  end

  test "view retrieval distinguishes unavailable facts from missing tasks and rechecks access", ctx do
    snapshot = %{"version" => 1, "project_id" => ctx.context.project_id, "visible_task_ids" => ["github:example/repo:1"]}
    context = Map.put(ctx.context, :view_context, snapshot)

    for board <- [:unavailable, %{ctx.board | source_error: "GitHub unavailable"}] do
      Application.put_env(:symphony_elixir, :chat_test_board, board)
      assert {:ok, result} = Tools.call("symphony_view_context", %{}, context)
      assert result["current_tasks"] == []
      assert Enum.any?(result["warnings"], &String.contains?(&1, "unavailable"))
      assert (result["missing_task_ids"] || []) == []
    end

    Application.put_env(:symphony_elixir, :chat_test_board, fn ->
      System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("n", 40))
      ctx.board
    end)

    assert {:error, :unauthorized} = Tools.call("symphony_view_context", %{}, context)
  end

  test "task details preserve independent PR review, CI, links and partial evidence", ctx do
    prs =
      for {number, state, review, checks, status} <- [
            {10, "merged", "approved", "success", "available"},
            {11, "open", "changes_requested", "failure", "partial"},
            {12, "open", "no_decision", "stale", "stale"}
          ] do
        %{
          number: number,
          title: "PR #{number}",
          url: "https://github.com/example/repo/pull/#{number}",
          state: state,
          draft: false,
          created_at: "2026-09-15T09:00:00Z",
          updated_at: "2026-09-15T10:00:00Z",
          review: review,
          checks: checks,
          head_sha: String.duplicate(Integer.to_string(rem(number, 10)), 40),
          relation: "linked",
          check_total: 2,
          check_details_status: status,
          check_runs: [%{kind: "check_run", name: "tests", status: "completed", conclusion: checks, url: "https://github.com/example/repo/actions/runs/#{number}", duration_ms: 1200}],
          secret: "do not expose internal fields"
        }
      end

    links = [%{kind: "checks", label: "Actions", url: "https://github.com/example/repo/actions"}]
    board = update_in(ctx.board, [:tasks, Access.at(0)], &Map.merge(&1, %{pull_requests: prs, links: links, github_status: "partial"}))
    board = %{board | enrichment_error: "Only part of GitHub evidence was available"}
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    assert {:ok, %{"widgets" => [%{"task" => task}]}} = Tools.call("symphony_task_details", %{"task_id" => "1"}, ctx.context)
    assert Enum.map(task["pull_requests"], & &1["number"]) == [10, 11, 12]
    assert Enum.map(task["pull_requests"], & &1["review"]) == ["approved", "changes_requested", "no_decision"]
    assert Enum.map(task["pull_requests"], & &1["check_details_status"]) == ["available", "partial", "stale"]
    assert get_in(task, ["pull_requests", Access.at(1), "check_runs", Access.at(0), "conclusion"]) == "failure"
    assert get_in(task, ["pull_requests", Access.at(1), "check_runs", Access.at(0), "url"]) =~ "/runs/11"
    assert task["links"] == [%{"kind" => "checks", "label" => "Actions", "url" => "https://github.com/example/repo/actions"}]
    assert task["github_status"] == "partial"
    assert task["enrichment_error"] == board.enrichment_error
    assert task["checked_at"] == board.generated_at
    refute Jason.encode!(task) =~ "do not expose"

    assert {:ok, %{"widgets" => [search]}} = Tools.call("symphony_search_tasks", %{}, ctx.context)
    assert search["checked_at"] == board.generated_at
    assert Enum.find(search["tasks"], &(&1["issue_id"] == "1"))["pull_requests"] == Enum.map(task["pull_requests"], &Map.delete(&1, "check_runs"))
    assert search["enrichment_error"] == board.enrichment_error
    artifact = Artifacts.entries(%{"project_id" => ctx.context.project_id, "messages" => [%{"widgets" => [search]}]}) |> Enum.find(&(&1["kind"] == "pull_request"))
    assert artifact["created_at"] == "2026-09-15T09:00:00Z"
    assert artifact["updated_at"] == "2026-09-15T10:00:00Z"
    refute Jason.encode!(search) =~ "do not expose"
  end

  test "a native action produces a preview and never a command", ctx do
    for action <- ~w(pause drain resume) do
      proposal = propose(ctx.context, %{"action" => action})
      assert proposal["expected_revision"] == 3
      assert proposal["project_id"] == ctx.context.project_id
      assert proposal["args"] == %{}
    end

    for action <- ~w(cancel retry) do
      proposal = propose(ctx.context, %{"action" => action, "task_id" => "1"})
      assert proposal["expected_updated_at"] == "2026-09-15T10:00:00Z"
    end
  end

  test "action-specific argument validation rejects accidental or hidden extra effects", ctx do
    for args <- [
          %{"action" => "pause", "task_id" => "1"},
          %{"action" => "cancel"},
          %{"action" => "create_task", "title" => "x", "body" => ""},
          %{"action" => "edit_task", "task_id" => "1"},
          %{"action" => "feedback", "task_id" => "1", "body" => "hello", "state" => "closed"},
          %{"action" => "create_task", "title" => " ", "body" => "x"},
          %{"action" => "feedback", "task_id" => "1", "body" => "<!-- symphony-chat:malicious -->"}
        ] do
      assert {:error, :invalid_arguments} = Tools.call("symphony_propose_action", args, ctx.context)
    end
  end

  test "unsafe edits need cancellation and a durable owner revision", ctx do
    args = %{"action" => "edit_task", "task_id" => "1", "title" => "Updated"}
    assert {:error, :cancel_task_before_edit} = Tools.call("symphony_propose_action", args, ctx.context)
    board = put_in(ctx.board, [:tasks, Access.at(0), :hold], "cancelled")
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    assert propose(ctx.context, args)["action"] == "edit_task"
    Application.put_env(:symphony_elixir, :chat_test_board, %{board | control: %{"enabled" => false}})
    assert {:error, :control_unavailable} = Tools.call("symphony_propose_action", args, ctx.context)
  end

  test "project agent creates the same simple task draft and never grants the dispatch label", ctx do
    fields = %{"title" => "New", "description" => "Document the unit-test command.", "verification" => "The README matches the configured test command."}
    assert {:ok, normalized} = SymphonyElixir.TaskDraft.action_args(fields)
    proposal = propose(ctx.context, Map.put(fields, "action", "create_task"))
    assert proposal["args"] == Map.delete(normalized, "action")
    assert Map.keys(proposal["args"]) |> Enum.sort() == ["body", "title"]

    script([
      fn "GET", "/repos/example/repo/issues", params, nil, _ ->
        assert params["state"] == "all"
        {:ok, %{status: 200, body: []}}
      end,
      fn "POST", "/repos/example/repo/issues", %{}, body, _ ->
        assert body["labels"] == []
        assert body["title"] == "New"
        assert body["body"] =~ normalized["body"]
        assert body["body"] =~ "Depends on: none"
        {:ok, %{status: 201, body: Map.put(body, "number", 3)}}
      end
    ])

    assert {:ok, %{"widgets" => [%{"summary" => summary}]}} = Tools.confirm(proposal, ctx.context)
    assert summary =~ "execution was not queued"
    assert_finished()
  end

  test "project agent accepts a title-only task and confirmation creates it without queueing", ctx do
    proposal = propose(ctx.context, %{"action" => "create_task", "title" => "Investigate slow board loading"})
    assert proposal["args"] == %{"title" => "Investigate slow board loading", "body" => "Depends on: none"}

    script([
      fn "GET", "/repos/example/repo/issues", params, nil, _ ->
        assert params["state"] == "all"
        {:ok, %{status: 200, body: []}}
      end,
      fn "POST", "/repos/example/repo/issues", %{}, body, _ ->
        assert body["title"] == "Investigate slow board loading"
        assert body["labels"] == []
        assert String.starts_with?(body["body"], "Depends on: none")
        refute body["body"] =~ "## Description"
        refute body["body"] =~ "## Verification"
        {:ok, %{status: 201, body: Map.put(body, "number", 3)}}
      end
    ])

    assert {:ok, %{"widgets" => [%{"summary" => summary}]}} = Tools.confirm(proposal, ctx.context)
    assert summary =~ "execution was not queued"
    assert_finished()
  end

  test "project agent accepts either optional detail independently and omits blank sections", ctx do
    base = %{"action" => "create_task", "title" => "New"}
    assert propose(ctx.context, Map.put(base, "description", "Description"))["args"]["body"] == "## Description\n\nDescription\n\nDepends on: none"
    assert propose(ctx.context, Map.put(base, "verification", "Check it"))["args"]["body"] == "## Verification\n\nCheck it\n\nDepends on: none"
    assert propose(ctx.context, Map.merge(base, %{"description" => " \n ", "verification" => ""}))["args"]["body"] == "Depends on: none"
  end

  test "project agent rejects malformed or mixed task draft fields", ctx do
    args = %{"action" => "create_task", "title" => "New", "description" => "Description", "verification" => "Check it"}

    for invalid <- [
          Map.delete(args, "title"),
          Map.put(args, "title", " "),
          Map.put(args, "description", nil),
          Map.put(args, "verification", 1),
          Map.put(args, "body", "Different body"),
          Map.put(args, "priority", 1),
          Map.put(args, "title", String.duplicate("x", 201)),
          Map.put(args, "description", "Depends on: unknown"),
          Map.put(args, "description", "Depends on: none\nDepends on: #2"),
          Map.put(args, "description", String.duplicate("x", 4_001)),
          Map.put(args, "verification", String.duplicate("x", 4_001))
        ] do
      assert {:error, :invalid_arguments} = Tools.call("symphony_propose_action", invalid, ctx.context)
    end

    proposal = propose(ctx.context, Map.put(args, "description", "Implement after prerequisite.\nDepends on: #2"))
    assert proposal["args"]["body"] =~ "Depends on: #2"
    refute proposal["args"]["body"] =~ "Depends on: none"
  end

  test "new task idempotency finds an existing marker and never repeats POST", ctx do
    proposal = propose(ctx.context, %{"action" => "create_task", "title" => "New", "body" => "Body"})
    existing = %{"number" => 3, "body" => marker(proposal)}
    script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: [existing]}} end])
    assert {:ok, %{"widgets" => [%{"summary" => "Task already created."}]}} = Tools.confirm(proposal, ctx.context)
    assert_finished()
  end

  test "unknown write outcomes are not retried and only marker recovery can confirm success", ctx do
    proposal = propose(ctx.context, %{"action" => "create_task", "title" => "New", "body" => "Body"})
    fail_write = fn "POST", _, _, _, _ -> {:error, :connection_reset} end
    script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: []}} end, fail_write])
    assert {:error, :write_outcome_unknown} = Tools.confirm(proposal, ctx.context)
    assert_finished()
    script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: []}} end])
    assert {:error, :write_outcome_unknown} = Tools.reconcile(proposal, ctx.context)
    assert_finished()
    script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: [%{"number" => 3, "body" => marker(proposal)}]}} end])
    assert {:ok, _} = Tools.reconcile(proposal, ctx.context)
    assert_finished()
  end

  test "feedback checks current task revision and records an additive comment", ctx do
    proposal = propose(ctx.context, %{"action" => "feedback", "task_id" => "GH-1", "body" => "Please add tests."})

    script([
      fn "GET", "/repos/example/repo/issues/1/comments", _, nil, _ -> {:ok, %{status: 200, body: []}} end,
      fn "GET", "/repos/example/repo/issues/1", _, nil, _ -> {:ok, %{status: 200, body: raw_issue()}} end,
      fn "POST", "/repos/example/repo/issues/1/comments", _, body, _ -> {:ok, %{status: 201, body: body}} end
    ])

    assert {:ok, %{"widgets" => [%{"summary" => summary}]}} = Tools.confirm(proposal, ctx.context)
    assert summary =~ "does not interrupt or steer"
    assert_finished()
  end

  test "feedback refuses stale tasks, pull requests and expired authorization", ctx do
    proposal = propose(ctx.context, %{"action" => "feedback", "task_id" => "1", "body" => "Feedback"})

    for {issue, expected} <- [
          {Map.put(raw_issue(), "updated_at", "later"), :task_changed},
          {Map.put(raw_issue(), "pull_request", %{}), :invalid_github_issue},
          {Map.put(raw_issue(), "number", 2), :invalid_github_issue},
          {nil, :invalid_github_issue}
        ] do
      read_issue = fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: issue}} end
      script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: []}} end, read_issue])
      assert {:error, ^expected} = Tools.confirm(proposal, ctx.context)
      assert_finished()
    end

    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("z", 40))
    assert {:error, :unauthorized} = Tools.confirm(proposal, ctx.context)
  end

  test "edit confirmation enters the owner guard and preserves reserved labels and hold", ctx do
    Application.put_env(:symphony_elixir, :chat_test_board, put_in(ctx.board, [:tasks, Access.at(0), :hold], "cancelled"))
    proposal = propose(ctx.context, %{"action" => "edit_task", "task_id" => "github:example/repo:1", "title" => "Updated", "priority" => 2, "state" => "closed"})

    script([
      fn "GET", _, _, nil, _ -> {:ok, %{status: 200, body: Map.put(raw_issue(), "labels", [%{"name" => "ready"}, "priority:p1", "publish-approved", %{}])}} end,
      fn "PATCH", "/repos/example/repo/issues/1", %{}, body, _ ->
        assert body["labels"] == ["ready", "publish-approved", "priority:p2"]
        assert body["title"] == "Updated"
        assert body["state"] == "closed"
        assert body["body"] =~ "Existing description"
        {:ok, %{status: 200, body: Map.put(body, "number", 1)}}
      end
    ])

    assert {:ok, _} = Tools.confirm(proposal, ctx.context)
    assert_receive {:guarded_edit, _, 3, "1"}
    assert_finished()
  end

  test "edit recovery never repeats PATCH and requires the exact marker", ctx do
    Application.put_env(:symphony_elixir, :chat_test_board, put_in(ctx.board, [:tasks, Access.at(0), :hold], "cancelled"))
    proposal = propose(ctx.context, %{"action" => "edit_task", "task_id" => "1", "body" => "Updated body"})

    for {body, outcome} <- [{"old", :unknown}, {marker(proposal), :found}] do
      script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: Map.put(raw_issue(), "body", body)}} end])
      result = Tools.reconcile(proposal, ctx.context)

      if outcome == :found do
        assert match?({:ok, _}, result)
      else
        assert result == {:error, :write_outcome_unknown}
      end

      assert_finished()
    end
  end

  test "proposals cannot alter project, inject arguments or use unpersisted identifiers", ctx do
    proposal = propose(ctx.context, %{"action" => "pause"})

    for invalid <- [
          nil,
          Map.delete(proposal, "id"),
          Map.put(proposal, "id", "../../x"),
          Map.put(proposal, "project_id", "other"),
          Map.put(proposal, "args", nil),
          Map.put(proposal, "arbitrary", "x"),
          put_in(proposal, ["args", "repo"], "other/repo")
        ] do
      assert {:error, _} = Tools.confirm(invalid, ctx.context)
    end

    assert {:error, :command_not_found} = Tools.reconcile(proposal, ctx.context)
  end

  test "PR work proposals bind host IDs and approved base, and reject model authority", ctx do
    configure(put_in(ctx.config, [:control, :base_sha], String.duplicate("a", 40)))
    args = %{"action" => "create_pr_work", "task_id" => "GH-1", "body" => "Add validation tests"}
    first = propose(ctx.context, args)
    second = propose(ctx.context, args)
    assert first["args"] == %{"task_id" => "1", "body" => "Add validation tests"}
    assert first["expected_revision"] == 3
    assert first["pr_work"]["base_sha"] == String.duplicate("a", 40)
    assert first["pr_work"]["work_id"] =~ ~r/\A[0-9a-f]{32}\z/
    refute first["pr_work"]["work_id"] == second["pr_work"]["work_id"]

    for field <- ~w(work_id base_sha branch workspace_key expected_head_sha builder_thread_id) do
      assert {:error, :invalid_arguments} = Tools.call("symphony_propose_action", Map.put(args, field, "untrusted"), ctx.context)
    end

    configure(ctx.config)
    assert {:error, :approved_baseline_changed} = Tools.call("symphony_propose_action", args, ctx.context)
  end

  test "PR continuation captures current candidate including explicit nil and fences work identity", ctx do
    work_id = String.duplicate("b", 32)
    args = %{"action" => "continue_pr_work", "task_id" => "1", "work_id" => work_id, "body" => "Fix the review findings"}
    assert {:error, :pr_work_not_found} = Tools.call("symphony_propose_action", args, ctx.context)

    for head <- [nil, String.duplicate("c", 40)] do
      put_pr_work(ctx, work_id, %{"head_sha" => head})
      proposal = propose(ctx.context, args)
      assert proposal["pr_work"] == %{"work_id" => work_id, "expected_head_sha" => head}
    end

    put_pr_work(ctx, work_id, %{"tracker_fingerprint" => "different"})
    assert {:error, :tracker_changed} = Tools.call("symphony_propose_action", args, ctx.context)
    put_pr_work(ctx, work_id, %{"head_sha" => "invalid"})
    assert {:error, :pr_head_changed} = Tools.call("symphony_propose_action", args, ctx.context)
    put_pr_work(ctx, work_id, %{"issue_id" => "2"})
    assert {:error, :pr_work_not_found} = Tools.call("symphony_propose_action", args, ctx.context)
    assert {:error, :invalid_arguments} = Tools.call("symphony_propose_action", %{args | "work_id" => "../session"}, ctx.context)
  end

  test "canonical task scope fences PR proposals, confirmation and recovery while main chat may coordinate", ctx do
    configure(put_in(ctx.config, [:control, :base_sha], String.duplicate("a", 40)))
    args = %{"action" => "create_pr_work", "task_id" => "GH-1", "body" => "Add validation tests"}
    own = Map.put(ctx.context, :task_id, "github:example/repo:1")
    other = Map.put(ctx.context, :task_id, "github:example/repo:2")
    assert {:error, :task_scope_mismatch} = Tools.call("symphony_propose_action", args, other)
    proposal = propose(own, args)
    assert {:error, :task_scope_mismatch} = Tools.confirm(proposal, other)
    assert {:error, :task_scope_mismatch} = Tools.reconcile(proposal, other)
    assert {:error, :command_not_found} = Tools.reconcile(proposal, ctx.context)
    refute_receive {:native_command, _, _, _}
  end

  test "confirmed PR work preserves exact command and replay payload with guarded owner outcomes", ctx do
    configure(put_in(ctx.config, [:control, :base_sha], String.duplicate("a", 40)))
    owner = start_supervised!({CommandOwner, self()})
    context = Map.put(ctx.context, :orchestrator, owner)
    proposal = propose(context, %{"action" => "create_pr_work", "task_id" => "1", "body" => "Implement acceptance checks"})
    assert {:ok, _} = Tools.confirm(proposal, context)
    assert_receive {:native_command, command, fingerprint, true}
    assert fingerprint == context.tracker_fingerprint

    assert command ==
             Map.merge(proposal["pr_work"], %{"action" => "create_pr_work", "issue_id" => "1", "instruction" => "Implement acceptance checks", "command_id" => @proposal_id, "expected_revision" => 3})

    Application.put_env(:symphony_elixir, :chat_test_receipt, {:ok, %{"revision" => 4, "replayed" => true}})
    assert {:ok, _} = Tools.reconcile(proposal, context)
    assert_receive {:receipt_read, ^command, ^fingerprint}
    refute_receive {:native_command, _, _, _}

    failures = [
      :revision_conflict,
      :approved_baseline_changed,
      :pr_work_pending,
      :pr_work_exists,
      :pr_head_changed,
      :pr_already_merged,
      :pr_identity_changed,
      :pr_evidence_unavailable,
      :budget_exhausted
    ]

    for reason <- failures do
      Application.put_env(:symphony_elixir, :chat_test_command, {:error, reason})
      assert {:error, ^reason} = Tools.confirm(proposal, context)
      assert_receive {:native_command, ^command, ^fingerprint, true}
      assert Tools.error_message(reason)["code"] == Atom.to_string(reason)
    end

    Application.put_env(:symphony_elixir, :chat_test_command, {:error, :unavailable})
    assert {:error, :write_outcome_unknown} = Tools.confirm(proposal, context)
    assert_receive {:native_command, ^command, ^fingerprint, true}
    assert {:error, :unauthorized} = Tools.confirm(proposal, %{context | auth: %{}})
    refute_receive {:native_command, _, _, _}
  end

  test "PR work board adapter accepts only exact native fields and requires authorization", ctx do
    assert {:error, :invalid_command} = BoardActions.pr_work_command(%{"action" => "pause"}, ctx.context.auth)

    command = %{
      "action" => "continue_pr_work",
      "issue_id" => "1",
      "command_id" => @proposal_id,
      "expected_revision" => 3,
      "work_id" => String.duplicate("b", 32),
      "instruction" => "Resume",
      "expected_head_sha" => nil
    }

    assert {:error, :unauthorized} = BoardActions.pr_work_command(command, %{})
    assert {:error, :invalid_command} = BoardActions.pr_work_command(Map.delete(command, "expected_head_sha"), ctx.context.auth)
    assert {:error, :invalid_command} = BoardActions.pr_work_command(Map.put(command, "branch", "untrusted"), ctx.context.auth)
  end

  test "continuation confirmation and recovery retain nil head and reject altered evidence", ctx do
    work_id = String.duplicate("b", 32)
    put_pr_work(ctx, work_id, %{})
    owner = start_supervised!({CommandOwner, self()})
    context = Map.put(ctx.context, :orchestrator, owner)
    proposal = propose(context, %{"action" => "continue_pr_work", "task_id" => "1", "work_id" => work_id, "body" => "Resume the design"})
    assert {:ok, _} = Tools.confirm(proposal, context)
    assert_receive {:native_command, command, _, true}
    assert Map.has_key?(command, "expected_head_sha")
    assert is_nil(command["expected_head_sha"])
    refute Map.has_key?(command, "base_sha")
    assert {:error, :command_not_found} = Tools.reconcile(proposal, context)
    assert_receive {:receipt_read, ^command, _}

    for evidence <- [
          nil,
          %{},
          Map.delete(proposal["pr_work"], "expected_head_sha"),
          %{"work_id" => String.duplicate("d", 32), "expected_head_sha" => nil},
          Map.put(proposal["pr_work"], "branch", "other")
        ] do
      invalid = Map.put(proposal, "pr_work", evidence)
      assert {:error, :invalid_proposal} = Tools.confirm(invalid, context)
      assert {:error, :invalid_proposal} = Tools.reconcile(invalid, context)
    end

    assert {:error, :invalid_proposal} = Tools.confirm(Map.delete(proposal, "pr_work"), context)
    assert {:error, :invalid_proposal} = Tools.confirm(Map.put(propose(context, %{"action" => "pause"}), "pr_work", proposal["pr_work"]), context)
    refute_receive {:native_command, _, _, _}
  end

  test "task details expose bounded PR sessions without runtime paths or unsafe publication URLs", ctx do
    work_id = String.duplicate("b", 32)
    empty = put_pr_work(ctx, work_id, %{})
    assert {:ok, %{"widgets" => [%{"task" => %{"pr_work" => [pending]}}]}} = Tools.call("symphony_task_details", %{"task_id" => "1"}, ctx.context)
    assert pending["publication"] == nil
    assert pending["head_sha"] == nil
    assert pending["phase"] == "unknown"

    works =
      Map.new(1..25, fn number ->
        id = Integer.to_string(number, 16) |> String.downcase() |> String.pad_leading(32, "0")
        {id, Map.put(empty, "id", id)}
      end)

    board = put_in(ctx.board, [:tasks, Access.at(0), :ledger], %{"pr_work" => works})
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    assert {:ok, %{"widgets" => [%{"task" => %{"pr_work" => bounded}}]}} = Tools.call("symphony_task_details", %{"task_id" => "1"}, ctx.context)
    assert length(bounded) == 20

    work =
      put_pr_work(ctx, work_id, %{
        "instruction" => String.duplicate("x", 700),
        "phase" => "owner_review",
        "workspace_key" => "/private/owner",
        "auth" => "secret",
        "head_sha" => String.duplicate("c", 40),
        "publication" => %{"pr_number" => 12, "pr_url" => "https://github.com/example/repo/pull/12", "status" => "ready"}
      })

    assert {:ok, %{"widgets" => [%{"task" => %{"pr_work" => [details]}}]}} = Tools.call("symphony_task_details", %{"task_id" => "1"}, ctx.context)
    assert details["id"] == work_id
    assert details["publication"] == %{"number" => 12, "url" => "https://github.com/example/repo/pull/12", "status" => "ready"}
    assert String.length(details["summary"]) == 500
    refute Jason.encode!(details) =~ "/private/owner"
    refute Jason.encode!(details) =~ "secret"

    put_pr_work(ctx, work_id, Map.put(work, "publication", %{"pr_number" => 12, "pr_url" => "javascript:alert(1)", "status" => "ready"}))
    assert {:ok, %{"widgets" => [%{"task" => %{"pr_work" => [details]}}]}} = Tools.call("symphony_task_details", %{"task_id" => "1"}, ctx.context)
    assert is_nil(details["publication"])
  end

  test "native confirmation retains revision fencing and durable command IDs", ctx do
    config = put_in(ctx.config, [:tracker], %{kind: "memory", project_slug: "team", active_states: ["open"], terminal_states: ["closed"]})
    configure(config)
    supervisor = start_supervised!({Task.Supervisor, []})
    name = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor})
    fingerprint = Orchestrator.tracker_fingerprint()
    context = %{ctx.context | project_id: "memory:team", tracker_fingerprint: fingerprint, auth: %{ctx.context.auth | tracker_fingerprint: fingerprint}} |> Map.put(:orchestrator, pid)
    board = %{ctx.board | tasks: [], control: Orchestrator.control_snapshot(pid)}
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    proposal = propose(context, %{"action" => "drain"})
    assert {:ok, %{"widgets" => [%{"result" => %{"revision" => 1, "replayed" => false}}]}} = Tools.confirm(proposal, context)
    assert {:ok, %{"widgets" => [%{"result" => %{"revision" => 1, "replayed" => true}}]}} = Tools.confirm(proposal, context)
    conflict = %{proposal | "id" => "c63f2004-17cf-4f50-bae7-e1368b8d046b", "action" => "pause"}
    assert {:error, :revision_conflict} = Tools.confirm(conflict, context)
  end

  test "chat concurrency changes preview exact limits, confirm through the owner and reconcile without writing", ctx do
    config = put_in(ctx.config, [:tracker], %{kind: "memory", project_slug: "team", active_states: ["open"], terminal_states: ["closed"]})
    configure(Map.put(config, :agent, %{max_concurrent_agents: 3}))
    supervisor = start_supervised!({Task.Supervisor, []})
    name = Module.concat(__MODULE__, "Settings#{System.unique_integer([:positive])}")
    pid = start_supervised!({Orchestrator, name: name, task_supervisor: supervisor})
    fingerprint = Orchestrator.tracker_fingerprint()
    context = %{ctx.context | project_id: "memory:team", tracker_fingerprint: fingerprint, auth: %{ctx.context.auth | tracker_fingerprint: fingerprint}} |> Map.put(:orchestrator, pid)
    board = %{ctx.board | tasks: [], control: Orchestrator.control_snapshot(pid)}
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    Application.put_env(:symphony_elixir, :chat_tracker_owner, Orchestrator)

    for args <- [
          %{"action" => "set_concurrency"},
          %{"action" => "set_concurrency", "limit" => 0},
          %{"action" => "set_concurrency", "limit" => "2"},
          %{"action" => "set_concurrency", "limit" => 2, "task_id" => "1"}
        ] do
      assert {:error, :invalid_arguments} = Tools.call("symphony_propose_action", args, context)
    end

    assert {:error, :concurrency_limit_exceeded} = Tools.call("symphony_propose_action", %{"action" => "set_concurrency", "limit" => 4}, context)
    assert {:ok, %{"widgets" => [%{"control" => %{"settings" => %{"concurrency" => %{"ceiling" => 3}}}}]}} = Tools.call("symphony_project_status", %{}, context)
    proposal = propose(context, %{"action" => "set_concurrency", "limit" => 2})
    assert Orchestrator.control_snapshot(pid)["revision"] == 0
    assert {:ok, %{"widgets" => [%{"result" => %{"limit" => 2, "revision" => 1}}]}} = Tools.confirm(proposal, context)
    assert {:ok, %{"widgets" => [%{"result" => %{"limit" => 2, "replayed" => true}}]}} = Tools.confirm(proposal, context)
    assert {:ok, %{"widgets" => [%{"result" => %{"limit" => 2}}]}} = Tools.reconcile(proposal, context)
    assert {:error, :command_id_conflict} = Tools.reconcile(put_in(proposal, ["args", "limit"], 1), context)
    Application.put_env(:symphony_elixir, :chat_test_board, %{board | control: Orchestrator.control_snapshot(pid)})
    reset = propose(context, %{"action" => "set_concurrency", "limit" => nil}) |> Map.put("id", "c63f2004-17cf-4f50-bae7-e1368b8d046b")
    assert {:ok, %{"widgets" => [%{"result" => %{"limit" => nil}}]}} = Tools.confirm(reset, context)
    assert %{"effective" => 3, "override" => nil} = Orchestrator.control_snapshot(pid)["settings"]["concurrency"]
  end

  test "creation requires an explicit nonempty queue label and a supported fixed GitHub repository", ctx do
    proposal = propose(ctx.context, %{"action" => "create_task", "title" => "New", "body" => "Body"})
    configure(put_in(ctx.config, [:tracker, :required_labels], []))
    fingerprint = Orchestrator.tracker_fingerprint()
    context = %{ctx.context | tracker_fingerprint: fingerprint, auth: %{ctx.context.auth | tracker_fingerprint: fingerprint}}
    assert {:error, :backlog_creation_requires_queue_labels} = Tools.call("symphony_propose_action", %{"action" => "create_task", "title" => "New", "body" => "Body"}, context)
    assert {:error, :unauthorized} = Tools.confirm(proposal, ctx.context)
  end

  test "board URLs encode values and ignore unrecognized navigation instructions" do
    url = Tools.board_url("github:example/repo", %{"q" => "x & y", "redirect" => "https://evil", "project" => "other"})
    assert URI.decode_query(URI.parse(url).query) == %{"project" => "github:example/repo", "q" => "x & y"}
  end

  test "missing workflow configuration is unavailable even before a session can be restored", ctx do
    path = Workflow.workflow_file_path()
    running = is_pid(Process.whereis(WorkflowStore))
    if running, do: Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    try do
      Workflow.set_workflow_file_path(path <> ".missing")
      assert {:error, :configuration_unavailable} = Tools.call("symphony_project_status", %{}, ctx.context)
    after
      Workflow.set_workflow_file_path(path)
      if running, do: Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    end
  end

  test "task details safely represent an absent description", ctx do
    Application.put_env(:symphony_elixir, :chat_test_board, put_in(ctx.board, [:tasks, Access.at(0), :description], nil))
    assert {:ok, %{"widgets" => [%{"task" => %{"description" => nil}}]}} = Tools.call("symphony_task_details", %{"task_id" => "1"}, ctx.context)
  end

  test "non-GitHub projects cannot acquire GitHub write capabilities", ctx do
    configure(put_in(ctx.config, [:tracker], %{kind: "memory", project_slug: "team"}))
    fingerprint = Orchestrator.tracker_fingerprint()
    context = %{ctx.context | project_id: "memory:team", tracker_fingerprint: fingerprint, auth: %{ctx.context.auth | tracker_fingerprint: fingerprint}}
    Application.put_env(:symphony_elixir, :chat_test_board, %{ctx.board | tasks: []})
    assert {:error, :github_tracker_required} = Tools.call("symphony_propose_action", %{"action" => "create_task", "title" => "New", "body" => "Body"}, context)
  end

  test "confirmation and recovery contain unexpected adapter crashes without resubmission", ctx do
    proposal = propose(ctx.context, %{"action" => "create_task", "title" => "New", "body" => "Body"})

    for failure <- [fn _, _, _, _, _ -> raise "secret" end, fn _, _, _, _, _ -> throw("secret") end] do
      Application.put_env(:symphony_elixir, :chat_github_request, failure)
      assert {:error, :write_outcome_unknown} = Tools.confirm(proposal, ctx.context)
      assert {:error, :write_outcome_unknown} = Tools.reconcile(proposal, ctx.context)
    end
  end

  test "existing feedback markers recover the result without another comment", ctx do
    proposal = propose(ctx.context, %{"action" => "feedback", "task_id" => "1", "body" => "Feedback"})
    script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: [%{"body" => marker(proposal)}]}} end])
    assert {:ok, %{"widgets" => [%{"summary" => "Feedback already recorded."}]}} = Tools.confirm(proposal, ctx.context)
    assert_finished()
  end

  test "reconciliation is bounded and duplicate markers require attention", ctx do
    proposal = propose(ctx.context, %{"action" => "create_task", "title" => "New", "body" => "Body"})
    assert {:error, :invalid_proposal} = Tools.reconcile(%{proposal | "created_at" => "not-a-date"}, ctx.context)
    script(List.duplicate(fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: List.duplicate(%{"body" => "unrelated"}, 100)}} end, 5))
    assert {:error, :reconciliation_limit} = Tools.reconcile(proposal, ctx.context)
    assert_finished()
    script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: List.duplicate(%{"body" => marker(proposal)}, 2)}} end])
    assert {:error, :duplicate_write_marker} = Tools.reconcile(proposal, ctx.context)
    assert_finished()
  end

  test "explicit GitHub rejection and malformed successful responses cannot become receipts", ctx do
    proposal = propose(ctx.context, %{"action" => "create_task", "title" => "New", "body" => "Body"})

    for status <- [401, 403, 404, 409, 410, 422, 429] do
      script([fn "GET", _, _, _, _ -> {:ok, %{status: status, body: %{}}} end])
      assert {:error, {:github_rejected, ^status}} = Tools.confirm(proposal, ctx.context)
    end

    script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: %{}}} end])
    assert {:error, :invalid_github_response} = Tools.confirm(proposal, ctx.context)
    malformed_write = fn "POST", _, _, _, _ -> {:ok, %{status: 201, body: %{}}} end
    script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: []}} end, malformed_write])
    assert {:error, :write_outcome_unknown} = Tools.confirm(proposal, ctx.context)
  end

  test "auth expiry after a write remains an unknown outcome, never a failed clean retry", ctx do
    proposal = propose(ctx.context, %{"action" => "create_task", "title" => "New", "body" => "Body"})

    script([
      fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: []}} end,
      fn "POST", _, _, body, _ ->
        System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("r", 40))
        {:ok, %{status: 201, body: Map.put(body, "number", 3)}}
      end
    ])

    assert {:error, :write_outcome_unknown} = Tools.confirm(proposal, ctx.context)
    assert_finished()
  end

  test "edits without priority touch only previewed fields and preserve existing labels", ctx do
    Application.put_env(:symphony_elixir, :chat_test_board, put_in(ctx.board, [:tasks, Access.at(0), :hold], "cancelled"))
    proposal = propose(ctx.context, %{"action" => "edit_task", "task_id" => "1", "body" => "New body"})

    script([
      fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: raw_issue()}} end,
      fn "PATCH", _, _, body, _ ->
        refute Map.has_key?(body, "labels")
        assert body["body"] =~ "New body"
        {:ok, %{status: 200, body: body}}
      end
    ])

    assert {:ok, _} = Tools.confirm(proposal, ctx.context)
    assert_finished()
  end

  test "HTTP transport sends bounded requests once and does not follow redirects" do
    for {method, status, body} <- [{"GET", 200, nil}, {"POST", 503, %{"body" => "text"}}, {"PATCH", 302, %{"title" => "updated"}}] do
      {port, server} = http_server(status)
      settings = %{api_url: "http://127.0.0.1:#{port}", token: "test-token"}
      assert {:ok, %{status: ^status, body: %{}}} = ChatGitHub.request_once(method, "/bounded", %{}, body, settings)
      assert Task.await(server) == :ok
    end

    settings = %{api_url: "http://127.0.0.1:1", token: "test-token"}
    assert {:error, :github_unavailable} = ChatGitHub.request_once("GET", "/bounded", %{}, nil, settings)
  end

  test "native owner timeouts remain uncertain and native recovery only reads exact command evidence", ctx do
    proposal = propose(ctx.context, %{"action" => "cancel", "task_id" => "GH-1"})
    assert proposal["args"]["task_id"] == "1"
    context = Map.put(ctx.context, :orchestrator, :missing_chat_test_owner)
    assert {:error, :write_outcome_unknown} = Tools.confirm(proposal, context)
    Application.put_env(:symphony_elixir, :chat_test_receipt, {:ok, %{"revision" => 4, "replayed" => true}})
    assert {:ok, %{"widgets" => [%{"result" => %{"revision" => 4}}]}} = Tools.reconcile(proposal, context)
    assert_receive {:receipt_read, command, _fingerprint}
    assert command == %{"action" => "cancel", "issue_id" => "1", "expected_revision" => 3, "command_id" => @proposal_id}
  end

  test "a guarded edit call timeout cannot be reported as a clean rejection", ctx do
    Application.put_env(:symphony_elixir, :chat_test_board, put_in(ctx.board, [:tasks, Access.at(0), :hold], "cancelled"))
    proposal = propose(ctx.context, %{"action" => "edit_task", "task_id" => "1", "body" => "New body"})
    Application.put_env(:symphony_elixir, :chat_test_guard_result, {:error, :unavailable})
    assert {:error, :write_outcome_unknown} = Tools.confirm(proposal, ctx.context)
  end

  test "queue changes only routing labels under the cancelled owner guard and retain admission checks", ctx do
    board = put_in(ctx.board, [:tasks, Access.at(0), :hold], "cancelled")
    Application.put_env(:symphony_elixir, :chat_test_board, board)

    for {action, previous, expected} <- [
          {"queue_task", ["publish-approved"], ["publish-approved", "ready"]},
          {"queue_task", ["publish-approved", "Ready"], ["publish-approved", "Ready"]},
          {"unqueue_task", ["publish-approved", "Ready"], ["publish-approved"]}
        ] do
      proposal = propose(ctx.context, %{"action" => action, "task_id" => "1"})
      assert proposal["queue_labels"] == ["ready"]
      assert {:error, :proposal_changed} = Tools.confirm(%{proposal | "queue_labels" => ["publish-approved"]}, ctx.context)
      source = Map.put(raw_issue(), "labels", previous)

      script([
        fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: source}} end,
        fn "PATCH", _, _, body, _ ->
          assert body["labels"] == expected
          issue = Map.merge(body, %{"state" => "open", "title" => "Task", "number" => 1})
          normalized = GitHubClient.normalize_issue_for_test(issue, "example/repo")
          [admitted] = Admission.evaluate([normalized], fn _ids -> {:ok, []} end)
          refute admitted.dispatchable
          assert admitted.native_ref["admission_reason"] =~ "Depends on:"
          {:ok, %{status: 200, body: issue}}
        end
      ])

      assert {:ok, %{"widgets" => [%{"summary" => summary}]}} = Tools.confirm(proposal, ctx.context)
      assert summary =~ "cancelled"
      assert_receive {:guarded_edit, _, 3, "1"}
      assert_finished()
    end
  end

  test "queue changes cannot select labels or requeue an already routed unheld task", ctx do
    args = %{"action" => "queue_task", "task_id" => "1"}
    assert {:error, :task_not_queueable} = Tools.call("symphony_propose_action", args, ctx.context)
    assert {:error, :invalid_arguments} = Tools.call("symphony_propose_action", Map.put(args, "labels", ["publish-approved"]), ctx.context)
    board = put_in(ctx.board, [:tasks, Access.at(0), :hold], "cancelled")
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    configure(put_in(ctx.config, [:tracker, :required_labels], []))
    fingerprint = Orchestrator.tracker_fingerprint()
    context = %{ctx.context | tracker_fingerprint: fingerprint, auth: %{ctx.context.auth | tracker_fingerprint: fingerprint}}
    assert {:error, :queue_labels_unconfigured} = Tools.call("symphony_propose_action", args, context)
  end

  test "an unheld backlog task queues through its serialized owner and preserves other labels", ctx do
    backlog = update_in(ctx.board, [:tasks, Access.at(0)], &Map.merge(&1, %{stage: "backlog", labels: ["documentation"]}))
    Application.put_env(:symphony_elixir, :chat_test_board, backlog)
    proposal = propose(ctx.context, %{"action" => "queue_task", "task_id" => "GH-1"})
    assert proposal["queue_unheld"] == true
    assert proposal["queue_labels"] == ["ready"]
    assert {:error, :proposal_changed} = Tools.confirm(Map.delete(proposal, "queue_unheld"), ctx.context)

    source = Map.merge(raw_issue(), %{"state" => "open", "labels" => ["documentation"]})

    script([
      fn "GET", "/repos/example/repo/issues/1", _, _, _ -> {:ok, %{status: 200, body: source}} end,
      fn "PATCH", "/repos/example/repo/issues/1", _, body, _ ->
        assert body["labels"] == ["documentation", "ready"]
        assert body["body"] == source["body"] <> "\n\n" <> marker(proposal)
        refute Map.has_key?(body, "state")
        {:ok, %{status: 200, body: Map.merge(source, body)}}
      end
    ])

    assert {:ok, %{"widgets" => [%{"summary" => summary}]}} = Tools.confirm(proposal, ctx.context)
    assert summary =~ "Task queued"
    assert summary =~ "paused controller remains paused"
    refute summary =~ "Retry"
    assert_receive :guarded_unheld_queue
    assert_finished()
  end

  test "queue previews retain fresh task scope for both unheld and cancelled tasks", ctx do
    description = "## Outcome\n\nCurrent scope, preserved exactly.\n\nDepends on: none"

    for hold <- [nil, "cancelled"] do
      current = %{stage: "backlog", labels: [], hold: hold, title: "Updated task title", description: description}
      board = update_in(ctx.board, [:tasks, Access.at(0)], &Map.merge(&1, current))
      Application.put_env(:symphony_elixir, :chat_test_board, board)
      proposal = propose(ctx.context, %{"action" => "queue_task", "task_id" => "1"})
      assert proposal["task_title"] == "Updated task title"
      assert proposal["task_description"] == description

      for change <- [%{title: "Changed again"}, %{description: "Different scope\n\nDepends on: none"}] do
        changed = update_in(board, [:tasks, Access.at(0)], &Map.merge(&1, change))
        Application.put_env(:symphony_elixir, :chat_test_board, changed)
        assert {:error, :task_changed} = Tools.confirm(proposal, ctx.context)
        refute_receive {:guarded_edit, _, _, _}
      end
    end
  end

  test "fresh queue rejects held, running, reserved, reviewed and closed tasks", ctx do
    fresh = %{stage: "backlog", labels: [], hold: nil, runtime: nil, ledger: %{}, handoff: nil, tracker_state: "open"}

    changes = [
      %{hold: "owner_review"},
      %{hold: "interrupted"},
      %{runtime: %{status: "running"}},
      %{ledger: %{"active" => %{}}},
      %{handoff: %{}},
      %{tracker_state: "closed"}
    ]

    for changed <- changes do
      task = ctx.board.tasks |> hd() |> Map.merge(fresh) |> Map.merge(changed)
      Application.put_env(:symphony_elixir, :chat_test_board, %{ctx.board | tasks: [task]})
      assert {:error, _} = Tools.call("symphony_propose_action", %{"action" => "queue_task", "task_id" => "1"}, ctx.context)
    end
  end

  test "queue confirmation rejects a newly held task and rechecks open unqueued state inside the owner", ctx do
    backlog = update_in(ctx.board, [:tasks, Access.at(0)], &Map.merge(&1, %{stage: "backlog", labels: []}))
    Application.put_env(:symphony_elixir, :chat_test_board, backlog)
    proposal = propose(ctx.context, %{"action" => "queue_task", "task_id" => "1"})
    held = put_in(backlog, [:tasks, Access.at(0), :hold], "cancelled")
    Application.put_env(:symphony_elixir, :chat_test_board, held)
    assert {:error, :proposal_changed} = Tools.confirm(proposal, ctx.context)
    Application.put_env(:symphony_elixir, :chat_test_board, backlog)

    for changed <- [%{"state" => "closed", "labels" => []}, %{"state" => "open", "labels" => ["READY"]}] do
      source = Map.merge(raw_issue(), changed)
      script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: source}} end])
      assert {:error, :task_not_queueable} = Tools.confirm(proposal, ctx.context)
      assert_finished()
    end

    source = Map.merge(raw_issue(), %{"state" => "open", "labels" => [], "updated_at" => "2026-09-15T10:00:01Z"})
    script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: source}} end])
    assert {:error, :task_changed} = Tools.confirm(proposal, ctx.context)
    assert_finished()
  end

  test "an uncertain fresh queue outcome is recovered without another write", ctx do
    backlog = update_in(ctx.board, [:tasks, Access.at(0)], &Map.merge(&1, %{stage: "backlog", labels: []}))
    Application.put_env(:symphony_elixir, :chat_test_board, backlog)
    proposal = propose(ctx.context, %{"action" => "queue_task", "task_id" => "1"})
    source = Map.merge(raw_issue(), %{"state" => "open", "labels" => []})
    completed = Map.merge(source, %{"labels" => ["ready"], "body" => source["body"] <> "\n\n" <> marker(proposal)})

    script([
      fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: source}} end,
      fn "PATCH", _, _, _, _ -> {:error, :timeout} end,
      fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: completed}} end
    ])

    assert {:error, :write_outcome_unknown} = Tools.confirm(proposal, ctx.context)
    assert {:ok, %{"widgets" => [%{"summary" => "Task update recovered from GitHub."}]}} = Tools.reconcile(proposal, ctx.context)
    assert_finished()
  end

  test "priority edits cannot remove reserved routing labels", ctx do
    board = put_in(ctx.board, [:tasks, Access.at(0), :hold], "cancelled")
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    configure(put_in(ctx.config, [:tracker, :required_labels], ["priority:p1"]))
    fingerprint = Orchestrator.tracker_fingerprint()
    context = %{ctx.context | tracker_fingerprint: fingerprint, auth: %{ctx.context.auth | tracker_fingerprint: fingerprint}}
    args = %{"action" => "edit_task", "task_id" => "1", "priority" => 2}
    assert {:error, :priority_label_reserved} = Tools.call("symphony_propose_action", args, context)
  end

  test "project documents use a pinned default-branch revision without relying on a healthy board", ctx do
    revision = String.duplicate("a", 40)
    Application.put_env(:symphony_elixir, :chat_test_board, fn -> raise "No board read should be needed" end)

    for document <- ~w(ARCHITECTURE.md WORKFLOW.md PROJECT.md README.md AGENTS.md) do
      script([
        fn "GET", "/repos/example/repo/commits", %{"per_page" => 1}, nil, _ ->
          {:ok, %{status: 200, body: [%{"sha" => revision}]}}
        end,
        fn "GET", path, %{"ref" => ^revision}, nil, _ ->
          assert path == "/repos/example/repo/contents/#{document}"
          {:ok, %{status: 200, body: document_payload(document, "# Project\nA committed explanation.")}}
        end
      ])

      assert {:ok, result} = Tools.call("symphony_read_project_document", %{"document" => document}, ctx.context)
      assert result["document"]["text"] =~ "A committed explanation."
      assert [%{"revision" => ^revision, "url" => url}] = result["references"]
      assert url == "https://github.com/example/repo/blob/#{revision}/#{document}"
      assert_finished()
    end
  end

  test "document reads cannot select arbitrary paths, URLs, projects or revisions", ctx do
    for args <- [
          %{},
          %{"document" => "../AGENTS.md"},
          %{"document" => ".env"},
          %{"document" => "https://evil.example"},
          %{"document" => "README.md", "ref" => "main"},
          %{"document" => "README.md", "project" => "other"}
        ] do
      assert {:error, :invalid_arguments} = Tools.call("symphony_read_project_document", args, ctx.context)
    end

    invalid = %{ctx.context | project_id: "github:other/repo"}
    assert {:error, :project_mismatch} = Tools.call("symphony_read_project_document", %{"document" => "README.md"}, invalid)
  end

  test "document decoding rejects malformed, oversized and non-UTF8 content", ctx do
    valid = document_payload("README.md", "Valid")

    payloads = [
      nil,
      Map.put(valid, "encoding", "none"),
      Map.put(valid, "path", ".env"),
      Map.put(valid, "type", "dir"),
      Map.put(valid, "content", "%%%"),
      Map.put(valid, "content", String.duplicate("a", 180_001)),
      document_payload("README.md", String.duplicate("a", 131_073)),
      document_payload("README.md", <<255>>),
      document_payload("README.md", <<0>>)
    ]

    for payload <- payloads do
      document_script(payload)
      assert {:error, :invalid_document} = Tools.call("symphony_read_project_document", %{"document" => "README.md"}, ctx.context)
      assert_finished()
    end
  end

  test "document lookup rejects invalid revisions and revoked auth before reading content", ctx do
    args = %{"document" => "README.md"}

    for body <- [[], %{}, [%{"sha" => "main"}], [%{"sha" => "../private"}], [%{"sha" => 42}]] do
      script([fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: body}} end])
      assert {:error, :invalid_revision} = Tools.call("symphony_read_project_document", args, ctx.context)
      assert_finished()
    end

    script([
      fn "GET", _, _, _, _ ->
        System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("r", 40))
        {:ok, %{status: 200, body: [%{"sha" => String.duplicate("a", 40)}]}}
      end
    ])

    assert {:error, :unauthorized} = Tools.call("symphony_read_project_document", args, ctx.context)
    assert_finished()
  end

  test "unavailable and crashing document reads are scrubbed", ctx do
    args = %{"document" => "README.md"}
    script([fn "GET", _, _, _, _ -> {:ok, %{status: 404, body: %{}}} end])
    assert {:error, {:github_rejected, 404}} = Tools.call("symphony_read_project_document", args, ctx.context)

    for failure <- [fn _, _, _, _, _ -> raise "private-token" end, fn _, _, _, _, _ -> throw("private-token") end] do
      Application.put_env(:symphony_elixir, :chat_github_request, failure)
      assert {:error, :document_unavailable} = Tools.call("symphony_read_project_document", args, ctx.context)
    end
  end

  @tag timeout: 10_000
  test "the entire document lookup has a five-second deadline", ctx do
    owner = self()

    script([
      fn "GET", _, _, _, _ ->
        send(owner, {:document_reader, self()})
        receive do: (:finish -> {:error, :unexpected})
      end
    ])

    assert {:error, :document_unavailable} = Tools.call("symphony_read_project_document", %{"document" => "README.md"}, ctx.context)
    assert_receive {:document_reader, reader}
    refute Process.alive?(reader)
    assert_finished()
  end

  test "tool errors preserve safe recovery guidance without exposing unknown exception details" do
    assert %{"code" => "cancel_task_before_edit", "message" => message} = Tools.error_message(:cancel_task_before_edit)
    assert message =~ "Cancel"
    assert Tools.error_message(:task_changed)["message"] =~ "fresh proposal"
    assert Tools.error_message({:github_rejected, 403})["code"] == "github_rejected"

    for reason <- [:unexpected, "private-token", {:failed, "private-token"}, {:github_rejected, "private-token"}] do
      assert %{"code" => "tool_unavailable"} = error = Tools.error_message(reason)
      refute Jason.encode!(error) =~ "private-token"
    end
  end

  defp document_payload(path, text), do: %{"type" => "file", "path" => path, "encoding" => "base64", "content" => Base.encode64(text)}

  defp document_script(payload) do
    script([
      fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: [%{"sha" => String.duplicate("a", 40)}]}} end,
      fn "GET", _, _, _, _ -> {:ok, %{status: 200, body: payload}} end
    ])
  end

  defp http_server(status) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, {_ip, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        assert request =~ "/bounded"
        :ok = :gen_tcp.send(socket, "HTTP/1.1 #{status} Test\r\nContent-Type: application/json\r\nContent-Length: 2\r\nLocation: http://127.0.0.1:1/unexpected\r\nConnection: close\r\n\r\n{}")
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {port, server}
  end

  defp put_pr_work(ctx, work_id, fields) do
    work = Map.merge(%{"id" => work_id, "issue_id" => "1", "tracker_fingerprint" => ctx.context.tracker_fingerprint, "head_sha" => nil}, fields)
    board = put_in(ctx.board, [:tasks, Access.at(0), :ledger], %{"pr_work" => %{work_id => work}, "selected_work_id" => work_id})
    Application.put_env(:symphony_elixir, :chat_test_board, board)
    work
  end

  defp propose(context, args) do
    assert {:ok, %{"proposal" => proposal, "widgets" => [%{"type" => "proposal"}]}} = Tools.call("symphony_propose_action", args, context)
    Map.put(proposal, "id", @proposal_id)
  end

  defp script(steps) do
    {:ok, agent} = Agent.start_link(fn -> steps end)
    Process.put(:chat_request_script, agent)

    Application.put_env(:symphony_elixir, :chat_github_request, fn method, path, params, body, settings ->
      step =
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> raise "Unexpected HTTP request"
        end)

      step.(method, path, params, body, settings)
    end)
  end

  defp assert_finished, do: assert(Agent.get(Process.get(:chat_request_script), & &1) == [])
  defp marker(proposal), do: "<!-- symphony-chat:#{proposal["id"]} -->"
  defp raw_issue, do: %{"number" => 1, "updated_at" => "2026-09-15T10:00:00Z", "body" => "Existing description"}

  defp issue(id, attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: id,
          identifier: "GH-#{id}",
          title: "Task #{id}",
          state: "open",
          description: "Depends on: none",
          labels: ["ready"],
          dispatchable: true,
          native_ref: %{"repo" => "example/repo"},
          updated_at: ~U[2026-09-15 10:00:00Z]
        ],
        attrs
      )
    )
  end

  defp configure(config) do
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    assert :ok = WorkflowStore.force_reload()
  end
end
