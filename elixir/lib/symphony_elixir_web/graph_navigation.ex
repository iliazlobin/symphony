defmodule SymphonyElixirWeb.GraphNavigation do
  @moduledoc "Bounded, bookmarkable graph presentation preferences, separate from task filters."

  @keys ~w(mode direction hops group_by group anchor page query search_page gaps_only)

  @spec read(map()) :: map()
  def read(params) do
    Enum.reduce(params, %{}, fn
      {"graph_" <> name, value}, acc when name in @keys -> Map.put(acc, name, value)
      _, acc -> acc
    end)
    |> validate()
  end

  @spec update(map(), map()) :: map()
  def update(previous, params), do: previous |> Map.merge(Map.take(params, @keys)) |> validate()

  @spec params(map()) :: map()
  def params(options) do
    options
    |> validate()
    |> Map.new(fn {key, value} -> {"graph_" <> key, to_string(value)} end)
  end

  defp validate(options) do
    %{}
    |> choice(options, "mode", ~w(overview focus tasks))
    |> choice(options, "direction", ~w(both upstream downstream))
    |> choice(options, "group_by", ~w(milestone task_kind))
    |> number(options, "hops", 1, 2)
    |> number(options, "page", 0, 10_000)
    |> number(options, "search_page", 0, 10_000)
    |> text(options, "group", 512)
    |> text(options, "anchor", 512)
    |> text(options, "query", 160)
    |> then(fn result -> if options["gaps_only"] in [true, "true"], do: Map.put(result, "gaps_only", true), else: result end)
  end

  defp choice(result, options, key, choices), do: if(options[key] in choices, do: Map.put(result, key, options[key]), else: result)

  defp text(result, options, key, limit) do
    case options[key] do
      value when is_binary(value) and value != "" -> Map.put(result, key, String.slice(value, 0, limit))
      _ -> result
    end
  end

  defp number(result, options, key, low, high) do
    case integer(options[key]) do
      value when is_integer(value) and value >= low and value <= high -> Map.put(result, key, value)
      _ -> result
    end
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil
end
