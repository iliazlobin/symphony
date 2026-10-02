defmodule SymphonyElixirWeb.WorkspaceSessions do
  @moduledoc "Private workspace broker client; no network or local-session fallback on failure."

  @spec call(term()) :: term()
  def call(command) do
    with {:ok, body} <- encode(command),
         {:ok, %{status: 200, body: response}} <-
           Req.post("http://localhost/session", unix_socket: System.fetch_env!("SYMPHONY_WORKSPACE_AUTH_SOCKET"), json: body, retry: false, redirect: false, receive_timeout: 5_000, max_retries: 0) do
      decode(response)
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp encode({:issue, kind, value}) when kind in [:flow, :session] and is_map(value),
    do: {:ok, %{op: "issue", kind: kind, value: pack(value)}}

  defp encode({:get, kind, id}) when kind in [:flow, :session], do: {:ok, %{op: "get", kind: kind, id: id}}
  defp encode({:complete_flow, id, value}) when is_map(value), do: {:ok, %{op: "complete_flow", id: id, value: pack(value)}}
  defp encode({:revoke, id}), do: {:ok, %{op: "revoke", id: id}}
  defp encode(_), do: {:error, :invalid}
  defp pack(value), do: value |> :erlang.term_to_binary() |> Base.encode64()

  defp decode(%{"id" => id}) when is_binary(id), do: {:ok, id}

  defp decode(%{"value" => value}) when is_binary(value) do
    with {:ok, binary} <- Base.decode64(value),
         true <- byte_size(binary) <= 65_536,
         decoded when is_map(decoded) <- :erlang.binary_to_term(binary, [:safe]) do
      {:ok, decoded}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp decode(%{"ok" => true}), do: :ok
  defp decode(%{"error" => "expired"}), do: {:error, :expired}
  defp decode(%{"error" => "capacity"}), do: {:error, :capacity}
  defp decode(_), do: {:error, :unavailable}
end
