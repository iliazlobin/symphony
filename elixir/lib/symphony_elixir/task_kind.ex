defmodule SymphonyElixir.TaskKind do
  @moduledoc "Task intent classification; kinds and domain labels grant no execution authority."

  @kinds ~w(feature enhancement bug testing security release operations analysis maintenance general)

  @spec values() :: [String.t()]
  def values, do: @kinds

  @spec from_labels(list() | nil) :: String.t()
  def from_labels(labels) do
    labels = Enum.map(labels || [], &normalize/1)

    case Enum.filter(labels, &String.starts_with?(&1, "kind:")) do
      [] -> legacy_kind(labels)
      ["kind:" <> kind] when kind in @kinds -> kind
      _ -> "invalid"
    end
  end

  defp legacy_kind(labels) do
    case Enum.filter(labels, &(&1 in ~w(work:deployment work:operations))) do
      ["work:deployment"] -> "release"
      ["work:operations"] -> "operations"
      [] -> "general"
      _ -> "invalid"
    end
  end

  defp normalize(%{"name" => name}), do: normalize(name)
  defp normalize(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize(_), do: ""
end
