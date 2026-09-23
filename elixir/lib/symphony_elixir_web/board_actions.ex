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

  @doc "Submit one confirmed PR work command to the native owner, retaining its exact revision and replay ID."
  @spec pr_work_command(map(), BrowserAuth.context(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def pr_work_command(command, context, orchestrator \\ Orchestrator) do
    fields =
      case command["action"] do
        "create_pr_work" -> ~w(action issue_id command_id expected_revision work_id instruction base_sha)
        "continue_pr_work" -> ~w(action issue_id command_id expected_revision work_id instruction expected_head_sha)
        _ -> []
      end

    cond do
      not BrowserAuth.authorized?(context) ->
        {:error, :unauthorized}

      fields == [] or Enum.sort(Map.keys(Map.delete(command, "feedback"))) != Enum.sort(fields) ->
        {:error, :invalid_command}

      true ->
        Orchestrator.control_command_guarded(
          command,
          context.tracker_fingerprint,
          orchestrator,
          fn -> BrowserAuth.authorized?(context) end
        )
    end
  end

  @doc "Record explicit human acceptance through the native owner; no merge or publication is implied."
  @spec accept_command(map(), BrowserAuth.context(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def accept_command(command, context, orchestrator \\ Orchestrator) do
    fields = ~w(action issue_id command_id expected_revision expected_candidate_sha expected_updated_at expected_tracker_state)

    cond do
      not BrowserAuth.authorized?(context) ->
        {:error, :unauthorized}

      command["action"] != "accept_task" or Enum.sort(Map.keys(command)) != Enum.sort(fields) ->
        {:error, :invalid_command}

      true ->
        Orchestrator.control_command_guarded(
          command,
          context.tracker_fingerprint,
          orchestrator,
          fn -> BrowserAuth.authorized?(context) end
        )
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
