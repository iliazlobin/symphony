defmodule SymphonyElixir.GitHub.Admission do
  @moduledoc "Dependency declaration compatibility API; the native owner evaluates prerequisites from its durable local acceptance state."

  alias SymphonyElixir.TaskDependencies

  @spec validate_declaration(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def validate_declaration(description), do: validate_declaration(description, nil)

  @spec validate_declaration(term(), String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def validate_declaration(description, id) do
    case TaskDependencies.parse(description, id) do
      {:ok, dependencies} -> {:ok, Enum.map(dependencies, & &1["issue_id"])}
      error -> error
    end
  end
end
