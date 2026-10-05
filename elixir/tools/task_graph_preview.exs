# From elixir/: mix run --no-start tools/task_graph_preview.exs [--port 8778] [--check]
# Review fixture only. Never load the application or an existing operator config.
Code.require_file("../test/fixtures/task_graph.exs", __DIR__)

defmodule SymphonyElixirWeb.TaskGraphPreview.Runtime do
  @moduledoc false
  use GenServer

  def start_link(board), do: GenServer.start_link(__MODULE__, board, name: __MODULE__)

  @impl true
  def init(board), do: {:ok, board}

  @impl true
  def handle_call(:board, _from, board),
    do: {:reply, %{board | generated_at: DateTime.utc_now() |> DateTime.to_iso8601()}, board}

  def handle_call(:snapshot, _from, board), do: {:reply, board.runtime, board}
  def handle_call(:control_snapshot, _from, board), do: {:reply, board.control, board}
  def handle_call(_command, _from, board), do: {:reply, {:error, :control_disabled}, board}

  @impl true
  def handle_cast(_command, board), do: {:noreply, board}

  @impl true
  def handle_info(_message, board), do: {:noreply, board}
end

defmodule SymphonyElixirWeb.TaskGraphPreview.Chat do
  @moduledoc false
  @project "github:example/graph-preview"

  def health(_auth), do: {:ok, %{enabled: false, healthy: true}}
  def projects(_auth), do: {:ok, [%{"id" => @project, "label" => "Synthetic scale preview"}]}
  def list(_project, _auth), do: {:ok, []}
  def get(_project, _id, _auth), do: {:error, :chat_not_found}
  def ensure_pr_conversation(_project, _task, _session, _auth), do: {:error, :control_disabled}

  # This stateless navigation placeholder creates no conversation, response or job.
  def ensure_conversation(@project, task, _auth) do
    {:ok,
     %{
       "id" => :crypto.hash(:md5, @project <> (task || "main")) |> Base.encode16(case: :lower),
       "project_id" => @project,
       "task_id" => task,
       "conversation_role" => if(task, do: "task", else: "main"),
       "title" => "Preview navigation · no model runtime",
       "status" => "idle",
       "queued_count" => 0,
       "queue_paused" => true,
       "queue" => [],
       "archived" => false,
       "messages" => [],
       "proposals" => [],
       "context" => [],
       "error" => nil,
       "activity" => nil,
       "updated_at" => "2026-10-04T00:00:00Z"
     }}
  end

  def ensure_conversation(_project, _task, _auth), do: {:error, :project_not_found}

  for {operation, arity} <- [
        create: 3,
        pin: 4,
        move: 5,
        stop: 3,
        remove_queued: 4,
        prioritize_queued: 4,
        resume_queue: 3,
        decide: 5,
        send_message_with_context: 6
      ] do
    def unquote(operation)(unquote_splicing(List.duplicate({:_, [], nil}, arity))), do: {:error, :control_disabled}
  end
end

defmodule SymphonyElixirWeb.TaskGraphPreview.Intake do
  @moduledoc false
  def list(_project, _auth), do: {:ok, []}
  def get(_project, _id, _auth), do: {:error, :control_disabled}
  def prepare(_project, _id, _args, _auth), do: {:error, :control_disabled}
  def decide(_project, _id, _decision, _auth), do: {:error, :control_disabled}
end

defmodule SymphonyElixirWeb.TaskGraphPreview do
  @moduledoc false
  alias SymphonyElixir.Assurance.{Contract, GraphSnapshot, Store}
  alias SymphonyElixir.{Config, PathSafety, Workflow, WorkflowStore}
  alias SymphonyElixirWeb.{AssuranceObservations, BoardCache, BrowserAuth, BrowserSessions, Endpoint, TaskGraphFixture}
  alias SymphonyElixirWeb.TaskGraphPreview.{Chat, Intake, Runtime}

  @project "github:example/graph-preview"
  # Public synthetic fixture token, unrelated to any operator or model credential.
  @token "symphony-preview-local-token-only"
  @forbidden [
    SymphonyElixir.Supervisor,
    SymphonyElixir.AgentRuntimeSupervisor,
    SymphonyElixir.Orchestrator,
    SymphonyElixir.Chat.Store
  ]

  def main(args) do
    {options, [], []} = OptionParser.parse(args, strict: [port: :integer, check: :boolean])
    port = Keyword.get(options, :port, 8778)
    if port not in 1..65_535, do: raise(ArgumentError, "Choose a port from 1 to 65535")
    assert_no_execution_owner!()
    clear_inherited_authority()

    for app <- [:logger, :phoenix_live_view, :bandit, :ecto, :yaml_elixir, :req] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    {:ok, root} =
      PathSafety.canonicalize(
        Path.join(System.tmp_dir!(), "symphony-graph-preview-#{System.unique_integer([:positive])}")
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    try do
      run(root, port, options[:check] == true)
    after
      File.rm_rf!(root)
    end
  end

  defp run(root, port, check) do
    workflow = Path.join(root, "WORKFLOW.md")
    write_workflow(workflow, root)
    :ok = Workflow.set_workflow_file_path(workflow)

    {:ok, supervisor} =
      Supervisor.start_link(
        [{Phoenix.PubSub, name: SymphonyElixir.PubSub}, WorkflowStore, BoardCache, BrowserSessions],
        strategy: :one_for_one
      )

    try do
      settings = Config.settings!()
      reviewed_board = TaskGraphFixture.preview_board(settings)
      current_board = TaskGraphFixture.preview_changed(reviewed_board, settings.tracker)
      {:ok, _} = Supervisor.start_child(supervisor, {Runtime, current_board})

      {:ok, _} =
        Supervisor.start_child(
          supervisor,
          {Store,
           state_dir: Path.join(root, "assurance"),
           project: @project,
           scope: fn -> "isolated-graph-preview-v1" end,
           authorize: fn auth -> auth == :preview_seed or BrowserAuth.authorized?(auth) end,
           verify_evidence: fn _, _ -> false end}
        )

      seed(reviewed_board)
      self_check(reviewed_board, current_board)

      if check do
        IO.puts(
          "Preview check passed: 1000 tasks, 3000 dependencies, immutable graph history, uncovered/stale criteria, release not ready, commands disabled."
        )
      else
        configure_endpoint()

        {:ok, _} =
          Supervisor.start_child(
            supervisor,
            {SymphonyElixir.HttpServer, port: port, host: "127.0.0.1", orchestrator: Runtime}
          )

        :ok = BoardCache.put(BoardCache.scope(Runtime), current_board)
        IO.puts("Synthetic review preview: http://localhost:#{port}/?view=graph")
        IO.puts("Unlock in Settings with synthetic token: #{@token}")

        IO.puts(
          "1000 tasks / 3000 dependencies; Coverage has reviewed history, current changes and missing evidence. No execution, task intake, publication or model runtime."
        )

        IO.puts("Temporary state: #{root}. Press Enter to stop and remove it. EOF also stops the preview.")
        IO.gets("")
      end
    after
      Supervisor.stop(supervisor, :normal, 15_000)
    end
  end

  defp configure_endpoint do
    existing = Application.get_env(:symphony_elixir, Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      Endpoint,
      Keyword.merge(existing,
        board_read_only: false,
        board_loader: fn _, _ -> GenServer.call(Runtime, :board) end,
        snapshot_loader: fn -> GenServer.call(Runtime, :snapshot) end,
        assurance_store: Store,
        chat_store: Chat,
        task_intake: Intake
      )
    )
  end

  defp write_workflow(path, root) do
    config = %{
      "tracker" => %{
        "kind" => "github",
        "provider" => %{"repo" => "example/graph-preview", "token" => "synthetic-no-tracker-token"},
        "active_states" => ["open"],
        "terminal_states" => ["closed"],
        "required_labels" => ["ready"]
      },
      "control" => %{
        "enabled" => false,
        "initial_mode" => "paused",
        "state_path" => Path.join(root, "unused-control.json")
      },
      "chat" => %{"enabled" => true, "state_path" => Path.join(root, "unused-chat")},
      "browser_auth" => %{"provider" => "local_token"},
      "workspace" => %{"root" => Path.join(root, "unused-workspaces")},
      "server" => %{"port" => nil, "host" => "127.0.0.1", "session_cookie" => "_symphony_graph_preview"},
      "observability" => %{"dashboard_enabled" => false}
    }

    File.write!(
      path,
      "---\n" <> Jason.encode!(config) <> "\n---\nSynthetic graph review only; all execution commands are disabled.\n"
    )

    File.chmod!(path, 0o600)
    System.put_env("SYMPHONY_CONTROL_TOKEN", @token)
  end

  defp seed(board) do
    tasks = Map.new(board.tasks, &{&1.issue_id, &1})

    document = %{
      "version" => 1,
      "project" => @project,
      "requirements" => [
        requirement(
          "REQ-NAV",
          "Navigate task dependencies",
          "functional",
          "AC-NAV",
          "Select a task, inspect prerequisites and retain focus across Graph and Kanban.",
          [
            "ui-navigation",
            "independent-review"
          ]
        ),
        requirement(
          "REQ-SCALE",
          "Keep large graphs usable",
          "nonfunctional",
          "AC-SCALE",
          "Explore 1000 tasks and 3000 dependencies using bounded graph pages.",
          ["graph-benchmark"]
        ),
        requirement(
          "REQ-RELEASE",
          "Trace a release to exact evidence",
          "functional",
          "AC-RELEASE",
          "Bind integrated source, immutable artifact and runtime target to their required receipts.",
          [
            "source-ci"
          ]
        )
      ],
      "task_links" =>
        Enum.map([{"1", "AC-NAV"}, {"2", "AC-SCALE"}], fn {id, criterion} ->
          %{
            "task_id" => tasks[id].id,
            "criterion_id" => criterion,
            "task_revision" => AssuranceObservations.revision(tasks[id]),
            "subject" => nil
          }
        end),
      "dependencies" => [
        %{
          "task_id" => tasks["1"].id,
          "depends_on" => tasks["2"].id,
          "reason" => "Synthetic schema contract",
          "output" => "Versioned schema",
          "reviewed_ref" => nil
        }
      ]
    }

    {:ok, saved} = Store.save(@project, 0, document, :preview_seed)
    {:ok, reviewed} = Store.baseline_graph(@project, saved["storage_revision"], board.workflow_graph, :preview_seed)

    changed =
      put_in(
        document,
        ["requirements", Access.at(1), "criteria", Access.at(0), "text"],
        "Explore 1000 tasks and 3000 dependencies, with each visible graph page responding within 200ms."
      )

    {:ok, draft} = Store.save(@project, reviewed["storage_revision"], changed, :preview_seed)

    release = %{
      "id" => "synthetic-candidate",
      "baseline_ref" => reviewed["reviewed"]["ref"],
      "task_ids" => Enum.map(document["task_links"], & &1["task_id"]),
      "integrated_sha" => String.duplicate("a", 40),
      "artifact_digest" => "sha256:" <> String.duplicate("b", 64),
      "target" => "synthetic-preview",
      "configuration_ref" => "synthetic-config-v1",
      "required_checks" => ["source-ci"],
      "required_gates" => ["artifact", "deployment", "runtime"],
      "evidence_ids" => []
    }

    {:ok, _} = Store.release(@project, draft["storage_revision"], release, :preview_seed)
  end

  defp requirement(id, title, kind, criterion, text, checks),
    do: %{
      "id" => id,
      "title" => title,
      "kind" => kind,
      "exclusion" => nil,
      "criteria" => [%{"id" => criterion, "text" => text, "required_checks" => checks}]
    }

  defp self_check(reviewed_board, current_board) do
    1_000 = length(current_board.tasks)
    3_000 = Enum.count(current_board.workflow_graph["edges"], &(&1["type"] == "depends_on"))
    {:ok, snapshot} = Store.read(@project, :preview_seed)
    {:ok, current_graph} = GraphSnapshot.capture(current_board.workflow_graph, @project)
    true = GraphSnapshot.valid?(snapshot["reviewed"]["graph_snapshot"], @project)

    %{"nodes" => %{"changed" => [_ | _]}, "edges" => %{"added" => [_ | _], "removed" => [_ | _]}} =
      GraphSnapshot.diff(snapshot["reviewed"]["graph_snapshot"], current_graph)

    {:ok, projection} =
      Store.projection(@project, AssuranceObservations.from_board(current_board, snapshot["draft"]), :preview_seed)

    true = projection["counts"]["stale"] > 0
    true = projection["counts"]["uncovered"] > 0
    0 = projection["counts"]["covered"]
    [%{"ready" => false, "deployment_authority" => false}] = projection["release_readiness"]
    [] = snapshot["evidence"]
    true = Contract.valid_document?(snapshot["draft"], @project)
    {:error, :control_disabled} = GenServer.call(Runtime, {:authorized_control_command, %{}, nil, fn -> true end})
    {:error, :control_disabled} = GenServer.call(Runtime, {:record_pr_publication, %{}})
    {:error, :control_disabled} = Intake.prepare(@project, "preview", %{}, nil)
    {:error, :control_disabled} = Chat.send_message_with_context(@project, "preview", "Start work", "preview", nil, nil)
    true = reviewed_board.workflow_graph != current_board.workflow_graph
    assert_no_execution_owner!()
  end

  defp assert_no_execution_owner! do
    if Enum.any?(@forbidden, &Process.whereis/1),
      do: raise("Use mix run --no-start in a new VM; preview must not share an execution owner")
  end

  defp clear_inherited_authority do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(
      &(String.starts_with?(&1, "SYMPHONY_") or
          &1 in ~w(GITHUB_TOKEN GITHUB_REPO GH_TOKEN LINEAR_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY))
    )
    |> Enum.each(&System.delete_env/1)
  end
end

SymphonyElixirWeb.TaskGraphPreview.main(System.argv())
