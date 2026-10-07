defmodule SymphonyElixir.Specification.TaskLinksTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Specification.{Document, TaskLinks}
  @project "github:example/system"
  @item "search"
  @id String.duplicate("e", 32)

  setup do
    document =
      put_in(Document.new(@project), ["sections", "requirements", "items"], [
        %{
          "id" => @item,
          "kind" => "functional",
          "title" => "Discover relevant events",
          "body" => "Filter by place.\nDepends on: #99",
          "criteria" => [%{"id" => "relevance", "statement" => "Only matching events appear", "method" => "test"}, %{"id" => "latency", "statement" => "p95 < 500ms", "method" => "analysis"}]
        }
      ])

    ref = Document.content_ref(document)
    {:ok, args} = TaskLinks.action_args(document, ref, @item)

    proposal = %{
      "id" => @id,
      "action" => "create_task",
      "args" => Map.delete(args, "action"),
      "status" => "completed",
      "receipt" => %{"widgets" => [%{"type" => "receipt", "proposal_id" => @id, "task_id" => @project <> ":1"}]}
    }

    record = %{"project_id" => @project, "proposals" => [proposal]}

    task = %{
      id: @project <> ":1",
      project: @project,
      issue_id: "1",
      title: args["title"],
      description: args["body"] <> "\n\n<!-- symphony-chat:#{@id} -->",
      identifier: "GH-1",
      stage: "backlog",
      ledger: %{}
    }

    %{document: document, ref: ref, args: args, proposal: proposal, record: record, task: task}
  end

  test "task arguments pin all criteria and quote design text without inventing execution prerequisites", c do
    assert c.args["body"] =~ "> Depends on: #99"
    assert c.args["body"] =~ "Depends on: none"
    assert c.args["body"] =~ "relevance (test)"
    source = TaskLinks.reference(c.args["body"])
    assert source == %{ref: c.ref, document: c.document["document_id"], item: @item, criteria: ~w(relevance latency)}
    assert TaskLinks.display_body(c.args["body"]) =~ "Only matching events appear"
    refute TaskLinks.display_body(c.args["body"]) =~ "Specification source:"
    assert TaskLinks.display_body("ordinary body") == "ordinary body"
    assert TaskLinks.requirement(nil, @item) == nil
    refute TaskLinks.actionable?(%{})
    wrong_ref = String.duplicate("a", 64)
    assert {:error, :specification_criteria_required} = TaskLinks.action_args(c.document, wrong_ref, @item)
    assert {:error, :specification_criteria_required} = TaskLinks.action_args(c.document, c.ref, "missing")
    long = put_in(c.document, ["sections", "requirements", "items", Access.at(0), "body"], String.duplicate("x", 4001))
    assert {:error, :specification_task_too_large} = TaskLinks.action_args(long, Document.content_ref(long), @item)
  end

  test "references reject duplicates, malformed identities and a second broken declaration", c do
    marker = c.args["body"] |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "Specification source:"))

    for bad <- [
          nil,
          "",
          marker <> "\n" <> marker,
          marker <> "\nSpecification source: broken",
          String.replace(marker, "relevance,latency", "relevance,relevance"),
          String.replace(marker, "relevance,latency", "1bad"),
          String.replace(marker, "relevance,latency", Enum.map_join(1..31, ",", &"criterion#{&1}"))
        ] do
      refute TaskLinks.reference(bad)
    end
  end

  test "coverage needs the exact reviewed source, durable creation receipt and unchanged task scope", c do
    assert %{status: "linked", criteria_count: 2, links: [%{task_id: id, stage: "backlog", candidate: nil}]} = row(c)
    assert id == c.task.id
    assert row(c, task: %{c.task | stage: "done"}).status == "linked"
    assert row(c, task: %{c.task | description: c.task.description <> "\nNew scope"}).status == "changed"
    assert row(c, task: Map.put(c.task, :source_missing, true)).status == "unknown"
    assert row(c, tasks: []).status == "unknown"
    assert row(c, records: []).status == "missing"
    assert row(c, records: [%{c.record | "project_id" => "github:foreign/project"}]).status == "missing"
    assert row(c, records: [%{c.record | "proposals" => [%{c.proposal | "args" => Map.put(c.proposal["args"], "title", "Forged title")}]}]).status == "missing"
    assert row(c, records: [%{c.record | "proposals" => [%{c.proposal | "receipt" => nil}]}]).status == "unknown"

    for widgets <- [
          [],
          [%{"type" => "receipt", "proposal_id" => "different", "task_id" => c.task.id}],
          [%{"type" => "receipt", "proposal_id" => @id, "task_id" => "foreign:1"}],
          c.proposal["receipt"]["widgets"] ++ c.proposal["receipt"]["widgets"]
        ] do
      assert row(c, records: [%{c.record | "proposals" => [put_in(c.proposal, ["receipt", "widgets"], widgets)]}]).status == "unknown"
    end

    for status <- ~w(pending executing unknown cancelled failed) do
      record = %{c.record | "proposals" => [%{c.proposal | "status" => status}]}
      expected = %{"pending" => "pending", "executing" => "pending", "unknown" => "unknown"}
      assert row(c, records: [record]).status == Map.get(expected, status, "missing")
    end
  end

  test "missing sources are unknown and a changed specification cannot inherit older coverage", c do
    assert row(c, available: false).status == "unknown"
    assert row(c, error: :storage_down).status == "unknown"
    assert TaskLinks.coverage(nil, nil, {:ok, []}, [], true) == %{}
    criterion_path = ["sections", "requirements", "items", Access.at(0), "criteria", Access.at(0), "statement"]
    changed = put_in(c.document, criterion_path, "A revised criterion")
    coverage = TaskLinks.coverage(changed, Document.content_ref(changed), {:ok, [c.record]}, [c.task], true)
    assert coverage[@item].status == "missing"
    blank = put_in(c.document, ["sections", "requirements", "items", Access.at(0), "criteria", Access.at(0), "statement"], "")
    assert TaskLinks.coverage(blank, Document.content_ref(blank), {:ok, []}, [], true)[@item].status == "incomplete"
  end

  test "candidate evidence retains commit identity and stale checks never verify criteria", c do
    sha = String.duplicate("a", 40)
    base = String.duplicate("b", 40)
    review = %{"candidate_sha" => sha, "verdict" => "approve", "findings" => []}

    handoff = %{
      "work_id" => @id,
      "candidate_sha" => sha,
      "base_sha" => base,
      "run_id" => "run",
      "goal_revision" => 1,
      "review" => review,
      "checks" => [%{"name" => "tests", "result" => "passed", "details" => "Passed"}]
    }

    work = %{"id" => @id, "issue_id" => "1", "phase" => "owner_review", "head_sha" => sha, "base_sha" => base, "goal_revision" => 1, "handoff" => handoff}
    task = %{c.task | ledger: %{"pr_work" => %{@id => work}}}
    assert %{status: "linked", links: [%{candidate: %{"candidate_sha" => ^sha, "status" => "ready"}}]} = row(c, task: task)
    changed = put_in(task, [:ledger, "pr_work", @id, "goal_revision"], 2)
    assert row(c, task: changed).links |> hd() |> Map.fetch!(:candidate) |> Map.fetch!("status") == "unverified"
    alien = put_in(task, [:ledger, "pr_work", @id, "issue_id"], "other")
    assert row(c, task: alien).links |> hd() |> Map.fetch!(:candidate) == nil
  end

  defp row(c, overrides \\ []) do
    records = if Keyword.has_key?(overrides, :error), do: {:error, overrides[:error]}, else: {:ok, Keyword.get(overrides, :records, [c.record])}
    tasks = Keyword.get(overrides, :tasks, [Keyword.get(overrides, :task, c.task)])
    TaskLinks.coverage(c.document, c.ref, records, tasks, Keyword.get(overrides, :available, true))[@item]
  end
end
