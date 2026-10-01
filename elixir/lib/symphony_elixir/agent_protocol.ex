defmodule SymphonyElixir.AgentProtocol do
  @moduledoc "Public agent roles and permitted management actions. Execution is owned by the native orchestrator."

  @purposes ~w(coding testing security analysis deployment)
  @actions %{
    "project" => ~w(create_task edit_task feedback queue_task unqueue_task cancel retry pause drain resume set_concurrency create_pr_work continue_pr_work),
    "task" => ~w(edit_task feedback create_pr_work continue_pr_work cancel retry),
    "work" => ~w(continue_pr_work cancel retry)
  }

  @spec role(map()) :: String.t()
  def role(%{"conversation_role" => "pr"}), do: "work"
  def role(%{"conversation_role" => "task"}), do: "task"
  def role(_), do: "project"

  @spec context_role(map()) :: String.t()
  def context_role(%{session_id: id}) when is_binary(id), do: "work"
  def context_role(%{task_id: id}) when is_binary(id), do: "task"
  def context_role(_), do: "project"

  @spec purposes() :: [String.t()]
  def purposes, do: @purposes

  @doc "Only the existing coding adapter can execute in this iteration."
  @spec executable_purpose?(term()) :: boolean()
  def executable_purpose?(purpose), do: purpose == "coding"

  @spec actions(String.t()) :: [String.t()]
  def actions(role), do: Map.get(@actions, role, [])

  @spec authorize_action(String.t(), String.t()) :: :ok | {:error, :agent_role_forbidden}
  def authorize_action(role, action) do
    if action in actions(role), do: :ok, else: {:error, :agent_role_forbidden}
  end

  @spec execution_state(map() | nil) :: String.t()
  def execution_state(nil), do: "discussion"
  def execution_state(%{"phase" => phase}) when phase in ~w(building reviewing), do: "running"
  def execution_state(%{"phase" => "owner_review"}), do: "review"
  def execution_state(%{"phase" => phase}) when phase in ~w(queued paused), do: phase
  def execution_state(_), do: "unknown"
end
