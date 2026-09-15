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

  @doc "Persist a project concurrency override (nil restores the configured default); running work is unaffected."
  @spec settings_command(pos_integer() | nil, non_neg_integer(), String.t(), BrowserAuth.context(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def settings_command(limit, expected_revision, command_id, context, orchestrator \\ Orchestrator) do
    if BrowserAuth.authorized?(context) do
      Orchestrator.control_command_guarded(
        %{"action" => "set_concurrency", "issue_id" => nil, "limit" => limit, "expected_revision" => expected_revision, "command_id" => command_id},
        context.tracker_fingerprint,
        orchestrator,
        fn -> BrowserAuth.authorized?(context) end
      )
    else
      {:error, :unauthorized}
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
