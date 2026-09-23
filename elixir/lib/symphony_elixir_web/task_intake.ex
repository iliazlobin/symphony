defmodule SymphonyElixirWeb.TaskIntake do
  @moduledoc "Deterministic board forms using the same durable proposal, approval and recovery owner as chat."

  alias SymphonyElixir.Chat.{Store, Tools}
  alias SymphonyElixirWeb.Endpoint

  @errors %{
    read_only: "Task changes are unavailable in this read-only view.",
    chat_not_configured: "Configure durable task action storage before creating tasks.",
    chat_storage_unavailable: "Task action storage is unavailable. Recover storage and check saved outcomes before submitting another action.",
    chat_storage_locked: "Another service owns task action storage. Use that service or restore ownership first.",
    chat_not_found: "This saved task action is unavailable in the current project.",
    project_not_found: "Select an available project before preparing a task action.",
    project_changed: "The project configuration changed. Reload the board before preparing another action.",
    invalid_submission: "Check the task fields before creating the task.",
    submission_id_conflict: "This submission already contains a different action. Open a new form to prepare a new action.",
    invalid_decision: "This action cannot be confirmed in its current state. Refresh it and check any uncertain outcome.",
    chat_busy: "This action is still in progress. Wait for its result before continuing.",
    chat_capacity: "Another action or chat response is using the available capacity. Try again after it finishes.",
    action_history_full: "The durable action journal is full. Preserve its records and arrange storage maintenance before adding an action."
  }

  @spec list(String.t(), map()) :: {:ok, list()} | {:error, term()}
  def list(project, auth), do: invoke(:list_actions, [project, auth])

  @spec get(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get(project, id, auth), do: invoke(:get_action, [project, id, auth])

  @spec prepare(String.t(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(project, id, args, auth), do: invoke(:prepare_action, [project, id, args, auth])

  @spec decide(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def decide(project, id, decision, auth), do: invoke(:decide_action_record, [project, id, decision, auth])

  @spec error_message(term()) :: String.t()
  def error_message({:invalid_dependency_declaration, reason}), do: reason
  def error_message(reason) when is_binary(reason), do: reason
  def error_message(reason), do: Map.get(@errors, reason) || Tools.error_message(reason)["message"]

  defp invoke(operation, args) do
    if Endpoint.config(:board_read_only, false) == true do
      {:error, :read_only}
    else
      apply(Endpoint.config(:chat_store) || Store, operation, args)
    end
  end
end
