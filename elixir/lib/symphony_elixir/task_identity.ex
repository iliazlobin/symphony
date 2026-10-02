defmodule SymphonyElixir.TaskIdentity do
  @moduledoc "Stable project identity; configuration fingerprints separately fence individual reads and commands."

  @spec project_id(map()) :: String.t()
  def project_id(tracker) do
    provider = Map.get(tracker, :provider) || %{}
    scope = provider["repo"] || Map.get(tracker, :project_slug) || provider["project_id"] || provider["project"] || "configured-project"
    (Map.get(tracker, :kind) || "tracker") <> ":" <> scope
  end
end
