defmodule SymphonyElixirWeb.LiveSocket do
  @moduledoc "LiveView transport rejects IAP connections before WebSocket upgrade."
  use Phoenix.LiveView.Socket
  alias SymphonyElixirWeb.IAPIdentity

  @impl Phoenix.Socket
  def id(socket), do: Phoenix.LiveView.Socket.id(socket)

  @impl Phoenix.Socket
  def connect(_params, socket, info) do
    case SymphonyElixir.Config.browser_auth_settings()["provider"] do
      "iap" ->
        case IAPIdentity.verify_headers(info[:x_headers], info[:uri]) do
          {:ok, _identity} -> {:ok, socket}
          _ -> :error
        end

      provider when provider in ["google", "local_token"] ->
        {:ok, socket}

      _ ->
        :error
    end
  end
end
