defmodule SymphonyElixirWeb.SpecificationActions do
  @moduledoc "Reviewed requirements enter the existing durable task preview, without changing execution gates."

  alias SymphonyElixir.Specification.{Document, Store, TaskLinks}
  alias SymphonyElixirWeb.{Endpoint, SpecificationEditor, TaskIntake, WorkspacePath}

  @spec prepare(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(project, %{"ref" => ref, "item" => id, "storage_revision" => revision}, auth) do
    with true <- is_binary(ref) and String.match?(ref, ~r/\A[a-f0-9]{64}\z/) and Document.identifier?(id),
         {:ok, source} <- store().source(project, ref, auth),
         true <- SpecificationEditor.revision(revision) == source["storage_revision"] or {:error, :stale_specification_revision},
         document = source["reviewed"]["specification"],
         item when is_map(item) <- TaskLinks.requirement(document, id),
         ^item <- TaskLinks.requirement(source["draft"], id),
         {:ok, args} <- TaskLinks.action_args(document, ref, id),
         {:ok, records} <- intake().list(project, auth) do
      submission = submission_id(project, ref, id, records, args)
      pending = Enum.find(records, &(status(&1) in ~w(pending executing unknown) and &1["id"] != submission))
      if pending, do: {:error, :specification_task_pending}, else: intake().prepare(project, submission, args, auth)
    else
      {:error, _} = error -> error
      _ -> {:error, :specification_item_not_reviewed}
    end
  end

  def prepare(_project, _params, _auth), do: {:error, :specification_item_not_reviewed}

  @spec source_url(String.t(), term()) :: String.t() | nil
  def source_url(project, body) do
    if source = TaskLinks.reference(body) do
      WorkspacePath.path("/?" <> URI.encode_query(%{"project" => project, "view" => "design", "spec_ref" => source.ref, "spec_document" => source.document, "spec_item" => source.item}))
    end
  end

  @spec task_url(String.t(), String.t()) :: String.t()
  def task_url(project, id), do: WorkspacePath.path("/?" <> URI.encode_query(%{"project" => project, "view" => "kanban", "task" => id}))

  @spec get(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get(project, id, auth), do: intake().get(project, id, auth)

  @spec records(String.t(), map()) :: {:ok, list()} | {:error, term()}
  def records(project, auth) do
    case intake().list(project, auth) do
      {:ok, records} when is_list(records) -> {:ok, records}
      {:error, _} = error -> error
      _ -> {:error, :task_links_unavailable}
    end
  rescue
    _ -> {:error, :task_links_unavailable}
  catch
    :exit, _ -> {:error, :task_links_unavailable}
  end

  defp submission_id(project, ref, item, records, args) do
    matching = Enum.filter(records, &(get_in(&1, ["proposals", Access.at(0), "args", "body"]) == args["body"]))

    if existing = Enum.find(matching, &(status(&1) in ~w(pending executing unknown completed))) do
      existing["id"]
    else
      retired = matching |> Enum.map(& &1["id"]) |> Enum.sort()
      :crypto.hash(:sha256, Jason.encode!(["specification-task-v1", project, ref, item, retired])) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    end
  end

  defp status(record), do: get_in(record, ["proposals", Access.at(0), "status"])
  defp intake, do: Endpoint.config(:task_intake, TaskIntake)
  defp store, do: Endpoint.config(:specification_store, Store)
end
