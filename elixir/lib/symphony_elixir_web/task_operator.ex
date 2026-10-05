defmodule SymphonyElixirWeb.TaskOperator do
  @moduledoc "One read-only task summary and contextual affordances; native controls retain all authority."
  use Phoenix.Component

  alias SymphonyElixir.{AgentProtocol, IssueAcceptance, PRWork, WorkEvidence}
  alias SymphonyElixirWeb.{StatusIndicator, TaskExecution}

  @dependency_wait "Dependencies require human-accepted Done in this project."

  def attention?(task, control \\ %{}, unavailable? \\ false)

  @spec attention?(map(), map(), boolean()) :: boolean()
  def attention?(task, control, false) when map_size(control) == 0 do
    task[:stage] not in ["done", "running"] and get_in(task, [:runtime, :status]) != "running" and
      text(task[:attention]) not in ["", "Retry scheduled", @dependency_wait]
  end

  def attention?(task, control, unavailable?) do
    blocker = blocker(task, TaskExecution.summary(task, control, unavailable?))
    not is_nil(blocker) and blocker.action_required?
  end

  @spec summary(map(), map(), map()) :: map()
  def summary(task, board, payload) do
    unavailable? = not is_nil(board[:source_error]) or not is_nil(board[:runtime_error]) or not is_nil(payload[:error])
    execution = TaskExecution.summary(task, board[:control] || %{}, unavailable?)
    work = PRWork.selected(task[:ledger] || %{})
    evidence = evidence(work, task)
    blocker = blocker(task, execution)
    actions = actions(task, execution, board[:control] || %{}, unavailable?)
    primary = primary_action(task, execution, blocker, actions)

    %{
      stage: stage(task[:lane] || task[:stage]),
      outcome: outcome(task),
      execution: execution,
      blocker: blocker,
      attention?: not is_nil(blocker) and blocker.action_required?,
      evidence: evidence,
      capability: capability(task, work),
      primary_action: primary,
      question_prompt: question_prompt(task),
      actions: if(primary, do: [primary | Enum.reject(actions, &(&1.id == primary.id))], else: actions)
    }
  end

  attr(:task, :map, required: true)
  attr(:board, :map, required: true)
  attr(:payload, :map, default: %{})
  attr(:controls_available, :boolean, default: false)
  attr(:id, :string, default: "task-operator")
  attr(:compact, :boolean, default: false)

  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    assigns = assign(assigns, :summary, summary(assigns.task, assigns.board, assigns.payload))

    ~H"""
    <section id={@id} class={["task-operator", @compact && "task-operator-compact"]} aria-label="Task progress and next action" data-attention={to_string(@summary.attention?)} data-compact={to_string(@compact)}>
      <div class="task-operator-heading">
        <span class="widget-label">{@summary.stage}</span><strong>{@summary.execution.status}</strong>
        <StatusIndicator.indicator id={@id <> "-outcome"} title="Outcome" detail={@summary.outcome} />
      </div>
      <div :if={@summary.blocker || @summary.capability} class="task-operator-indicators">
        <StatusIndicator.indicator :if={@summary.blocker} id={@id <> "-blocker"} title={@summary.blocker.label}
          label={@summary.blocker.label} detail={@summary.blocker.detail} data-blocker-kind={@summary.blocker.kind}
          tone={if @summary.blocker.action_required?, do: "warning", else: "neutral"} />
        <StatusIndicator.indicator :if={@summary.capability} id={@id <> "-capability"} title="Available work adapters"
          label="Adapters" detail={@summary.capability} />
      </div>
      <dl :if={@summary.evidence} class="task-operator-evidence">
        <div><dt>Candidate</dt><dd><code title={@summary.evidence.candidate_sha}>{short_sha(@summary.evidence.candidate_sha)}</code><span>{@summary.evidence.current_label}</span></dd></div>
        <div><dt>Independent review</dt><dd>{@summary.evidence.review_label}<code :if={@summary.evidence.reviewed_sha} title={@summary.evidence.reviewed_sha}>{short_sha(@summary.evidence.reviewed_sha)}</code></dd></div>
        <div><dt>Candidate checks</dt><dd>{@summary.evidence.checks_label}</dd></div>
      </dl>
      <div class="task-operator-actions">
        <span :for={action <- @summary.actions} :if={!action.control? || @controls_available} class="task-operator-action">
          <button type="button" id={action_id(@id, action, @compact)}
            class={if @summary.primary_action && action.id == @summary.primary_action.id, do: "button button-primary", else: "button"}
            disabled={action.control? && !@controls_available} phx-click={action.event} phx-value-id={@task.id}
            phx-value-action={action[:action]} phx-value-stage={action[:stage]} phx-value-tab={action[:tab]} phx-value-renew_attempts={action[:renew_attempts]}
            phx-value-prompt={action[:prompt]}>{action.label}</button>
          <StatusIndicator.indicator :if={action.id == "retry-cycle"} id={@id <> "-retry-help"} title="Retry cycle"
            detail="Retry cycle requires confirmation. It renews exhausted attempts only; recorded tokens, runtime, task scope and project gates stay unchanged." />
          <StatusIndicator.indicator :if={action.id == "stop-task"} id={@id <> "-stop-help"} title="Stop task"
            detail="Stop reply affects chat. Stop task requests worker cleanup; the task is stopped only after cleanup is confirmed." />
        </span>
      </div>
    </section>
    """
  end

  defp actions(task, execution, control, unavailable?) do
    if controls_ready?(execution, control, unavailable?) do
      execution_actions(execution) ++ task_actions(task)
    else
      []
    end
  end

  defp controls_ready?(execution, control, unavailable?) do
    control["enabled"] == true and execution.status != "Status unavailable" and not unavailable?
  end

  defp execution_actions(execution) do
    [
      if(execution.cancel?, do: command("stop-task", "Stop task", "cancel")),
      if(execution.retry?, do: command("retry", "Retry", "retry")),
      if(execution.renew_attempts?, do: Map.put(command("retry-cycle", "Retry cycle", "retry"), :renew_attempts, "true"))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp task_actions(task) do
    ledger = task[:ledger] || %{}
    idle? = is_nil(task[:runtime]) and is_nil(ledger["active"])
    terminal? = task[:tracker_terminal] == true or task[:tracker_state] == "closed"
    queue = queue_action(task, idle?, terminal?)
    review = review_actions(task, ledger, idle?, terminal?)
    if queue, do: [queue | review], else: review
  end

  defp queue_action(task, idle?, terminal?) do
    if task[:stage] == "backlog" and is_nil(task[:hold]) and idle? and not terminal?,
      do: %{id: "queue", label: "Move to Work", event: "queue-task", control?: true}
  end

  defp review_actions(task, ledger, idle?, terminal?) do
    if task[:stage] == "review" and idle? and IssueAcceptance.reviewable?(ledger, terminal?) do
      accept = command("accept", "Accept · Done", "accept_task")
      corrections = %{id: "correct", label: "Return with corrections", event: "move-task", stage: "work", control?: true}
      if terminal?, do: [accept], else: [accept, corrections]
    else
      []
    end
  end

  defp primary_action(%{stage: "done"}, _execution, _blocker, _actions), do: nil

  defp primary_action(_task, %{status: "Status unavailable"}, _blocker, _actions),
    do: %{id: "refresh", label: "Refresh status", event: "refresh", control?: false}

  defp primary_action(task, execution, blocker, actions) do
    cond do
      urgent_blocker?(blocker) -> question(task, "Discuss blocker")
      task[:stage] == "review" -> question(task, "Review evidence")
      execution.renew_attempts? -> Enum.find(actions, &(&1.id == "retry-cycle"))
      execution.retry? -> Enum.find(actions, &(&1.id == "retry"))
      recovery_blocker?(blocker) -> question(task, "Discuss recovery")
      true -> routine_action(task, execution, actions)
    end
  end

  defp urgent_blocker?(%{kind: kind}), do: kind in ~w(input authentication reconciliation)
  defp urgent_blocker?(_blocker), do: false
  defp recovery_blocker?(%{action_required?: true}), do: true
  defp recovery_blocker?(_blocker), do: false

  defp routine_action(task, execution, actions) do
    cond do
      execution.status in ["Queued · paused", "Queued · draining"] -> %{id: "execution-settings", label: "Execution settings", event: "open-settings", tab: "execution", control?: false}
      task[:stage] == "backlog" -> Enum.find(actions, &(&1.id == "queue"))
      true -> question(task, "Ask for progress")
    end
  end

  defp command(id, label, action), do: %{id: id, label: label, event: "prepare-command", action: action, control?: true}

  defp question(task, label) do
    %{id: "question", label: label, event: "operator-question", control?: false, prompt: question_prompt(task)}
  end

  defp question_prompt(task),
    do:
      "Read-only: inspect #{task[:identifier] || task[:title] || "this task"}, its current execution, retained work and candidate evidence. Explain the next safe step and any input needed from me. Do not queue, retry, cancel, approve, publish or launch work."

  defp action_id(_id, %{id: "queue"}, false), do: "queue-task-button"
  defp action_id(id, action, _compact), do: id <> "-" <> action.id

  defp blocker(%{stage: "done"}, _execution), do: nil
  defp blocker(_task, %{status: "Running"}), do: nil
  defp blocker(_task, %{status: "Status unavailable"} = execution), do: block("unavailable", "Status unavailable", execution.note, false)

  defp blocker(_task, %{status: "Needs reconciliation"} = execution),
    do: block("reconciliation", "Execution ownership needs reconciliation", execution.note, true)

  defp blocker(_task, %{status: "Needs input"}),
    do: block("input", "Worker needs input", "Discuss the retained question before continuing. A management reply does not answer or approve the coding worker.", true)

  defp blocker(_task, %{status: "Worker sign-in required"} = execution),
    do: block("authentication", "Coding worker sign-in required", execution.note, true)

  defp blocker(%{stage: "review"} = task, _execution), do: block("review", "Your review is needed", review_guidance(task), true)

  defp blocker(_task, %{renew_attempts?: true}),
    do: block("attempts", "Attempt cycle exhausted", "Confirm a new bounded attempt cycle when the original failure is resolved.", true)

  defp blocker(_task, %{status: status} = execution) when status in ["Limit reached", "Held"], do: block("recovery", status, execution.note, true)

  defp blocker(_task, %{status: "Retry scheduled"}),
    do: block("waiting", "Retry scheduled", "The controller owns the next attempt within existing limits.", false)

  defp blocker(task, execution) do
    case text(task[:dependency_error]) do
      @dependency_wait -> block("dependencies", "Waiting for prerequisites", "Prerequisite tasks must be accepted before this task can start.", false)
      "" -> status_blocker(task, execution)
      dependency -> block("dependencies", "Dependency needs correction", dependency, true)
    end
  end

  defp status_blocker(_task, %{status: status} = execution) when status in ["Queued · paused", "Queued · draining"],
    do: block("waiting", status, execution.note, false)

  defp status_blocker(_task, %{status: status} = execution) when status in ["Cancelled", "Interrupted"],
    do: block("recovery", status, execution.note, true)

  defp status_blocker(task, execution) do
    if text(task[:attention]) != "",
      do: block("recovery", "Task needs attention", execution.note || "Inspect current task evidence before changing execution.", true)
  end

  defp block(kind, label, detail, action_required?), do: %{kind: kind, label: label, detail: detail, action_required?: action_required?}

  defp review_guidance(task) do
    if task[:tracker_terminal] == true or task[:tracker_state] == "closed",
      do: "GitHub closure is an external fact. Accept the task when satisfied; reopen the issue on GitHub before requesting rework.",
      else: "Inspect the exact candidate and checks, then accept or return it with corrections. Acceptance does not merge or deploy."
  end

  defp evidence(work, task) do
    result = if work, do: WorkEvidence.for_task(work, task)
    handoff = task[:handoff] || get_in(task, [:ledger, "handoff"])

    cond do
      is_map(result) ->
        %{
          candidate_sha: sha(result["candidate_sha"]),
          reviewed_sha: sha(result["reviewed_sha"]),
          current?: result["current"] == true,
          status: result["status"],
          current_label: evidence_label(result),
          review_label: label(result["review_verdict"]),
          checks_label: label(result["checks_status"])
        }

      is_map(handoff) ->
        %{
          candidate_sha: sha(handoff["candidate_sha"]),
          reviewed_sha: sha(get_in(handoff, ["review", "candidate_sha"])),
          current?: false,
          status: "unverified",
          current_label: "Retained evidence · currentness unconfirmed",
          review_label: label(get_in(handoff, ["review", "verdict"])),
          checks_label: "Not verified against current work"
        }

      true ->
        nil
    end
  end

  defp evidence_label(%{"status" => "stale"}), do: "Retained candidate · work has changed"
  defp evidence_label(%{"current" => true}), do: "Current retained candidate"
  defp evidence_label(_result), do: "Currentness unconfirmed"

  defp capability(task, work) do
    purpose = if work, do: work["purpose"] || "coding"

    cond do
      purpose && not AgentProtocol.executable_purpose?(purpose) ->
        "This work purpose has no execution adapter. Discuss or redesign the work before launching it."

      task[:task_kind] in ~w(testing security release operations analysis) ->
        "#{label(task[:task_kind])} describes the task's intent. Execution currently uses coding work; test, analysis and deployment adapters are not enabled."

      true ->
        nil
    end
  end

  defp outcome(task) do
    declared =
      case Regex.run(~r/(?:\A|\n)\#{1,3} Outcome\s*\n+([^\n]+(?:\n(?!\#)[^\n]+)*)/i, text(task[:description]), capture: :all_but_first) do
        [value] -> value |> String.replace(~r/\s+/u, " ") |> String.slice(0, 400)
        _ -> ""
      end

    Enum.find([text(task[:outcome]), declared, text(task[:title])], &(&1 != "")) || "Outcome not recorded"
  end

  defp stage(value) when value in ["ready", "work"], do: "Work"
  defp stage(value) when value in ["running", "in_progress"], do: "In progress"
  defp stage(value), do: label(value)
  defp label("approve"), do: "Approved"
  defp label("request_changes"), do: "Changes requested"
  defp label("not_reported"), do: "Not reported"
  defp label(value) when is_binary(value) and value != "", do: value |> String.replace("_", " ") |> String.capitalize()
  defp label(_value), do: "Not reported"
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
  defp sha(value) when is_binary(value), do: if(String.match?(value, ~r/\A[0-9a-f]{40}\z/), do: value)
  defp sha(_value), do: nil
  defp short_sha(nil), do: "Not recorded"
  defp short_sha(value), do: String.slice(value, 0, 7)
end
