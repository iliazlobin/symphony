defmodule SymphonyElixirWeb.WorkflowGraph do
  @moduledoc "Read-only project/task/work graph from the board and native ledger; graph edges never grant agent authority."

  alias SymphonyElixir.{TaskDependencies, TaskIdentity, TaskRouting}

  @spec export([map()], map(), map()) :: map()
  def export(tasks, control, tracker) do
    project = TaskIdentity.project_id(tracker)
    project_id = "project:" <> project
    tasks = retained_prerequisites(tasks, control, tracker, project)
    by_issue = Map.new(tasks, &{&1.issue_id, &1})
    records = Map.new(tasks, &{&1.issue_id, %{"dependencies" => &1.dependencies}})

    cycles =
      records
      |> TaskDependencies.cycle_groups()
      |> Enum.with_index()
      |> Enum.flat_map(fn {members, group} -> Enum.map(members, &{&1, group}) end)
      |> Map.new()

    policy = if control["enabled"] == true, do: "human_acceptance", else: "tracker_completion"
    dependencies = Enum.flat_map(tasks, &dependency_edges(&1, by_issue, control, tracker, cycles, policy))
    missing = missing_nodes(dependencies, tasks, project)
    {works, ownership} = work_nodes(tasks, control, project, tracker)
    contains = Enum.map(tasks, &edge("contains", project_id, task_id(&1.id))) ++ ownership
    warnings = warnings(tasks, cycles, missing)

    %{
      "version" => 1,
      "project_id" => project,
      "policy" => policy,
      "nodes" => Enum.sort_by([%{"id" => project_id, "type" => "project", "name" => project}] ++ Enum.map(tasks, &task_node(&1, cycles)) ++ missing ++ works, & &1["id"]),
      "edges" => Enum.sort_by(contains ++ dependencies, & &1["id"]),
      "warnings" => warnings
    }
  end

  defp retained_prerequisites(tasks, control, tracker, project) do
    known = TaskDependencies.records(control, [], tracker)
    present = Map.new(tasks, &{&1.issue_id, true})
    records = Map.merge(known, Map.new(tasks, &{&1.issue_id, %{"dependencies" => &1.dependencies}}))
    references = Enum.flat_map(tasks, fn task -> Enum.map(task.dependencies, & &1["issue_id"]) end)
    reachable = reachable_references(references, records, present)

    extra =
      reachable
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(present, &1))
      |> Enum.filter(&Map.has_key?(known, &1))
      |> Enum.map(&retained_task(&1, known[&1], project))

    tasks ++ extra
  end

  defp reachable_references([], _records, seen), do: seen

  defp reachable_references([id | rest], records, seen) do
    if Map.has_key?(seen, id) do
      reachable_references(rest, records, seen)
    else
      dependencies = (records[id] || %{})["dependencies"] || []
      next = Enum.reduce(dependencies, rest, fn dependency, queue -> [dependency["issue_id"] | queue] end)
      reachable_references(next, records, Map.put(seen, id, true))
    end
  end

  defp retained_task(id, record, project) do
    %{
      id: project <> ":" <> id,
      project: project,
      issue_id: id,
      identifier: "GH-" <> id,
      title: "GH-" <> id <> " · unavailable",
      lane: "unknown",
      stage: "unknown",
      execution_status: "unknown",
      task_kind: "general",
      priority: nil,
      url: nil,
      source_missing: true,
      tracker_terminal: false,
      dependencies: record["dependencies"] || [],
      dependency_error: nil
    }
  end

  defp task_node(task, cycles) do
    %{
      "id" => task_id(task.id),
      "type" => "task",
      "task_id" => task.id,
      "issue_id" => task.issue_id,
      "identifier" => task.identifier,
      "title" => task.title,
      "lane" => task.lane,
      "stage" => task.stage,
      "execution_status" => task.execution_status,
      "task_kind" => task.task_kind,
      "priority" => task.priority,
      "url" => task.url,
      "missing" => task.source_missing,
      "cycle" => Map.has_key?(cycles, task.issue_id)
    }
  end

  defp dependency_edges(task, by_issue, control, tracker, cycles, policy) do
    Enum.map(task.dependencies, fn dependency ->
      id = dependency["issue_id"]
      target = task_id(task.project <> ":" <> id)
      satisfied = satisfied?(policy, control, id, tracker, by_issue)
      status = dependency_status(task.issue_id, id, cycles, satisfied, by_issue)

      evidence = get_in(control, ["issues", id, "acceptance"]) || %{}

      edge("depends_on", task_id(task.id), target)
      |> Map.merge(%{
        "kind" => dependency["kind"],
        "blocking" => dependency["blocking"],
        "reason" => dependency["reason"],
        "status" => status,
        "satisfaction" => policy,
        "evidence" => if(satisfied, do: Map.take(evidence, ~w(accepted_at candidate_sha)), else: %{})
      })
    end)
  end

  defp satisfied?("human_acceptance", control, id, tracker, _tasks), do: TaskDependencies.satisfied?(control, id, tracker)
  defp satisfied?(_policy, _control, id, _tracker, tasks), do: tasks[id] && tasks[id].tracker_terminal

  defp dependency_status(source, target, cycles, satisfied, tasks) do
    cond do
      Map.has_key?(cycles, source) and cycles[source] == cycles[target] -> "cycle"
      satisfied -> "satisfied"
      is_nil(tasks[target]) -> "missing"
      true -> "waiting"
    end
  end

  defp missing_nodes(dependencies, tasks, project) do
    known = MapSet.new(tasks, &task_id(&1.id))

    dependencies
    |> Enum.map(& &1["target"])
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.map(fn id ->
      issue_id = String.replace_prefix(id, "task:" <> project <> ":", "")

      %{
        "id" => id,
        "type" => "task",
        "task_id" => project <> ":" <> issue_id,
        "issue_id" => issue_id,
        "identifier" => "GH-" <> issue_id,
        "title" => "GH-" <> issue_id <> " · unavailable",
        "lane" => "unknown",
        "stage" => "unknown",
        "execution_status" => "unknown",
        "task_kind" => "general",
        "priority" => nil,
        "url" => nil,
        "missing" => true,
        "cycle" => false
      }
    end)
  end

  defp work_nodes(tasks, control, project, tracker) do
    Enum.reduce(tasks, {[], []}, fn task, {nodes, edges} ->
      works = get_in(control, ["issues", task.issue_id, "pr_work"]) || %{}

      works = Enum.filter(works, fn {_id, work} -> same_work_scope?(work, task.issue_id, tracker) end)

      Enum.reduce(works, {nodes, edges}, fn {id, work}, {nodes, edges} ->
        node_id = "work:" <> project <> ":" <> id

        node = %{
          "id" => node_id,
          "type" => "work",
          "work_id" => id,
          "task_id" => task.id,
          "title" => work["instruction"] |> to_string() |> String.split("\n") |> hd() |> String.slice(0, 160),
          "purpose" => work["purpose"] || "coding",
          "phase" => work["phase"],
          "candidate_sha" => get_in(work, ["handoff", "candidate_sha"]),
          "pr_number" => get_in(work, ["publication", "pr_number"]),
          "execution_status" => work["phase"]
        }

        {[node | nodes], [edge("contains", task_id(task.id), node_id) | edges]}
      end)
    end)
  end

  defp same_work_scope?(work, issue_id, tracker) do
    work["issue_id"] == issue_id and
      (work["tracker_fingerprint"] == TaskRouting.fingerprint(tracker) or published_work_scope?(work, tracker))
  end

  defp published_work_scope?(work, tracker) do
    receipt = work["publication"] || %{}
    repo = tracker.provider["repo"]
    number = receipt["pr_number"]
    candidate = receipt["candidate_sha"]

    is_binary(candidate) and String.match?(candidate, ~r/\A[0-9a-f]{40}\z/) and is_binary(repo) and is_integer(number) and number > 0 and
      receipt["pr_url"] == "https://github.com/#{repo}/pull/#{number}" and
      candidate == get_in(work, ["handoff", "candidate_sha"])
  end

  defp warnings(tasks, cycles, missing) do
    cycle =
      if map_size(cycles) > 0, do: ["Dependency cycle: " <> Enum.map_join(cycles |> Map.keys() |> Enum.sort(), ", ", &("GH-" <> &1)) <> ". Revise these prerequisites before work starts."], else: []

    absent = if missing == [], do: [], else: ["Some prerequisites are unavailable; their dependencies remain blocked."]
    invalid = Enum.filter(tasks, &is_binary(&1.dependency_error)) |> Enum.map(&(&1.identifier <> ": " <> &1.dependency_error))
    Enum.uniq(cycle ++ absent ++ invalid)
  end

  defp task_id(id), do: "task:" <> id
  defp edge(type, source, target), do: %{"id" => type <> ":" <> source <> ":" <> target, "type" => type, "source" => source, "target" => target}
end
