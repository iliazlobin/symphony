defmodule SymphonyElixirWeb.BrowserSessionController do
  @moduledoc "CSRF-protected browser login with Google or explicitly local operator tokens."
  use Phoenix.Controller, formats: [:html]

  alias Phoenix.HTML.Safe
  alias Plug.Conn
  alias SymphonyElixirWeb.{BrowserAuth, BrowserLoginHTML, BrowserSessions, Endpoint, GoogleOIDC}

  @spec login(Conn.t(), map()) :: Conn.t()
  def login(conn, _params) do
    if BrowserAuth.google_enabled?() do
      assigns = %{csrf_token: Plug.CSRFProtection.get_csrf_token(), error: Phoenix.Flash.get(conn.assigns.flash, :error)}

      # Form POSTs inherit this policy: no-referrer would replace their Origin with null.
      conn
      |> no_store()
      |> put_resp_header("referrer-policy", "same-origin")
      |> html(BrowserLoginHTML.render(assigns) |> Safe.to_iodata() |> IO.iodata_to_binary())
    else
      redirect(conn, to: "/?panel=settings")
    end
  end

  @spec google(Conn.t(), map()) :: Conn.t()
  def google(conn, params) do
    if BrowserAuth.browser_request?(conn) and BrowserAuth.google_enabled?() do
      conn = disconnect_sessions(conn)
      BrowserSessions.revoke(get_session(conn, "google_flow"))

      case GoogleOIDC.start(return_to(params)) do
        {:ok, id, url} ->
          conn
          |> configure_session(renew: true)
          |> delete_session(BrowserAuth.session_key())
          |> put_session("google_flow", id)
          |> no_store()
          |> redirect(external: url)

        _ ->
          login_failed(conn)
      end
    else
      conn |> no_store() |> send_resp(403, "Sign-in requires the configured browser origin.") |> halt()
    end
  end

  @spec callback(Conn.t(), map()) :: Conn.t()
  def callback(conn, params) do
    flow = get_session(conn, "google_flow")
    conn = delete_session(conn, "google_flow") |> no_store()
    # Google redirects cross-site; match the exact callback location, not its Origin header.
    valid_location = BrowserAuth.callback_request?(conn)

    cond do
      not valid_location ->
        conn |> send_resp(403, "Invalid sign-in callback origin.") |> halt()

      BrowserAuth.authorized?(BrowserAuth.conn_context(conn)) ->
        # A cross-site callback GET carries the Lax cookie. Only a CSRF-protected
        # login start may replace an existing grant, never an unsolicited callback.
        redirect(conn, to: "/")

      true ->
        complete_callback(conn, flow, params)
    end
  end

  defp complete_callback(conn, flow, params) do
    case GoogleOIDC.complete(flow, params) do
      {:ok, marker, destination} ->
        conn
        |> disconnect_sessions()
        |> configure_session(renew: true)
        |> put_session(BrowserAuth.session_key(), marker)
        |> put_session("live_socket_id", "operator:" <> marker["id"])
        |> redirect(to: destination)

      _ ->
        login_failed(conn)
    end
  end

  defp login_failed(conn) do
    conn
    |> disconnect_sessions()
    |> delete_session(BrowserAuth.session_key())
    |> delete_session("live_socket_id")
    |> delete_session("google_flow")
    |> put_flash(:error, "Google sign-in failed or this account is not allowed. Please try again.")
    |> no_store()
    |> redirect(to: "/login")
  end

  defp no_store(conn), do: conn |> put_resp_header("cache-control", "no-store") |> put_resp_header("referrer-policy", "no-referrer")

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
        |> redirect(to: return_to(params))

      {:error, :google_required} ->
        conn |> no_store() |> redirect(to: "/login")

      {:error, :local_browser_required} ->
        conn |> send_resp(403, "Operator controls require a same-origin loopback browser.") |> halt()

      {:error, reason} ->
        message = if reason == :control_auth_unconfigured, do: "Operator controls are not configured.", else: "Could not unlock controls. Check the control token."

        conn
        |> disconnect_sessions()
        |> delete_session(BrowserAuth.session_key())
        |> delete_session("live_socket_id")
        |> put_flash(:error, message)
        |> redirect(to: return_to(params))
    end
  end

  # Only known app entrypoints can receive an authentication redirect.
  defp return_to(%{"return_to" => "/chat"}), do: "/chat"
  defp return_to(%{"return_to" => "/?assistant=1"}), do: "/?assistant=1"
  defp return_to(%{"return_to" => "/"}), do: "/"
  defp return_to(_params), do: "/?panel=settings"

  @spec delete(Conn.t(), map()) :: Conn.t()
  def delete(conn, _params) do
    if BrowserAuth.browser_request?(conn) do
      conn
      |> disconnect_sessions()
      |> configure_session(renew: true)
      |> delete_session(BrowserAuth.session_key())
      |> delete_session("live_socket_id")
      |> delete_session("google_flow")
      |> no_store()
      |> put_flash(:info, "Signed out.")
      |> redirect(to: if(BrowserAuth.google_enabled?(), do: "/login", else: "/?panel=settings"))
    else
      conn |> send_resp(403, "Operator controls require a same-origin loopback browser.") |> halt()
    end
  end

  defp disconnect_sessions(conn) do
    BrowserSessions.revoke(get_session(conn, "google_flow"))
    BrowserAuth.revoke(get_session(conn, BrowserAuth.session_key()))

    case get_session(conn, "live_socket_id") do
      socket_id when is_binary(socket_id) -> Endpoint.broadcast(socket_id, "disconnect", %{})
      _ -> :ok
    end

    conn
  end
end
