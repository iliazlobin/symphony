defmodule SymphonyElixir.Specification.Document do
  @moduledoc "Bounded structured specification documents; Mermaid source remains editable text."
  alias SymphonyElixir.Specification.Object

  @sections ~w(brief requirements data architecture decisions)
  @kinds %{
    "brief" => ~w(goal scope assumption),
    "requirements" => ~w(functional nonfunctional),
    "data" => ~w(entity relationship),
    "architecture" => ~w(component flow interface),
    "decisions" => ~w(decision question validation)
  }

  @spec sections() :: [String.t()]
  def sections, do: @sections

  @spec kinds(String.t()) :: [String.t()]
  def kinds(section), do: Map.get(@kinds, section, [])

  @spec new(String.t()) :: map()
  def new(project) do
    %{"version" => 2, "project" => project, "document_id" => id("spec"), "sections" => Map.new(@sections, &{&1, %{"items" => [], "diagrams" => []}})}
  end

  @spec item(String.t(), String.t() | nil) :: map() | nil
  def item(section, requested_kind \\ nil) do
    case kinds(section) do
      [kind | _] -> if is_nil(requested_kind) or requested_kind in kinds(section), do: Object.new(id("item"), requested_kind || kind)
      [] -> nil
    end
  end

  @doc "Explicit, lossless draft conversion; retained version-one reviews are never rewritten."
  @spec upgrade(map()) :: {:ok, map()} | {:error, atom()}
  def upgrade(document) do
    if is_map(document) and valid?(document, document["project"]) do
      if document["version"] == 1 do
        sections = Map.new(document["sections"], &upgrade_section/1)

        checked(%{document | "version" => 2, "sections" => sections})
      else
        {:ok, document}
      end
    else
      {:error, :invalid_specification_form}
    end
  end

  @doc "Import a typed draft only when its identity, original notes and diagrams carry forward."
  @spec import_objects(map(), term()) :: {:ok, map()} | {:error, atom()}
  def import_objects(document, json) do
    with true <- is_map(document) and valid?(document, document["project"]),
         true <- is_binary(json) and byte_size(json) <= 1_000_000,
         {:ok, candidate} <- Jason.decode(json),
         true <- is_map(candidate) and candidate["version"] == 2 and valid?(candidate, document["project"]),
         true <- candidate["document_id"] == document["document_id"],
         true <- retained?(document, candidate) do
      {:ok, candidate}
    else
      _ -> {:error, :invalid_specification_import}
    end
  end

  @spec diagram() :: map()
  def diagram, do: %{"id" => id("diagram"), "title" => "", "source" => "flowchart TD\n  A[Start] --> B[Next]"}

  @doc "Edits only existing stable IDs in one section; unknown or incomplete form rows fail closed."
  @spec edit(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def edit(document, section, params) do
    with true <- editable?(document, section) and is_map(params),
         {:ok, items} <- edit_items(document, section, Map.get(params, "items", %{})),
         {:ok, diagrams} <- edit_rows(document["sections"][section]["diagrams"], Map.get(params, "diagrams", %{}), ~w(title source)) do
      checked(put_in(document, ["sections", section], %{"items" => items, "diagrams" => diagrams}))
    else
      _ -> {:error, :invalid_specification_form}
    end
  end

  @spec add(map(), String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def add(document, section, type, kind \\ nil) do
    if editable?(document, section) and type in ~w(items diagrams) and (is_nil(kind) or kind in kinds(section)) do
      row = if type == "items", do: new_item(document["version"], section, kind), else: diagram()
      checked(update_in(document, ["sections", section, type], &(&1 ++ [row])))
    else
      {:error, :invalid_specification_form}
    end
  end

  @spec member(map(), String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def member(document, section, item_id, group, action, row_id \\ nil) do
    with true <- editable?(document, section) and document["version"] == 2 and group in ~w(rows links sources),
         index when is_integer(index) <- Enum.find_index(document["sections"][section]["items"], &(&1["id"] == item_id)),
         item <- Enum.at(document["sections"][section]["items"], index),
         true <- Object.row_fields(item["kind"], group) != [],
         {:ok, rows} <- member_rows(item, group, action, row_id) do
      checked(put_in(document, ["sections", section, "items", Access.at(index), group], rows))
    else
      _ -> {:error, :invalid_specification_form}
    end
  end

  @spec objects(map()) :: [map()]
  def objects(document), do: Enum.flat_map(@sections, fn section -> Enum.map(document["sections"][section]["items"], &Map.put(&1, "section", section)) end)

  @spec remove(map(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def remove(document, section, type, id) do
    if editable?(document, section) and type in ~w(items diagrams) and Enum.any?(document["sections"][section][type], &(&1["id"] == id)) do
      checked(update_in(document, ["sections", section, type], &Enum.reject(&1, fn row -> row["id"] == id end)))
    else
      {:error, :invalid_specification_form}
    end
  end

  @spec valid?(term(), String.t()) :: boolean()
  def valid?(document, project) do
    with true <- exact?(document, ~w(version project document_id sections)),
         true <- document["version"] in [1, 2] and document["project"] == project,
         true <- text?(project, 512) and project != "" and identifier?(document["document_id"]),
         true <- exact?(document["sections"], @sections),
         true <- Enum.all?(@sections, &valid_section?(document["sections"][&1], &1, document["version"], targets(document))),
         true <- unique_ids?(document),
         {:ok, bytes} <- Jason.encode(document) do
      byte_size(bytes) <= 1_000_000
    else
      _ -> false
    end
  end

  @doc "Content-addressed specification identity, independent of browser and drawing state."
  @spec content_ref(map()) :: String.t()
  def content_ref(document) do
    :crypto.hash(:sha256, Jason.encode!(canonical(["specification-v#{document["version"]}", document]))) |> Base.encode16(case: :lower)
  end

  @spec identifier?(term()) :: boolean()
  def identifier?(value), do: is_binary(value) and String.valid?(value) and String.match?(value, ~r/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/)

  @spec content?(map()) :: boolean()
  def content?(document) do
    Enum.any?(@sections, fn section ->
      part = document["sections"][section]

      Enum.any?(part["items"], &item_content?/1) or
        Enum.any?(part["diagrams"], &(String.trim(&1["source"]) != ""))
    end)
  end

  defp id(prefix), do: prefix <> "-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp editable?(document, section), do: is_map(document) and valid?(document, document["project"]) and section in @sections

  defp new_item(1, section, kind), do: %{"id" => id("item"), "kind" => kind || hd(kinds(section)), "title" => "", "body" => ""}
  defp new_item(2, section, kind), do: item(section, kind)

  defp upgrade_section({name, part}), do: {name, %{part | "items" => Enum.map(part["items"], &upgrade_item/1)}}
  defp upgrade_item(old), do: Object.new(old["id"], old["kind"]) |> Map.put("title", old["title"]) |> Map.put("notes", old["body"])
  defp item_content?(%{"notes" => _} = item), do: Object.content?(item)
  defp item_content?(item), do: String.trim(item["title"] <> item["body"]) != ""

  defp retained?(document, candidate) do
    Enum.all?(@sections, fn section ->
      next = Map.new(candidate["sections"][section]["items"], &{&1["id"], &1})

      Enum.all?(document["sections"][section]["items"], &retained_item?(&1, next, document["version"])) and
        document["sections"][section]["diagrams"] == candidate["sections"][section]["diagrams"]
    end)
  end

  defp retained_item?(item, next, version) do
    notes = if version == 1, do: item["body"], else: item["notes"]
    is_map(next[item["id"]]) and next[item["id"]]["notes"] == notes
  end

  defp edit_items(%{"version" => 1} = document, section, params), do: edit_rows(document["sections"][section]["items"], params, ~w(kind title body))

  defp edit_items(document, section, params) do
    rows = document["sections"][section]["items"]

    if exact?(params, Enum.map(rows, & &1["id"])) do
      Enum.reduce_while(rows, {:ok, []}, fn item, {:ok, acc} ->
        edit_object(item, params[item["id"]], acc)
      end)
    else
      {:error, :invalid_specification_form}
    end
  end

  defp edit_object(item, params, acc) do
    case Object.edit(item, params) do
      {:ok, row} -> {:cont, {:ok, acc ++ [row]}}
      :error -> {:halt, {:error, :invalid_specification_form}}
    end
  end

  defp member_rows(item, group, "add", _), do: {:ok, item[group] ++ [Object.row(id("member"), item["kind"], group)]}

  defp member_rows(item, group, "remove", row_id) do
    if Enum.any?(item[group], &(&1["id"] == row_id)), do: {:ok, Enum.reject(item[group], &(&1["id"] == row_id))}, else: :error
  end

  defp member_rows(_, _, _, _), do: :error

  defp edit_rows(rows, params, keys) do
    ids = Enum.map(rows, & &1["id"])

    if exact?(params, ids) and Enum.all?(Map.values(params), &exact?(&1, keys)) do
      {:ok, Enum.map(rows, &Map.merge(&1, params[&1["id"]]))}
    else
      {:error, :invalid_specification_form}
    end
  end

  defp checked(document) do
    if valid?(document, document["project"]), do: {:ok, document}, else: {:error, :invalid_specification_form}
  end

  defp valid_section?(section, name, version, targets) do
    exact?(section, ~w(items diagrams)) and bounded_list?(section["items"], 200) and
      bounded_list?(section["diagrams"], 30) and Enum.all?(section["items"], &valid_item?(&1, name, version, targets)) and
      Enum.all?(section["diagrams"], &valid_diagram?/1)
  end

  defp valid_item?(item, section, 2, targets), do: is_map(item) and item["kind"] in kinds(section) and Object.valid?(item, targets)

  defp valid_item?(item, section, 1, _) do
    exact?(item, ~w(id kind title body)) and identifier?(item["id"]) and item["kind"] in kinds(section) and
      text?(item["title"], 256) and text?(item["body"], 24_000)
  end

  defp valid_diagram?(diagram) do
    exact?(diagram, ~w(id title source)) and identifier?(diagram["id"]) and text?(diagram["title"], 256) and text?(diagram["source"], 60_000)
  end

  defp unique_ids?(document) do
    ids =
      Enum.flat_map(@sections, fn section ->
        Enum.flat_map(document["sections"][section]["items"] ++ document["sections"][section]["diagrams"], fn item ->
          [item["id"] | Enum.flat_map(~w(rows links sources), &Enum.map(Map.get(item, &1, []), fn r -> r["id"] end))]
        end)
      end)

    length(ids) == length(Enum.uniq(ids))
  end

  defp targets(document) do
    Enum.flat_map(@sections, fn section ->
      case document["sections"][section] do
        %{"items" => items} when is_list(items) -> item_targets(items)
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp item_targets(items), do: for(item <- items, is_map(item), do: {item["id"], item["kind"]})

  defp text?(value, limit) do
    is_binary(value) and String.valid?(value) and byte_size(:unicode.characters_to_binary(value, :utf8, :utf16)) <= limit * 2
  end

  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp bounded_list?(value, limit), do: is_list(value) and length(value) <= limit
  defp canonical(value) when is_map(value), do: ["map", value |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, item} -> [key, canonical(item)] end)]
  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
