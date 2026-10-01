defmodule SymphonyElixir.Chat.Checkpoint do
  @moduledoc "Bounds portable source context while preserving the newest settled messages."
  @message_bytes 65_536
  @history_bytes 256_000
  @marker "\n[Context truncated; full source remains in Symphony.]"

  @spec bound([map()]) :: [map()]
  def bound(messages) do
    messages
    |> Enum.take(-80)
    |> Enum.map(&Map.update!(&1, "content", fn text -> bounded_text(text) end))
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn entry, {retained, bytes} ->
      size = byte_size(entry["content"])
      if bytes + size <= @history_bytes, do: {:cont, {[entry | retained], bytes + size}}, else: {:halt, {retained, bytes}}
    end)
    |> elem(0)
  end

  defp bounded_text(text) when byte_size(text) <= @message_bytes, do: text
  defp bounded_text(text), do: utf8_prefix(binary_part(text, 0, @message_bytes - byte_size(@marker))) <> @marker
  defp utf8_prefix(text) do
    if String.valid?(text), do: text, else: utf8_prefix(binary_part(text, 0, byte_size(text) - 1))
  end
end
