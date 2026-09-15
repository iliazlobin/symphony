defmodule SymphonyElixir.Chat.Tools do
  @moduledoc "Project-bound management tools. Model calls can prepare writes; only an operator confirms them."

  alias SymphonyElixir.Chat.GitHub
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.{BoardActions, BrowserAuth, TaskBoard}

  @controls ~w(pause drain resume cancel retry)
  @writes ~w(create_task edit_task feedback queue_task unqueue_task)
  @stages ~w(backlog ready running review done attention)
  @sorts ~w(updated priority title oldest)
  @task_keys ~w(id issue_id identifier title project project_label stage attention priority updated_at created_at tracker_state completion_evidence source_missing hold)a
  @proposal_keys ~w(id action args project_id tracker_fingerprint expected_revision expected_updated_at created_at queue_labels)

  @spec specs() :: [map()]
  def specs do
    [
      spec("symphony_project_status", "Read current project counts, execution state and blockers. Unavailable data is never an idle project.", %{}),
      spec("symphony_search_tasks", "Search this chat's project and render task cards with a filtered board link.", %{
        "q" => string(200),
        "status" => enum(@stages),
        "priority" => enum(~w(P1 P2 P3 P4)),
        "sort" => enum(@sorts),
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
      }),
      spec("symphony_task_details", "Read one task in this chat's project, including its description and current execution evidence.", %{"task_id" => string(240)}, ["task_id"]),
      spec(
        "symphony_propose_action",
        "Prepare an exact action preview for operator approval. Never claim a proposal was executed. create_task makes an unqueued backlog issue. edit_task, queue_task and unqueue_task require a cancelled, idle task and retain its hold: cancel, edit/queue, then retry are separate actions. Queue changes affect only configured routing labels, never bypass admission or launch gates. Feedback adds a GitHub comment without steering a running worker.",
        %{
          "action" => enum(@controls ++ @writes),
          "task_id" => string(240),
          "title" => string(240),
          "body" => string(16_000),
          "state" => enum(~w(open closed)),
          "priority" => %{"type" => "integer", "minimum" => 1, "maximum" => 4}
        },
        ["action"]
      )
    ]
  end

  @spec call(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def call(name, args, context) do
    with {:ok, settings} <- scope(context),
         :ok <- validate(name, args),
         {:ok, board} <- read_board(context) do
      dispatch(name, args, context, settings, board)
    end
  rescue
    _ -> {:error, :tool_unavailable}
  catch
    _, _ -> {:error, :tool_unavailable}
  end

  @doc "Executes only a persisted, explicitly approved proposal. The caller owns durable single-use execution and receipts."
  @spec confirm(map(), map()) :: {:ok, map()} | {:error, term()}
  def confirm(proposal, context) do
    with {:ok, settings} <- scope(context),
         :ok <- validate_proposal(proposal, context),
         {:ok, board} <- read_board(context) do
      execute(proposal, context, settings, board)
    end
  rescue
    _ -> {:error, :write_outcome_unknown}
  catch
    _, _ -> {:error, :write_outcome_unknown}
  end

  @doc "Read-only recovery after an ambiguous GitHub write or process interruption. Never resubmits a write."
  @spec reconcile(map(), map()) :: {:ok, map()} | {:error, term()}
  def reconcile(proposal, context) do
    with {:ok, settings} <- scope(context),
         :ok <- validate_proposal(proposal, context) do
      recover(proposal, settings, context)
    end
  rescue
    _ -> {:error, :write_outcome_unknown}
  catch
    _, _ -> {:error, :write_outcome_unknown}
  end

  @spec board_url(String.t(), map()) :: String.t()
  def board_url(project, filters \\ %{}) do
    allowed = Map.take(filters, ~w(status priority q sort task))
    "/?" <> URI.encode_query(Map.put(allowed, "project", project))
  end

  @doc false
  @spec scope(map()) :: {:ok, map()} | {:error, atom()}
  def scope(context) do
    with {:ok, settings} <- Config.settings(),
         true <- (is_map(context) and BrowserAuth.authorized?(Map.get(context, :auth))) or {:error, :unauthorized},
         true <- context[:tracker_fingerprint] == Orchestrator.tracker_fingerprint() or {:error, :project_changed},
         true <- context[:project_id] == project_id(settings.tracker) or {:error, :project_mismatch} do
      {:ok, settings}
    else
      {:error, reason} when reason in [:unauthorized, :project_changed, :project_mismatch] -> {:error, reason}
      _ -> {:error, :configuration_unavailable}
    end
  end

  defp spec(name, description, properties, required \\ []) do
    %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object", "properties" => properties, "required" => required, "additionalProperties" => false}}
  end

  defp string(maximum), do: %{"type" => "string", "maxLength" => maximum}
  defp enum(values), do: %{"type" => "string", "enum" => values}

  defp validate(name, args) when is_map(args) do
    case Enum.find(specs(), &(&1["name"] == name)) do
      nil -> {:error, :unknown_tool}
      tool -> validate_schema(args, tool["inputSchema"])
    end
  end

  defp validate(_name, _args), do: {:error, :invalid_arguments}

  defp validate_schema(args, schema) do
    properties = schema["properties"]

    valid =
      Enum.all?(schema["required"], &Map.has_key?(args, &1)) and
        Enum.all?(args, fn {key, value} -> Map.has_key?(properties, key) and valid_value?(value, properties[key]) end)

    if valid, do: :ok, else: {:error, :invalid_arguments}
  end

  defp valid_value?(value, %{"enum" => values}), do: value in values

  defp valid_value?(value, %{"type" => "string", "maxLength" => max}) do
    is_binary(value) and String.valid?(value) and byte_size(value) <= max and not String.contains?(value, [<<0>>, "<!-- symphony-chat:"])
  end

  defp valid_value?(value, %{"type" => "integer", "minimum" => min, "maximum" => max}), do: is_integer(value) and value >= min and value <= max

  defp read_board(context) do
    board_module = Application.get_env(:symphony_elixir, :chat_board_module, TaskBoard)
    board = board_module.load(context[:orchestrator] || Orchestrator, 5_000)

    with {:ok, _settings} <- scope(context),
         true <- (is_map(board) and is_list(board[:tasks])) or {:error, :board_unavailable},
         true <- Enum.all?(board.tasks, &(&1[:project] == context.project_id)) or {:error, :project_mismatch} do
      {:ok, board}
    end
  end

  defp dispatch("symphony_project_status", _args, context, _settings, board) do
    counts = Enum.frequencies_by(board.tasks, & &1.stage)

    status = %{
      "type" => "status",
      "counts" => counts,
      "project_id" => context.project_id,
      "control" => Map.take(board[:control] || %{}, ~w(enabled revision mode)),
      "source_error" => board[:source_error],
      "runtime_error" => board[:runtime_error],
      "generated_at" => board[:generated_at],
      "blockers" => board.tasks |> Enum.filter(&is_binary(&1[:attention])) |> Enum.take(50) |> Enum.map(&task_view/1),
      "url" => board_url(context.project_id)
    }

    {:ok, %{"widgets" => [status]}}
  end

  defp dispatch("symphony_search_tasks", args, context, _settings, board) do
    with :ok <- complete_board(board) do
      filters = Map.take(args, ~w(q status priority sort))
      tasks = board.tasks |> Enum.filter(&matches?(&1, args)) |> sort_tasks(args["sort"] || "updated")

      widget = %{
        "type" => "tasks",
        "tasks" => tasks |> Enum.take(args["limit"] || 20) |> Enum.map(&task_view/1),
        "total" => length(tasks),
        "filters" => filters,
        "url" => board_url(context.project_id, filters),
        "project_id" => context.project_id
      }

      {:ok, %{"widgets" => [widget]}}
    end
  end

  defp dispatch("symphony_task_details", args, context, _settings, board) do
    with :ok <- complete_board(board), {:ok, task} <- find_task(args["task_id"], context, board) do
      details = task_view(task) |> Map.put("description", truncate(task[:description], 32_000)) |> Map.put("labels", task[:labels] || [])
      {:ok, %{"widgets" => [%{"type" => "task", "task" => details, "url" => board_url(context.project_id, %{"task" => task.id})}]}}
    end
  end

  defp dispatch("symphony_propose_action", args, context, settings, board) do
    with :ok <- complete_board(board),
         :ok <- action_args(args),
         {:ok, evidence} <- proposal_evidence(args, context, settings, board) do
      action_args = normalized_action_args(args, context, board)

      proposal =
        Map.merge(evidence, %{
          "action" => args["action"],
          "args" => action_args,
          "project_id" => context.project_id,
          "tracker_fingerprint" => context.tracker_fingerprint,
          "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })

      {:ok, %{"proposal" => proposal, "widgets" => [%{"type" => "proposal", "action" => args["action"], "title" => action_title(args["action"]), "details" => proposal}]}}
    end
  end

  defp normalized_action_args(%{"task_id" => id} = args, context, board) do
    {:ok, task} = find_task(id, context, board)
    args |> Map.delete("action") |> Map.put("task_id", task.issue_id)
  end

  defp normalized_action_args(args, _context, _board), do: Map.delete(args, "action")

  defp complete_board(%{source_error: nil, runtime_error: nil}), do: :ok
  defp complete_board(_board), do: {:error, :board_unavailable}

  defp task_view(task) do
    task
    |> Map.take(@task_keys)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("url", board_url(task.project, %{"task" => task.id}))
  end

  defp truncate(text, max) when is_binary(text), do: String.slice(text, 0, max)
  defp truncate(_text, _max), do: nil

  defp matches?(task, args) do
    query = String.downcase(args["q"] || "")
    text = Enum.join([task[:title], task[:identifier]], " ") |> String.downcase()
    stage_matches?(task, args["status"]) and priority_matches?(task, args["priority"]) and String.contains?(text, query)
  end

  defp stage_matches?(_task, nil), do: true
  defp stage_matches?(task, "attention"), do: not is_nil(task[:attention])
  defp stage_matches?(task, stage), do: task.stage == stage
  defp priority_matches?(_task, nil), do: true
  defp priority_matches?(task, priority), do: "P#{task[:priority]}" == priority

  defp sort_tasks(tasks, "title"), do: Enum.sort_by(tasks, &String.downcase(&1.title))
  defp sort_tasks(tasks, "priority"), do: Enum.sort_by(tasks, &{&1[:priority] || 99, &1.id})
  defp sort_tasks(tasks, "oldest"), do: Enum.sort_by(tasks, &{&1[:created_at] || "9999", &1.id})
  defp sort_tasks(tasks, "updated"), do: Enum.sort_by(tasks, &{&1[:updated_at] || "", &1.id}, :desc)

  defp find_task(id, context, board) when is_binary(id) do
    task = Enum.find(board.tasks, &(id in [&1.id, &1.issue_id, &1.identifier]))

    if task && task.project == context.project_id && not task[:source_missing] do
      {:ok, task}
    else
      {:error, :task_not_found}
    end
  end

  defp action_args(%{"action" => action} = args) do
    {allowed, required} = action_fields(action)

    valid =
      Enum.all?(Map.keys(args), &(&1 in allowed)) and Enum.all?(required, &present?(args[&1])) and
        valid_edit_fields?(args) and valid_title?(args)

    if valid, do: :ok, else: {:error, :invalid_arguments}
  end

  defp action_fields("create_task"), do: {~w(action title body), ~w(title body)}
  defp action_fields("edit_task"), do: {~w(action task_id title body state priority), ~w(task_id)}
  defp action_fields("feedback"), do: {~w(action task_id body), ~w(task_id body)}
  defp action_fields(action) when action in ~w(cancel retry queue_task unqueue_task), do: {~w(action task_id), ~w(task_id)}
  defp action_fields(_action), do: {~w(action), []}
  defp valid_edit_fields?(%{"action" => "edit_task"} = args), do: Enum.any?(~w(title body state priority), &Map.has_key?(args, &1))
  defp valid_edit_fields?(_args), do: true
  defp valid_title?(%{"title" => title}), do: present?(title)
  defp valid_title?(_args), do: true

  defp present?(text), do: is_binary(text) and String.trim(text) != ""

  defp proposal_evidence(%{"action" => "create_task"}, _context, settings, _board) do
    with :ok <- github_tracker(settings.tracker),
         true <- settings.tracker.required_labels != [] or {:error, :backlog_creation_requires_queue_labels} do
      {:ok, %{}}
    end
  end

  defp proposal_evidence(%{"action" => action} = args, context, settings, board) do
    with {:ok, revision} <- control_revision(board),
         {:ok, task} <- action_task(args, context, board),
         :ok <- writable_task(action, task, settings.tracker),
         :ok <- labels_available(args, settings.tracker) do
      evidence = %{"expected_revision" => revision}
      evidence = if task, do: Map.put(evidence, "expected_updated_at", task[:updated_at]), else: evidence
      evidence = if action in ~w(queue_task unqueue_task), do: Map.put(evidence, "queue_labels", settings.tracker.required_labels), else: evidence
      {:ok, evidence}
    end
  end

  defp control_revision(%{control: %{"enabled" => true, "revision" => revision}}) when is_integer(revision) and revision >= 0, do: {:ok, revision}
  defp control_revision(_board), do: {:error, :control_unavailable}
  defp action_task(%{"task_id" => id}, context, board), do: find_task(id, context, board)
  defp action_task(_args, _context, _board), do: {:ok, nil}

  defp writable_task(action, task, tracker) when action in ~w(edit_task feedback queue_task unqueue_task) do
    with :ok <- github_tracker(tracker),
         true <- present?(task[:updated_at]) or {:error, :task_revision_unavailable} do
      unsafe = task[:hold] != "cancelled" or not is_nil(task[:runtime]) or not is_nil(get_in(task, [:ledger, "active"]))
      if action != "feedback" and unsafe, do: {:error, :cancel_task_before_edit}, else: :ok
    end
  end

  defp writable_task(_action, _task, _tracker), do: :ok

  defp labels_available(%{"action" => action}, tracker) when action in ~w(queue_task unqueue_task) do
    if tracker.required_labels == [], do: {:error, :queue_labels_unconfigured}, else: :ok
  end

  defp labels_available(%{"priority" => _priority}, tracker) do
    reserved = Enum.any?(tracker.required_labels, &String.match?(&1, ~r/^priority:p[1-4]$/i))
    if reserved, do: {:error, :priority_label_reserved}, else: :ok
  end

  defp labels_available(_args, _tracker), do: :ok

  defp github_tracker(%{kind: "github", provider: %{"repo" => repo}}) do
    if is_binary(repo) and String.match?(repo, ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/), do: :ok, else: {:error, :unsupported_tracker_scope}
  end

  defp github_tracker(_tracker), do: {:error, :github_tracker_required}

  defp validate_proposal(proposal, context) when is_map(proposal) do
    args = if is_map(proposal["args"]), do: Map.put(proposal["args"], "action", proposal["action"]), else: nil

    valid =
      Enum.all?(Map.keys(proposal), &(&1 in @proposal_keys)) and uuid?(proposal["id"]) and
        proposal["project_id"] == context.project_id and proposal["tracker_fingerprint"] == context.tracker_fingerprint and
        present?(proposal["created_at"])

    with true <- valid or {:error, :invalid_proposal}, :ok <- validate("symphony_propose_action", args) do
      action_args(args)
    end
  end

  defp validate_proposal(_proposal, _context), do: {:error, :invalid_proposal}
  defp uuid?(id) when is_binary(id), do: String.match?(id, ~r/^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/)
  defp uuid?(_id), do: false

  defp execute(%{"action" => action} = proposal, context, settings, board) when action in @writes do
    with :ok <- complete_board(board),
         {:ok, evidence} <- proposal_evidence(Map.put(proposal["args"], "action", action), context, settings, board),
         true <- evidence["queue_labels"] == proposal["queue_labels"] or {:error, :proposal_changed} do
      GitHub.confirm(proposal, settings.tracker, context)
    end
  end

  defp execute(proposal, context, _settings, board) do
    with :ok <- complete_board(board),
         {:ok, task} <- action_task(proposal["args"], context, board),
         {:ok, result} <- native_command(proposal, context, task) do
      summary = action_title(proposal["action"]) <> " completed."
      widget = %{"type" => "receipt", "summary" => summary, "url" => board_url(context.project_id), "result" => result}
      {:ok, %{"widgets" => [widget]}}
    end
  end

  defp native_command(proposal, context, task) do
    action = proposal["action"]
    revision = proposal["expected_revision"]
    server = context[:orchestrator] || Orchestrator

    case BoardActions.command(action, task && task.issue_id, revision, proposal["id"], context.auth, server) do
      {:error, :unavailable} -> {:error, :write_outcome_unknown}
      result -> result
    end
  end

  defp recover(%{"action" => action} = proposal, settings, context) when action in @writes do
    GitHub.reconcile(proposal, settings.tracker, context)
  end

  defp recover(proposal, _settings, context) do
    command = %{"action" => proposal["action"], "issue_id" => proposal["args"]["task_id"], "expected_revision" => proposal["expected_revision"], "command_id" => proposal["id"]}
    owner = Application.get_env(:symphony_elixir, :chat_tracker_owner, Orchestrator)
    server = context[:orchestrator] || Orchestrator

    with {:ok, result} <- owner.control_receipt_guarded(command, context.tracker_fingerprint, server) do
      widget = %{"type" => "receipt", "summary" => "Previous control result recovered from the execution ledger.", "url" => board_url(context.project_id), "result" => result}
      {:ok, %{"widgets" => [widget]}}
    end
  end

  defp action_title(action), do: action |> String.replace("_", " ") |> String.capitalize()

  defp project_id(tracker) do
    provider = tracker.provider || %{}
    scope = provider["repo"] || tracker.project_slug || provider["project_id"] || provider["project"] || "configured-project"
    (tracker.kind || "tracker") <> ":" <> scope
  end
end
