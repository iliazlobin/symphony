defmodule SymphonyElixir.Assurance.Contract do
  @moduledoc "Bounded project assurance records; declarations are never execution authority."

  alias SymphonyElixir.Assurance.GraphSnapshot
  alias SymphonyElixir.Design.Persistence

  @max_records 10_000
  @max_bytes 8_000_000
  @subject_keys ~w(kind repository revision artifact_digest environment configuration_ref pr_number)
  @evidence_keys ~w(id criterion_id release_id check subject producer run_id result observed_at origin)

  @spec empty(String.t(), String.t()) :: map()
  def empty(project, scope) do
    %{"version" => 1, "project" => project, "scope" => scope, "storage_revision" => 0, "draft" => nil, "reviewed_ref" => nil, "baselines" => %{}, "evidence" => %{}, "releases" => %{}}
  end

  @spec document(String.t()) :: map()
  def document(project), do: %{"version" => 1, "project" => project, "requirements" => [], "task_links" => [], "dependencies" => []}

  @spec ref(term()) :: String.t()
  def ref(value), do: Persistence.scope_ref(["assurance-v1", value])

  @spec valid?(term(), String.t(), String.t()) :: boolean()
  def valid?(journal, project, scope) do
    exact?(journal, ~w(version project scope storage_revision draft reviewed_ref baselines evidence releases)) and
      journal_identity?(journal, project, scope) and journal_content?(journal, project)
  end

  @spec valid_document?(term(), String.t()) :: boolean()
  def valid_document?(doc, project) do
    exact?(doc, ~w(version project requirements task_links dependencies)) and doc["version"] == 1 and doc["project"] == project and
      present_text?(project, 512) and document_content?(doc)
  end

  @spec reviewable?(map()) :: boolean()
  def reviewable?(doc) do
    doc["requirements"] != [] and
      Enum.all?(doc["requirements"], fn req ->
        present?(req["title"]) and
          (present?(req["exclusion"]) or (req["criteria"] != [] and Enum.all?(req["criteria"], &(present?(&1["text"]) and &1["required_checks"] != []))))
      end) and Enum.all?(doc["dependencies"], &(present?(&1["reason"]) and present?(&1["output"])))
  end

  @spec valid_evidence?(term()) :: boolean()
  def valid_evidence?(record) do
    exact?(record, @evidence_keys) and id?(record["id"]) and nullable?(record["criterion_id"], &id?/1) and
      nullable?(record["release_id"], &id?/1) and (not is_nil(record["criterion_id"]) or not is_nil(record["release_id"])) and
      evidence_observation?(record)
  end

  @spec valid_subject?(term()) :: boolean()
  def valid_subject?(subject) do
    exact?(subject, @subject_keys) and subject["kind"] in ~w(pr source artifact runtime) and
      present_text?(subject["repository"], 512) and sha?(subject["revision"]) and subject_bindings?(subject) and subject_shape?(subject)
  end

  @spec valid_release?(term()) :: boolean()
  def valid_release?(record) do
    exact?(record, ~w(id baseline_ref task_ids integrated_sha artifact_digest target configuration_ref required_checks required_gates evidence_ids)) and
      id?(record["id"]) and hash?(record["baseline_ref"]) and ids?(record["task_ids"]) and record["task_ids"] != [] and
      release_artifact?(record) and release_policy?(record)
  end

  @spec valid_observations?(term()) :: boolean()
  def valid_observations?(value) do
    exact?(value, ~w(tasks evidence)) and list?(value["tasks"]) and unique?(value["tasks"], "id") and
      Enum.all?(value["tasks"], &observed_task?/1) and observed_evidence?(value["evidence"]) and size?(value)
  end

  @spec criteria(map()) :: [map()]
  def criteria(doc) do
    Enum.flat_map(doc["requirements"], fn req ->
      Enum.map(req["criteria"], &Map.merge(&1, %{"requirement_id" => req["id"], "title" => req["title"], "kind" => req["kind"], "excluded" => present?(req["exclusion"])}))
    end)
  end

  @spec diff(map(), map()) :: map()
  def diff(before, after_doc) do
    Map.new(~w(requirements task_links dependencies), fn key ->
      left = index(before[key], key)
      right = index(after_doc[key], key)

      {key,
       %{
         "added" => sorted(Map.keys(right) -- Map.keys(left)),
         "removed" => sorted(Map.keys(left) -- Map.keys(right)),
         "changed" => left |> Enum.filter(fn {id, value} -> Map.has_key?(right, id) and right[id] != value end) |> Enum.map(&elem(&1, 0)) |> sorted()
       }}
    end)
  end

  defp valid_baselines?(journal, project) do
    is_map(journal["baselines"]) and map_size(journal["baselines"]) <= @max_records and
      (is_nil(journal["reviewed_ref"]) or Map.has_key?(journal["baselines"], journal["reviewed_ref"])) and
      Enum.all?(journal["baselines"], &valid_baseline?(&1, project))
  end

  defp journal_identity?(journal, project, scope), do: journal["version"] == 1 and journal["project"] == project and journal["scope"] == scope and integer?(journal["storage_revision"])

  defp journal_content?(journal, project) do
    (is_nil(journal["draft"]) or valid_document?(journal["draft"], project)) and valid_baselines?(journal, project) and
      records?(journal["evidence"], &valid_evidence?/1) and records?(journal["releases"], &valid_release_record?(&1, journal))
  end

  defp document_content?(doc) do
    list?(doc["requirements"]) and unique?(doc["requirements"], "id") and Enum.all?(doc["requirements"], &requirement?/1) and
      valid_criteria?(doc) and valid_links?(doc) and valid_dependencies?(doc) and size?(doc)
  end

  defp evidence_observation?(record) do
    present_text?(record["check"], 256) and valid_subject?(record["subject"]) and present_text?(record["producer"], 256) and
      present_text?(record["run_id"], 512) and record["result"] in ~w(passed failed skipped pending) and time?(record["observed_at"]) and record["origin"] in ~w(manual imported native github)
  end

  defp subject_bindings?(subject) do
    nullable?(subject["artifact_digest"], &digest?/1) and nullable?(subject["environment"], &present_text?(&1, 256)) and
      nullable?(subject["configuration_ref"], &present_text?(&1, 512)) and nullable?(subject["pr_number"], &(integer?(&1) and &1 > 0))
  end

  defp release_artifact?(record), do: sha?(record["integrated_sha"]) and digest?(record["artifact_digest"]) and present_text?(record["target"], 256) and present_text?(record["configuration_ref"], 512)

  defp release_policy?(record) do
    names?(record["required_checks"]) and record["required_checks"] != [] and names?(record["required_gates"]) and record["required_gates"] != [] and ids?(record["evidence_ids"])
  end

  defp observed_task?(task), do: exact?(task, ~w(id revision subject)) and id?(task["id"]) and present_text?(task["revision"], 512) and nullable?(task["subject"], &valid_subject?/1)
  defp observed_evidence?(evidence), do: list?(evidence) and unique?(evidence, "id") and Enum.all?(evidence, &(valid_evidence?(&1) and &1["origin"] in ~w(native github)))

  defp valid_baseline?({key, base}, project) do
    exact?(base, ~w(ref reviewed_at document graph_snapshot)) and base["ref"] == key and hash?(key) and time?(base["reviewed_at"]) and
      valid_document?(base["document"], project) and reviewable?(base["document"]) and nullable?(base["graph_snapshot"], &GraphSnapshot.valid?(&1, project)) and
      baseline_ref(base["document"], base["graph_snapshot"]) == key
  end

  defp valid_release_record?(value, journal) do
    exact?(value, ~w(id ref created_at record)) and valid_release?(value["record"]) and value["id"] == value["record"]["id"] and hash?(value["ref"]) and
      time?(value["created_at"]) and ref(value["record"]) == value["ref"] and
      Map.has_key?(journal["baselines"], value["record"]["baseline_ref"]) and Enum.all?(value["record"]["evidence_ids"], &Map.has_key?(journal["evidence"], &1))
  end

  defp requirement?(req) do
    exact?(req, ~w(id title kind exclusion criteria)) and id?(req["id"]) and text?(req["title"], 512) and req["kind"] in ~w(functional nonfunctional) and
      nullable?(req["exclusion"], &present_text?(&1, 4_000)) and list?(req["criteria"], 100) and Enum.all?(req["criteria"], &criterion?/1)
  end

  defp criterion?(criterion) do
    exact?(criterion, ~w(id text required_checks)) and id?(criterion["id"]) and text?(criterion["text"], 4_000) and names?(criterion["required_checks"])
  end

  defp valid_criteria?(doc) do
    all = Enum.flat_map(doc["requirements"], & &1["criteria"])
    length(all) <= @max_records and unique?(all, "id")
  end

  defp valid_links?(doc) do
    ids = MapSet.new(Enum.map(criteria(doc), & &1["id"]))

    list?(doc["task_links"]) and unique_pairs?(doc["task_links"], "task_id", "criterion_id") and
      Enum.all?(doc["task_links"], fn link ->
        exact?(link, ~w(task_id criterion_id task_revision subject)) and task_id?(link["task_id"], doc["project"]) and MapSet.member?(ids, link["criterion_id"]) and
          present_text?(link["task_revision"], 512) and nullable?(link["subject"], &valid_subject?/1)
      end)
  end

  defp valid_dependencies?(doc) do
    list?(doc["dependencies"]) and unique_pairs?(doc["dependencies"], "task_id", "depends_on") and
      Enum.all?(doc["dependencies"], fn dep ->
        exact?(dep, ~w(task_id depends_on reason output reviewed_ref)) and task_id?(dep["task_id"], doc["project"]) and task_id?(dep["depends_on"], doc["project"]) and
          dep["task_id"] != dep["depends_on"] and
          text?(dep["reason"], 4_000) and text?(dep["output"], 4_000) and nullable?(dep["reviewed_ref"], &hash?/1)
      end)
  end

  defp subject_shape?(%{"kind" => "pr"} = subject),
    do: is_integer(subject["pr_number"]) and is_nil(subject["artifact_digest"]) and is_nil(subject["environment"]) and is_nil(subject["configuration_ref"])

  defp subject_shape?(%{"kind" => "source"} = subject),
    do: is_nil(subject["pr_number"]) and is_nil(subject["artifact_digest"]) and is_nil(subject["environment"]) and is_nil(subject["configuration_ref"])

  defp subject_shape?(%{"kind" => "artifact"} = subject),
    do: digest?(subject["artifact_digest"]) and is_nil(subject["pr_number"]) and is_nil(subject["environment"]) and is_nil(subject["configuration_ref"])

  defp subject_shape?(%{"kind" => "runtime"} = subject),
    do: digest?(subject["artifact_digest"]) and present?(subject["environment"]) and present?(subject["configuration_ref"]) and is_nil(subject["pr_number"])

  @spec baseline_ref(map(), map() | nil) :: String.t()
  def baseline_ref(document, nil), do: ref(document)
  def baseline_ref(document, snapshot), do: ref([document, snapshot["content_ref"]])

  defp records?(value, predicate), do: is_map(value) and map_size(value) <= @max_records and Enum.all?(value, fn {id, record} -> predicate.(record) and id == record["id"] end)
  defp index(values, "requirements"), do: Map.new(values, &{&1["id"], &1})
  defp index(values, "task_links"), do: Map.new(values, &{&1["task_id"] <> "/" <> &1["criterion_id"], &1})
  defp index(values, "dependencies"), do: Map.new(values, &{&1["task_id"] <> "/" <> &1["depends_on"], &1})
  defp sorted(values), do: Enum.sort(values)
  defp unique?(values, key), do: is_list(values) and values |> Enum.map(&if(is_map(&1), do: &1[key])) |> then(&(length(&1) == MapSet.size(MapSet.new(&1))))
  defp unique_pairs?(values, left, right), do: is_list(values) and values |> Enum.map(&if(is_map(&1), do: {&1[left], &1[right]})) |> then(&(length(&1) == MapSet.size(MapSet.new(&1))))
  defp ids?(value), do: list?(value) and Enum.all?(value, &id?/1) and length(value) == MapSet.size(MapSet.new(value))
  defp names?(value), do: list?(value, 100) and Enum.all?(value, &present_text?(&1, 256)) and length(value) == MapSet.size(MapSet.new(value))
  defp list?(value, max \\ @max_records), do: is_list(value) and length(value) <= max
  defp id?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:\/-]{0,511}\z/, value)
  defp task_id?(value, project), do: id?(value) and String.starts_with?(value, project <> ":") and byte_size(value) > byte_size(project) + 1
  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{40}\z/, value)
  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp digest?("sha256:" <> value), do: hash?(value)
  defp digest?(_), do: false
  defp integer?(value), do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp present_text?(value, max), do: text?(value, max) and present?(value)
  defp text?(value, max), do: is_binary(value) and String.valid?(value) and byte_size(value) <= max
  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp nullable?(nil, _), do: true
  defp nullable?(value, predicate), do: predicate.(value)
  defp time?(value) when is_binary(value), do: match?({:ok, _, 0}, DateTime.from_iso8601(value))
  defp time?(_), do: false

  defp size?(value), do: byte_size(Jason.encode!(value)) <= @max_bytes
end
