defmodule SymphonyElixir.Specification.Persistence do
  @moduledoc "Specification journal contract over the existing private atomic journal transport."

  alias SymphonyElixir.Design.Persistence, as: Journal
  alias SymphonyElixir.Specification.Document

  @spec open(Path.t(), String.t(), String.t()) :: {:ok, map(), map()} | {:error, atom()}
  def open(root, project, scope), do: translate(Journal.open(root, project, scope, __MODULE__))

  @spec check(map()) :: :ok | {:error, atom()}
  def check(owner), do: translate(Journal.check(owner))

  @spec put(map(), map()) :: {:ok, map()} | {:error, atom()}
  def put(owner, journal), do: translate(Journal.put(owner, journal))

  @spec close(map() | nil) :: :ok
  def close(owner), do: Journal.close(owner)

  @spec scope_ref(term()) :: String.t()
  def scope_ref(scope), do: Journal.scope_ref(scope)

  @spec empty(String.t(), String.t()) :: map()
  def empty(project, scope) do
    %{"version" => 1, "project" => project, "scope" => scope, "storage_revision" => 0, "draft" => nil, "reviewed_ref" => nil, "reviews" => %{}}
  end

  @spec valid?(term(), String.t(), String.t()) :: boolean()
  def valid?(journal, project, scope), do: valid_journal?(journal, project, scope)

  @spec valid_journal?(term(), String.t(), String.t()) :: boolean()
  def valid_journal?(journal, project, scope) do
    exact?(journal, ~w(version project scope storage_revision draft reviewed_ref reviews)) and
      journal["version"] == 1 and journal["project"] == project and journal["scope"] == scope and
      is_integer(journal["storage_revision"]) and journal["storage_revision"] >= 0 and
      is_map(journal["reviews"]) and valid_content?(journal, project)
  end

  defp valid_content?(journal, project) do
    (is_nil(journal["draft"]) or Document.valid?(journal["draft"], project)) and
      (is_nil(journal["reviewed_ref"]) or Map.has_key?(journal["reviews"], journal["reviewed_ref"])) and
      Enum.all?(journal["reviews"], &valid_review?(&1, project, journal["draft"]))
  end

  defp valid_review?({ref, record}, project, draft) do
    exact?(record, ~w(ref document_id reviewed_at specification)) and
      is_binary(ref) and String.match?(ref, ~r/\A[a-f0-9]{64}\z/) and record["ref"] == ref and
      valid_review_document?(record, ref, project, draft)
  end

  defp valid_review_document?(record, ref, project, draft) do
    Document.valid?(record["specification"], project) and Document.content_ref(record["specification"]) == ref and
      record["document_id"] == record["specification"]["document_id"] and
      is_map(draft) and record["document_id"] == draft["document_id"] and valid_time?(record["reviewed_at"])
  end

  defp valid_time?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, 0} -> true
      _ -> false
    end
  end

  defp valid_time?(_), do: false
  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp translate({:error, :design_storage_full}), do: {:error, :specification_storage_full}
  defp translate({:error, :design_storage_locked}), do: {:error, :specification_storage_locked}
  defp translate({:error, :design_storage_unavailable}), do: {:error, :specification_storage_unavailable}
  defp translate(result), do: result
end
