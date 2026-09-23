defmodule SymphonyElixir.Chat.HierarchySchemaTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Chat.{Coordination, Persistence}

  @project "github:example/project"
  @task @project <> ":11"
  @fingerprint "scope"
  @now "2026-09-23T15:00:00Z"
  @root_id String.duplicate("a", 32)
  @message_id String.duplicate("b", 32)
  @work_session "work:" <> String.duplicate("c", 32)

  setup do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "hierarchy-schema-#{System.unique_integer([:positive])}"))
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "coordination exposes only strict object schemas and rejects unknown tools and arguments" do
    specs = Coordination.specs()
    assert Enum.map(specs, & &1["name"]) == ~w(symphony_agent_graph symphony_delegate symphony_report symphony_set_goal)

    for spec <- specs do
      assert Coordination.tool?(spec["name"])
      assert spec["inputSchema"]["type"] == "object"
      assert spec["inputSchema"]["additionalProperties"] == false

      for non_object <- [nil, false, [], "{}", 1] do
        assert {:error, :invalid_arguments} = Coordination.validate(spec["name"], non_object)
      end
    end

    refute Coordination.tool?("symphony_merge")
    assert {:error, :invalid_arguments} = Coordination.validate("symphony_merge", %{})
    assert :ok = Coordination.validate("symphony_agent_graph", %{})
    assert {:error, :invalid_arguments} = Coordination.validate("symphony_agent_graph", %{"project" => @project})

    args = %{"conversation_id" => @root_id, "text" => "Review the feature report", "request_id" => "request-1"}
    assert :ok = Coordination.validate("symphony_delegate", args)

    for field <- Map.keys(args) do
      assert {:error, :invalid_arguments} = Coordination.validate("symphony_delegate", Map.delete(args, field))
    end

    assert {:error, :invalid_arguments} = Coordination.validate("symphony_delegate", Map.put(args, "approve", true))
    assert {:error, :invalid_arguments} = Coordination.validate("symphony_delegate", Map.put(args, :text, "Atom keys are not wire keys"))
    assert :ok = Coordination.validate("symphony_report", Map.take(args, ~w(text request_id)))
    assert {:error, :invalid_arguments} = Coordination.validate("symphony_report", args)
  end

  test "tool arguments require bounded UTF-8 strings and declared goal statuses" do
    args = %{"conversation_id" => @root_id, "text" => "Review", "request_id" => "request-1"}

    for field <- ~w(conversation_id text request_id), invalid <- [nil, 1, [], %{}, "", " \n\t", <<255>>] do
      assert {:error, :invalid_arguments} = Coordination.validate("symphony_delegate", Map.put(args, field, invalid))
    end

    for {field, limit} <- [{"conversation_id", 32}, {"text", 8000}, {"request_id", 100}] do
      assert :ok = Coordination.validate("symphony_delegate", Map.put(args, field, String.duplicate("x", limit)))
      assert {:error, :invalid_arguments} = Coordination.validate("symphony_delegate", Map.put(args, field, String.duplicate("x", limit + 1)))
    end

    assert :ok = Coordination.validate("symphony_report", %{"text" => String.duplicate("é", 4000), "request_id" => "utf8"})
    assert {:error, :invalid_arguments} = Coordination.validate("symphony_report", %{"text" => String.duplicate("é", 4001), "request_id" => "utf8"})

    for status <- ~w(active achieved blocked) do
      assert :ok = Coordination.validate("symphony_set_goal", %{"text" => "Ship verified documentation", "status" => status})
      assert :ok = Coordination.validate("symphony_set_goal", %{"conversation_id" => @root_id, "text" => "Ship verified documentation", "status" => status})
    end

    for status <- [nil, "done", "approved", "Active", "active ", false] do
      assert {:error, :invalid_arguments} = Coordination.validate("symphony_set_goal", %{"text" => "Ship", "status" => status})
    end

    assert {:error, :invalid_arguments} = Coordination.validate("symphony_set_goal", %{"text" => "Ship"})
    assert {:error, :invalid_arguments} = Coordination.validate("symphony_set_goal", %{"status" => "active"})
  end

  test "agent labels preserve the name and express the three hierarchy roles" do
    for {role, suffix} <- [{"main", "project"}, {"task", "task"}, {"pr", "feature"}, {"legacy", "project"}] do
      assert Coordination.label(%{"conversation_role" => role, "agent_name" => "README", "title" => "Old title"}) == "README #{suffix} agent"
    end

    assert Coordination.label(%{"conversation_role" => "task", "title" => "Fallback title"}) == "Fallback title task agent"
    assert Coordination.label(%{"agent_name" => "Events Concierge"}) == "Events Concierge project agent"
  end

  test "long reports truncate at a complete grapheme within the protocol byte limit" do
    assert Coordination.bounded_text("") == ""
    assert Coordination.bounded_text(String.duplicate("x", 8000)) == String.duplicate("x", 8000)
    assert Coordination.bounded_text(String.duplicate("x", 8001)) == String.duplicate("x", 7997) <> "…"

    for grapheme <- ["é", "e\u0301", "👩🏽‍💻"] do
      source = String.duplicate("x", 7996) <> grapheme <> String.duplicate("z", 20)
      result = Coordination.bounded_text(source)
      assert result == String.duplicate("x", 7996) <> "…"
      assert String.valid?(result)
      assert byte_size(result) <= 8000
    end

    assert Coordination.bounded_text(String.duplicate("é", 4001)) == String.duplicate("é", 3998) <> "…"
  end

  test "hierarchy metadata and provenance roundtrip with canonical and effective PR identities", c do
    record = hierarchy_chat()
    assert {:ok, owner, %{}} = Persistence.open(c.root)
    assert :ok = Persistence.put(owner, record)
    Persistence.close(owner)
    {owner, records} = open_when_released(c.root)
    assert records == %{record["id"] => record}

    for status <- ~w(active achieved blocked) do
      changed = put_in(record, ["agent_goal", "status"], status)
      assert :ok = Persistence.put(owner, changed)
      assert Jason.decode!(File.read!(record_path(c.root, record))) == changed
    end

    # Retained conversations from before hierarchy metadata remain readable.
    legacy = Map.drop(record, ~w(parent_id alias_of agent_session_id agent_name agent_goal agent_chains agent_outbox))
    assert :ok = Persistence.put(owner, legacy)
    optional = Map.merge(legacy, %{"parent_id" => nil, "alias_of" => nil, "agent_session_id" => nil, "agent_name" => nil, "agent_goal" => nil})
    assert :ok = Persistence.put(owner, optional)
    Persistence.close(owner)
    {owner, records} = open_when_released(c.root)
    assert records[record["id"]] == optional
    Persistence.close(owner)
  end

  test "invalid hierarchy identities goals and chains cannot overwrite history or load as valid state", c do
    record = hierarchy_chat()

    invalid =
      [
        Map.put(record, "parent_id", "not-a-conversation"),
        Map.put(record, "alias_of", 7),
        Map.put(record, "agent_session_id", "work:invalid"),
        Map.put(record, "agent_session_id", 7),
        Map.put(record, "agent_name", 7),
        Map.put(record, "agent_name", String.duplicate("x", 16_001)),
        Map.put(record, "agent_goal", []),
        Map.put(record, "agent_chains", []),
        Map.put(record, "agent_chains", %{"not-an-id" => 1})
      ] ++
        Enum.map([0, 25, "1", 1.5, nil], &Map.put(record, "agent_chains", %{@root_id => &1})) ++
        Enum.map(
          [{"text", 1}, {"text", String.duplicate("x", 8001)}, {"status", "done"}, {"set_by", "invalid"}, {"updated_at", nil}],
          fn {key, value} -> put_in(record, ["agent_goal", key], value) end
        )

    assert_rejected_records(c.root, record, invalid)
  end

  test "effective feature session metadata is rejected on project and task conversations", c do
    records =
      for {role, task} <- [{"main", nil}, {"task", @task}] do
        hierarchy_chat()
        |> Map.merge(%{
          "id" => Persistence.conversation_id(@project, task, @fingerprint),
          "conversation_role" => role,
          "task_id" => task,
          "session_id" => nil,
          "agent_outbox" => []
        })
      end

    assert {:ok, owner, %{}} = Persistence.open(c.root)

    for record <- records do
      assert {:error, :chat_storage_unavailable} = Persistence.put(owner, record)
      refute File.exists?(record_path(c.root, record))
      assert :ok = Persistence.put(owner, Map.delete(record, "agent_session_id"))
    end

    Persistence.close(owner)
  end

  test "outbox events require sender ownership bounded delivery metadata and known states", c do
    record = hierarchy_chat()
    event = hd(record["agent_outbox"])

    invalid_events =
      [nil, []] ++
        Enum.map(~w(id source_id target_id root root_chat), &Map.put(event, &1, "invalid")) ++
        Enum.map(
          [
            {"source_id", @root_id},
            {"text", nil},
            {"text", String.duplicate("x", 8001)},
            {"source_name", nil},
            {"source_name", String.duplicate("x", 16_201)},
            {"kind", "approval"},
            {"status", "processed"},
            {"depth", 0},
            {"depth", 7},
            {"depth", "1"},
            {"created_at", nil}
          ],
          fn {key, value} -> Map.put(event, key, value) end
        )

    invalid = Enum.map(invalid_events, &Map.put(record, "agent_outbox", [&1])) ++ [Map.put(record, "agent_outbox", %{})]
    assert_rejected_records(c.root, record, invalid)
  end

  test "provenance is validated in both retained messages and queued reports", c do
    record = hierarchy_chat()
    entry = hd(record["queue"])

    invalid_entries =
      Enum.map(~w(source_agent agent_root agent_root_chat), &Map.put(entry, &1, "invalid")) ++
        Enum.map(
          [{"role", "assistant"}, {"source_name", nil}, {"source_name", String.duplicate("x", 16_201)}, {"agent_kind", "approval"}, {"agent_depth", 0}, {"agent_depth", 7}, {"agent_depth", "1"}],
          fn {key, value} -> Map.put(entry, key, value) end
        )

    invalid = for field <- ~w(messages queue), entry <- invalid_entries, do: Map.put(record, field, [entry])
    assert_rejected_records(c.root, record, invalid)
  end

  test "UTF-8 and byte boundaries also apply before persisting hierarchy metadata", c do
    record = hierarchy_chat()
    assert {:ok, owner, %{}} = Persistence.open(c.root)
    assert :ok = Persistence.put(owner, record)
    original = File.read!(record_path(c.root, record))

    for path <- [
          ["agent_name"],
          ["agent_goal", "text"],
          ["agent_outbox", Access.at(0), "text"],
          ["agent_outbox", Access.at(0), "source_name"],
          ["messages", Access.at(0), "source_name"],
          ["queue", Access.at(0), "source_name"]
        ] do
      assert {:error, :chat_storage_unavailable} = Persistence.put(owner, put_in(record, path, <<255>>))
      assert File.read!(record_path(c.root, record)) == original
    end

    boundary =
      record
      |> Map.put("agent_name", String.duplicate("é", 8000))
      |> put_in(["agent_goal", "text"], String.duplicate("é", 4000))
      |> put_in(["agent_outbox", Access.at(0), "source_name"], String.duplicate("é", 8100))
      |> put_in(["agent_outbox", Access.at(0), "text"], String.duplicate("é", 4000))

    assert :ok = Persistence.put(owner, boundary)
    Persistence.close(owner)
    {owner, records} = open_when_released(c.root)
    assert records[record["id"]] == boundary
    Persistence.close(owner)
  end

  defp hierarchy_chat do
    id = Persistence.session_conversation_id(@project, @task, "pr:7", @fingerprint)
    parent = Persistence.conversation_id(@project, @task, @fingerprint)

    event = %{
      "id" => @message_id,
      "source_id" => id,
      "target_id" => parent,
      "root" => @root_id,
      "root_chat" => parent,
      "text" => "Checks passed",
      "source_name" => "README feature agent",
      "kind" => "report",
      "status" => "pending",
      "depth" => 1,
      "created_at" => @now
    }

    entry = %{
      "id" => @message_id,
      "role" => "user",
      "text" => "Review the failing check",
      "status" => "queued",
      "widgets" => [],
      "origin" => "agent_message",
      "source_agent" => parent,
      "source_name" => "Documentation task agent",
      "agent_root" => @root_id,
      "agent_root_chat" => parent,
      "agent_kind" => "instruction",
      "agent_depth" => 1,
      "created_at" => @now,
      "client_id" => "coordination-1",
      "view_context" => nil
    }

    %{
      "id" => id,
      "project_id" => @project,
      "task_id" => @task,
      "conversation_role" => "pr",
      "session_id" => "pr:7",
      "agent_session_id" => @work_session,
      "agent_name" => "README",
      "parent_id" => parent,
      "alias_of" => Persistence.session_conversation_id(@project, @task, @work_session, @fingerprint),
      "agent_goal" => %{"text" => "Verify the README update", "status" => "active", "set_by" => parent, "updated_at" => @now},
      "agent_chains" => %{@root_id => 24},
      "agent_outbox" => [event, %{event | "id" => String.duplicate("d", 32), "kind" => "instruction", "status" => "delivered", "depth" => 6}],
      "title" => "PR #7",
      "tracker_fingerprint" => @fingerprint,
      "runtime_identity" => "runtime",
      "updated_at" => @now,
      "archived" => false,
      "status" => "idle",
      "context" => [],
      "client_ids" => [],
      "messages" => [%{entry | "status" => "completed", "agent_kind" => "report", "agent_depth" => 6}],
      "queue" => [entry],
      "proposals" => []
    }
  end

  defp assert_rejected_records(root, good, invalid) do
    assert {:ok, owner, %{}} = Persistence.open(root)
    assert :ok = Persistence.put(owner, good)
    path = record_path(root, good)
    original = File.read!(path)

    for record <- invalid do
      assert {:error, :chat_storage_unavailable} = Persistence.put(owner, record)
      assert File.read!(path) == original
    end

    Persistence.close(owner)

    for record <- invalid do
      bytes = Jason.encode!(record)
      File.write!(path, bytes)
      assert_unavailable_after_release(root)
      assert File.read!(path) == bytes
    end

    File.write!(path, original)
    {owner, records} = open_when_released(root)
    assert records == %{good["id"] => good}
    Persistence.close(owner)
  end

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
