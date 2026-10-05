defmodule SymphonyElixir.Assurance.Projection do
  @moduledoc "Pure coverage and release evidence projection. No result grants execution or acceptance."
  alias SymphonyElixir.Assurance.Contract

  @spec build(map(), term(), DateTime.t()) :: map()
  def build(journal, observations, now \\ DateTime.utc_now()) do
    valid = Contract.valid_observations?(observations)
    observed = if valid, do: observations, else: %{"tasks" => [], "evidence" => []}
    doc = journal["draft"] || Contract.document(journal["project"])
    base = journal["baselines"][journal["reviewed_ref"]]
    tasks = Map.new(observed["tasks"], &{&1["id"], &1})
    evidence = Enum.filter(observed["evidence"], &fresh?(&1, now))
    passing = unambiguous_passes(evidence)
    by_evidence = Map.new(evidence, &{&1["id"], &1})
    links = Enum.group_by(doc["task_links"], & &1["criterion_id"])
    reviewed = reviewed_context(base)
    dependencies = Enum.group_by(doc["dependencies"], & &1["task_id"])
    rows = Enum.map(Contract.criteria(doc), &criterion(&1, links[&1["id"]] || [], reviewed, dependencies, tasks, passing))
    linked_ids = MapSet.new(doc["task_links"], & &1["task_id"])
    counts = Map.new(~w(covered uncovered unreviewed stale missing_subject missing_checks excluded), fn status -> {status, Enum.count(rows, &(status in &1["issues"] or &1["status"] == status))} end)

    %{
      "criteria" => rows,
      "counts" => counts,
      "unlinked_task_ids" => Enum.sort(Enum.reject(Map.keys(tasks), &MapSet.member?(linked_ids, &1))),
      "stale_task_ids" => doc["task_links"] |> Enum.filter(&(not current_link?(&1, tasks))) |> Enum.map(& &1["task_id"]) |> Enum.uniq() |> Enum.sort(),
      "release_readiness" => journal["releases"] |> Map.values() |> Enum.sort_by(& &1["id"]) |> Enum.map(&release(&1, journal, tasks, by_evidence, passing)),
      "observations_available" => valid,
      "execution_authority" => false,
      "deployment_authority" => false
    }
  end

  defp criterion(%{"excluded" => true} = value, links, _reviewed, _dependencies, _tasks, _evidence), do: row(value, links, "excluded", [], [])

  defp criterion(value, links, reviewed, dependencies, tasks, passing) do
    missing =
      Enum.reject(value["required_checks"], fn check ->
        links != [] and Enum.all?(links, fn link -> not is_nil(link["subject"]) and MapSet.member?(passing, {value["id"], check, link["subject"]}) end)
      end)

    issues =
      []
      |> add(links == [], "uncovered")
      |> add(not reviewed_criterion?(value, links, reviewed, dependencies), "unreviewed")
      |> add(Enum.any?(links, &(not current_link?(&1, tasks))), "stale")
      |> add(Enum.any?(links, &is_nil(&1["subject"])), "missing_subject")
      |> add(value["required_checks"] == [] or missing != [], "missing_checks")

    row(value, links, List.first(issues) || "covered", issues, missing)
  end

  defp row(value, links, status, issues, missing) do
    Map.merge(value, %{"task_ids" => Enum.sort(Enum.map(links, & &1["task_id"])), "status" => status, "issues" => issues, "missing_checks" => missing})
  end

  defp reviewed_context(nil), do: %{criteria: %{}, links: %{}, dependencies: %{}}

  defp reviewed_context(base) do
    document = base["document"]

    %{
      criteria: Map.new(Contract.criteria(document), &{&1["id"], &1}),
      links: Enum.group_by(document["task_links"], & &1["criterion_id"]),
      dependencies: Enum.group_by(document["dependencies"], & &1["task_id"])
    }
  end

  defp reviewed_criterion?(criterion, links, reviewed, dependencies) do
    baseline_links = reviewed.links[criterion["id"]] || []
    task_ids = Enum.map(links ++ baseline_links, & &1["task_id"]) |> Enum.uniq()

    reviewed.criteria[criterion["id"]] == criterion and Enum.sort(links) == Enum.sort(baseline_links) and
      Enum.all?(task_ids, fn id -> Enum.sort(dependencies[id] || []) == Enum.sort(reviewed.dependencies[id] || []) end)
  end

  defp release(wrapper, journal, tasks, current_evidence, passing) do
    record = wrapper["record"]
    base = journal["baselines"][record["baseline_ref"]]
    doc = base["document"]
    linked = Enum.filter(doc["task_links"], &(&1["task_id"] in record["task_ids"]))
    expected_ids = doc["task_links"] |> Enum.map(& &1["task_id"]) |> Enum.uniq() |> Enum.sort()
    selected = selected_evidence(record, journal, current_evidence, passing)
    repositories = linked |> Enum.map(&get_in(&1, ["subject", "repository"])) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    source = Enum.filter(selected, &(release_subject?(&1["subject"], "source", record, repositories) and passed?(&1)))
    source_checks = MapSet.new(source, & &1["check"])
    source_criteria = MapSet.new(source, &{&1["criterion_id"], &1["check"]})
    linked_criteria = MapSet.new(linked, & &1["criterion_id"])
    missing_checks = Enum.reject(record["required_checks"], &MapSet.member?(source_checks, &1))

    missing_criteria =
      doc
      |> Contract.criteria()
      |> Enum.reject(& &1["excluded"])
      |> Enum.filter(fn criterion ->
        missing_release_criterion?(criterion, linked_criteria, source_criteria)
      end)
      |> Enum.map(& &1["id"])

    gates = Enum.reject(record["required_gates"], fn gate -> Enum.any?(selected, &(passed?(&1) and &1["check"] == gate and gate_subject?(&1["subject"], gate, record, repositories))) end)
    artifact = receipt?(selected, "artifact", "artifact", record, repositories)
    deployed = receipt?(selected, "deployment", "runtime", record, repositories)
    runtime = receipt?(selected, "runtime", "runtime", record, repositories)

    issues =
      []
      |> add(journal["reviewed_ref"] != record["baseline_ref"], "superseded_baseline")
      |> add(journal["draft"] != doc, "unreviewed_changes")
      |> add(Enum.sort(record["task_ids"]) != expected_ids, "included_tasks_mismatch")
      |> add(Enum.any?(linked, &(not current_revision?(&1, tasks))), "stale_task_revisions")
      |> add(repositories == [] or Enum.any?(linked, &is_nil(&1["subject"])), "missing_subject")
      |> add(missing_checks != [], "missing_integrated_checks")
      |> add(missing_criteria != [], "missing_integrated_criteria")
      |> add(gates != [], "missing_required_gates")
      |> add(not artifact, "missing_artifact_receipt")
      |> add(not deployed, "missing_deployment_receipt")
      |> add(not runtime, "missing_runtime_receipt")

    build_issues = Enum.reject(issues, &(&1 in ~w(missing_deployment_receipt missing_runtime_receipt missing_required_gates)))
    missing_build_gates = Enum.reject(gates, &(&1 in ~w(deployment runtime)))

    %{
      "id" => record["id"],
      "baseline_ref" => record["baseline_ref"],
      "ready" => issues == [],
      "build_ready" => build_issues == [] and missing_build_gates == [],
      "deployment_recorded" => deployed,
      "runtime_verified" => runtime,
      "issues" => issues,
      "missing_checks" => missing_checks,
      "missing_criteria" => missing_criteria,
      "missing_gates" => gates,
      "execution_authority" => false,
      "deployment_authority" => false
    }
  end

  defp selected_evidence(record, journal, current, passing) do
    Enum.flat_map(record["evidence_ids"], fn id ->
      saved = journal["evidence"][id]
      observed = current[id]
      if current_receipt?(saved, observed, record["id"], passing), do: [observed], else: []
    end)
  end

  defp current_receipt?(saved, observed, release_id, passing) do
    saved != nil and observed != nil and saved["release_id"] == release_id and
      Map.delete(saved, "observed_at") == Map.delete(observed, "observed_at") and
      MapSet.member?(passing, {observed["criterion_id"], observed["check"], observed["subject"]})
  end

  defp unambiguous_passes(evidence) do
    evidence
    |> Enum.group_by(&{&1["criterion_id"], &1["check"], &1["subject"]})
    |> Enum.filter(fn {_key, observations} -> Enum.all?(observations, &passed?/1) end)
    |> MapSet.new(&elem(&1, 0))
  end

  defp missing_release_criterion?(criterion, linked, source) do
    not MapSet.member?(linked, criterion["id"]) or criterion["required_checks"] == [] or
      Enum.any?(criterion["required_checks"], fn check -> not MapSet.member?(source, {criterion["id"], check}) end)
  end

  defp receipt?(evidence, check, kind, record, repositories), do: Enum.any?(evidence, &(passed?(&1) and &1["check"] == check and release_subject?(&1["subject"], kind, record, repositories)))
  defp gate_subject?(subject, "artifact", record, repos), do: release_subject?(subject, "artifact", record, repos)
  defp gate_subject?(subject, check, record, repos) when check in ~w(deployment runtime), do: release_subject?(subject, "runtime", record, repos)
  defp gate_subject?(subject, _check, record, repos), do: release_subject?(subject, "artifact", record, repos) or release_subject?(subject, "runtime", record, repos)

  defp release_subject?(subject, kind, record, repositories) do
    subject["kind"] == kind and subject["revision"] == record["integrated_sha"] and subject["repository"] in repositories and
      (kind == "source" or subject["artifact_digest"] == record["artifact_digest"]) and
      (kind != "runtime" or (subject["environment"] == record["target"] and subject["configuration_ref"] == record["configuration_ref"]))
  end

  defp current_link?(link, tasks), do: current_revision?(link, tasks) and tasks[link["task_id"]]["subject"] == link["subject"]
  defp current_revision?(link, tasks), do: not is_nil(tasks[link["task_id"]]) and tasks[link["task_id"]]["revision"] == link["task_revision"]
  defp passed?(evidence), do: evidence["origin"] in ~w(native github) and evidence["result"] == "passed"
  defp add(issues, true, value), do: issues ++ [value]
  defp add(issues, _, _), do: issues

  defp fresh?(record, now) do
    {:ok, at, 0} = DateTime.from_iso8601(record["observed_at"])
    DateTime.diff(now, at) in 0..120
  end
end
