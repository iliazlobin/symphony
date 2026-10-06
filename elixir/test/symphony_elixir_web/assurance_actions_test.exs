defmodule SymphonyElixirWeb.AssuranceActionsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Assurance.Contract
  alias SymphonyElixirWeb.AssuranceActions

  @project "github:owner/repo"
  @task "github:owner/repo:1"
  @sha String.duplicate("a", 40)
  @digest "sha256:" <> String.duplicate("b", 64)

  test "small forms create, edit and remove a requirement and preserve linked criterion IDs" do
    {document, board, req, criterion} = linked_document()
    assert {:ok, edited} = AssuranceActions.edit(document, "save-requirement", %{"id" => req["id"], "title" => "A revised outcome", "kind" => "nonfunctional"}, board)
    assert hd(edited["requirements"])["criteria"] == [criterion]
    assert edited["task_links"] == document["task_links"]

    assert {:ok, edited} =
             AssuranceActions.edit(
               edited,
               "save-criterion",
               %{"requirement_id" => req["id"], "id" => criterion["id"], "text" => "New observable behavior", "required_checks" => "integration (macos, 3.10)\nsecurity"},
               board
             )

    assert hd(hd(edited["requirements"])["criteria"])["required_checks"] == ["integration (macos, 3.10)", "security"]
    assert {:ok, removed} = AssuranceActions.edit(edited, "remove-criterion", %{"requirement_id" => req["id"], "id" => criterion["id"]}, board)
    assert removed["task_links"] == []
    assert {:ok, blank} = AssuranceActions.edit(document, "remove-requirement", %{"id" => req["id"]}, board)
    assert blank["requirements"] == [] and blank["task_links"] == []
  end

  test "task links capture trusted planning revisions and ignore supplied subject/revision" do
    {document, board, _req, criterion} = linked_document()
    assert hd(document["task_links"])["subject"] == nil
    subject = %{"kind" => "source", "repository" => "owner/repo", "revision" => @sha, "artifact_digest" => nil, "environment" => nil, "configuration_ref" => nil, "pr_number" => nil}
    board = Map.put(board, :assurance_observations, %{"tasks" => [%{"id" => @task, "revision" => "updated-2", "subject" => subject}], "evidence" => []})
    params = %{"task_id" => @task, "criterion_id" => criterion["id"], "task_revision" => "forged", "subject" => %{}}
    assert {:ok, refreshed} = AssuranceActions.edit(document, "link-task", params, board)
    assert refreshed["task_links"] == [%{"task_id" => @task, "criterion_id" => criterion["id"], "task_revision" => "updated-2", "subject" => subject}]
  end

  test "unknown, cross-project and unobserved task IDs cannot enter the draft" do
    {document, board, req, criterion} = linked_document()

    for id <- ["missing", "github:other/repo:1"] do
      assert {:error, :unknown_assurance_task} = AssuranceActions.edit(document, "link-task", %{"task_id" => id, "criterion_id" => criterion["id"]}, board)
    end

    assert {:error, :assurance_task_unobserved} = AssuranceActions.edit(document, "link-task", %{"task_id" => @task, "criterion_id" => criterion["id"]}, Map.delete(board, :assurance_observations))
    assert {:error, :unknown_assurance_requirement} = AssuranceActions.edit(document, "save-requirement", %{"id" => "missing", "title" => "x"}, board)
    assert {:error, :unknown_assurance_criterion} = AssuranceActions.edit(document, "save-criterion", %{"requirement_id" => req["id"], "id" => "bad"}, board)
    assert {:error, :invalid_assurance_document} = AssuranceActions.edit(document, "save-requirement", %{"title" => "x", "kind" => "arbitrary"}, board)
  end

  test "release form requires controlled linked tasks and exact immutable identifiers" do
    {document, board, _req, _criterion} = linked_document()

    params = %{
      "id" => "release-1",
      "baseline_ref" => String.duplicate("c", 64),
      "task_ids" => @task,
      "integrated_sha" => @sha,
      "artifact_digest" => @digest,
      "target" => "staging",
      "configuration_ref" => "config-1",
      "required_checks" => "integration\nsecurity",
      "required_gates" => "deployment\nruntime"
    }

    assert {:ok, release} = AssuranceActions.release(document, params, board)
    assert release["task_ids"] == [@task] and release["evidence_ids"] == []
    assert {:error, :invalid_assurance_release} = AssuranceActions.release(document, Map.put(params, "integrated_sha", "main"), board)
    assert {:error, :unknown_assurance_task} = AssuranceActions.release(document, Map.put(params, "task_ids", "missing"), board)
    assert {:error, :unknown_assurance_evidence} = AssuranceActions.release(document, Map.put(params, "evidence_ids", "claimed"), board)
  end

  test "revision fields reject malformed values and conflicts explain recovery" do
    assert {:ok, 9} = AssuranceActions.expected_revision(%{"storage_revision" => "9"})

    for params <- [%{}, %{"storage_revision" => "-1"}, %{"storage_revision" => "1x"}, %{"storage_revision" => 1}] do
      assert {:error, :invalid_assurance_revision} = AssuranceActions.expected_revision(params)
    end

    assert AssuranceActions.error_message(:stale_assurance_revision) =~ "another session"
  end

  test "malformed edits and missing criterion parents fail without changing the draft" do
    {document, board, requirement, _criterion} = linked_document()
    assert {:error, :invalid_assurance_document} = AssuranceActions.edit(nil, "save-requirement", %{}, board)
    assert {:error, :invalid_assurance_document} = AssuranceActions.edit(document, "save-requirement", nil, board)

    assert {:error, :unknown_assurance_requirement} =
             AssuranceActions.edit(document, "remove-criterion", %{"requirement_id" => "removed", "id" => "criterion"}, board)

    assert {:error, :unknown_assurance_criterion} =
             AssuranceActions.edit(document, "remove-criterion", %{"requirement_id" => requirement["id"], "id" => "removed"}, board)

    assert length(document["requirements"]) == 1
    assert length(hd(document["requirements"])["criteria"]) == 1
    assert length(document["task_links"]) == 1
  end

  test "list-valued form checks retain exact names while dropping malformed and duplicate entries" do
    {document, board, requirement, criterion} = linked_document()

    fields = %{
      "requirement_id" => requirement["id"],
      "criterion_id" => criterion["id"],
      "text" => criterion["text"],
      "required_checks" => [" security ", nil, 17, "", "security", "integration (macos, 3.10)"]
    }

    assert {:ok, edited} = AssuranceActions.edit(document, "save-criterion", fields, board)
    assert hd(hd(edited["requirements"])["criteria"])["required_checks"] == ["security", "integration (macos, 3.10)"]
    assert edited["task_links"] == document["task_links"]
  end

  test "prerequisite annotations cannot invent edges, cross projects or change scheduling" do
    {document, original, _req, _criterion} = linked_document()
    prerequisite = @project <> ":2"

    graph = %{
      "version" => 1,
      "nodes" => [%{"id" => "task-a", "task_id" => @task}, %{"id" => "task-b", "task_id" => prerequisite}],
      "edges" => [%{"id" => "declared", "type" => "depends_on", "source" => "task-a", "target" => "task-b", "blocking" => true, "reason" => "Needs the contract"}]
    }

    ref = String.duplicate("c", 64)
    board = original |> Map.put(:workflow_graph, graph) |> Map.put(:assurance_baselines, [%{"ref" => ref}]) |> Map.update!(:tasks, &(&1 ++ [%{id: prerequisite, project: @project}]))

    params = %{
      "task_id" => @task,
      "depends_on" => prerequisite,
      "reason" => "Consumers need the agreed schema",
      "output" => "Reviewed API schema",
      "reviewed_ref" => ref,
      "blocking" => false,
      "source" => "forged",
      "status" => "satisfied"
    }

    assert {:ok, edited} = AssuranceActions.edit(document, "save-dependency", params, board)
    assert edited["dependencies"] == [Map.take(params, ~w(task_id depends_on reason output reviewed_ref))]
    assert board.workflow_graph == graph and edited["task_links"] == document["task_links"]
    assert {:error, :unknown_assurance_dependency} = AssuranceActions.edit(document, "save-dependency", Map.merge(params, %{"task_id" => prerequisite, "depends_on" => @task}), board)
    assert {:error, :unknown_assurance_task} = AssuranceActions.edit(document, "save-dependency", Map.put(params, "depends_on", "github:other/repo:2"), board)
    assert {:error, :unknown_assurance_dependency_review} = AssuranceActions.edit(document, "save-dependency", Map.put(params, "reviewed_ref", String.duplicate("d", 64)), board)
    assert {:error, :unknown_assurance_task} = AssuranceActions.edit(document, "save-dependency", params, Map.put(board, :source_error, "Unavailable"))
    assert {:ok, revised} = AssuranceActions.edit(edited, "save-dependency", Map.put(params, "output", "Reviewed schema at revision two"), board)
    assert length(revised["dependencies"]) == 1
    assert hd(revised["dependencies"])["output"] == "Reviewed schema at revision two"
    removed_edge = Map.put(board, :workflow_graph, Map.put(graph, "edges", []))
    assert {:error, :unknown_assurance_dependency} = AssuranceActions.edit(revised, "save-dependency", params, removed_edge)
    assert {:ok, cleaned} = AssuranceActions.edit(revised, "remove-dependency", params, removed_edge)
    assert cleaned["dependencies"] == [] and removed_edge.workflow_graph["edges"] == []
  end

  defp linked_document do
    board = %{
      tasks: [%{id: @task, project: @project, title: "Reset tokens", identifier: "GH-1"}],
      assurance_observations: %{"tasks" => [%{"id" => @task, "revision" => "updated-1", "subject" => nil}], "evidence" => []}
    }

    assert {:ok, document} = AssuranceActions.edit(Contract.document(@project), "save-requirement", %{"title" => "Reject expired tokens", "kind" => "functional"}, board)
    req = hd(document["requirements"])

    assert {:ok, document} =
             AssuranceActions.edit(
               document,
               "save-criterion",
               %{"requirement_id" => req["id"], "text" => "Expired token leaves the password unchanged", "required_checks" => "reset-token\nreset-token\nsecurity"},
               board
             )

    criterion = hd(hd(document["requirements"])["criteria"])
    assert criterion["required_checks"] == ["reset-token", "security"]
    assert {:ok, document} = AssuranceActions.edit(document, "link-task", %{"task_id" => @task, "criterion_id" => criterion["id"]}, board)
    {document, board, req, criterion}
  end
end
