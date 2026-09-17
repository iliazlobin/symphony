defmodule SymphonyElixirWeb.ChatLive do
  @moduledoc "Standalone URL host for the shared project management chat panel."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  alias SymphonyElixirWeb.{BrowserAuth, ChatPanel, Endpoint}

  @impl true
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        auth: BrowserAuth.context(session, socket),
        csrf_token: Plug.CSRFProtection.get_csrf_token(),
        project_id: nil,
        chat_id: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, project_id: scalar(params["project"]), chat_id: scalar(params["chat"]))}
  end

  @impl true
  def handle_info({:chat_updated, id}, socket) do
    send_update(ChatPanel, id: "management-chat", refresh_chat: id)
    {:noreply, socket}
  end

  def handle_info({:chat_list_updated, project}, socket) do
    send_update(ChatPanel, id: "management-chat", refresh_threads: project)
    {:noreply, socket}
  end

  def handle_info({:chat_panel, :project_subscription, _project}, socket), do: {:noreply, socket}

  def handle_info({:chat_panel, :navigate, location}, socket) do
    params = %{"project" => location.project_id, "chat" => location.chat_id} |> Map.reject(fn {_key, value} -> is_nil(value) end)
    path = if params == %{}, do: "/chat", else: "/chat?" <> URI.encode_query(params)
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_info({:chat_panel, :board_link, url}, socket), do: {:noreply, redirect(socket, to: url)}
  def handle_info({:chat_panel, :close}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <p :if={Phoenix.Flash.get(@flash, :error)} class="board-warning" role="alert">{Phoenix.Flash.get(@flash, :error)}</p>
    <.live_component module={ChatPanel} id="management-chat" auth={@auth} csrf_token={@csrf_token}
      embedded={false} project_id={@project_id} chat_id={@chat_id} view_context={nil} read_only={Endpoint.config(:board_read_only, false)} />
    """
  end

  defp scalar(value) when is_binary(value) and byte_size(value) <= 2_000, do: value
  defp scalar(_), do: nil
end
