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
    websocket: [connect_info: [:peer_data, :uri, session: @session_options]],
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
  plug(Plug.Session, @session_options)
  plug(SymphonyElixirWeb.Router)
end
