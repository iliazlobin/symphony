defmodule SymphonyElixirWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Symphony's optional observability UI and API.
  """

  use Phoenix.Endpoint, otp_app: :symphony_elixir

  @session_options [
    store: :cookie,
    key: "_symphony_elixir_key",
    signing_salt: "symphony-session",
    encryption_salt: "symphony-browser-encryption",
    http_only: true,
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :uri, session: {__MODULE__, :session_options, []}]],
    longpoll: false
  )

  plug(SymphonyElixirWeb.BrowserOrigin)
  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(:project_session)
  plug(SymphonyElixirWeb.Router)

  @doc "Shared HTTP and LiveView cookie options; project controllers on one host need distinct keys."
  @spec session_options() :: keyword()
  def session_options do
    Keyword.put(@session_options, :key, SymphonyElixir.Config.settings!().server.session_cookie)
  end

  defp project_session(conn, _opts), do: Plug.Session.call(conn, Plug.Session.init(session_options()))
end
