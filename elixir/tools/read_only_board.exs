# Launched by tools/symphony_web.py. Do not start Symphony.Application here.
for app <- [:logger, :phoenix_live_view, :bandit, :ecto, :yaml_elixir, :req] do
  {:ok, _} = Application.ensure_all_started(app)
end

[workflow, port] = System.argv()
SymphonyElixir.Workflow.set_workflow_file_path(workflow)
{:ok, _} = SymphonyElixir.WorkflowStore.start_link()
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: SymphonyElixir.PubSub}, SymphonyElixirWeb.BoardCache], strategy: :one_for_one)

for name <- [SymphonyElixir.AgentRuntimeSupervisor, SymphonyElixir.Orchestrator, SymphonyElixir.Chat.Store] do
  if Process.whereis(name), do: raise("Read-only board must not own execution or chat processes")
end

alias SymphonyElixirWeb.{Endpoint, ReadOnlyBoard}
existing = Application.get_env(:symphony_elixir, Endpoint, [])

Application.put_env(
  :symphony_elixir,
  Endpoint,
  Keyword.merge(existing, board_loader: &ReadOnlyBoard.load/2, snapshot_loader: &ReadOnlyBoard.snapshot/0, board_read_only: true, board_timeout_ms: 15_000)
)

{:ok, _} = SymphonyElixir.HttpServer.start_link(port: String.to_integer(port), host: "127.0.0.1", orchestrator: :read_only_board_no_execution_owner)
IO.puts("Live GitHub board: http://127.0.0.1:#{port}/ (read-only; no workers or model runtime)")
Process.sleep(:infinity)
