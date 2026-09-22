defmodule SymphonyElixir.ProjectDirectory do
  @moduledoc "Trusted links between project controllers; each destination owns its auth and state."

  alias SymphonyElixir.Config

  @spec valid?(term()) :: boolean()
  def valid?(links) when is_list(links) do
    length(links) <= 20 and Enum.all?(links, &valid_link?/1) and
      length(Enum.uniq_by(links, & &1["id"])) == length(links) and
      length(Enum.uniq_by(links, & &1["url"])) == length(links)
  end

  def valid?(_), do: false

  @spec links() :: [map()]
  def links do
    case Config.settings() do
      {:ok, %{server: %{project_links: links}}} when is_list(links) -> if valid?(links), do: links, else: []
      _ -> []
    end
  end

  defp valid_link?(%{"id" => id, "label" => label, "url" => url} = link)
       when is_binary(id) and is_binary(label) and is_binary(url) do
    map_size(link) == 3 and byte_size(id) <= 200 and
      Regex.match?(~r/\Agithub:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, id) and
      String.trim(label) != "" and byte_size(label) <= 80 and safe_origin?(url)
  end

  defp valid_link?(_), do: false

  defp safe_origin?(url) do
    byte_size(url) <= 512 and not Regex.match?(~r/[\s\x00-\x1f\x7f\\]/, url) and
      case URI.new(url) do
        {:ok, uri} -> allowed_origin?(uri)
        _ -> false
      end
  end

  defp allowed_origin?(%URI{scheme: scheme, host: host, port: port, path: path, userinfo: nil, query: nil, fragment: nil})
       when is_binary(host) and host != "" and is_integer(port) and port in 1..65_535 and path in [nil, "", "/"] do
    scheme == "https" or (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"])
  end

  defp allowed_origin?(_), do: false
end
