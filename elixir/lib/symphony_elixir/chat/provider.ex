defmodule SymphonyElixir.Chat.Provider do
  @moduledoc "Dispatches a captured management turn without changing its durable chat identity."

  alias SymphonyElixir.Chat.{OpenRouter, Runtime}

  @spec run(map() | keyword(), (tuple() -> any()), (String.t(), map() -> map())) :: {:ok, map()} | {:error, atom()}
  def run(opts, emit, tool) do
    opts = Map.new(opts)

    case Map.get(opts, :provider, "codex") do
      "codex" -> Runtime.run(opts, emit, tool)
      "openrouter" -> OpenRouter.run(opts, emit, tool) |> openrouter_result()
      _ -> {:error, :invalid_provider}
    end
  end

  defp openrouter_result({:error, :authentication_required}), do: {:error, :openrouter_auth_required}
  defp openrouter_result({:error, :provider_rate_limited}), do: {:error, :openrouter_rate_limited}
  defp openrouter_result({:error, :provider_unavailable}), do: {:error, :openrouter_unavailable}
  defp openrouter_result({:error, :tool_limit}), do: {:error, :openrouter_tool_limit}
  defp openrouter_result(result), do: result
end
