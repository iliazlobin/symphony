defmodule SymphonyElixir.Specification.Document do
  @moduledoc "Bounded structured specification documents; Mermaid source remains editable text."

  @sections ~w(brief requirements data architecture decisions)
  @methods ~w(test analysis inspection review)
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

  @spec methods() :: [String.t()]
  def methods, do: @methods

  @spec new(String.t()) :: map()
  def new(project) do
    %{"version" => 1, "project" => project, "document_id" => id("spec"), "sections" => Map.new(@sections, &{&1, %{"items" => [], "diagrams" => []}})}
  end

  @spec item(String.t()) :: map() | nil
  def item(section) do
    case kinds(section) do
      [kind | _] -> %{"id" => id("item"), "kind" => kind, "title" => "", "body" => ""}
      [] -> nil
    end
  end

  @spec diagram() :: map()
  def diagram, do: %{"id" => id("diagram"), "title" => "", "source" => "flowchart TD\n  A[Start] --> B[Next]"}

  @doc "Edits only existing stable IDs in one section; unknown or incomplete form rows fail closed."
  @spec edit(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def edit(document, section, params) do
    with true <- editable?(document, section) and is_map(params),
         {:ok, items} <- edit_items(document["sections"][section]["items"], Map.get(params, "items", %{})),
         {:ok, diagrams} <- edit_rows(document["sections"][section]["diagrams"], Map.get(params, "diagrams", %{}), ~w(title source)) do
      checked(put_in(document, ["sections", section], %{"items" => items, "diagrams" => diagrams}))
    else
      _ -> {:error, :invalid_specification_form}
    end
  end

  @doc "Acceptance criteria belong to requirement items, with stable identities across draft edits."
  @spec add_criterion(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def add_criterion(document, item_id) do
    change_criteria(document, item_id, fn criteria ->
      {:ok, criteria ++ [%{"id" => id("criterion"), "statement" => "", "method" => "test"}]}
    end)
  end

  @spec remove_criterion(map(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def remove_criterion(document, item_id, criterion_id) do
    change_criteria(document, item_id, fn criteria ->
      if Enum.any?(criteria, &(&1["id"] == criterion_id)),
        do: {:ok, Enum.reject(criteria, &(&1["id"] == criterion_id))},
        else: {:error, :invalid_specification_form}
    end)
  end

  @spec add(map(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def add(document, section, type) do
    if editable?(document, section) and type in ~w(items diagrams) do
      row = if type == "items", do: item(section), else: diagram()
      checked(update_in(document, ["sections", section, type], &(&1 ++ [row])))
    else
      {:error, :invalid_specification_form}
    end
  end

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
         true <- document["version"] == 1 and document["project"] == project,
         true <- text?(project, 512) and project != "" and identifier?(document["document_id"]),
         true <- exact?(document["sections"], @sections),
         true <- Enum.all?(@sections, &valid_section?(document["sections"][&1], &1)),
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
    :crypto.hash(:sha256, Jason.encode!(canonical(["specification-v1", document]))) |> Base.encode16(case: :lower)
  end

  @spec identifier?(term()) :: boolean()
  def identifier?(value), do: is_binary(value) and String.valid?(value) and String.match?(value, ~r/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/)

  @spec content?(map()) :: boolean()
  def content?(document) do
    Enum.any?(@sections, fn section ->
      part = document["sections"][section]

      Enum.any?(part["items"], &(String.trim(&1["title"] <> &1["body"]) != "")) or
        Enum.any?(part["diagrams"], &(String.trim(&1["source"]) != ""))
    end)
  end

  defp id(prefix), do: prefix <> "-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp editable?(document, section), do: is_map(document) and valid?(document, document["project"]) and section in @sections

  defp change_criteria(document, item_id, change) do
    with true <- editable?(document, "requirements"),
         items = document["sections"]["requirements"]["items"],
         item when is_map(item) <- Enum.find(items, &(&1["id"] == item_id)),
         {:ok, criteria} <- change.(Map.get(item, "criteria", [])) do
      updated = if criteria == [], do: Map.delete(item, "criteria"), else: Map.put(item, "criteria", criteria)
      checked(put_in(document, ["sections", "requirements", "items"], Enum.map(items, &if(&1["id"] == item_id, do: updated, else: &1))))
    else
      _ -> {:error, :invalid_specification_form}
    end
  end

  defp edit_items(rows, params) do
    if exact?(params, Enum.map(rows, & &1["id"])) do
      Enum.reduce_while(rows, {:ok, []}, &reduce_item(&1, &2, params))
    else
      {:error, :invalid_specification_form}
    end
  end

  defp reduce_item(row, {:ok, edited}, params) do
    case edit_item(row, params[row["id"]]) do
      {:ok, item} -> {:cont, {:ok, edited ++ [item]}}
      error -> {:halt, error}
    end
  end

  defp edit_item(row, input) do
    keys = if Map.has_key?(row, "criteria"), do: ~w(kind title body criteria), else: ~w(kind title body)

    with true <- exact?(input, keys),
         {:ok, criteria} <- edit_rows(Map.get(row, "criteria", []), Map.get(input, "criteria", %{}), ~w(statement method)) do
      fields = Map.take(input, ~w(kind title body))
      fields = if Map.has_key?(row, "criteria"), do: Map.put(fields, "criteria", criteria), else: fields
      {:ok, Map.merge(row, fields)}
    else
      _ -> {:error, :invalid_specification_form}
    end
  end

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

  defp valid_section?(section, name) do
    exact?(section, ~w(items diagrams)) and bounded_list?(section["items"], 200) and
      bounded_list?(section["diagrams"], 30) and Enum.all?(section["items"], &valid_item?(&1, name)) and
      Enum.all?(section["diagrams"], &valid_diagram?/1)
  end

  defp valid_item?(item, section) do
    keys = if section == "requirements" and is_map(item) and Map.has_key?(item, "criteria"), do: ~w(id kind title body criteria), else: ~w(id kind title body)

    exact?(item, keys) and identifier?(item["id"]) and item["kind"] in kinds(section) and
      text?(item["title"], 256) and text?(item["body"], 24_000) and valid_criteria?(Map.get(item, "criteria", []))
  end

  defp valid_criteria?(criteria) do
    bounded_list?(criteria, 30) and Enum.all?(criteria, &valid_criterion?/1)
  end

  defp valid_criterion?(criterion) do
    exact?(criterion, ~w(id statement method)) and identifier?(criterion["id"]) and
      text?(criterion["statement"], 4_000) and criterion["method"] in @methods
  end

  defp valid_diagram?(diagram) do
    exact?(diagram, ~w(id title source)) and identifier?(diagram["id"]) and text?(diagram["title"], 256) and text?(diagram["source"], 60_000)
  end

  defp unique_ids?(document) do
    ids =
      Enum.flat_map(@sections, fn section ->
        items = document["sections"][section]["items"]
        rows = items ++ document["sections"][section]["diagrams"] ++ Enum.flat_map(items, &Map.get(&1, "criteria", []))
        Enum.map(rows, & &1["id"])
      end)

    length(ids) == length(Enum.uniq(ids))
  end

  defp text?(value, limit) do
    is_binary(value) and String.valid?(value) and byte_size(:unicode.characters_to_binary(value, :utf8, :utf16)) <= limit * 2
  end

  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp bounded_list?(value, limit), do: is_list(value) and length(value) <= limit
  defp canonical(value) when is_map(value), do: ["map", value |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, item} -> [key, canonical(item)] end)]
  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
