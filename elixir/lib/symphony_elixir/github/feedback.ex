defmodule SymphonyElixir.GitHub.Feedback do
  @moduledoc "Projects bounded human comments from the existing GitHub board read."

  alias SymphonyElixir.Feedback

  @limit 20
  @thread_limit 10
  @reply_limit 3

  @spec collect(map(), [map()], map(), String.t(), boolean()) :: map()
  def collect(issue, prs, task, repo, relationship_partial) do
    issue_source = comments(issue["comments"], "issue", nil, repo, task.issue_id)
    sources = [issue_source | Enum.flat_map(prs, &pr_sources(&1, repo))]
    {records, partial, available} = combine(sources)

    conflicts =
      records
      |> Enum.group_by(fn {item, _at} -> item["id"] end)
      |> Enum.filter(fn {_id, entries} -> entries |> Enum.uniq_by(fn {item, _at} -> item["revision"] end) |> length() > 1 end)
      |> Enum.map(&elem(&1, 0))

    ordered =
      records
      |> Enum.reject(fn {item, _at} -> item["id"] in conflicts end)
      |> Enum.sort_by(fn {item, at} -> {-at, item["id"]} end)
      |> Enum.uniq_by(fn {item, _at} -> item["id"] end)

    {items, capped} =
      Enum.reduce(ordered, {[], false}, fn {item, _at}, {items, capped} ->
        if Feedback.valid_items?(items ++ [item]), do: {items ++ [item], capped}, else: {items, true}
      end)

    progress = Feedback.progress(items, task[:ledger] || %{})

    status =
      cond do
        not available -> "unavailable"
        relationship_partial or partial or capped or conflicts != [] -> "partial"
        true -> "available"
      end

    %{items: progress, counts: Feedback.counts(progress), status: status}
  end

  @spec unavailable() :: map()
  def unavailable, do: %{items: [], counts: Feedback.counts([]), status: "unavailable"}

  defp pr_sources(pr, repo) do
    number = pr["number"]
    general = comments(pr["comments"], "pr", number, repo, number)
    reviews = comments(pr["reviews"], "review", number, repo, number)
    {threads, partial, available} = connection(pr["reviewThreads"], "hasPreviousPage", @thread_limit)

    roots =
      Enum.map(threads, fn
        %{"comments" => comments} -> comments(comments, "review", number, repo, number, "hasPreviousPage", @reply_limit)
        _ -> {[], true, false}
      end)

    [general, reviews, {[], partial, available} | roots]
  end

  defp comments(value, source, pr, repo, number, direction \\ "hasPreviousPage", limit \\ @limit) do
    {nodes, partial, available} = connection(value, direction, limit)

    {records, partial} =
      Enum.reduce(nodes, {[], partial}, fn node, {records, partial} ->
        case comment(node, source, pr, repo, number) do
          {:ok, record} -> {[record | records], partial}
          :skip -> {records, partial}
          :invalid -> {records, true}
        end
      end)

    {records, partial, available}
  end

  defp connection(%{"nodes" => nodes, "pageInfo" => page, "totalCount" => total}, direction, limit)
       when is_list(nodes) and is_map(page) and is_integer(total) and total >= 0 do
    {Enum.take(nodes, limit), page[direction] != false or total != length(nodes) or length(nodes) > limit, true}
  end

  defp connection(_value, _direction, _limit), do: {[], true, false}

  defp comment(%{"body" => body, "author" => author} = node, source, pr, repo, number) when is_binary(body) do
    cond do
      not String.valid?(body) -> :invalid
      node["state"] == "PENDING" or bot?(author) or host_status?(body) or String.trim(body) == "" -> :skip
      not human?(author) -> :invalid
      true -> normalize(node, source, pr, repo, number)
    end
  end

  defp comment(_node, _source, _pr, _repo, _number), do: :invalid

  defp normalize(node, source, pr, repo, number) do
    with true <- valid_url?(node["url"], source, repo, number),
         updated when is_binary(updated) <- node["updatedAt"],
         true <- byte_size(updated) <= 64 and String.valid?(updated),
         {:ok, at, _offset} <- DateTime.from_iso8601(updated) do
      item = %{
        "id" => node["id"],
        "revision" => :crypto.hash(:sha256, Jason.encode!([updated, node["body"]])) |> Base.encode16(case: :lower),
        "url" => node["url"],
        "body" => node["body"],
        "author" => node["author"]["login"],
        "source" => source,
        "pr_number" => pr
      }

      if Feedback.valid_items?([item]), do: {:ok, {item, DateTime.to_unix(at, :microsecond)}}, else: :invalid
    else
      _ -> :invalid
    end
  end

  defp valid_url?(url, source, repo, number) when is_binary(url) do
    path = if source == "issue", do: "issues", else: "pull"
    prefix = "https://github.com/#{repo}/#{path}/#{number}#"
    fragment = String.replace_prefix(url, prefix, "")
    allowed = if source == "review", do: ~r/\A(?:discussion_r|pullrequestreview-)[1-9][0-9]*\z/, else: ~r/\Aissuecomment-[1-9][0-9]*\z/
    String.starts_with?(url, prefix) and Regex.match?(allowed, fragment)
  end

  defp valid_url?(_url, _source, _repo, _number), do: false
  defp human?(%{"__typename" => "User", "login" => login}), do: is_binary(login) and login != ""
  defp human?(_author), do: false
  defp bot?(%{"__typename" => "Bot"}), do: true
  defp bot?(%{"login" => login}) when is_binary(login), do: String.ends_with?(String.downcase(login), "[bot]")
  defp bot?(_author), do: false
  defp host_status?(body), do: String.contains?(body, ["<!-- symphony issue=", "<!-- symphony-feedback:"])

  defp combine(sources) do
    Enum.reduce(sources, {[], false, false}, fn {records, partial, available}, {all, any_partial, any_available} ->
      {records ++ all, partial or any_partial, available or any_available}
    end)
  end
end
