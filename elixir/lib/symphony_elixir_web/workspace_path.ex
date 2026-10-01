defmodule SymphonyElixirWeb.WorkspacePath do
  @moduledoc "Project-explicit paths for a workspace's private engine transport."

  @spec prefix() :: String.t()
  def prefix do
    case System.get_env("SYMPHONY_WORKSPACE_PROJECT") do
      slug when is_binary(slug) -> if Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,79}\z/, slug), do: "/projects/" <> slug, else: ""
      _ -> ""
    end
  end

  @spec path(String.t()) :: String.t()
  def path("/projects/" <> _ = value), do: value
  def path("/" <> _ = value), do: prefix() <> value
  def path(value), do: value

  @spec relative(String.t()) :: String.t()
  def relative(value) do
    current = prefix()

    if current != "" and String.starts_with?(value, current <> "/") do
      String.replace_prefix(value, current, "")
    else
      value
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    prefix() != "" and absolute_socket?("SYMPHONY_WORKSPACE_AUTH_SOCKET") and
      absolute_socket?("SYMPHONY_WORKSPACE_ENGINE_SOCKET")
  end

  defp absolute_socket?(name) do
    case System.get_env(name) do
      "/" <> _ -> true
      _ -> false
    end
  end

  @spec peer_ip(term()) :: term()
  def peer_ip(ip) when ip in [:unspec], do: if(enabled?(), do: {127, 0, 0, 1}, else: ip)
  def peer_ip({:local, _} = ip), do: if(enabled?(), do: {127, 0, 0, 1}, else: ip)
  def peer_ip(ip), do: ip
end
