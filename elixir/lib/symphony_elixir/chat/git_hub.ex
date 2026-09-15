defmodule SymphonyElixir.Chat.GitHub do
  @moduledoc "Bounded repository writes with exact previews, no transport retries and read-only recovery."

  alias SymphonyElixir.Chat.Tools
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Orchestrator

  @doc "Reads one already-validated filename from a pinned default-branch revision, within a five-second budget."
  @spec read_document(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def read_document(document, tracker, context) do
    task = Task.async(fn -> read_document_now(document, tracker, context) end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :document_unavailable}
    end
  end

  defp read_document_now(document, tracker, context) do
    repo = tracker.provider["repo"]

    with {:ok, [%{"sha" => revision}]} <- request("GET", "/repos/#{repo}/commits", %{"per_page" => 1}, nil, tracker, context),
         true <- (is_binary(revision) and String.match?(revision, ~r/^[0-9a-f]{40}$/)) or {:error, :invalid_revision},
         {:ok, payload} <- request("GET", "/repos/#{repo}/contents/#{document}", %{"ref" => revision}, nil, tracker, context),
         {:ok, text} <- decode_document(payload, document) do
      url = "https://github.com/#{repo}/blob/#{revision}/#{document}"
      reference = %{"label" => document, "url" => url, "revision" => revision}
      {:ok, %{"document" => Map.merge(reference, %{"path" => document, "text" => text}), "references" => [reference]}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_revision}
    end
  rescue
    _ -> {:error, :document_unavailable}
  catch
    _, _ -> {:error, :document_unavailable}
  end

  defp decode_document(%{"type" => "file", "path" => document, "encoding" => "base64", "content" => encoded}, document)
       when is_binary(encoded) and byte_size(encoded) <= 180_000 do
    with {:ok, text} <- Base.decode64(encoded, ignore: :whitespace),
         true <- byte_size(text) <= 131_072 and String.valid?(text) and not String.contains?(text, <<0>>) do
      {:ok, text}
    else
      _ -> {:error, :invalid_document}
    end
  end

  defp decode_document(_payload, _document), do: {:error, :invalid_document}

  @spec confirm(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def confirm(%{"action" => "create_task"} = proposal, tracker, context) do
    with {:ok, existing} <- find_marker(proposal, tracker, context) do
      case existing do
        nil ->
          body = %{"title" => proposal["args"]["title"], "body" => marked_body(proposal), "labels" => []}
          write("POST", issues_path(tracker), body, proposal, tracker, context)

        found ->
          receipt(found, proposal, "Task already created.")
      end
    end
  end

  def confirm(%{"action" => "feedback"} = proposal, tracker, context) do
    with {:ok, existing} <- find_marker(proposal, tracker, context) do
      deliver_feedback(existing, proposal, tracker, context)
    end
  end

  def confirm(%{"action" => action} = proposal, tracker, context) when action in ~w(edit_task queue_task unqueue_task) do
    callback = fn ->
      with {:ok, _settings} <- Tools.scope(context),
           {:ok, issue} <- fetch_issue(proposal, tracker, context),
           :ok <- current_revision(issue, proposal) do
        body = edit_body(proposal, issue, tracker)
        write("PATCH", issue_path(proposal, tracker), body, proposal, tracker, context)
      end
    end

    owner = Application.get_env(:symphony_elixir, :chat_tracker_owner, Orchestrator)
    scope = context.tracker_fingerprint
    revision = proposal["expected_revision"]
    id = issue_id(proposal, context.project_id)
    server = context[:orchestrator] || Orchestrator

    case owner.tracker_action_guarded(scope, revision, id, callback, server) do
      {:error, :unavailable} -> {:error, :write_outcome_unknown}
      result -> result
    end
  end

  @spec reconcile(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def reconcile(%{"action" => action} = proposal, tracker, context) when action in ~w(edit_task queue_task unqueue_task) do
    with {:ok, issue} <- fetch_issue(proposal, tracker, context),
         true <- marked?(issue, proposal) or {:error, :write_outcome_unknown} do
      receipt(issue, proposal, "Task update recovered from GitHub.")
    end
  end

  def reconcile(proposal, tracker, context) do
    with {:ok, found} <- find_marker(proposal, tracker, context),
         true <- is_map(found) or {:error, :write_outcome_unknown} do
      receipt(found, proposal, "Previous write recovered from GitHub.")
    end
  end

  # Both reads and writes are bounded. POST/PATCH must never receive a transport retry.
  @doc false
  @spec request_once(String.t(), String.t(), map(), term(), map()) :: {:ok, map()} | {:error, atom()}
  def request_once(method, path, params, body, settings) do
    options = [
      method: method_atom(method),
      url: settings.api_url <> path,
      params: params,
      auth: {:bearer, settings.token},
      headers: [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}, {"user-agent", "symphony-chat"}],
      retry: false,
      redirect: false,
      receive_timeout: 2_000,
      request_timeout: 4_000,
      finch: [pool_timeout: 500, conn_opts: [transport_opts: [timeout: 1_500]]]
    ]

    options = if body, do: Keyword.put(options, :json, body), else: options

    case Req.request(options) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _reason} -> {:error, :github_unavailable}
    end
  end

  defp method_atom("GET"), do: :get
  defp method_atom("POST"), do: :post
  defp method_atom("PATCH"), do: :patch

  defp deliver_feedback(nil, proposal, tracker, context) do
    with {:ok, issue} <- fetch_issue(proposal, tracker, context), :ok <- current_revision(issue, proposal) do
      path = issue_path(proposal, tracker) <> "/comments"
      write("POST", path, %{"body" => marked_body(proposal)}, proposal, tracker, context)
    end
  end

  defp deliver_feedback(found, proposal, _tracker, _context), do: receipt(found, proposal, "Feedback already recorded.")

  defp request(method, path, params, body, tracker, context) do
    with {:ok, %{tracker: current}} <- Tools.scope(context),
         true <- current == tracker or {:error, :project_changed} do
      request_fun = Application.get_env(:symphony_elixir, :chat_github_request, &request_once/5)

      response = Client.request(method, path, params, body, tracker_settings: tracker, request_fun: request_fun)
      handle_response(response, method, context)
    end
  end

  defp handle_response({:ok, %{status: status, body: result}}, method, context) when status in 200..299 do
    case Tools.scope(context) do
      {:ok, _settings} -> {:ok, result}
      {:error, reason} -> {:error, if(method == "GET", do: reason, else: :write_outcome_unknown)}
    end
  end

  defp handle_response({:ok, %{status: status}}, _method, _context) when status in [401, 403, 404, 409, 410, 422, 429], do: {:error, {:github_rejected, status}}
  defp handle_response(_response, method, _context), do: {:error, if(method == "GET", do: :github_unavailable, else: :write_outcome_unknown)}

  defp fetch_issue(proposal, tracker, context) do
    number = String.to_integer(issue_id(proposal, context.project_id))

    with {:ok, issue} <- request("GET", issue_path(proposal, tracker), %{}, nil, tracker, context),
         true <- valid_issue?(issue, number) or {:error, :invalid_github_issue} do
      {:ok, issue}
    end
  end

  defp valid_issue?(issue, number) when is_map(issue), do: not Map.has_key?(issue, "pull_request") and issue["number"] == number
  defp valid_issue?(_issue, _number), do: false

  defp current_revision(issue, proposal) do
    if is_binary(proposal["expected_updated_at"]) and issue["updated_at"] == proposal["expected_updated_at"], do: :ok, else: {:error, :task_changed}
  end

  defp find_marker(proposal, tracker, context) do
    case DateTime.from_iso8601(proposal["created_at"]) do
      {:ok, created, _offset} ->
        since = created |> DateTime.add(-300, :second) |> DateTime.to_iso8601()
        path = if proposal["action"] == "create_task", do: issues_path(tracker), else: issue_path(proposal, tracker) <> "/comments"
        params = %{"since" => since, "per_page" => 100, "sort" => "created", "direction" => "desc"}
        params = if proposal["action"] == "create_task", do: Map.put(params, "state", "all"), else: params
        marker_page(proposal, tracker, context, path, params, 1)

      _ ->
        {:error, :invalid_proposal}
    end
  end

  defp marker_page(_proposal, _tracker, _context, _path, _params, page) when page > 5, do: {:error, :reconciliation_limit}

  defp marker_page(proposal, tracker, context, path, params, page) do
    with {:ok, rows} <- request("GET", path, Map.put(params, "page", page), nil, tracker, context),
         true <- (is_list(rows) and Enum.all?(rows, &is_map/1)) or {:error, :invalid_github_response} do
      found = Enum.filter(rows, &marked?(&1, proposal))

      case found do
        [row] -> {:ok, row}
        [] when length(rows) < 100 -> {:ok, nil}
        [] -> marker_page(proposal, tracker, context, path, params, page + 1)
        _ -> {:error, :duplicate_write_marker}
      end
    end
  end

  defp write(method, path, body, proposal, tracker, context) do
    with {:ok, result} <- request(method, path, %{}, body, tracker, context),
         true <- (is_map(result) and marked?(result, proposal)) or {:error, :write_outcome_unknown} do
      summary =
        case proposal["action"] do
          "create_task" -> "Task created in the backlog; execution was not queued."
          "feedback" -> "Feedback recorded on GitHub; it does not interrupt or steer a running worker."
          "edit_task" -> "Task updated; its cancelled execution hold remains in place."
          "queue_task" -> "Routing labels added. The cancelled hold remains; Retry can release it after normal admission and launch checks."
          "unqueue_task" -> "Routing labels removed; the cancelled execution hold remains in place."
        end

      receipt(result, proposal, summary)
    end
  end

  defp edit_body(proposal, issue, tracker) do
    args = proposal["args"]
    body = Map.take(args, ~w(title state))
    text = Map.get(args, "body", issue["body"] || "")
    body = Map.put(body, "body", text <> "\n\n" <> marker(proposal))

    update_labels(body, issue, proposal, tracker)
  end

  defp update_labels(body, issue, %{"action" => action}, tracker) when action in ~w(queue_task unqueue_task) do
    labels = issue_labels(issue)
    required = tracker.required_labels
    normalized = Enum.map(labels, &String.downcase/1)

    updated =
      if action == "queue_task" do
        labels ++ Enum.reject(required, &(String.downcase(&1) in normalized))
      else
        required = Enum.map(required, &String.downcase/1)
        Enum.reject(labels, &(String.downcase(&1) in required))
      end

    Map.put(body, "labels", updated)
  end

  defp update_labels(body, issue, proposal, tracker) do
    if proposal["args"]["priority"] do
      labels = issue_labels(issue)

      reserved = Enum.map(tracker.required_labels, &String.downcase/1)
      preserved = Enum.reject(labels, &(String.match?(&1, ~r/^priority:p[1-4]$/i) and String.downcase(&1) not in reserved))
      # Required admission labels and unrelated labels are retained exactly.
      Map.put(body, "labels", preserved ++ ["priority:p#{proposal["args"]["priority"]}"])
    else
      body
    end
  end

  defp issue_labels(issue) do
    Enum.flat_map(issue["labels"] || [], fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp receipt(result, proposal, summary) do
    repo = String.replace_prefix(proposal["project_id"], "github:", "")
    id = if proposal["action"] == "create_task", do: result["number"], else: issue_id(proposal, proposal["project_id"])

    if (is_integer(id) and id > 0) or (is_binary(id) and String.match?(id, ~r/^[1-9][0-9]*$/)) do
      url = Tools.board_url(proposal["project_id"], %{"task" => "github:#{repo}:#{id}"})
      {:ok, %{"widgets" => [%{"type" => "receipt", "summary" => summary, "url" => url, "task_id" => "github:#{repo}:#{id}", "proposal_id" => proposal["id"]}]}}
    else
      {:error, :write_outcome_unknown}
    end
  end

  defp marked?(row, proposal), do: is_binary(row["body"]) and String.contains?(row["body"], marker(proposal))
  defp marked_body(proposal), do: proposal["args"]["body"] <> "\n\n" <> marker(proposal)
  defp marker(proposal), do: "<!-- symphony-chat:" <> proposal["id"] <> " -->"
  defp issues_path(tracker), do: "/repos/" <> tracker.provider["repo"] <> "/issues"
  defp issue_path(proposal, tracker), do: issues_path(tracker) <> "/" <> issue_id(proposal, "github:" <> tracker.provider["repo"])

  defp issue_id(proposal, project) do
    id = proposal["args"]["task_id"] |> String.replace_prefix(project <> ":", "") |> String.replace_prefix("GH-", "")
    if String.match?(id, ~r/^[1-9][0-9]*$/), do: id, else: raise(ArgumentError, "Invalid task reference")
  end
end
