defmodule SymphonyElixirWeb.BrowserSessionController do
  @moduledoc "CSRF-protected loopback browser login; the configured bearer is never serialized into a session."
  use Phoenix.Controller, formats: [:html]

  alias Plug.Conn
  alias SymphonyElixirWeb.{BrowserAuth, Endpoint}

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    case BrowserAuth.authenticate(conn, params["operator_token"]) do
      {:ok, marker} ->
        conn
        |> disconnect_sessions()
        |> configure_session(renew: true)
        |> put_session(BrowserAuth.session_key(), marker)
        |> put_session("live_socket_id", "operator:" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false))
        |> put_flash(:info, "Operator controls unlocked for this browser for 8 hours.")
        |> redirect(to: "/?panel=settings")

      {:error, :local_browser_required} ->
        conn |> send_resp(403, "Operator controls require a same-origin loopback browser.") |> halt()

      {:error, reason} ->
        message = if reason == :control_auth_unconfigured, do: "Operator controls are not configured.", else: "Could not unlock controls. Check the control token."

        conn
        |> disconnect_sessions()
        |> delete_session(BrowserAuth.session_key())
        |> delete_session("live_socket_id")
        |> put_flash(:error, message)
        |> redirect(to: "/?panel=settings")
    end
  end

  @spec delete(Conn.t(), map()) :: Conn.t()
  def delete(conn, _params) do
    if BrowserAuth.local_request?(conn) do
      conn
      |> disconnect_sessions()
      |> configure_session(renew: true)
      |> delete_session(BrowserAuth.session_key())
      |> delete_session("live_socket_id")
      |> put_flash(:info, "Operator controls locked.")
      |> redirect(to: "/?panel=settings")
    else
      conn |> send_resp(403, "Operator controls require a same-origin loopback browser.") |> halt()
    end
  end

  defp disconnect_sessions(conn) do
    case get_session(conn, "live_socket_id") do
      socket_id when is_binary(socket_id) -> Endpoint.broadcast(socket_id, "disconnect", %{})
      _ -> :ok
    end

    conn
  end
end
