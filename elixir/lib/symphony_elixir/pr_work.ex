defmodule SymphonyElixir.PRWork do
  @moduledoc "Durable PR-work identities and transitions, written only through the native control owner."

  alias SymphonyElixir.Feedback
  alias SymphonyElixir.GitHub.Client

  @actions ~w(create_pr_work continue_pr_work)
  @phases ~w(queued building reviewing owner_review paused)
  @publication_fields ~w(issue_id work_id run_id candidate_sha expected_head_sha branch base_sha pr_number pr_url status merge_sha)
  @remote_conflicts [:unsupported_tracker_scope, :pr_already_merged, :pr_head_changed, :approved_baseline_changed]

  @spec command?(map()) :: boolean()
  def command?(params), do: params["action"] in @actions

  @spec command_fields(String.t()) :: [String.t()]
  def command_fields("create_pr_work"), do: ~w(work_id instruction base_sha feedback)
  def command_fields("continue_pr_work"), do: ~w(work_id instruction expected_head_sha feedback)
  def command_fields(_), do: []

  @spec valid_command?(map()) :: boolean()
  def valid_command?(params) do
    command?(params) and id?(params["work_id"]) and issue_id?(params["issue_id"]) and text?(params["instruction"], 16_000) and Feedback.valid_items?(Map.get(params, "feedback", [])) and
      case params["action"] do
        "create_pr_work" -> sha?(params["base_sha"])
        "continue_pr_work" -> Map.has_key?(params, "expected_head_sha") and optional_sha?(params["expected_head_sha"])
      end
  end

  @spec transition(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def transition(issue, params, context) do
    cond do
      not is_nil(issue["active"]) -> {:error, :issue_running}
      not text?(context[:tracker_fingerprint], 256) -> {:error, :tracker_changed}
      true -> change(issue, params, context)
    end
  end

  defp change(issue, %{"action" => "create_pr_work"} = params, context) do
    works = issue["pr_work"] || %{}
    id = params["work_id"]

    cond do
      Map.has_key?(works, id) ->
        {:error, :pr_work_exists}

      Enum.any?(works, fn {_id, work} -> work["tracker_fingerprint"] != context.tracker_fingerprint end) ->
        {:error, :tracker_changed}

      map_size(works) >= 20 ->
        {:error, :pr_work_limit}

      pending?(issue) ->
        {:error, :pr_work_pending}

      params["base_sha"] != context[:base_sha] ->
        {:error, :approved_baseline_changed}

      true ->
        work = %{
          "id" => id,
          "issue_id" => params["issue_id"],
          "tracker_fingerprint" => context.tracker_fingerprint,
          "base_sha" => params["base_sha"],
          "branch" => branch(params["issue_id"], id),
          "workspace_key" => workspace_key(params["issue_id"], id),
          "builder_thread_id" => nil,
          "builder_usage" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
          "head_sha" => nil,
          "working_head_sha" => nil,
          "published_head_sha" => nil,
          "instruction" => params["instruction"],
          "feedback" => Map.get(params, "feedback", []),
          "phase" => "queued",
          "created_at" => timestamp(),
          "updated_at" => timestamp()
        }

        next = issue |> preserve_legacy_handoff() |> Map.put("pr_work", Map.put(works, id, work)) |> Map.put("selected_work_id", id)
        {:ok, release_review_hold(next)}
    end
  end

  defp change(issue, params, context) do
    work = get_in(issue, ["pr_work", params["work_id"]])

    cond do
      is_nil(work) ->
        {:error, :pr_work_not_found}

      work["tracker_fingerprint"] != context.tracker_fingerprint ->
        {:error, :tracker_changed}

      work["base_sha"] != context[:base_sha] ->
        {:error, :approved_baseline_changed}

      pending?(issue) ->
        {:error, :pr_work_pending}

      work["head_sha"] != params["expected_head_sha"] ->
        {:error, :pr_head_changed}

      not Feedback.history_capacity?(work, Map.get(params, "feedback", [])) ->
        {:error, :feedback_history_full}

      true ->
        updated = Map.merge(work, %{"instruction" => params["instruction"], "feedback" => Map.get(params, "feedback", []), "phase" => "queued", "updated_at" => timestamp()})
        next = issue |> put_in(["pr_work", work["id"]], updated) |> Map.put("selected_work_id", work["id"])
        {:ok, release_review_hold(next)}
    end
  end

  defp release_review_hold(%{"hold" => "owner_review"} = issue), do: Map.put(issue, "hold", nil)
  defp release_review_hold(issue), do: issue

  defp preserve_legacy_handoff(%{"handoff" => handoff} = issue) when is_map(handoff) do
    if is_nil(handoff["work_id"]), do: Map.put_new(issue, "legacy_handoff", handoff), else: issue
  end

  defp preserve_legacy_handoff(issue), do: issue

  @spec selected(map()) :: map() | nil
  def selected(issue), do: get_in(issue, ["pr_work", issue["selected_work_id"]])

  @spec dispatchable?(map()) :: boolean()
  def dispatchable?(issue), do: is_nil(issue["pr_work"]) or match?(%{"phase" => "queued"}, selected(issue))

  defp pending?(issue), do: match?(%{"phase" => phase} when phase in ["queued", "building", "reviewing"], selected(issue))

  @spec reserve(map()) :: map()
  def reserve(issue) do
    case selected(issue) do
      nil -> issue
      work -> issue |> put_in(["active", "work_id"], work["id"]) |> update_work(work["id"], %{"phase" => "building"})
    end
  end

  @spec checkpoint(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def checkpoint(issue, id, attrs) do
    work = get_in(issue, ["pr_work", id])

    if is_map(work) and get_in(issue, ["active", "work_id"]) == id and is_nil(issue["hold"]),
      do: checkpoint_attrs(issue, work, attrs),
      else: {:error, :stale_run}
  end

  defp checkpoint_attrs(issue, work, %{"builder_thread_id" => thread} = attrs) when map_size(attrs) == 1,
    do: checkpoint_thread(issue, work, thread)

  defp checkpoint_attrs(issue, work, %{"working_head_sha" => sha} = attrs) when map_size(attrs) == 1 do
    if sha?(sha) and text?(work["builder_thread_id"], 128) do
      {:ok, update_work(issue, work["id"], Map.put(attrs, "phase", "reviewing"))}
    else
      {:error, :invalid_checkpoint}
    end
  end

  defp checkpoint_attrs(issue, work, %{"phase" => "reviewing"} = attrs) when map_size(attrs) == 1 do
    if text?(work["builder_thread_id"], 128), do: {:ok, update_work(issue, work["id"], attrs)}, else: {:error, :invalid_checkpoint}
  end

  defp checkpoint_attrs(_issue, _work, _attrs), do: {:error, :invalid_checkpoint}

  defp checkpoint_thread(issue, work, thread) do
    if text?(thread, 128) and work["builder_thread_id"] in [nil, thread],
      do: {:ok, update_work(issue, work["id"], %{"builder_thread_id" => thread})},
      else: {:error, :builder_thread_changed}
  end

  @spec usage(map(), map() | nil) :: map()
  def usage(issue, nil), do: issue

  def usage(issue, usage) do
    work = selected(issue)

    if work && work["builder_thread_id"] == usage["thread_id"] do
      totals = Map.new(~w(input_tokens output_tokens total_tokens), &{&1, max(usage[&1], work["builder_usage"][&1])})
      update_work(issue, work["id"], %{"builder_usage" => totals})
    else
      issue
    end
  end

  @spec finish(map(), String.t() | nil, map() | nil) :: {:ok, map()} | {:error, atom()}
  def finish(issue, hold, evidence) do
    id = get_in(issue, ["active", "work_id"])

    cond do
      is_nil(id) ->
        {:ok, issue}

      is_nil(evidence) ->
        {:ok, update_work(issue, id, %{"phase" => if(hold || issue["hold"], do: "paused", else: "queued")})}

      valid_evidence?(get_in(issue, ["pr_work", id]), evidence) and evidence["run_id"] == issue["active"]["run_id"] ->
        history = Feedback.history(get_in(issue, ["pr_work", id]), evidence)

        if Feedback.valid_history?(history),
          do: {:ok, update_work(issue, id, %{"phase" => "owner_review", "head_sha" => evidence["candidate_sha"], "handoff" => evidence, "feedback_history" => history})},
          else: {:error, :feedback_history_full}

      true ->
        {:error, :invalid_pr_handoff}
    end
  end

  @spec retry(map()) :: {:ok, map()} | {:error, atom()}
  def retry(issue) do
    case selected(issue) do
      %{"phase" => "owner_review"} -> {:error, :pr_work_continuation_required}
      %{"id" => id, "phase" => "paused"} -> {:ok, update_work(issue, id, %{"phase" => "queued"})}
      _ -> {:ok, issue}
    end
  end

  @spec recover(map()) :: map()
  def recover(issue) do
    case get_in(issue, ["active", "work_id"]) do
      nil -> issue
      id -> update_work(issue, id, %{"phase" => "paused"})
    end
  end

  @spec hold(map(), String.t()) :: map()
  def hold(issue, reason) do
    issue = Map.put(issue, "hold", reason)

    case {issue["active"], selected(issue)} do
      {nil, %{"id" => id, "phase" => "queued"}} -> update_work(issue, id, %{"phase" => "paused"})
      _ -> issue
    end
  end

  @spec publication(map(), map(), map()) :: {:ok, map(), boolean()} | {:error, atom()}
  def publication(issue, receipt, context) do
    work = get_in(issue, ["pr_work", receipt["work_id"]])

    cond do
      not valid_publication?(receipt, context[:repository]) -> {:error, :invalid_publication}
      is_nil(work) -> {:error, :pr_work_not_found}
      work["tracker_fingerprint"] != context[:tracker_fingerprint] -> {:error, :tracker_changed}
      not is_nil(issue["active"]) -> {:error, :issue_running}
      issue["hold"] != "owner_review" -> {:error, :pr_work_pending}
      work["phase"] != "owner_review" -> {:error, :pr_work_pending}
      not same_handoff?(work["handoff"], receipt) -> {:error, :pr_head_changed}
      true -> accept_publication(issue, work, receipt)
    end
  end

  defp accept_publication(issue, work, receipt) do
    previous = work["publication"]

    cond do
      is_map(previous) and Map.take(previous, ~w(pr_number pr_url)) != Map.take(receipt, ~w(pr_number pr_url)) ->
        {:error, :pr_identity_changed}

      is_map(previous) and previous["status"] == "merged" and previous != receipt ->
        {:error, :pr_already_merged}

      previous == receipt ->
        {:ok, issue, true}

      true ->
        attrs = %{"publication" => receipt, "published_head_sha" => receipt["candidate_sha"]}
        {:ok, update_work(issue, work["id"], attrs), false}
    end
  end

  defp same_handoff?(handoff, receipt) when is_map(handoff) do
    Enum.all?(~w(work_id run_id candidate_sha expected_head_sha branch base_sha), &(handoff[&1] == receipt[&1])) and
      get_in(handoff, ["review", "verdict"]) == "approve" and get_in(handoff, ["review", "findings"]) == []
  end

  defp same_handoff?(_, _), do: false

  defp valid_publication?(receipt, repository) do
    is_map(receipt) and Enum.all?(Map.keys(receipt), &(&1 in @publication_fields)) and
      publication_identity?(receipt, repository) and publication_revision?(receipt) and publication_status?(receipt)
  end

  defp publication_identity?(receipt, repository) do
    issue_id?(receipt["issue_id"]) and id?(receipt["work_id"]) and text?(repository, 256) and
      is_integer(receipt["pr_number"]) and receipt["pr_number"] > 0 and
      receipt["pr_url"] == "https://github.com/#{repository}/pull/#{receipt["pr_number"]}"
  end

  defp publication_revision?(receipt) do
    text?(receipt["run_id"], 128) and sha?(receipt["candidate_sha"]) and sha?(receipt["base_sha"]) and
      Map.has_key?(receipt, "expected_head_sha") and optional_sha?(receipt["expected_head_sha"]) and
      receipt["branch"] == branch(receipt["issue_id"], receipt["work_id"])
  end

  defp publication_status?(receipt) do
    receipt["status"] in ~w(draft_pr ready merged) and
      if(receipt["status"] == "merged", do: sha?(receipt["merge_sha"]), else: is_nil(receipt["merge_sha"]))
  end

  @spec verify_remote(map() | nil, map()) :: :ok | {:error, atom()}
  def verify_remote(nil, _tracker), do: :ok
  def verify_remote(%{"published_head_sha" => nil}, _tracker), do: :ok

  def verify_remote(work, tracker) do
    receipt = work["publication"] || %{}
    repo = tracker.provider["repo"]

    with true <- (tracker.kind == "github" and tracker.provider["api_url"] in [nil, "https://api.github.com"]) or {:error, :unsupported_tracker_scope},
         true <- receipt["status"] != "merged" or {:error, :pr_already_merged},
         {:ok, %{status: 200, body: pr}} when is_map(pr) <-
           Client.request("GET", "/repos/#{repo}/pulls/#{receipt["pr_number"]}", %{}, nil,
             tracker_settings: tracker,
             request_fun: Application.get_env(:symphony_elixir, :pr_work_github_request, &remote_request/5)
           ),
         true <- remote_identity?(pr, work, repo) or {:error, :pr_head_changed},
         true <- get_in(pr, ["base", "sha"]) == work["base_sha"] or {:error, :approved_baseline_changed} do
      :ok
    else
      {:error, reason} when reason in @remote_conflicts ->
        {:error, reason}

      _ ->
        {:error, :pr_evidence_unavailable}
    end
  end

  defp remote_identity?(%{"head" => %{"repo" => %{}}, "base" => %{"repo" => %{}}} = pr, work, repo) do
    receipt = work["publication"]

    pr["number"] == receipt["pr_number"] and pr["html_url"] == receipt["pr_url"] and
      pr["state"] == "open" and pr["merged"] == false and
      get_in(pr, ["head", "sha"]) == work["published_head_sha"] and get_in(pr, ["head", "ref"]) == work["branch"] and
      get_in(pr, ["head", "repo", "full_name"]) == repo and get_in(pr, ["base", "repo", "full_name"]) == repo
  end

  defp remote_identity?(_, _, _), do: false

  defp remote_request(method, path, params, body, settings) do
    case Req.request(
           method: method,
           url: settings.api_url <> path,
           params: params,
           json: body,
           auth: {:bearer, settings.token},
           headers: [{"accept", "application/vnd.github+json"}],
           retry: false,
           redirect: false,
           request_timeout: 4_000,
           receive_timeout: 4_000,
           connect_options: [timeout: 4_000]
         ) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      _ -> {:error, :pr_evidence_unavailable}
    end
  end

  @spec valid_issue?(String.t(), map()) :: boolean()
  def valid_issue?(issue_id, issue) do
    case issue["pr_work"] do
      nil ->
        is_nil(issue["selected_work_id"]) and is_nil(get_in(issue, ["active", "work_id"]))

      works when is_map(works) and map_size(works) in 1..20 ->
        valid_legacy_handoff?(issue["legacy_handoff"]) and Map.has_key?(works, issue["selected_work_id"]) and
          Enum.all?(works, fn {id, work} -> valid_work?(issue_id, id, work) end) and
          valid_active_work?(issue)

      _ ->
        false
    end
  end

  defp valid_active_work?(issue), do: is_nil(issue["active"]) or get_in(issue, ["active", "work_id"]) == issue["selected_work_id"]

  defp valid_legacy_handoff?(nil), do: true
  defp valid_legacy_handoff?(handoff), do: is_map(handoff) and is_nil(handoff["work_id"])

  defp valid_work?(issue_id, id, work) when is_map(work) do
    valid_identity?(issue_id, id, work) and valid_revisions?(work) and valid_session?(work) and
      valid_description?(work) and valid_stored_handoff?(work) and valid_stored_publication?(work)
  end

  defp valid_work?(_, _, _), do: false

  defp valid_identity?(issue_id, id, work) do
    id?(id) and work["id"] == id and issue_id?(issue_id) and work["issue_id"] == issue_id and
      text?(work["tracker_fingerprint"], 256) and work["branch"] == branch(issue_id, id) and
      work["workspace_key"] == workspace_key(issue_id, id)
  end

  defp valid_revisions?(work) do
    sha?(work["base_sha"]) and Enum.all?(~w(head_sha working_head_sha published_head_sha), &optional_sha?(work[&1]))
  end

  defp valid_session?(work) do
    (is_nil(work["builder_thread_id"]) or text?(work["builder_thread_id"], 128)) and
      is_map(work["builder_usage"]) and Enum.all?(~w(input_tokens output_tokens total_tokens), &non_negative?(work["builder_usage"][&1]))
  end

  defp valid_description?(work) do
    text?(work["instruction"], 16_000) and work["phase"] in @phases and
      text?(work["created_at"], 64) and text?(work["updated_at"], 64) and Feedback.valid_items?(Map.get(work, "feedback", [])) and Feedback.valid_history?(work["feedback_history"])
  end

  defp valid_stored_handoff?(work) do
    (work["phase"] != "owner_review" or is_map(work["handoff"])) and
      is_nil(work["head_sha"]) == is_nil(work["handoff"]) and stored_handoff_matches?(work)
  end

  defp stored_handoff_matches?(%{"handoff" => handoff} = work) when is_map(handoff) do
    Map.has_key?(handoff, "expected_head_sha") and optional_sha?(handoff["expected_head_sha"]) and
      valid_evidence?(Map.put(work, "feedback", Map.get(handoff, "feedback_items", [])), Map.put(handoff, "expected_head_sha", work["head_sha"])) and
      handoff["candidate_sha"] == work["head_sha"]
  end

  defp stored_handoff_matches?(work), do: is_nil(work["handoff"])
  defp non_negative?(value), do: is_integer(value) and value >= 0

  defp valid_stored_publication?(%{"published_head_sha" => nil} = work), do: is_nil(work["publication"])

  defp valid_stored_publication?(%{"publication" => %{"pr_url" => url} = receipt} = work) when is_binary(url) do
    case Regex.run(~r/\Ahttps:\/\/github\.com\/([^\/]+\/[^\/]+)\/pull\/[1-9][0-9]*\z/, url) do
      [_, repo] ->
        valid_publication?(receipt, repo) and receipt["work_id"] == work["id"] and receipt["issue_id"] == work["issue_id"] and
          receipt["branch"] == work["branch"] and receipt["base_sha"] == work["base_sha"] and receipt["candidate_sha"] == work["published_head_sha"]

      _ ->
        false
    end
  end

  defp valid_stored_publication?(_), do: false

  defp valid_evidence?(work, evidence) when is_map(work) and is_map(evidence) do
    evidence_identity?(work, evidence) and evidence_review?(evidence) and evidence_sessions?(work, evidence) and
      Map.get(evidence, "feedback_items", []) == Map.get(work, "feedback", []) and
      Feedback.valid_results?(Map.get(work, "feedback", []), Map.get(evidence, "feedback_results", []))
  end

  defp valid_evidence?(_, _), do: false

  defp evidence_identity?(work, evidence) do
    evidence["work_id"] == work["id"] and evidence["expected_head_sha"] == work["head_sha"] and
      evidence["base_sha"] == work["base_sha"] and evidence["branch"] == work["branch"] and sha?(evidence["candidate_sha"])
  end

  defp evidence_review?(evidence) do
    review = evidence["review"] || %{}

    is_map(review) and review["candidate_sha"] == evidence["candidate_sha"] and review["verdict"] in ~w(approve request_changes blocked) and
      is_list(review["findings"]) and (review["verdict"] != "approve" or review["findings"] == [])
  end

  defp evidence_sessions?(work, evidence) do
    text?(work["builder_thread_id"], 128) and text?(evidence["builder_session_id"], 256) and
      String.starts_with?(evidence["builder_session_id"], work["builder_thread_id"] <> "-") and
      text?(evidence["reviewer_session_id"], 256) and not String.starts_with?(evidence["reviewer_session_id"], work["builder_thread_id"] <> "-")
  end

  defp update_work(issue, id, attrs), do: update_in(issue, ["pr_work", id], &Map.merge(&1, Map.put(attrs, "updated_at", timestamp())))
  defp branch(issue, id), do: "codex/gh-#{issue}-#{id}"
  defp workspace_key(issue, id), do: "GH-#{issue}-#{id}"
  defp id?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{32}\z/)
  defp issue_id?(value), do: is_binary(value) and String.match?(value, ~r/\A[1-9][0-9]{0,19}\z/)
  defp sha?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{40}\z/)
  defp optional_sha?(value), do: is_nil(value) or sha?(value)
  defp text?(value, size), do: is_binary(value) and byte_size(value) in 1..size and String.valid?(value) and String.trim(value) != ""
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
