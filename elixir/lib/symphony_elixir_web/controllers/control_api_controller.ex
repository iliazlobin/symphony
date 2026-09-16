defmodule SymphonyElixirWeb.ControlApiController do
  @moduledoc "Authenticated local operator commands; no agent or deployment endpoint."
  use Phoenix.Controller, formats: [:json]
  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.Endpoint
  @conflict_reasons [:revision_conflict, :command_id_conflict, :issue_running, :budget_exhausted]

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, _params) do
    conn = authorize(conn)

    if conn.halted do
      conn
    else
      case Orchestrator.control_snapshot(orchestrator()) do
        {:error, _} -> error(conn, 503, :unavailable)
        payload -> json(conn, payload)
      end
    end
  end

  @spec update(Conn.t(), map()) :: Conn.t()
  def update(conn, params) do
    conn = authorize(conn)

    if conn.halted do
      conn
    else
      case Orchestrator.control_command(params, orchestrator()) do
        {:ok, payload} -> json(conn, payload)
        {:error, reason} when reason in @conflict_reasons -> error(conn, 409, reason)
        {:error, reason} when reason in [:invalid_command, :concurrency_limit_exceeded] -> error(conn, 400, reason)
        {:error, reason} -> error(conn, 503, reason)
      end
    end
  end

  @spec authorize(Conn.t()) :: Conn.t()
  def authorize(conn) do
    token = Config.control_token()

    supplied =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> value] -> value
        _ -> ""
      end

    cond do
      conn.host not in ["localhost", "127.0.0.1", "::1"] or get_req_header(conn, "origin") != [] -> conn |> error(403, :local_client_required) |> halt()
      not is_binary(token) or byte_size(token) < 32 -> conn |> error(503, :control_auth_unconfigured) |> halt()
      not Plug.Crypto.secure_compare(token, supplied) -> conn |> error(401, :unauthorized) |> halt()
      true -> conn
    end
  end

  defp error(conn, status, reason), do: conn |> put_status(status) |> json(%{error: %{code: to_string(reason)}})
  defp orchestrator, do: Endpoint.config(:orchestrator) || Orchestrator
end
