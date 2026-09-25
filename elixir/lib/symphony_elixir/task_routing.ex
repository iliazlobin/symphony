defmodule SymphonyElixir.TaskRouting do
  @moduledoc "Local task routing decisions and their durable GitHub mirror intent."

  alias SymphonyElixir.Tracker.Issue

  @queue_actions ~w(queue_task retry create_pr_work continue_pr_work)
  @unqueue_actions ~w(unqueue_task cancel accept_task)

  @spec fingerprint(map()) :: String.t()
  def fingerprint(tracker), do: :crypto.hash(:sha256, :erlang.term_to_binary(tracker)) |> Base.url_encode64(padding: false)

  @spec routable?(Issue.t(), map() | nil, map()) :: boolean()
  def routable?(issue, item, tracker) do
    case scoped(item, fingerprint(tracker)) do
      %{"queued" => queued} -> issue.dispatchable and queued
      nil -> Issue.routable?(issue, tracker.required_labels)
    end
  end

  @spec scoped(map() | nil, String.t()) :: map() | nil
  def scoped(%{"routing" => %{"tracker_fingerprint" => scope} = routing}, scope), do: routing
  def scoped(_, _), do: nil

  @spec intent(map(), String.t(), non_neg_integer(), map()) :: map()
  def intent(item, action, revision, context) when action in @queue_actions or action in @unqueue_actions do
    if context[:tracker_kind] == "github" do
      routing = %{
        "tracker_fingerprint" => context.tracker_fingerprint,
        "repository" => context.repository,
        "labels" => context.required_labels,
        "queued" => action in @queue_actions,
        "revision" => revision,
        "status" => "pending",
        "error" => nil,
        "synced_at" => nil
      }

      Map.put(item, "routing", routing)
    else
      item
    end
  end

  def intent(item, _action, _revision, _context), do: item

  @spec observation(Issue.t(), map()) :: map() | nil
  def observation(%Issue{id: id, native_ref: %{"repo" => repo}, updated_at: %DateTime{} = updated} = issue, tracker) do
    record = %{
      "id" => id,
      "repository" => repo,
      "tracker_fingerprint" => fingerprint(tracker),
      "state" => issue.state,
      "updated_at" => DateTime.to_iso8601(updated),
      "dispatchable" => issue.dispatchable
    }

    if tracker.kind == "github" and repo == tracker.provider["repo"] and valid_observation?(record), do: record
  end

  def observation(_, _tracker), do: nil

  @spec valid_observation?(term()) :: boolean()
  def valid_observation?(record) when is_map(record) do
    Enum.sort(Map.keys(record)) == Enum.sort(~w(id repository tracker_fingerprint state updated_at dispatchable)) and
      is_binary(record["id"]) and String.match?(record["id"], ~r/\A[1-9][0-9]{0,9}\z/) and
      repository?(record["repository"]) and text?(record["tracker_fingerprint"], 256) and
      record["state"] in ~w(open closed) and timestamp?(record["updated_at"]) and is_boolean(record["dispatchable"])
  end

  def valid_observation?(_), do: false

  @spec valid?(term()) :: boolean()
  def valid?(nil), do: true

  def valid?(routing) when is_map(routing) do
    Enum.sort(Map.keys(routing)) == Enum.sort(~w(tracker_fingerprint repository labels queued revision status error synced_at)) and
      text?(routing["tracker_fingerprint"], 256) and repository?(routing["repository"]) and
      valid_labels?(routing["labels"]) and is_boolean(routing["queued"]) and positive?(routing["revision"]) and
      valid_delivery?(routing)
  end

  def valid?(_), do: false

  defp valid_labels?(labels), do: is_list(labels) and length(labels) <= 100 and Enum.all?(labels, &text?(&1, 256))
  defp positive?(number), do: is_integer(number) and number > 0

  defp valid_delivery?(routing) do
    routing["status"] in ~w(pending synced) and (is_nil(routing["error"]) or text?(routing["error"], 128)) and
      (is_nil(routing["synced_at"]) or timestamp?(routing["synced_at"]))
  end

  defp repository?(value), do: is_binary(value) and String.match?(value, ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/) and Enum.all?(String.split(value, "/"), &(&1 not in [".", ".."]))
  defp text?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and not String.contains?(value, <<0>>)
  defp timestamp?(value), do: text?(value, 40) and match?({:ok, _, _}, DateTime.from_iso8601(value))
end
