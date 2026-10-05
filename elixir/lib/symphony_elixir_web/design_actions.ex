defmodule SymphonyElixirWeb.DesignActions do
  @moduledoc "Reviewed design references feed the existing durable Backlog preview."

  alias SymphonyElixir.{Design.Store, TaskDraft}
  alias SymphonyElixirWeb.{Endpoint, TaskIntake}

  @sections ~w(brief requirements data architecture decisions)
  @id ~r/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/
  @ref ~r/\A[a-f0-9]{64}\z/
  @source ~r/^Design source: ([a-f0-9]{64})\/([A-Za-z][A-Za-z0-9_-]{0,63})\/(brief|requirements|data|architecture|decisions)\/([A-Za-z][A-Za-z0-9_-]{0,63})$/m

  @spec store() :: module()
  def store, do: Endpoint.config(:design_store, Store)

  @spec prepare(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(project, %{"ref" => ref, "section" => section, "item" => item}, auth) do
    with true <- is_binary(ref) and Regex.match?(@ref, ref) and section in @sections and is_binary(item) and Regex.match?(@id, item),
         {:ok, source} <- store().source(project, ref, auth),
         reviewed = source["reviewed"],
         {:ok, node} <- node(reviewed["scene"], section, item),
         {:ok, ^node} <- node(source["draft"], section, item),
         {:ok, args} <- draft_args(reviewed, section, item, node),
         {:ok, records} <- intake().list(project, auth) do
      submission = submission_id(project, ref, section, item, records, args)
      pending = Enum.find(records, &(action_status(&1) in ~w(pending executing unknown) and &1["id"] != submission))
      if pending, do: {:error, :design_task_pending}, else: intake().prepare(project, submission, args, auth)
    else
      {:error, _} = error -> error
      _ -> {:error, :design_item_not_reviewed}
    end
  end

  def prepare(_project, _params, _auth), do: {:error, :design_item_not_reviewed}

  @spec reference(term()) :: map() | nil
  def reference(body) when is_binary(body) do
    case Regex.scan(@source, body) do
      [[_line, ref, document, section, item]] -> %{ref: ref, document: document, section: section, item: item}
      _ -> nil
    end
  end

  def reference(_body), do: nil

  @spec display_body(String.t()) :: String.t()
  def display_body(body) do
    if reference(body), do: Regex.replace(@source, body, "") |> String.trim(), else: body
  end

  @spec source_url(String.t(), term()) :: String.t() | nil
  def source_url(project, body) do
    case reference(body) do
      nil ->
        nil

      source ->
        SymphonyElixirWeb.WorkspacePath.path(
          "/?" <>
            URI.encode_query(%{
              "project" => project,
              "view" => "idea",
              "design_ref" => source.ref,
              "design_section" => source.section,
              "design_item" => source.item
            })
        )
    end
  end

  @spec node(term(), String.t(), String.t()) :: {:ok, map()} | {:error, :design_item_not_reviewed}
  def node(%{"boards" => boards}, section, id) do
    elements = get_in(boards, [section, "elements"]) || []
    members = Enum.filter(elements, &(&1["isDeleted"] != true and get_in(&1, ["customData", "symphony", "id"]) == id))
    shape = Enum.find(members, &(get_in(&1, ["customData", "symphony", "role"]) == "node"))

    if shape do
      {:ok, %{title: member_text(members, "title"), text: member_text(members, "body"), kind: get_in(shape, ["customData", "symphony", "kind"])}}
    else
      {:error, :design_item_not_reviewed}
    end
  end

  def node(_scene, _section, _id), do: {:error, :design_item_not_reviewed}

  defp draft_args(reviewed, section, item, node) do
    source = "Design source: #{reviewed["ref"]}/#{reviewed["document_id"]}/#{section}/#{item}"
    # Quotes retain source text without interpreting a design's phrases as task
    # prerequisite declarations. Dependencies are chosen separately in planning.
    excerpt = node.text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
    fields = %{"title" => node.title, "description" => "Reviewed design excerpt:\n\n#{excerpt}\n\n#{source}", "verification" => ""}

    case TaskDraft.action_args(fields) do
      {:ok, args} -> {:ok, args}
      {:error, _} -> {:error, :design_item_too_large}
    end
  end

  defp member_text(members, role) do
    member = Enum.find(members, &(get_in(&1, ["customData", "symphony", "role"]) == role)) || %{}
    member["originalText"] || member["text"] || ""
  end

  defp submission_id(project, ref, section, item, records, args) do
    matching = Enum.filter(records, &(get_in(&1, ["proposals", Access.at(0), "args", "body"]) == args["body"]))
    existing = Enum.find(matching, &(action_status(&1) in ~w(pending executing unknown completed)))

    if existing do
      existing["id"]
    else
      retired = matching |> Enum.map(& &1["id"]) |> Enum.sort()
      :crypto.hash(:sha256, Jason.encode!(["design-task-v1", project, ref, section, item, retired])) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    end
  end

  defp action_status(record), do: get_in(record, ["proposals", Access.at(0), "status"])
  defp intake, do: Endpoint.config(:task_intake, TaskIntake)
end
