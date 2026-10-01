defmodule SymphonyElixirWeb.TaskExecution do
  @moduledoc "Presents recorded execution progress without inferring worker or review completion."

  @type metric :: %{label: String.t(), value: String.t(), title: String.t(), used: non_neg_integer() | nil}
  @type summary :: %{
          status: String.t(),
          metrics: [metric()],
          note: String.t() | nil,
          cancel?: boolean(),
          retry?: boolean()
        }

  @spec summary(map(), map(), boolean()) :: summary()
  def summary(task, control, unavailable? \\ false), do: summarize(task, control, unavailable?)

  defp summarize(task, %{"enabled" => false} = control, unavailable?) do
    available? = not unavailable? and task[:source_missing] != true and no_control_error?(control)
    {status, note, _cancel?, _retry?} = uncontrolled_state(task, available?)

    %{
      status: status,
      metrics: uncontrolled_metrics(task, available?),
      note: note,
      cancel?: false,
      retry?: false
    }
  end

  defp summarize(task, control, unavailable?) do
    ledger = task[:ledger] || %{}
    budgets = get_in(control, ["settings", "budgets"]) || %{}
    available? = not unavailable? and healthy_control?(control) and task[:source_missing] != true
    usage = usage(ledger, if(available?, do: task[:runtime]))
    {status, note, cancel?, retry?} = state(task, control, usage, budgets, available?)

    %{
      status: status,
      metrics: metrics(usage, budgets, available?),
      note: note,
      cancel?: cancel?,
      retry?: retry?
    }
  end

  defp healthy_control?(control) do
    control["enabled"] == true and is_integer(control["revision"]) and control["revision"] >= 0 and
      no_control_error?(control)
  end

  defp no_control_error?(control), do: is_nil(control["fault"]) and is_nil(control["error"])

  defp usage(ledger, runtime) do
    active = ledger["active"]

    %{
      tokens: total_tokens(number(ledger["tokens"]), active),
      attempts: cycle_attempts(ledger),
      lifetime_attempts: number(ledger["attempts"]),
      runtime_ms: total_runtime(number(ledger["runtime_ms"]), active, runtime)
    }
  end

  defp cycle_attempts(ledger) do
    case {number(ledger["attempts"]), number(Map.get(ledger, "attempt_base", 0))} do
      {total, base} when is_integer(total) and is_integer(base) and base <= total -> total - base
      _ -> nil
    end
  end

  defp total_tokens(settled, nil), do: settled
  defp total_tokens(settled, active) when is_map(active), do: add(settled, number(active["tokens"]))
  defp total_tokens(_settled, _active), do: nil

  defp total_runtime(settled, nil, _runtime), do: settled

  defp total_runtime(settled, active, %{status: "running"} = runtime) when is_map(active) do
    add(settled, running_elapsed(runtime))
  end

  defp total_runtime(_settled, _active, _runtime), do: nil

  defp running_elapsed(%{status: "running", started_at: started_at}), do: elapsed_since(started_at)
  defp running_elapsed(_runtime), do: nil

  defp elapsed_since(%DateTime{} = started_at), do: max(0, DateTime.diff(DateTime.utc_now(), started_at, :millisecond))

  defp elapsed_since(started_at) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, date_time, _offset} -> elapsed_since(date_time)
      _ -> nil
    end
  end

  defp elapsed_since(_started_at), do: nil
  defp add(left, right) when is_integer(left) and is_integer(right), do: left + right
  defp add(_left, _right), do: nil
  defp number(value) when is_integer(value) and value >= 0, do: value
  defp number(_value), do: nil

  defp metrics(usage, budgets, available?) do
    [
      metric("Tokens", usage.tokens, number(budgets["max_total_tokens"]), &compact_number/1, available?),
      attempts_metric(usage, budgets, available?),
      metric("Time", usage.runtime_ms, number(budgets["max_total_runtime_ms"]), &duration/1, available?)
    ]
  end

  defp attempts_metric(usage, budgets, available?) do
    metric = metric("Attempts", usage.attempts, number(budgets["max_attempts"]), &Integer.to_string/1, available?)

    if is_integer(usage.attempts) and usage.attempts != usage.lifetime_attempts,
      do: %{metric | title: metric.title <> " in this work cycle; " <> exact(usage.lifetime_attempts, "Attempts") <> " lifetime attempts"},
      else: metric
  end

  defp uncontrolled_metrics(%{ledger: ledger} = task, available?) when map_size(ledger) > 0 do
    usage = usage(ledger, if(available?, do: task[:runtime]))

    [
      recorded_metric("Tokens", usage.tokens, &compact_number/1, available?),
      recorded_metric("Attempts", usage.lifetime_attempts, &Integer.to_string/1, available?),
      recorded_metric("Time", usage.runtime_ms, &duration/1, available?)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp uncontrolled_metrics(task, available?) do
    runtime = task[:runtime] || %{}

    [
      recorded_metric("Tokens", number(get_in(runtime, [:tokens, :total_tokens])), &compact_number/1, available?),
      recorded_metric("Time", if(available?, do: running_elapsed(runtime)), &duration/1, available?)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp recorded_metric(_label, nil, _format, _available?), do: nil

  defp recorded_metric(label, value, format, available?) do
    prefix = if available?, do: "Recorded · ", else: "Last recorded · "
    %{label: label, value: format.(value), title: prefix <> label <> ": " <> exact(value, label), used: value}
  end

  defp metric(label, used, limit, format, available?) do
    prefix = if available?, do: "", else: "Last recorded · "

    %{
      label: label,
      value: formatted(used, format) <> " / " <> formatted(limit, format),
      title: prefix <> label <> ": " <> exact(used, label) <> " used; limit " <> exact(limit, label),
      used: used
    }
  end

  defp formatted(nil, _format), do: "—"
  defp formatted(value, format), do: format.(value)
  defp exact(nil, _label), do: "not reported"
  defp exact(value, "Time"), do: grouped(value) <> " ms"
  defp exact(value, _label), do: grouped(value)

  defp grouped(value) do
    value |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()
  end

  defp compact_number(value) when value >= 1_000_000 do
    millions = Float.round(value / 1_000_000, 1)
    String.trim_trailing(Float.to_string(millions), ".0") <> "M"
  end

  defp compact_number(value) when value >= 1_000, do: Integer.to_string(round(value / 1_000)) <> "k"
  defp compact_number(value), do: Integer.to_string(value)

  defp duration(milliseconds) do
    seconds = div(milliseconds, 1_000)

    cond do
      seconds >= 3_600 -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
      seconds >= 60 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  defp state(_task, _control, _usage, _budgets, false) do
    {"Status unavailable", "Execution status is unavailable. Usage shown is last recorded.", false, false}
  end

  defp state(%{stage: "done"}, _control, _usage, _budgets, true), do: {"Done", nil, false, false}

  defp state(task, control, usage, budgets, true) do
    runtime = task[:runtime]

    cond do
      awaiting_acceptance?(task, runtime) -> {"Awaiting acceptance", nil, false, false}
      settled_review?(task, runtime) -> review_state(task[:handoff])
      is_map(runtime) -> runtime_state(runtime)
      not is_nil(get_in(task, [:ledger, "active"])) -> {"Needs reconciliation", "A reserved execution has no current worker status.", false, false}
      task[:hold] in ["input_required", "needs_input", "approval_required"] -> input_state()
      is_binary(task[:hold]) -> held_state(task[:hold], usage, budgets)
      task[:stage] == "ready" -> ready_state(control, usage, budgets)
      true -> {"Not queued", nil, false, false}
    end
  end

  defp awaiting_acceptance?(task, runtime) do
    task[:stage] == "review" and (task[:tracker_terminal] == true or task[:tracker_state] == "closed") and
      is_nil(runtime) and is_nil(get_in(task, [:ledger, "active"]))
  end

  defp settled_review?(%{hold: "owner_review"} = task, runtime) do
    is_nil(get_in(task, [:ledger, "active"])) and (is_nil(runtime) or runtime[:status] == "retrying")
  end

  defp settled_review?(_task, _runtime), do: false

  defp uncontrolled_state(task, false), do: state(task, %{}, %{}, %{}, false)
  defp uncontrolled_state(%{stage: "done"}, true), do: {"Done", nil, false, false}
  defp uncontrolled_state(%{runtime: runtime}, true) when is_map(runtime), do: runtime_state(runtime)
  defp uncontrolled_state(%{stage: "ready"}, true), do: {"Queued", nil, false, false}
  defp uncontrolled_state(_task, true), do: {"Not queued", nil, false, false}

  defp runtime_state(%{status: "running"}), do: {"Running", nil, true, false}
  defp runtime_state(%{status: "retrying"}), do: {"Retry scheduled", nil, true, false}
  defp runtime_state(%{status: "blocked"}), do: input_state()
  defp runtime_state(_runtime), do: {"Status unavailable", "Current worker status is not reported.", false, false}

  defp input_state, do: {"Needs input", "Resolve the worker's question or approval request before continuing.", false, false}

  defp review_state(%{"review" => %{"verdict" => "approve"}}), do: {"Awaiting your review", nil, false, false}
  defp review_state(%{"review" => %{"verdict" => "request_changes"}}), do: {"Changes requested", "Review the candidate findings before planning another attempt.", false, false}
  defp review_state(%{"review" => %{"verdict" => "blocked"}}), do: {"Review blocked", "Review the candidate and resolve its blocker before continuing.", false, false}
  defp review_state(_handoff), do: {"Review pending", "Independent review is not confirmed.", false, false}

  defp ready_state(control, usage, budgets) do
    case budget_state(usage, budgets) do
      {:exhausted, limit} -> {"Limit reached", "#{limit} limit reached. Existing usage is preserved.", true, false}
      _ -> ready_state(control)
    end
  end

  defp ready_state(%{"mode" => "running"}), do: {"Queued", "Waiting for admission and an available worker.", true, false}
  defp ready_state(%{"mode" => "paused"}), do: {"Queued · paused", "Resume execution in Settings to admit ready tasks.", true, false}
  defp ready_state(%{"mode" => "draining"}), do: {"Queued · draining", "The controller is finishing active work before pausing.", true, false}
  defp ready_state(_control), do: {"Queued", "Controller mode is not reported.", false, false}

  defp held_state(hold, usage, budgets) do
    case budget_state(usage, budgets) do
      {:exhausted, limit} -> {"Held", "#{limit} limit reached. Retrying preserves existing usage.", false, false}
      :unknown -> {"Held", "Usage or limits are not fully reported; retry availability cannot be confirmed.", false, false}
      :remaining -> {hold_status(hold), "Retry keeps the task's recorded usage and remaining limits.", false, true}
    end
  end

  defp hold_status("cancelled"), do: "Cancelled"
  defp hold_status("interrupted"), do: "Interrupted"
  defp hold_status(_hold), do: "Held"

  defp budget_state(usage, budgets) do
    limits = [
      {"Attempts", usage.attempts, number(budgets["max_attempts"])},
      {"Token", usage.tokens, number(budgets["max_total_tokens"])},
      {"Time", usage.runtime_ms, number(budgets["max_total_runtime_ms"])}
    ]

    case Enum.find(limits, &limit_reached?/1) do
      {name, _used, _limit} -> {:exhausted, name}
      nil -> if Enum.all?(limits, &known_limit?/1), do: :remaining, else: :unknown
    end
  end

  defp limit_reached?({_name, used, limit}), do: is_integer(used) and is_integer(limit) and used >= limit
  defp known_limit?({_name, used, limit}), do: is_integer(used) and is_integer(limit) and limit > 0
end
