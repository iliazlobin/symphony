defmodule SymphonyElixirWeb.BrowserIdentity do
  @moduledoc "Google browser identity configuration and admission; never worker/model authentication."
  alias SymphonyElixir.Config

  @loopback ["localhost", "127.0.0.1", "::1"]

  @spec enabled?() :: boolean()
  def enabled?, do: Config.browser_auth_settings()["provider"] != "local_token"

  @spec settings() :: {:ok, map()} | {:error, :auth_unconfigured}
  def settings do
    raw = Config.browser_auth_settings()
    origin = raw["public_origin"]
    uri = URI.parse(if(is_binary(origin), do: origin, else: ""))
    emails = raw["allowed_emails"]
    subjects = raw["allowed_subjects"] || []
    proxies = raw["trusted_proxy_ips"] || []
    client_id = resolve(raw["client_id"])
    secret = resolve_secret(raw["client_secret"])

    config = %{
      origin: origin,
      uri: uri,
      client_id: client_id,
      client_secret: secret,
      emails: emails,
      subjects: subjects,
      proxies: proxies
    }

    if valid_config?(raw, config) do
      config = %{config | emails: Enum.map(emails, &String.downcase/1)}
      {:ok, Map.put(config, :fingerprint, :crypto.hash(:sha256, :erlang.term_to_binary(config)))}
    else
      {:error, :auth_unconfigured}
    end
  end

  defp valid_config?(raw, config) do
    raw["provider"] == "google" and valid_origin?(config.uri, config.origin) and
      valid_credentials?(config) and valid_emails?(config.emails) and
      strings?(config.subjects, 20, 255) and valid_proxies?(config.proxies)
  end

  defp valid_credentials?(config) do
    is_binary(config.client_id) and String.ends_with?(config.client_id, ".apps.googleusercontent.com") and
      is_binary(config.client_secret) and byte_size(config.client_secret) > 0
  end

  defp valid_emails?(emails) do
    strings?(emails, 20, 320) and emails != [] and Enum.all?(emails, &Regex.match?(~r/\A[^\s@]+@[^\s@]+\z/, &1))
  end

  defp valid_proxies?(proxies), do: strings?(proxies, 20, 100) and Enum.all?(proxies, &valid_ip?/1)

  @spec admit(map(), map()) :: boolean()
  def admit(%{"iss" => "https://accounts.google.com", "sub" => sub, "email" => email, "email_verified" => true} = user, config)
      when is_binary(sub) and byte_size(sub) > 0 and byte_size(sub) <= 255 and is_binary(email) do
    email = String.downcase(email)
    pinned = sub in config.subjects
    gmail = String.ends_with?(email, "@gmail.com")
    workspace = hosted_domain?(user["hd"]) and pinned
    email in config.emails and (gmail or workspace) and (config.subjects == [] or pinned)
  end

  def admit(_user, _config), do: false

  @spec trusted_peer?(term(), map()) :: boolean()
  def trusted_peer?(ip, config) when is_tuple(ip) do
    Enum.any?(config.proxies, fn allowed -> :inet.parse_address(String.to_charlist(allowed)) == {:ok, ip} end)
  end

  def trusted_peer?(_ip, _config), do: false

  defp valid_origin?(uri, origin) do
    valid_location?(uri) and bare_origin?(uri) and origin == URI.to_string(uri) and
      (uri.scheme == "https" or (uri.scheme == "http" and uri.host in @loopback))
  end

  defp valid_location?(uri), do: is_binary(uri.host) and uri.host != "" and is_integer(uri.port) and uri.port > 0 and uri.port <= 65_535
  defp bare_origin?(uri), do: is_nil(uri.userinfo) and uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment)
  defp hosted_domain?(hd), do: is_binary(hd) and hd != ""

  defp strings?(items, max, bytes), do: is_list(items) and length(items) <= max and Enum.all?(items, &(is_binary(&1) and byte_size(&1) > 0 and byte_size(&1) <= bytes))
  defp valid_ip?(ip), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(ip)))
  defp resolve("$" <> name), do: environment(name)
  defp resolve(value), do: value
  defp resolve_secret("$" <> name), do: environment(name)
  defp resolve_secret(_value), do: nil
  defp environment(name), do: if(Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name), do: System.get_env(name), else: nil)
end
