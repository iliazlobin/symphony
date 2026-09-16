defmodule SymphonyElixirWeb.BrowserAccess do
  @moduledoc "Google-mode read boundary for HTTP and every LiveView lifecycle callback."
  import Plug.Conn
  alias Phoenix.LiveView
  alias SymphonyElixirWeb.{BrowserAuth, ControlApiController}

  @spec init(atom()) :: atom()
  def init(mode), do: mode

  @spec call(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def call(conn, mode) do
    if BrowserAuth.google_enabled?() do
      protect(conn, mode)
    else
      conn
    end
  end

  defp protect(conn, :api), do: ControlApiController.authorize(conn)

  defp protect(conn, :browser) do
    if BrowserAuth.authorized?(BrowserAuth.conn_context(conn)) do
      put_resp_header(conn, "cache-control", "no-store")
    else
      conn |> Phoenix.Controller.redirect(to: "/login") |> halt()
    end
  end

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) :: {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    auth = BrowserAuth.context(session, socket)
    socket = Phoenix.Component.assign(socket, :browser_gate_auth, auth)

    if BrowserAuth.google_enabled?() and not BrowserAuth.authorized?(auth) do
      {:halt, LiveView.redirect(socket, to: "/login")}
    else
      if LiveView.connected?(socket), do: Process.send_after(self(), :browser_session_check, 15_000)

      socket =
        socket
        |> LiveView.attach_hook(:browser_auth, :handle_event, fn _, _, s -> guard(s) end)
        |> LiveView.attach_hook(:browser_auth, :handle_params, fn _, _, s -> guard(s) end)
        |> LiveView.attach_hook(:browser_auth, :handle_async, fn _, _, s -> guard(s) end)
        |> LiveView.attach_hook(:browser_auth, :handle_info, &guard_info/2)

      {:cont, socket}
    end
  end

  defp guard_info(:browser_session_check, socket) do
    case guard(socket) do
      {:cont, socket} ->
        Process.send_after(self(), :browser_session_check, 15_000)
        {:halt, socket}

      halted ->
        halted
    end
  end

  defp guard_info(_message, socket), do: guard(socket)

  defp guard(socket) do
    if not BrowserAuth.google_enabled?() or BrowserAuth.authorized?(socket.assigns.browser_gate_auth) do
      {:cont, socket}
    else
      {:halt, LiveView.redirect(socket, to: "/login")}
    end
  end
end
