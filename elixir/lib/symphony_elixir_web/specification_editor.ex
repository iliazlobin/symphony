defmodule SymphonyElixirWeb.SpecificationEditor do
  @moduledoc "Validates browser edits against the owned specification draft and its revision."
  alias SymphonyElixir.Specification.Document

  @spec edit(map(), map(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def edit(draft, state, params, section) do
    if bound?(draft, state, params, section) do
      params = Map.reject(params, fn {key, value} -> key in ["items", "diagrams"] and is_nil(value) end)
      params = params |> normalize_inputs("items", ~w(kind title body)) |> normalize_inputs("diagrams", ~w(title source))
      params = normalize_criteria(params)
      normalize(Document.edit(draft, section, params))
    else
      {:error, :invalid_specification_edit}
    end
  end

  @spec change(map(), String.t(), String.t(), term()) :: {:ok, map()} | {:error, atom()}
  def change(draft, section, action, id) do
    result =
      case action do
        "spec-add-item" -> Document.add(draft, section, "items")
        "spec-add-diagram" -> Document.add(draft, section, "diagrams")
        "spec-remove-item" -> Document.remove(draft, section, "items", id)
        "spec-remove-diagram" -> Document.remove(draft, section, "diagrams", id)
        "spec-add-criterion" when section == "requirements" -> Document.add_criterion(draft, id)
        "spec-remove-criterion" when section == "requirements" and is_map(id) -> Document.remove_criterion(draft, id["item"], id["criterion"])
        _ -> {:error, :invalid_specification_edit}
      end

    normalize(result)
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

  defp normalize_criteria(%{"items" => items} = params) when is_map(items) do
    Map.put(
      params,
      "items",
      Map.new(items, fn {id, row} ->
        {id, if(is_map(row), do: normalize_inputs(row, "criteria", ~w(statement method)), else: row)}
      end)
    )
  end

  defp normalize_criteria(params), do: params

  defp normalize({:ok, document}), do: {:ok, document}
  defp normalize({:error, _reason}), do: {:error, :invalid_specification_edit}
end
