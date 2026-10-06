defmodule SymphonyElixirWeb.SpecificationEditor do
  @moduledoc "Validates browser edits against the owned specification draft and its revision."
  alias SymphonyElixir.Specification.Document
  alias SymphonyElixir.Specification.Object

  @spec edit(map(), map(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def edit(draft, state, params, section) do
    if bound?(draft, state, params, section) do
      params = Map.reject(params, fn {key, value} -> key in ["items", "diagrams"] and is_nil(value) end)
      params = normalize_items(params, draft, section) |> normalize_inputs("diagrams", ~w(title source))
      normalize(Document.edit(draft, section, params))
    else
      {:error, :invalid_specification_edit}
    end
  end

  @spec change(map(), String.t(), String.t(), term(), map()) :: {:ok, map()} | {:error, atom()}
  def change(draft, section, action, id, options \\ %{}) do
    result =
      case action do
        "spec-add-item" -> Document.add(draft, section, "items", options["kind"])
        "spec-add-diagram" -> Document.add(draft, section, "diagrams")
        "spec-remove-item" -> Document.remove(draft, section, "items", id)
        "spec-remove-diagram" -> Document.remove(draft, section, "diagrams", id)
        "spec-add-member" -> Document.member(draft, section, id, options["group"], "add")
        "spec-remove-member" -> Document.member(draft, section, id, options["group"], "remove", options["row_id"])
        _ -> {:error, :invalid_specification_edit}
      end

    normalize(result)
  end

  defp normalize_items(params, %{"version" => 1}, _section), do: normalize_inputs(params, "items", ~w(kind title body))

  defp normalize_items(params, draft, section) do
    case params["items"] do
      rows when is_map(rows) ->
        known = Map.new(draft["sections"][section]["items"], &{&1["id"], &1})
        Map.put(params, "items", Map.new(rows, fn {id, row} -> {id, if(known[id], do: Object.normalize(known[id], row), else: row)} end))

      _ ->
        params
    end
  end

  @spec revision(term()) :: non_neg_integer() | nil
  def revision(value) when is_integer(value) and value >= 0, do: value

  def revision(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  def revision(_value), do: nil

  defp bound?(draft, state, params, section) do
    section in Document.sections() and params["section"] == section and
      params["project"] == draft["project"] and params["document_id"] == draft["document_id"] and
      revision(params["storage_revision"]) == state["storage_revision"]
  end

  # LiveView serializes an empty _unused_<field> beside untouched visible inputs.
  # Strip only those framework markers; Document still requires every real field.
  defp normalize_inputs(params, group, fields) do
    case Map.get(params, group) do
      rows when is_map(rows) -> Map.put(params, group, Map.new(rows, fn {id, row} -> {id, normalize_row(row, fields)} end))
      _ -> params
    end
  end

  defp normalize_row(row, fields) when is_map(row) do
    Enum.reduce(fields, row, fn field, values ->
      marker = "_unused_" <> field

      if Map.has_key?(values, field) and values[marker] == "", do: Map.delete(values, marker), else: values
    end)
  end

  defp normalize_row(row, _fields), do: row

  defp normalize({:ok, document}), do: {:ok, document}
  defp normalize({:error, _reason}), do: {:error, :invalid_specification_edit}
end
