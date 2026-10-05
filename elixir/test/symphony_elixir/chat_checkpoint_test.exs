defmodule SymphonyElixir.Chat.CheckpointTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Chat.Checkpoint

  test "keeps newest bounded context in original order" do
    entries = for i <- 1..100, do: %{"role" => "user", "content" => "message #{i}"}
    assert Checkpoint.bound(entries) == Enum.take(entries, -80)
    assert Checkpoint.bound([]) == []
  end

  test "large receipts and Unicode content cannot erase the latest history or violate provider limits" do
    entries = [
      %{"role" => "user", "content" => "Earlier instruction"},
      %{"role" => "assistant", "content" => String.duplicate("€", 70_000)}
    ]

    assert [earlier, latest] = Checkpoint.bound(entries)
    assert earlier == hd(entries)
    assert byte_size(latest["content"]) <= 65_536
    assert String.valid?(latest["content"])
    assert latest["content"] =~ "full source remains in Symphony"
    entries = List.duplicate(%{"role" => "assistant", "content" => String.duplicate("x", 65_536)}, 5)
    retained = Checkpoint.bound(entries)
    assert length(retained) == 3
    assert Enum.reduce(retained, 0, &(byte_size(&1["content"]) + &2)) <= 256_000
  end
end
