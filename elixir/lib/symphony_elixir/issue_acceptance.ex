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

  @spec accept(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def accept(issue, params, context) do
    cond do
      accepted?(issue) ->
        {:error, :task_already_accepted}

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

    cond do
      not valid_command?(params) ->
        {:error, :invalid_command}

      not text?(context[:tracker_fingerprint], 256) ->
        {:error, :tracker_changed}

      not matches_issue?(verified, params) ->
        {:error, :task_changed}

      candidate != params["expected_candidate_sha"] ->
        {:error, :candidate_changed}

      not reviewable?(issue, verified[:terminal] == true) ->
        {:error, :task_not_reviewable}

      true ->
        record = %{
          "command_id" => params["command_id"],
          "tracker_fingerprint" => context.tracker_fingerprint,
          "candidate_sha" => candidate,
          "tracker_state" => verified.state,
          "issue_updated_at" => verified.updated_at,
          "accepted_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }

        {:ok, issue |> Map.put("acceptance", record) |> Map.put("hold", "accepted")}
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
    Enum.sort(Map.keys(record)) == Enum.sort(~w(command_id tracker_fingerprint candidate_sha tracker_state issue_updated_at accepted_at)) and
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
