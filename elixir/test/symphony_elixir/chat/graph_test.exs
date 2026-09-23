defmodule SymphonyElixir.Chat.GraphTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Chat.{Graph, Persistence}

  test "exports a serializable three-layer hierarchy without private conversation content" do
    [project, task, feature] = hierarchy()
    goal = %{"text" => "Ship the documented command", "status" => "active", "updated_at" => "2026-09-23T12:00:00Z"}
    feature = Map.merge(feature, %{"agent_goal" => goal, "pr_number" => 7, "status" => "running"})
    graph = Graph.export([project, task, feature])

    assert graph["version"] == 1
    assert length(graph["nodes"]) == 3
    assert length(graph["edges"]) == 4
    assert Enum.sort(Enum.map(graph["nodes"], & &1["role"])) == ["feature", "project", "task"]
    assert node(graph, project)["name"] == "Example project agent"
    assert node(graph, task)["name"] == "Document tests task agent"

    assert %{
             "name" => "README feature agent",
             "conversation_id" => id,
             "parent_id" => parent,
             "work_id" => work_id,
             "pr_number" => 7,
             "status" => "running",
             "goal" => ^goal,
             "aliases" => []
           } = node(graph, feature)

    assert id == feature["id"]
    assert parent == Graph.node_id(task["id"])
    assert work_id == String.duplicate("a", 32)
    assert node(graph, project)["parent_id"] == nil
    assert Jason.decode!(Jason.encode!(graph)) == graph
    refute Jason.encode!(graph) =~ "private-secret"

    ranks = %{"project" => 0, "task" => 1, "feature" => 2}
    roles = Map.new(graph["nodes"], &{&1["id"], &1["role"]})

    for edge <- graph["edges"], edge["type"] == "supervises" do
      assert ranks[roles[edge["target"]]] == ranks[roles[edge["source"]]] + 1
    end
  end

  test "identity and ordering survive serialization, input order and name or status changes" do
    records = hierarchy()
    graph = Graph.export(records)
    assert Graph.export(Enum.reverse(records)) == graph
    assert Graph.export(Map.new(records, &{&1["id"], &1})) == graph
    assert Graph.export(Jason.decode!(Jason.encode!(records))) == graph

    changed = Enum.map(records, &Map.merge(&1, %{"agent_name" => "Renamed", "status" => "idle"}))
    next = Graph.export(changed)
    assert Enum.map(next["nodes"], & &1["id"]) == Enum.map(graph["nodes"], & &1["id"])
    assert next["edges"] == graph["edges"]
  end

  test "routes only to adjacent parent or child agents, never peers or a skipped layer" do
    [project, task, feature] = hierarchy()
    other_task = chat("task", "github:example/repo", "scope", "github:example/repo:2")
    records = [project, task, feature, other_task]

    assert Graph.relationship(records, project["id"], task["id"]) == {:ok, :supervises}
    assert Graph.relationship(records, task["id"], feature["id"]) == {:ok, :supervises}
    assert Graph.relationship(records, feature["id"], task["id"]) == {:ok, :reports_to}
    assert Graph.relationship(records, task["id"], project["id"]) == {:ok, :reports_to}

    for {source, target} <- [{project, feature}, {task, other_task}, {feature, other_task}, {task, task}] do
      assert Graph.relationship(records, source["id"], target["id"]) == {:error, :not_related}
    end

    assert Graph.relationship(records, project["id"], String.duplicate("f", 32)) == {:error, :not_related}
  end

  test "scope, role and task identity fence parents even with explicit parent IDs" do
    [project, task, feature] = hierarchy()
    foreign = chat("main", "github:other/repo", "scope")
    rotated = chat("task", project["project_id"], "rotated", task["task_id"])
    rejected_task = Map.put(task, "parent_id", foreign["id"])
    rejected_feature = Map.put(feature, "parent_id", project["id"])
    graph = Graph.export([project, foreign, rejected_task, rejected_feature, rotated])
    assert graph["edges"] == []
    assert Enum.all?(graph["nodes"], &is_nil(&1["parent_id"]))

    scoped = Graph.export([project, task, feature, rotated])
    assert length(scoped["edges"]) == 4
    assert node(scoped, rotated)["parent_id"] == nil
  end

  test "missing or ambiguous parents do not produce synthetic nodes or inferred authority" do
    [_project, task, feature] = hierarchy()
    assert %{"nodes" => [_], "edges" => []} = Graph.export([feature])
    other_parent = Map.put(task, "id", String.duplicate("e", 32))
    graph = Graph.export([task, other_parent, feature])
    assert graph["edges"] == []
    assert length(graph["nodes"]) == 3

    assert Graph.export([task, Map.put(task, "agent_name", "Conflict"), feature]) == Graph.export([feature])
    assert Graph.export([task, task, feature]) == Graph.export([task, feature])
  end

  test "historical aliases stay attached to one feature node without adopting a worker" do
    [project, task, native] = hierarchy()
    discussion = chat("pr", project["project_id"], "scope", task["task_id"], "pr:7")
    alias_record = Map.put(discussion, "alias_of", native["id"])
    foreign_alias = chat("pr", project["project_id"], "rotated", task["task_id"], "pr:7") |> Map.put("alias_of", native["id"])
    records = [project, task, native, alias_record, foreign_alias]
    graph = Graph.export(records)

    assert length(graph["nodes"]) == 3
    assert node(graph, native)["aliases"] == [discussion["id"]]
    assert {:error, :not_related} = Graph.relationship(records, task["id"], alias_record["id"])

    # A PR number or an arbitrary work field cannot replace the retained identity.
    discussion = Map.put(discussion, "work_id", native["session_id"])
    only_discussion = Graph.export([discussion])
    assert node(only_discussion, discussion)["work_id"] == nil
    assert node(only_discussion, discussion)["pr_number"] == 7
  end

  test "a verified host association keeps the original PR conversation identity after publication" do
    [project, task, native] = hierarchy()
    discussion = chat("pr", project["project_id"], "scope", task["task_id"], "pr:7")
    associated = Map.put(discussion, "agent_session_id", native["session_id"])
    graph = Graph.export([project, task, associated])
    feature = node(graph, associated)

    assert feature["id"] == Graph.node_id(discussion["id"])
    assert feature["session_id"] == "pr:7"
    assert feature["agent_session_id"] == native["session_id"]
    assert feature["work_id"] == String.duplicate("a", 32)
    assert feature["pr_number"] == 7

    for invalid <- ["work:../escape", "work:", 42, nil] do
      record = Map.put(discussion, "agent_session_id", invalid)
      feature = node(Graph.export([record]), record)
      assert feature["agent_session_id"] == "pr:7"
      assert feature["work_id"] == nil
    end
  end

  test "shared PR references point to one feature without giving other tasks supervision or reports" do
    [project, owner, feature] = hierarchy()
    linked = chat("task", project["project_id"], "scope", project["project_id"] <> ":2")
    rotated = chat("task", project["project_id"], "rotated", project["project_id"] <> ":3")
    foreign = chat("task", "github:other/repo", "scope", "github:other/repo:4")
    missing = project["project_id"] <> ":5"
    feature = Map.put(feature, "agent_task_refs", [owner["task_id"], linked["task_id"], linked["task_id"], rotated["task_id"], foreign["task_id"], missing, nil])
    records = [project, owner, feature, linked, rotated, foreign]
    graph = Graph.export(records)
    references = Enum.filter(graph["edges"], &(&1["type"] == "references"))

    assert [%{"source" => source, "target" => target}] = references
    assert source == Graph.node_id(linked["id"])
    assert target == Graph.node_id(feature["id"])
    assert node(graph, feature)["parent_id"] == Graph.node_id(owner["id"])
    assert Graph.relationship(records, owner["id"], feature["id"]) == {:ok, :supervises}
    assert Graph.relationship(records, feature["id"], owner["id"]) == {:ok, :reports_to}
    assert Graph.relationship(records, linked["id"], feature["id"]) == {:error, :not_related}
    assert Graph.relationship(records, feature["id"], linked["id"]) == {:error, :not_related}
    assert Graph.export(Enum.reverse(records)) == graph
    assert Jason.decode!(Jason.encode!(graph)) == graph

    # Invalid metadata and ambiguous task identities cannot create reference edges.
    for invalid <- [nil, %{}, linked["task_id"]] do
      invalid_records = [project, owner, linked, Map.put(feature, "agent_task_refs", invalid)]
      refute Enum.any?(Graph.export(invalid_records)["edges"], &(&1["type"] == "references"))
    end

    ambiguous = Map.put(linked, "id", String.duplicate("e", 32))
    refute Enum.any?(Graph.export([ambiguous | records])["edges"], &(&1["type"] == "references"))
  end

  test "cross-task aliases require the same verified PR and scope before contributing pending deliveries" do
    [project, owner, feature] = hierarchy()
    feature = Map.merge(feature, %{"pr_number" => 7, "agent_outbox" => [%{"status" => "pending"}]})
    linked_task = project["project_id"] <> ":2"

    verified =
      chat("pr", project["project_id"], "scope", linked_task, "pr:7")
      |> Map.merge(%{"alias_of" => feature["id"], "pr_number" => 7, "agent_outbox" => [%{"status" => "pending"}, %{"status" => "delivered"}]})

    legacy = chat("pr", project["project_id"], "scope", owner["task_id"], "pr:7") |> Map.put("alias_of", feature["id"])
    records = [project, owner, feature, verified, legacy]
    result = node(Graph.export(records), feature)
    assert result["aliases"] == Enum.sort([verified["id"], legacy["id"]])
    assert result["pending_deliveries"] == 2

    for invalid <- [nil, 0, "7", 8] do
      rejected = Map.put(verified, "pr_number", invalid)
      result = node(Graph.export([project, owner, feature, rejected, legacy]), feature)
      assert result["aliases"] == [legacy["id"]]
      assert result["pending_deliveries"] == 1
    end

    # A PR-shaped session ID does not prove that the canonical conversation was verified.
    unverified_feature = Map.delete(feature, "pr_number")
    result = node(Graph.export([unverified_feature, verified, legacy]), unverified_feature)
    assert result["aliases"] == [legacy["id"]]
    assert result["pending_deliveries"] == 1

    for {other_project, scope} <- [{project["project_id"], "rotated"}, {"github:other/repo", "scope"}] do
      foreign =
        chat("pr", other_project, scope, other_project <> ":2", "pr:7")
        |> Map.merge(%{"alias_of" => feature["id"], "pr_number" => 7, "agent_outbox" => [%{"status" => "pending"}]})

      result = node(Graph.export([feature, foreign]), feature)
      assert result["aliases"] == []
      assert result["pending_deliveries"] == 1
    end
  end

  test "ignores non-agent records and invalid task or session bindings" do
    [project, task, feature] = hierarchy()

    invalid = [
      nil,
      Map.put(project, "conversation_role", "legacy"),
      Map.put(project, "kind", "board_action"),
      Map.put(task, "task_id", "github:other/repo:1"),
      Map.put(project, "session_id", "pr:7"),
      Map.put(feature, "session_id", "pr:../7"),
      Map.put(task, "tracker_fingerprint", ""),
      Map.put(task, "id", "invalid")
    ]

    assert Graph.export(invalid) == %{"version" => 1, "nodes" => [], "edges" => []}
  end

  test "preserves archived agents and supplies stable fallback names for older records" do
    [project, task, native] = hierarchy() |> Enum.map(&Map.delete(&1, "agent_name"))
    task = Map.put(task, "archived", true)
    graph = Graph.export([project, task, native])
    assert node(graph, task)["archived"]
    assert node(graph, task)["name"] == "Document tests task agent"
    assert node(graph, project)["name"] == "github:example/repo project agent"
    assert node(graph, native)["pr_number"] == nil
    assert node(graph, native)["goal"] == nil
  end

  defp node(graph, chat), do: Enum.find(graph["nodes"], &(&1["conversation_id"] == chat["id"]))

  defp hierarchy do
    project = "github:example/repo"
    task = project <> ":1"

    [
      chat("main", project, "scope") |> Map.put("agent_name", "Example"),
      chat("task", project, "scope", task) |> Map.merge(%{"agent_name" => "Document tests", "title" => "Document tests"}),
      chat("pr", project, "scope", task, "work:" <> String.duplicate("a", 32)) |> Map.put("agent_name", "README")
    ]
  end

  defp chat(role, project, fingerprint, task \\ nil, session \\ nil) do
    id =
      if session do
        Persistence.session_conversation_id(project, task, session, fingerprint)
      else
        Persistence.conversation_id(project, task, fingerprint)
      end

    %{
      "id" => id,
      "conversation_role" => role,
      "project_id" => project,
      "tracker_fingerprint" => fingerprint,
      "task_id" => task,
      "session_id" => session,
      "title" => "Older conversation",
      "status" => "idle",
      "archived" => false,
      "messages" => [%{"text" => "private-secret"}],
      "runtime_identity" => "private-secret",
      "codex_thread_id" => "private-secret"
    }
  end
end
