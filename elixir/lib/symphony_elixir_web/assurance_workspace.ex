defmodule SymphonyElixirWeb.AssuranceWorkspace do
  @moduledoc "Authenticated board assurance reads and edits, independent of task execution."

  alias SymphonyElixir.Assurance.{Contract, Projection, Store}
  alias SymphonyElixirWeb.{AssuranceActions, AssuranceObservations, BrowserAuth}

  @spec load(map(), String.t(), term(), map(), boolean(), GenServer.server()) :: {:ok, map(), map(), map()} | {:error, atom()}
  def load(board, project, auth, previous, reload, server) do
    snapshot = if reload, do: Store.read(project, auth, server), else: {:ok, previous}

    with {:ok, value} <- snapshot do
      draft = value["draft"] || Contract.document(project)
      observations = AssuranceObservations.from_board(board, draft)
      projection = value |> journal(project) |> Projection.build(observations) |> AssuranceObservations.badges(observations)

      board =
        board
        |> Map.put(:assurance, projection)
        |> Map.put(:assurance_observations, observations)
        |> Map.put(:assurance_evidence, value["evidence"] || [])
        |> Map.put(:assurance_baselines, value["baselines"] || [])

      {:ok, value, projection, board}
    end
  end

  @spec mutate(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def mutate(context, action, params) do
    with :ok <- authorized(context),
         {:ok, expected} <- AssuranceActions.expected_revision(params),
         {:ok, snapshot} <- Store.read(context.project, context.auth, context.server),
         true <- snapshot["storage_revision"] == expected or {:error, :stale_assurance_revision} do
      draft = snapshot["draft"] || Contract.document(context.project)

      board =
        context.board
        |> Map.put(:assurance_observations, AssuranceObservations.from_board(context.board, draft))
        |> Map.put(:assurance_evidence, snapshot["evidence"] || [])
        |> Map.put(:assurance_baselines, snapshot["baselines"] || [])

      apply_action(context, action, params, expected, draft, board)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorized(context) do
    cond do
      not BrowserAuth.authorized?(context.auth) or context.read_only -> {:error, :unauthorized}
      not is_binary(context.project) -> {:error, :assurance_project_mismatch}
      true -> :ok
    end
  end

  defp apply_action(context, "save-baseline", _params, expected, _draft, board) do
    if is_map(board[:workflow_graph]) and AssuranceObservations.source_current?(board) and not context.loading,
      do: Store.baseline_graph(context.project, expected, board[:workflow_graph], context.auth, context.server),
      else: {:error, :assurance_graph_unavailable}
  end

  defp apply_action(context, "record-release", params, expected, draft, board) do
    with {:ok, record} <- AssuranceActions.release(draft, params, board),
         do: Store.release(context.project, expected, record, context.auth, context.server)
  end

  defp apply_action(context, action, params, expected, draft, board) do
    with {:ok, document} <- AssuranceActions.edit(draft, action, params, board),
         do: Store.save(context.project, expected, document, context.auth, context.server)
  end

  defp journal(snapshot, project) do
    %{
      "project" => project,
      "draft" => snapshot["draft"],
      "reviewed_ref" => get_in(snapshot, ["reviewed", "ref"]),
      "baselines" => Map.new(snapshot["baselines"] || [], &{&1["ref"], &1}),
      "evidence" => Map.new(snapshot["evidence"] || [], &{&1["id"], &1}),
      "releases" => Map.new(snapshot["releases"] || [], &{&1["id"], &1})
    }
  end
end
