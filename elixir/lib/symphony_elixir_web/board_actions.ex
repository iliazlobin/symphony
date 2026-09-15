defmodule SymphonyElixirWeb.BoardActions do
  @moduledoc "Browser adapter for existing native controls, without a second queue or tracker mutations."

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.BrowserAuth

  @spec command(String.t(), String.t() | nil, non_neg_integer(), String.t(), BrowserAuth.context(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def command(action, issue_id, expected_revision, command_id, context, orchestrator \\ Orchestrator) do
    cond do
      not BrowserAuth.authorized?(context) ->
        {:error, :unauthorized}

      action not in ["pause", "drain", "resume", "cancel", "retry"] ->
        {:error, :invalid_command}

      true ->
        forward_command(action, issue_id, expected_revision, command_id, context, orchestrator)
    end
  end

  defp forward_command(action, issue_id, expected_revision, command_id, context, orchestrator) do
    # The owner checks project scope and configuration without replacing the
    # displayed revision; revision and replay still belong to the native ledger.
    Orchestrator.control_command_guarded(
      %{"action" => action, "issue_id" => issue_id, "expected_revision" => expected_revision, "command_id" => command_id},
      context.tracker_fingerprint,
      orchestrator,
      fn -> BrowserAuth.authorized?(context) end
    )
  end
end
