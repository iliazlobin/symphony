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

  socket("/live", SymphonyElixirWeb.LiveSocket,
    websocket: [connect_info: [:peer_data, :uri, :x_headers, session: {__MODULE__, :session_options, []}]],
    longpoll: false
  )

  plug(SymphonyElixirWeb.IAPIdentity, :request)
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
  plug(SymphonyElixirWeb.IAPIdentity, :session)
  plug(SymphonyElixirWeb.Router)

  @doc "Shared HTTP and LiveView cookie options; a workspace owns one browser session."
  @spec session_options() :: keyword()
  def session_options do
    cookie =
      if SymphonyElixirWeb.WorkspacePath.enabled?(),
        do: "_symphony_workspace",
        else: SymphonyElixir.Config.settings!().server.session_cookie

    Keyword.put(@session_options, :key, cookie)
  end

  defp project_session(conn, _opts), do: Plug.Session.call(conn, Plug.Session.init(session_options()))
end
