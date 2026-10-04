defmodule SymphonyElixirWeb.ControlApiController do
  @moduledoc "Authenticated local operator commands; no agent or deployment endpoint."
  use Phoenix.Controller, formats: [:json]
  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.{BrowserAuth, Endpoint}

  @conflict_reasons [
    :revision_conflict,
    :command_id_conflict,
    :issue_running,
    :budget_exhausted,
    :attempts_not_exhausted,
    :pr_work_continuation_required
  ]

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
      authorize = current_authorization(conn)
      scope = Orchestrator.tracker_fingerprint()

      case Orchestrator.control_command_guarded(params, scope, orchestrator(), authorize) do
        {:ok, payload} -> json(conn, payload)
        {:error, :unauthorized} -> error(conn, 401, :unauthorized)
        {:error, reason} when reason in @conflict_reasons -> error(conn, 409, reason)
        {:error, reason} when reason in [:invalid_command, :concurrency_limit_exceeded] -> error(conn, 400, reason)
        {:error, reason} -> error(conn, 503, reason)
      end
    end
  end

  @spec publication(Conn.t(), map()) :: Conn.t()
  def publication(conn, params) do
    conn = authorize(conn)

    if conn.halted do
      conn
    else
      case Orchestrator.record_pr_publication(params, orchestrator()) do
        {:ok, payload} -> json(conn, payload)
        {:error, :invalid_publication} -> error(conn, 400, :invalid_publication)
        {:error, reason} when reason in [:control_unavailable, :unavailable] -> error(conn, 503, reason)
        {:error, reason} -> error(conn, 409, reason)
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
      not BrowserAuth.local_request?(conn) or get_req_header(conn, "origin") != [] ->
        conn |> error(403, :local_client_required) |> halt()

      not is_binary(token) or byte_size(token) < 32 ->
        conn |> error(503, :control_auth_unconfigured) |> halt()

      not Plug.Crypto.secure_compare(token, supplied) ->
        conn |> error(401, :unauthorized) |> halt()

      true ->
        conn
    end
  end

  defp error(conn, status, reason), do: conn |> put_status(status) |> json(%{error: %{code: to_string(reason)}})

  defp current_authorization(conn) do
    ["Bearer " <> supplied] = get_req_header(conn, "authorization")
    fn -> is_binary(Config.control_token()) and Plug.Crypto.secure_compare(Config.control_token(), supplied) end
  end

  defp orchestrator, do: Endpoint.config(:orchestrator) || Orchestrator
end
