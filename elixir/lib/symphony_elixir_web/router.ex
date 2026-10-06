defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :browser_identity do
    plug(SymphonyElixirWeb.BrowserAccess, :browser)
  end

  pipeline :api_identity do
    plug(SymphonyElixirWeb.BrowserAccess, :api)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/dashboard.js", StaticAssetController, :dashboard_js)
    get("/browser-login.js", StaticAssetController, :browser_login_js)
    get("/favicon.png", StaticAssetController, :favicon)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
    get("/design-editor/*asset", StaticAssetController, :design_editor_asset)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/login", BrowserSessionController, :login)
    post("/auth/google", BrowserSessionController, :google)
    post("/auth/iap", BrowserSessionController, :iap)
    get("/auth/google/callback", BrowserSessionController, :callback)
    post("/operator/session", BrowserSessionController, :create)
    post("/operator/session/logout", BrowserSessionController, :delete)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :browser_identity])

    live_session :browser, on_mount: [{SymphonyElixirWeb.BrowserAccess, :default}] do
      live("/", DashboardLive, :index)
      live("/chat", ChatLive, :index)
      live("/projects/:workspace/", DashboardLive, :index)
      live("/projects/:workspace/chat", ChatLive, :index)
    end
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:api_identity)
    get("/api/v1/control", ControlApiController, :show)
    post("/api/v1/control", ControlApiController, :update)
    match(:*, "/api/v1/control", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/pr-work/publication", ControlApiController, :publication)
    match(:*, "/api/v1/pr-work/publication", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
