defmodule SymphonyElixir.WorkerFailure do
  @moduledoc """
  Keeps structured worker failures inside the native runtime and exposes safe summaries.

  Subscription authentication is separate from the operator's browser and project chat.
  Only protocol error codes, never free-form task or provider prose, require worker sign-in.
  """

  defexception [:reason]

  @auth_codes ~w(unauthorized refresh_token_expired refresh_token_reused refresh_token_invalidated refresh_token_revoked)
  @legacy_limit 16_384

  @impl true
  def message(%__MODULE__{reason: reason}), do: summary(reason)

  @spec authentication_required?(term()) :: boolean()
  def authentication_required?(%__MODULE__{reason: reason}), do: authentication_required?(reason)
  def authentication_required?({%__MODULE__{} = failure, _stack}), do: authentication_required?(failure)
  def authentication_required?(:worker_auth_required), do: true
  def authentication_required?("Worker sign-in required"), do: true
  def authentication_required?({:turn_failed, params}) when is_map(params), do: auth_error?(turn_error(params))
  def authentication_required?({:startup_failed, _phase, reason}), do: authentication_required?(reason)
  def authentication_required?({:response_error, error}) when is_map(error), do: auth_error?(error)
  def authentication_required?(reason) when is_binary(reason), do: legacy_auth_failure?(reason)
  def authentication_required?(_reason), do: false

  @spec hold_reason(term()) :: String.t() | nil
  def hold_reason(%__MODULE__{reason: reason}), do: hold_reason(reason)
  def hold_reason({%__MODULE__{} = failure, _stack}), do: hold_reason(failure)
  def hold_reason(:workspace_baseline_changed), do: "workspace_baseline_changed"
  def hold_reason(reason), do: if(authentication_required?(reason), do: "worker_auth_required")

  @spec summary(term()) :: String.t()
  def summary(%__MODULE__{reason: reason}), do: summary(reason)
  def summary({%__MODULE__{} = failure, _stack}), do: summary(failure)

  def summary(reason) do
    if authentication_required?(reason), do: "Worker sign-in required", else: safe_summary(reason)
  end

  defp auth_error?(error) when is_map(error) do
    error["codexErrorInfo"] in @auth_codes or error["code"] in @auth_codes or
      auth_error?(error["data"])
  end

  defp auth_error?(_error), do: false

  defp turn_error(%{"turn" => %{"error" => error}}), do: error
  defp turn_error(params), do: params["error"]

  # Read compatibility for the previous card's inspected AgentRunner exception.
  # A sentence, title or ordinary upstream message containing "unauthorized" is insufficient.
  defp legacy_auth_failure?(reason) do
    byte_size(reason) <= @legacy_limit and
      String.starts_with?(reason, "agent exited: {%RuntimeError{message: \"Agent run failed for issue_id=") and
      String.contains?(reason, ":turn_failed") and
      Enum.any?(@auth_codes, fn code ->
        String.contains?(reason, "\\\"codexErrorInfo\\\" => \\\"#{code}\\\"")
      end)
  end

  defp safe_summary(:normal), do: "Worker completed"
  defp safe_summary(:workspace_baseline_changed), do: "Workspace baseline needs recovery"
  defp safe_summary(:turn_timeout), do: "Worker response timed out; retry scheduled"
  defp safe_summary(:response_timeout), do: "Worker startup timed out; retry scheduled"
  defp safe_summary({:startup_failed, _phase, reason}), do: safe_summary(reason)
  defp safe_summary({:turn_failed, _params}), do: "Worker response failed; retry scheduled"
  defp safe_summary({:turn_cancelled, _params}), do: "Worker response was interrupted"
  defp safe_summary({:port_exit, _status}), do: "Worker process exited; retry scheduled"
  defp safe_summary("no available orchestrator slots" = reason), do: reason
  defp safe_summary("codex turn requires operator input" = reason), do: reason
  defp safe_summary("codex turn requires approval" = reason), do: reason
  defp safe_summary("codex MCP elicitation requires operator input" = reason), do: reason
  defp safe_summary("Worker completed" = reason), do: reason
  defp safe_summary("Workspace baseline needs recovery" = reason), do: reason
  defp safe_summary("Worker response timed out; retry scheduled" = reason), do: reason
  defp safe_summary("Worker startup timed out; retry scheduled" = reason), do: reason
  defp safe_summary("Worker response failed; retry scheduled" = reason), do: reason
  defp safe_summary("Worker response was interrupted" = reason), do: reason
  defp safe_summary("Worker process exited; retry scheduled" = reason), do: reason
  defp safe_summary(_reason), do: "Worker failed; inspect service logs"
end
