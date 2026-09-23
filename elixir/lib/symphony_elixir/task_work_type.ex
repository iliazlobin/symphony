defmodule SymphonyElixir.TaskWorkType do
  @moduledoc "Task classification derived from GitHub labels, independent of routing and execution authority."

  @types ~w(application infrastructure deployment operations)
  @values @types ++ ["unclassified"]
  @labels %{
    "application" => "Application development",
    "infrastructure" => "Infrastructure",
    "deployment" => "Deployment",
    "operations" => "Operations",
    "unclassified" => "Unclassified",
    "invalid" => "Needs classification"
  }

  @spec values() :: [String.t()]
  def values, do: @values

  @spec options() :: [{String.t(), String.t()}]
  def options, do: Enum.map(@values, &{label(&1), &1})

  @spec label(String.t() | nil) :: String.t()
  def label(value), do: Map.get(@labels, value, @labels["invalid"])

  @spec from_labels(list() | nil) :: String.t()
  def from_labels(labels) do
    case Enum.map(labels || [], &normalize/1) |> Enum.filter(&String.starts_with?(&1, "work:")) do
      [] -> "unclassified"
      ["work:" <> value] when value in @types -> value
      _ -> "invalid"
    end
  end

  @spec update_labels([String.t()], String.t()) :: [String.t()]
  def update_labels(labels, value) when value in @values do
    preserved = Enum.reject(labels, &String.starts_with?(normalize(&1), "work:"))
    if value == "unclassified", do: preserved, else: preserved ++ ["work:" <> value]
  end

  defp normalize(%{"name" => name}), do: normalize(name)
  defp normalize(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize(_), do: ""
end
