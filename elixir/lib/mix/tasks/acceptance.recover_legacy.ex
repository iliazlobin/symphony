defmodule Mix.Tasks.Acceptance.RecoverLegacy do
  use Mix.Task

  alias SymphonyElixir.ControlLedger

  @shortdoc "Validate or recover explicitly selected legacy acceptance identities offline"
  @moduledoc """
  Stop all project engines before running. No application or workers are started.
  No live workflow configuration or API credentials are needed. The ledger-only
  lock helper runs isolated Python with its inherited environment removed.
  The default dry run validates the complete ledger and retained review evidence;
  it reports only selected issue IDs and never writes control state.

      mix acceptance.recover_legacy --state /private/state/control.json \
        --workspace-root /private/workspaces --project github:owner/repo \
        --legacy-fingerprint OLD --revision 105 --issue 6 --issue 11

  Add `--apply --backup /private/state/control.before-recovery.json` to persist.
  The backup must not already exist. It retains the exact original bytes with
  mode 0600. Recovery adds only stable project identity to acceptance records;
  original decisions, evidence, command IDs, ledger revision and budgets remain.
  Rerunning revalidates selected records and makes no write when already upgraded.

  Failure after atomic replacement may have persisted the change. Keep the backup,
  inspect the ledger and rerun the dry run before restarting; do not overwrite it.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          state: :string,
          workspace_root: :string,
          project: :string,
          legacy_fingerprint: :string,
          revision: :integer,
          issue: :keep,
          apply: :boolean,
          backup: :string,
          help: :boolean
        ]
      )

    cond do
      opts[:help] -> Mix.shell().info(@moduledoc)
      invalid != [] or rest != [] -> Mix.raise("Invalid recovery arguments; see --help.")
      not is_binary(opts[:state]) or not is_binary(opts[:workspace_root]) -> Mix.raise("--state and --workspace-root are required.")
      true -> recover(opts)
    end
  end

  defp recover(opts) do
    request = %{
      project_id: opts[:project],
      tracker_fingerprint: opts[:legacy_fingerprint],
      expected_revision: opts[:revision],
      issue_ids: Keyword.get_values(opts, :issue)
    }

    recovery_options = [apply: opts[:apply], backup_path: opts[:backup]]

    case ControlLedger.recover_legacy_acceptance(opts[:state], opts[:workspace_root], request, recovery_options) do
      {:ok, report} ->
        mode = if opts[:apply], do: "Applied", else: "Dry run"
        Mix.shell().info("#{mode}: changed issue IDs [#{Enum.join(report.changed_ids, ", ")}]; already upgraded issue IDs [#{Enum.join(report.already_upgraded_ids, ", ")}].")

      {:error, reason} ->
        label = if is_atom(reason), do: Atom.to_string(reason), else: "state_io_failed"
        Mix.raise("Acceptance recovery failed: #{label}. No execution was started; retain any backup and inspect state before restarting.")
    end
  end
end
