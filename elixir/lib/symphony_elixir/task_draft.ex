defmodule SymphonyElixir.TaskDraft do
  @moduledoc "The bounded task description shared by the board form and project agent."

  alias SymphonyElixir.GitHub.Admission

  @fields ~w(title description verification)

  @spec action_args(map()) :: {:ok, map()} | {:error, term()}
  def action_args(fields) when is_map(fields) do
    with :ok <- validate_fields(fields),
         :ok <- validate_lengths(fields),
         {:ok, body} <- issue_body(fields) do
      {:ok, %{"action" => "create_task", "title" => fields["title"], "body" => body}}
    end
  end

  def action_args(_fields), do: {:error, :invalid_task_fields}

  @spec validate_lengths(map()) :: :ok | {:error, term()}
  def validate_lengths(fields) do
    Enum.reduce_while(@fields, :ok, fn field, :ok ->
      limit = if field == "title", do: 200, else: 4_000
      value = fields[field]

      if is_binary(value) and byte_size(value) <= limit do
        {:cont, :ok}
      else
        {:halt, {:error, {:field_too_long, field, limit}}}
      end
    end)
  end

  defp validate_fields(fields) do
    cond do
      Enum.sort(Map.keys(fields)) != Enum.sort(@fields) -> {:error, :invalid_task_fields}
      Enum.all?(@fields, &(is_binary(fields[&1]) and String.valid?(fields[&1]) and String.trim(fields[&1]) != "")) -> :ok
      true -> {:error, :required_fields}
    end
  end

  defp issue_body(fields) do
    body = "## Description\n\n#{fields["description"]}\n\n## Verification\n\n#{fields["verification"]}"
    body = if String.match?(body, ~r/^\s*depends on\b/im), do: body, else: body <> "\n\nDepends on: none"

    case Admission.validate_declaration(body) do
      {:ok, _} -> {:ok, body}
      {:error, reason} -> {:error, {:invalid_dependency_declaration, reason}}
    end
  end
end
