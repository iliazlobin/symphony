defmodule SymphonyElixir.IssueAcceptance do
  @moduledoc "Explicit operator acceptance retained by the native control owner; tracker closure is not acceptance."

  @fields ~w(expected_candidate_sha expected_updated_at expected_tracker_state)

  @spec command_fields(String.t()) :: [String.t()]
  def command_fields("accept_task"), do: @fields
  def command_fields(_), do: []

  @spec valid_command?(map()) :: boolean()
  def valid_command?(params) do
    text?(params["issue_id"], 128) and text?(params["command_id"], 128) and
      is_integer(params["expected_revision"]) and params["expected_revision"] >= 0 and
      Enum.all?(@fields, &Map.has_key?(params, &1)) and optional_sha?(params["expected_candidate_sha"]) and
      timestamp?(params["expected_updated_at"]) and text?(params["expected_tracker_state"], 128)
  end

  @spec accepted?(map()) :: boolean()
  def accepted?(issue), do: is_map(issue["acceptance"]) and valid_record?(issue["acceptance"])

  @doc "Acceptance survives credential and routing configuration changes, while legacy records retain their exact scope fence."
  @spec accepted_in_scope?(map(), String.t() | nil, String.t()) :: boolean()
  def accepted_in_scope?(issue, project_id, fingerprint) do
    accepted?(issue) and is_nil(issue["active"]) and not pending_work?(issue) and
      get_in(issue, ["acceptance", "candidate_sha"]) == get_in(issue, ["handoff", "candidate_sha"]) and
      case issue["acceptance"] do
        %{"project_id" => recorded} -> recorded == project_id
        %{"tracker_fingerprint" => recorded} -> recorded == fingerprint
      end
  end

  @doc "Add stable project identity to one verified legacy acceptance without changing its original decision or evidence."
  @spec upgrade_legacy(map(), map(), String.t(), String.t()) :: {:ok, map()} | {:error, :acceptance_migration_mismatch}
  def upgrade_legacy(issue, observed, "github:" <> repo = project_id, old_fingerprint) do
    record = issue["acceptance"] || %{}
    candidate = get_in(issue, ["handoff", "candidate_sha"])

    if legacy_idle_acceptance?(issue, record, old_fingerprint) and
         reviewed_candidate?(issue, record, candidate) and legacy_source?(observed, record, repo) do
      {:ok, Map.put(issue, "acceptance", Map.put(record, "project_id", project_id))}
    else
      {:error, :acceptance_migration_mismatch}
    end
  end

  def upgrade_legacy(_issue, _observed, _project_id, _old_fingerprint), do: {:error, :acceptance_migration_mismatch}

  defp legacy_idle_acceptance?(issue, record, old_fingerprint) do
    accepted?(issue) and is_nil(record["project_id"]) and record["tracker_fingerprint"] == old_fingerprint and
      issue["hold"] == "accepted" and is_nil(issue["active"]) and not pending_work?(issue)
  end

  defp reviewed_candidate?(issue, record, candidate) do
    review_sha = get_in(issue, ["handoff", "review", "candidate_sha"])
    sha?(candidate) and record["candidate_sha"] == candidate and review_sha == candidate
  end

  defp legacy_source?(observed, record, repo) do
    observed["repository"] == repo and observed["state"] == record["tracker_state"] and
      observed["updated_at"] == record["issue_updated_at"]
  end

  @spec accept(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def accept(issue, params, context) do
    cond do
      not is_nil(issue["active"]) ->
        {:error, :issue_running}

      pending_work?(issue) ->
        {:error, :task_still_active}

      true ->
        accept_verified(issue, params, context)
    end
  end

  defp accept_verified(issue, params, context) do
    candidate = get_in(issue, ["handoff", "candidate_sha"])
    verified = context[:acceptance_issue] || %{}

    with :ok <- verify_request(params, context, verified),
         :ok <- verify_candidate(issue, params, context, candidate, verified) do
      record = acceptance_record(issue, candidate, params, context, verified)
      {:ok, issue |> Map.put("acceptance", record) |> Map.put("hold", "accepted")}
    end
  end

  defp verify_request(params, context, verified) do
    cond do
      not valid_command?(params) ->
        {:error, :invalid_command}

      not text?(context[:tracker_fingerprint], 256) ->
        {:error, :tracker_changed}

      not matches_issue?(verified, params) ->
        {:error, :task_changed}

      true ->
        :ok
    end
  end

  defp verify_candidate(issue, params, context, candidate, verified) do
    cond do
      not acceptance_scope_matches?(issue, context) ->
        {:error, :tracker_changed}

      candidate != params["expected_candidate_sha"] ->
        {:error, :candidate_changed}

      not accepted_candidate_matches?(issue, candidate) ->
        {:error, :candidate_changed}

      not reviewable_or_accepted?(issue, verified[:terminal] == true) ->
        {:error, :task_not_reviewable}

      true ->
        :ok
    end
  end

  defp accepted_candidate_matches?(issue, candidate) do
    not accepted?(issue) or get_in(issue, ["acceptance", "candidate_sha"]) == candidate
  end

  defp acceptance_scope_matches?(issue, context) do
    case issue["acceptance"] do
      %{"project_id" => project} -> project == context[:project_id]
      %{"tracker_fingerprint" => scope} -> scope == context[:tracker_fingerprint]
      _ -> true
    end
  end

  defp reviewable_or_accepted?(issue, terminal), do: accepted?(issue) or reviewable?(issue, terminal)

  defp acceptance_record(issue, candidate, params, context, verified) do
    if accepted_in_scope?(issue, context[:project_id], context.tracker_fingerprint) do
      issue["acceptance"]
    else
      record = %{
        "command_id" => params["command_id"],
        "tracker_fingerprint" => context.tracker_fingerprint,
        "candidate_sha" => candidate,
        "tracker_state" => verified.state,
        "issue_updated_at" => verified.updated_at,
        "accepted_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      if is_binary(context[:project_id]), do: Map.put(record, "project_id", context.project_id), else: record
    end
  end

  defp matches_issue?(verified, params) do
    verified[:id] == params["issue_id"] and verified[:state] == params["expected_tracker_state"] and
      verified[:updated_at] == params["expected_updated_at"]
  end

  @spec reviewable?(map(), boolean()) :: boolean()
  def reviewable?(issue, terminal) do
    not accepted?(issue) and is_nil(issue["active"]) and not pending_work?(issue) and
      (terminal or (issue["hold"] == "owner_review" and sha?(get_in(issue, ["handoff", "candidate_sha"]))))
  end

  @spec valid_record?(term()) :: boolean()
  def valid_record?(nil), do: true

  def valid_record?(record) when is_map(record) do
    fields = ~w(command_id tracker_fingerprint candidate_sha tracker_state issue_updated_at accepted_at)
    valid_keys = Enum.sort(Map.keys(record)) in [Enum.sort(fields), Enum.sort(["project_id" | fields])]

    valid_keys and (is_nil(record["project_id"]) or text?(record["project_id"], 512)) and
      text?(record["command_id"], 128) and text?(record["tracker_fingerprint"], 256) and text?(record["tracker_state"], 128) and
      optional_sha?(record["candidate_sha"]) and timestamp?(record["issue_updated_at"]) and timestamp?(record["accepted_at"])
  end

  def valid_record?(_), do: false
  defp pending_work?(issue), do: get_in(issue, ["pr_work", issue["selected_work_id"], "phase"]) in ~w(queued building reviewing)
  defp optional_sha?(nil), do: true
  defp optional_sha?(value), do: sha?(value)
  defp sha?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{40}\z/)
  defp text?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and not String.contains?(value, <<0>>)
  defp timestamp?(value), do: text?(value, 40) and match?({:ok, _, _}, DateTime.from_iso8601(value))
end
