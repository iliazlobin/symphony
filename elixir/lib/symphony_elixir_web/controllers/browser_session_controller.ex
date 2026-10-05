defmodule SymphonyElixirWeb.BrowserSessionController do
  @moduledoc "CSRF-protected browser login with Google or explicitly local operator tokens."
  use Phoenix.Controller, formats: [:html]

  alias Phoenix.HTML.Safe
  alias Plug.Conn
  alias SymphonyElixirWeb.{BrowserAuth, BrowserLoginHTML, BrowserOrigin, BrowserSessions, Endpoint, GoogleOIDC}

  @spec login(Conn.t(), map()) :: Conn.t()
  def login(conn, params) do
    case BrowserOrigin.loopback_login_url(conn) do
      nil -> login_page(conn, params)
      url -> conn |> no_store() |> redirect(external: url <> if(params["continue"] == "1", do: "?continue=1", else: ""))
    end
  end

  defp login_page(conn, params) do
    if params["continue"] == "1" and BrowserAuth.authorized?(BrowserAuth.conn_context(conn)) do
      conn |> no_store() |> redirect(to: SymphonyElixirWeb.WorkspacePath.path("/"))
    else
      sign_in_page(conn, params)
    end
  end

  defp sign_in_page(conn, params) do
    if BrowserAuth.google_enabled?() do
      error = Phoenix.Flash.get(conn.assigns.flash, :error)

      continue =
        params["continue"] == "1" and BrowserAuth.callback_request?(conn) and
          get_session(conn, "google_signed_out") != true and is_nil(error)

      assigns = %{csrf_token: Plug.CSRFProtection.get_csrf_token(), error: error, continue: continue}

      # Form POSTs inherit this policy: no-referrer would replace their Origin with null.
      conn
      |> put_session("google_continue", continue)
      |> no_store()
      |> put_resp_header("referrer-policy", "same-origin")
      |> html(BrowserLoginHTML.render(assigns) |> Safe.to_iodata() |> IO.iodata_to_binary())
    else
      redirect(conn, to: if(params["continue"] == "1", do: SymphonyElixirWeb.WorkspacePath.path("/"), else: SymphonyElixirWeb.WorkspacePath.path("/?panel=settings")))
    end
  end

  @spec google(Conn.t(), map()) :: Conn.t()
  def google(conn, params) do
    if BrowserAuth.browser_request?(conn) and BrowserAuth.google_enabled?() do
      google_intent(conn, params)
    else
      rejected_origin(conn)
    end
  end

  defp google_intent(conn, params) do
    continuation = params["continue"] == "1"
    permitted = get_session(conn, "google_continue") == true and get_session(conn, "google_signed_out") != true
    conn = delete_session(conn, "google_continue")

    cond do
      continuation and BrowserAuth.authorized?(BrowserAuth.conn_context(conn)) ->
        conn |> no_store() |> redirect(to: SymphonyElixirWeb.WorkspacePath.path("/"))

      continuation and not permitted ->
        conn |> no_store() |> redirect(to: SymphonyElixirWeb.WorkspacePath.path("/login"))

      true ->
        start_google(conn, params, if(continuation, do: :continuation, else: :interactive))
    end
  end

  defp start_google(conn, params, mode) do
    conn = conn |> disconnect_sessions() |> delete_session("google_signed_out")

    case GoogleOIDC.start(return_to(params), mode) do
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
  end

  defp rejected_origin(conn) do
    case BrowserOrigin.loopback_login_url(conn) do
      nil ->
        conn |> no_store() |> send_resp(403, "Sign-in requires the configured browser origin.") |> halt()

      url ->
        assigns = %{csrf_token: nil, error: "Open the configured Symphony address to sign in.", login_url: url}
        conn |> no_store() |> put_status(403) |> html(BrowserLoginHTML.render(assigns) |> Safe.to_iodata() |> IO.iodata_to_binary()) |> halt()
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
        redirect(conn, to: SymphonyElixirWeb.WorkspacePath.path("/"))

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

      {:error, :interaction_required} ->
        login_failed(conn, "Choose your Google account to continue to this project.")

      _ ->
        login_failed(conn)
    end
  end

  defp login_failed(conn, message \\ "Google sign-in failed or this account is not allowed. Please try again.") do
    conn
    |> disconnect_sessions()
    |> delete_session(BrowserAuth.session_key())
    |> delete_session("live_socket_id")
    |> delete_session("google_flow")
    |> delete_session("google_continue")
    |> put_flash(:error, message)
    |> no_store()
    |> redirect(to: SymphonyElixirWeb.WorkspacePath.path("/login"))
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
        conn |> no_store() |> redirect(to: SymphonyElixirWeb.WorkspacePath.path("/login"))

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
  defp return_to(params) do
    requested = params["return_to"]
    relative = if is_binary(requested), do: SymphonyElixirWeb.WorkspacePath.relative(requested)
    destination = if relative in ["/chat", "/?assistant=1", "/"] or board_destination?(relative), do: relative, else: "/?panel=settings"
    SymphonyElixirWeb.WorkspacePath.path(destination)
  end

  # Keep scoped operator navigation while accepting only this app's board
  # entrypoint and its bounded state parameters, never arbitrary local paths.
  defp board_destination?(value) when is_binary(value) and byte_size(value) <= 20_000 do
    case URI.parse(value) do
      %URI{scheme: nil, host: nil, path: "/", fragment: nil, query: query} when is_binary(query) ->
        fields =
          ~w(project status priority kind milestone label assignee q sort view task chat_task chat_session panel design_ref design_section design_item design_task baseline) ++
            ~w(graph_mode graph_direction graph_hops graph_group_by graph_group graph_anchor graph_page graph_query graph_search_page graph_gaps_only)

        params = URI.decode_query(query)

        Enum.all?(params, fn {key, item} -> key in fields and String.valid?(item) and byte_size(item) <= 2_000 and not Regex.match?(~r/[\x00-\x1f\x7f]/, item) end) and
          params["view"] in [nil, "idea", "design", "graph", "gantt", "kanban"] and params["panel"] in [nil, "settings", "coverage"]

      _ ->
        false
    end
  end

  defp board_destination?(_value), do: false

  @spec delete(Conn.t(), map()) :: Conn.t()
  def delete(conn, _params) do
    if BrowserAuth.browser_request?(conn) do
      conn
      |> disconnect_sessions()
      |> configure_session(renew: true)
      |> delete_session(BrowserAuth.session_key())
      |> delete_session("live_socket_id")
      |> delete_session("google_flow")
      |> delete_session("google_continue")
      |> put_session("google_signed_out", true)
      |> no_store()
      |> put_flash(:info, "Signed out.")
      |> redirect(to: if(BrowserAuth.google_enabled?(), do: SymphonyElixirWeb.WorkspacePath.path("/login"), else: SymphonyElixirWeb.WorkspacePath.path("/?panel=settings")))
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
