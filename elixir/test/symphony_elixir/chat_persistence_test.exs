defmodule SymphonyElixir.Chat.PersistenceTest do
  use ExUnit.Case, async: false

  import Bitwise
  alias SymphonyElixir.Chat.Persistence

  setup do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "chat-persistence-#{System.unique_integer([:positive])}"))

    on_exit(fn ->
      File.chmod(root, 0o700)
      File.rm_rf(root)
    end)

    %{root: root, chat: chat()}
  end

  test "private synced records survive replacing a conversation and reopening storage", c do
    assert {:ok, owner, %{}} = Persistence.open(c.root)
    assert :ok = Persistence.put(owner, c.chat)
    path = record_path(c.root, c.chat)
    assert band(File.stat!(c.root).mode, 0o777) == 0o700
    assert band(File.stat!(path).mode, 0o777) == 0o600
    changed = c.chat |> Map.put("title", "Updated conversation") |> Map.put("messages", [message()])
    assert :ok = Persistence.put(owner, changed)
    assert Path.wildcard(Path.join(c.root, "*.tmp")) == []
    assert :ok = Persistence.close(owner)
    assert :ok = Persistence.close(owner)
    {reopened, records} = open_when_released(c.root)
    assert records == %{c.chat["id"] => changed}
    assert :ok = Persistence.close(reopened)
  end

  test "presentation preferences share the owner lock and atomic private storage without becoming conversations", c do
    {:ok, owner, %{}} = Persistence.open(c.root)
    assert {:ok, %{"version" => 1, "scopes" => %{}}} = Persistence.preferences(owner)
    assert :ok = Persistence.put(owner, c.chat)
    scope = String.duplicate("a", 64)
    preferences = %{"version" => 1, "scopes" => %{scope => %{"pinned" => [c.chat["id"]], "order" => [c.chat["id"]]}}}
    assert :ok = Persistence.put_preferences(owner, preferences)
    assert {:ok, ^preferences} = Persistence.preferences(owner)
    assert band(File.stat!(Path.join(c.root, "presentation.json")).mode, 0o777) == 0o600
    assert {:error, :chat_storage_locked} = Persistence.open(c.root)
    Persistence.close(owner)
    {reopened, records} = open_when_released(c.root)
    assert records == %{c.chat["id"] => c.chat}
    assert {:ok, ^preferences} = Persistence.preferences(reopened)
    Persistence.close(reopened)
  end

  test "invalid preference shapes fail closed without replacing an existing record", c do
    {:ok, owner, %{}} = Persistence.open(c.root)
    scope = String.duplicate("a", 64)
    ids = [c.chat["id"]]
    good = %{"version" => 1, "scopes" => %{scope => %{"pinned" => ids, "order" => ids}}}
    assert :ok = Persistence.put_preferences(owner, good)
    path = Path.join(c.root, "presentation.json")
    original = File.read!(path)

    invalid = [
      nil,
      %{},
      %{good | "version" => 2},
      Map.put(good, "extra", "field"),
      put_in(good, ["scopes", scope], nil),
      put_in(good, ["scopes", scope, "order"], []),
      put_in(good, ["scopes", scope, "pinned"], "bad"),
      put_in(good, ["scopes", scope, "pinned"], ["bad"]),
      put_in(good, ["scopes", scope, "order"], ids ++ ids),
      put_in(good, ["scopes", scope, "order"], List.duplicate(c.chat["id"], 501)),
      %{"version" => 1, "scopes" => %{"unscoped" => %{"pinned" => [], "order" => []}}},
      %{"version" => 1, "scopes" => Map.new(1..501, &{Integer.to_string(&1), %{"pinned" => [], "order" => []}})}
    ]

    for record <- invalid do
      assert {:error, :chat_preferences_unavailable} = Persistence.put_preferences(owner, record)
      assert File.read!(path) == original
      File.write!(path, Jason.encode!(record))
      assert {:error, :chat_preferences_unavailable} = Persistence.preferences(owner)
      File.write!(path, original)
    end

    File.write!(path, "{invalid")
    assert {:error, :chat_preferences_unavailable} = Persistence.preferences(owner)
    Persistence.close(owner)
  end

  test "preference symlinks, directories and oversized records are rejected and their targets retained", c do
    {:ok, owner, %{}} = Persistence.open(c.root)
    path = Path.join(c.root, "presentation.json")
    target = Path.join(c.root, "retained-original")
    File.write!(target, "original")
    File.ln_s!(target, path)
    assert {:error, :chat_preferences_unavailable} = Persistence.preferences(owner)
    assert {:error, :chat_preferences_unavailable} = Persistence.put_preferences(owner, %{"version" => 1, "scopes" => %{}})
    assert File.read!(target) == "original"
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, :chat_preferences_unavailable} = Persistence.preferences(owner)
    File.rmdir!(path)
    File.write!(path, String.duplicate("x", 8_000_001))
    assert {:error, :chat_preferences_unavailable} = Persistence.preferences(owner)
    Persistence.close(owner)
  end

  test "an OS lock rejects a competing owner and releases when its process exits", c do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, owner, %{}} = Persistence.open(c.root)
        :ok = Persistence.put(owner, c.chat)
        send(parent, :locked)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :locked
    assert {:error, :chat_storage_locked} = Persistence.open(c.root)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    {owner, records} = open_when_released(c.root)
    assert records[c.chat["id"]] == c.chat
    Persistence.close(owner)
  end

  test "nonabsolute, noncanonical and unavailable roots are rejected", c do
    assert {:error, :chat_storage_unavailable} = Persistence.open(nil)
    assert {:error, :chat_storage_unavailable} = Persistence.open("relative/chat")
    assert {:error, :chat_storage_unavailable} = Persistence.open(c.root <> "/../other")
    File.write!(c.root, "existing file")
    assert {:error, :chat_storage_unavailable} = Persistence.open(c.root)
    assert File.read!(c.root) == "existing file"
  end

  test "symlinked roots and lock files cannot redirect storage or lock authority", c do
    target = c.root <> "/target"
    File.mkdir_p!(target)
    link = c.root <> "/alias"
    File.ln_s!(target, link)
    assert {:error, :chat_storage_unavailable} = Persistence.open(link)
    File.write!(Path.join(target, "real-lock"), "retained")
    File.ln_s!(Path.join(target, "real-lock"), Path.join(target, "owner.lock"))
    assert {:error, :chat_storage_unavailable} = Persistence.open(target)
    assert File.read!(Path.join(target, "real-lock")) == "retained"
  end

  test "symlinked records are neither followed while loading nor overwritten", c do
    {:ok, owner, %{}} = Persistence.open(c.root)
    target = Path.join(c.root, "original")
    File.write!(target, Jason.encode!(c.chat))
    path = record_path(c.root, c.chat)
    File.ln_s!(target, path)
    assert {:error, :chat_storage_unavailable} = Persistence.put(owner, Map.put(c.chat, "title", "Changed"))
    assert Jason.decode!(File.read!(target)) == c.chat
    Persistence.close(owner)
    assert_unavailable_after_release(c.root)
    assert File.lstat!(path).type == :symlink
  end

  test "malformed and corrupt nested records fail closed and preserve their bytes", c do
    File.mkdir_p!(c.root)
    path = record_path(c.root, c.chat)

    invalid_records = [
      "{unfinished",
      "null",
      Jason.encode!(Map.put(c.chat, "id", String.duplicate("f", 32))),
      Jason.encode!(Map.put(c.chat, "project_id", 7)),
      Jason.encode!(Map.put(c.chat, "messages", %{})),
      Jason.encode!(Map.put(c.chat, "messages", [nil])),
      Jason.encode!(Map.put(c.chat, "proposals", %{})),
      Jason.encode!(Map.put(c.chat, "proposals", [nil])),
      Jason.encode!(Map.put(c.chat, "client_ids", [nil])),
      Jason.encode!(Map.put(c.chat, "context", ["not a reference"])),
      Jason.encode!(Map.put(c.chat, "archived", "false")),
      Jason.encode!(Map.put(c.chat, "status", "invented")),
      Jason.encode!(Map.put(c.chat, "messages", [Map.put(message(), "role", "system")])),
      Jason.encode!(Map.put(c.chat, "messages", [Map.put(message(), "widgets", [nil])])),
      Jason.encode!(Map.put(c.chat, "proposals", [Map.put(proposal(), "args", [])])),
      Jason.encode!(Map.put(c.chat, "proposals", [Map.put(proposal(), "status", "approved-by-model")]))
    ]

    for bytes <- invalid_records do
      File.write!(path, bytes)
      assert_unavailable_after_release(c.root)
      assert File.read!(path) == bytes
    end

    File.write!(path, Jason.encode!(%{c.chat | "messages" => [message()], "proposals" => [proposal()]}))
    {owner, recovered} = open_when_released(c.root)
    assert length(recovered[c.chat["id"]]["proposals"]) == 1
    Persistence.close(owner)
  end

  test "invalid record filenames and nonregular records are rejected", c do
    File.mkdir_p!(c.root)
    bad = Path.join(c.root, "not-a-chat-id.json")
    File.write!(bad, Jason.encode!(c.chat))
    assert_unavailable_after_release(c.root)
    File.rm!(bad)
    File.mkdir!(record_path(c.root, c.chat))
    assert_unavailable_after_release(c.root)
  end

  test "queue records require one matching action and exact bounded submission arguments", c do
    File.mkdir_p!(c.root)
    path = record_path(c.root, c.chat)
    proposal = %{proposal() | "action" => "queue_task", "args" => %{"task_id" => "11"}}
    submission = %{"args" => %{"action" => "queue_task", "task_id" => "11"}}
    record = c.chat |> Map.put("kind", "board_action") |> Map.put("submission", submission) |> Map.put("proposals", [proposal])

    invalid_records = [
      put_in(record, ["submission", "args", "action"], "create_task"),
      put_in(record, ["submission", "args", "task_id"], "12"),
      put_in(record, ["submission", "args", "task_id"], nil),
      put_in(record, ["submission", "args", "task_id"], " "),
      put_in(record, ["submission", "args", "task_id"], String.duplicate("x", 241)),
      put_in(record, ["submission", "args", "labels"], ["symphony:ready"]),
      put_in(record, ["submission", "extra"], true),
      Map.put(record, "proposals", [proposal, proposal]),
      Map.put(record, "proposals", []),
      Map.put(record, "proposals", [%{proposal | "action" => "create_task"}]),
      Map.put(record, "proposals", [%{proposal | "args" => %{}}]),
      Map.put(record, "proposals", [%{proposal | "args" => %{"task_id" => "11", "resume" => true}}])
    ]

    invalid_id_records =
      Enum.map([nil, 11, "", " ", "0", "01", "11\n", "GH-11", String.duplicate("1", 241)], fn task_id ->
        record |> put_in(["submission", "args", "task_id"], task_id) |> put_in(["proposals", Access.at(0), "args", "task_id"], task_id)
      end)

    for invalid <- invalid_records ++ invalid_id_records do
      bytes = Jason.encode!(invalid)
      File.write!(path, bytes)
      assert_unavailable_after_release(c.root)
      assert File.read!(path) == bytes
    end

    File.write!(path, Jason.encode!(record))
    {owner, recovered} = open_when_released(c.root)
    assert recovered == %{record["id"] => record}
    Persistence.close(owner)
  end

  test "canonical bindings and pending message queues fail closed on malformed durable records", c do
    File.mkdir_p!(c.root)
    task_id = c.chat["project_id"] <> ":11"
    id = Persistence.conversation_id(c.chat["project_id"], task_id, "scope")

    entry =
      %{message() | "id" => String.duplicate("c", 32), "role" => "user", "text" => "Follow up", "status" => "queued", "widgets" => []}
      |> Map.merge(%{"client_id" => "next", "created_at" => "2026-09-22T00:00:00Z", "view_context" => nil})

    record = c.chat |> Map.merge(%{"id" => id, "conversation_role" => "task", "task_id" => task_id, "queue" => [entry], "queue_paused" => true})
    path = record_path(c.root, record)

    invalid = [
      Map.put(record, "conversation_role", "invented"),
      Map.put(record, "conversation_role", "main"),
      Map.put(record, "task_id", "github:other/project:11"),
      Map.put(record, "task_id", c.chat["project_id"] <> ":12"),
      Map.put(record, "queue_paused", "false"),
      Map.put(record, "queue", [nil]),
      Map.put(record, "queue", [entry, entry]),
      Map.put(record, "queue", List.duplicate(entry, 21)),
      Map.put(record, "queue", [Map.put(entry, "role", "assistant")]),
      Map.put(record, "queue", [Map.put(entry, "status", "completed")]),
      Map.put(record, "queue", [Map.put(entry, "created_at", "invalid")]),
      Map.put(record, "queue", [Map.put(entry, "client_id", nil)]),
      Map.put(record, "queue", [Map.put(entry, "view_context", %{})]),
      Map.put(record, "message_receipts", %{"next" => "not-a-hash"})
    ]

    for invalid_record <- invalid do
      bytes = Jason.encode!(invalid_record)
      File.write!(path, bytes)
      assert_unavailable_after_release(c.root)
      assert File.read!(path) == bytes
    end

    File.write!(path, Jason.encode!(record))
    {owner, records} = open_when_released(c.root)
    assert records[id] == record
    Persistence.close(owner)
  end

  test "record size and conversation count limits reject unbounded persisted state", c do
    {:ok, owner, %{}} = Persistence.open(c.root)
    oversized = Map.put(c.chat, "oversized", String.duplicate("x", 8_000_001))
    assert {:error, :chat_storage_unavailable} = Persistence.put(owner, oversized)
    assert {:error, :chat_storage_unavailable} = Persistence.put(owner, Map.put(c.chat, "id", "../escape"))
    assert {:error, :chat_storage_unavailable} = Persistence.put(owner, Map.put(c.chat, "invalid", self()))
    refute File.exists?(record_path(c.root, c.chat))
    Persistence.close(owner)
    File.write!(record_path(c.root, c.chat), String.duplicate("x", 8_000_001))
    assert_unavailable_after_release(c.root)
    File.rm!(record_path(c.root, c.chat))

    for number <- 0..500 do
      id = number |> Integer.to_string(16) |> String.pad_leading(32, "0")
      File.write!(Path.join(c.root, id <> ".json"), Jason.encode!(Map.put(c.chat, "id", id)))
    end

    assert_unavailable_after_release(c.root)
    assert length(Path.wildcard(Path.join(c.root, "*.json"))) == 501
  end

  test "a failed atomic replacement retains an existing target and removes temporary output", c do
    {:ok, owner, %{}} = Persistence.open(c.root)
    path = record_path(c.root, c.chat)
    File.mkdir!(path)
    File.write!(Path.join(path, "retained"), "original")
    assert {:error, :chat_storage_unavailable} = Persistence.put(owner, c.chat)
    assert File.read!(Path.join(path, "retained")) == "original"
    assert Path.wildcard(Path.join(c.root, "*.tmp")) == []
    Persistence.close(owner)
  end

  test "unwritable storage does not truncate the last successful record", c do
    {:ok, owner, %{}} = Persistence.open(c.root)
    assert :ok = Persistence.put(owner, c.chat)
    path = record_path(c.root, c.chat)
    File.chmod!(c.root, 0o500)

    try do
      assert {:error, :chat_storage_unavailable} = Persistence.put(owner, Map.put(c.chat, "title", "Unsaved"))
      assert Jason.decode!(File.read!(path)) == c.chat
    after
      File.chmod!(c.root, 0o700)
      Persistence.close(owner)
    end
  end

  test "missing lock runtime reports unavailability without inventing an owner", c do
    previous = System.get_env("PATH")
    System.put_env("PATH", "/definitely-no-executables")

    try do
      assert {:error, :chat_storage_unavailable} = Persistence.open(c.root)
    after
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
    end
  end

  test "a lock helper that never becomes ready times out and permits a later clean owner", c do
    bin = Path.join(c.root, "unready-runtime")
    File.mkdir_p!(bin)
    helper = Path.join(bin, "python3")
    # Simulate an external runtime stuck before its readiness handshake. Reading
    # until stdin closes lets the test peer exit when Persistence closes its port.
    File.write!(helper, "#!/bin/sh\nwhile read line; do :; done\n")
    File.chmod!(helper, 0o700)
    previous = System.get_env("PATH")
    System.put_env("PATH", bin)
    started = System.monotonic_time(:millisecond)

    try do
      assert {:error, :chat_storage_unavailable} = Persistence.open(c.root)
    after
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
    end

    assert System.monotonic_time(:millisecond) - started < 10_000
    {owner, %{}} = open_when_released(c.root)
    Persistence.close(owner)
  end

  defp chat do
    %{
      "id" => String.duplicate("a", 32),
      "project_id" => "github:example/project",
      "title" => "Planning",
      "tracker_fingerprint" => "scope",
      "runtime_identity" => "runtime",
      "updated_at" => "2026-09-15T00:00:00Z",
      "archived" => false,
      "status" => "idle",
      "context" => [],
      "client_ids" => [],
      "messages" => [],
      "proposals" => []
    }
  end

  defp message, do: %{"id" => "message-1", "role" => "assistant", "text" => "Current work", "status" => "completed", "widgets" => [%{"type" => "task", "id" => "GH-1"}]}
  defp proposal, do: %{"id" => String.duplicate("b", 32), "action" => "feedback", "args" => %{"body" => "Review"}, "status" => "pending"}
  defp record_path(root, chat), do: Path.join(root, chat["id"] <> ".json")

  defp open_when_released(root, attempts \\ 100) do
    case Persistence.open(root) do
      {:ok, owner, records} ->
        {owner, records}

      {:error, :chat_storage_locked} when attempts > 0 ->
        Process.sleep(10)
        open_when_released(root, attempts - 1)

      other ->
        flunk("Storage did not reopen: #{inspect(other)}")
    end
  end

  defp assert_unavailable_after_release(root, attempts \\ 100) do
    case Persistence.open(root) do
      {:error, :chat_storage_locked} when attempts > 0 ->
        Process.sleep(10)
        assert_unavailable_after_release(root, attempts - 1)

      result ->
        assert result == {:error, :chat_storage_unavailable}
    end
  end
end
