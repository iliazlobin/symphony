defmodule SymphonyElixirWeb.AssuranceViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias SymphonyElixirWeb.AssuranceView

  @task "github:owner/repo:1"
  @ref String.duplicate("a", 64)

  test "draft forms fence every edit by storage revision and preserve selected task context" do
    html = render(snapshot(), selected_task_id: @task)
    assert length(find(html, "[phx-submit=assurance-save-requirement]")) == 2
    assert length(find(html, "[phx-submit=assurance-save-criterion]")) == 2
    assert Floki.attribute(find(html, "input[name=storage_revision]"), "value") |> Enum.all?(&(&1 == "7"))
    assert Floki.attribute(find(html, "[phx-submit=assurance-link-task] input[name=task_id]"), "value") == [@task]
    assert html =~ "Unverified" and html =~ "No candidate evidence yet"
    refute html =~ "Current evidence passed"
    refute find(html, "button") |> Floki.text() =~ "Deploy"
  end

  test "historical and read-only versions contain no mutation forms or removal controls" do
    snap = Map.put(snapshot(), "selected_baseline", %{"ref" => @ref, "document" => document()})

    for opts <- [[baseline_ref: @ref], [read_only: true]] do
      html = render(snap, opts)
      assert find(html, "form") == []
      assert find(html, "[phx-click=assurance-remove-requirement]") == []
      assert find(html, "[phx-click=assurance-unlink-task]") == []
    end
  end

  test "user content is escaped and manual passed claims remain unverified" do
    snap = put_in(snapshot(), ["draft", "requirements", Access.at(0), "title"], "<script>bad()</script>")

    snap =
      Map.put(snap, "evidence", [
        %{"id" => "claim", "check" => "reset", "result" => "passed", "origin" => "manual", "producer" => "operator", "run_id" => "manual-1", "observed_at" => "2026-10-04T01:00:00Z", "subject" => %{}}
      ])

    html = render(snap)
    assert find(html, "script") == []
    assert html =~ "&lt;script&gt;" and html =~ "Declaration · unverified" and html =~ "Unverified"
  end

  test "only current exact criterion evidence passes and gaps filter does not promise readiness" do
    criterion = hd(hd(document()["requirements"])["criteria"])
    current = Map.merge(criterion, %{"status" => "covered", "issues" => []})
    html = render(snapshot(), projection: %{"criteria" => [current], "observations_available" => true}, gaps_only: true)
    assert find(html, "[data-requirement-id]") == []
    assert html =~ "does not establish release readiness"
    unavailable = render(snapshot(), projection: %{"criteria" => [current], "observations_available" => false})
    refute unavailable =~ "Current evidence passed"
    changed = Map.put(current, "text", "Another criterion")
    html = render(snapshot(), projection: %{"criteria" => [changed], "observations_available" => true}, gaps_only: true)
    assert length(find(html, "[data-requirement-id]")) == 1
    refute html =~ "Current evidence passed"
  end

  test "version differences are bounded to forty and preserve slash-containing task links" do
    difference = %{
      "task_links" => %{"added" => Enum.map(1..55, &(@task <> "/crit-#{&1}")), "changed" => [], "removed" => []},
      "graph" => %{"nodes" => %{"added" => ["task:" <> @task], "changed" => [], "removed" => []}}
    }

    snap = put_in(snapshot(), ["draft", "task_links"], Enum.map(1..55, &%{"task_id" => @task, "criterion_id" => "crit-#{&1}"}))

    board = %{
      tasks: [%{id: @task, identifier: "GH-1", title: "Reset tokens"}],
      workflow_graph: %{"nodes" => [%{"id" => "task:" <> @task, "task_id" => @task, "identifier" => "GH-1", "title" => "Reset tokens"}]}
    }

    html = render(snap, tab: "versions", difference: difference, board: board)
    assert length(find(html, ".assurance-difference li")) == 40
    assert Floki.attribute(find(html, ".assurance-difference [phx-click=select-task]"), "phx-value-id") |> Enum.all?(&(&1 == @task))
    assert html =~ "Show graph" and html =~ "of 56"
    html = render(snap, tab: "versions", difference: difference, board: board, page: 1)
    assert length(find(html, ".assurance-difference li")) == 16
  end

  test "current draft evidence never verifies another baseline's linked subject" do
    criterion = hd(hd(document()["requirements"])["criteria"])
    current = Map.merge(criterion, %{"status" => "covered", "issues" => []})
    historical = put_in(document(), ["task_links", Access.at(0), "task_revision"], "previous-revision")
    snap = Map.put(snapshot(), "selected_baseline", %{"ref" => @ref, "document" => historical})
    html = render(snap, baseline_ref: @ref, projection: %{"criteria" => [current], "observations_available" => true})
    refute html =~ "Current evidence passed"
    assert html =~ "Current observed evidence unavailable"
  end

  test "map-backed history remains sorted and removed task links retain their crosslinks" do
    older = String.duplicate("b", 64)

    baselines = %{
      "older" => %{"ref" => older, "reviewed_at" => "2026-10-03T01:00:00Z"},
      "current" => %{"ref" => @ref, "reviewed_at" => "2026-10-04T01:00:00Z"}
    }

    removed = "github:owner/repo:removed"

    difference = %{
      "task_links" => %{"removed" => [removed <> "/crit-1"]},
      "dependencies" => %{"removed" => [removed <> "/github:owner/repo:2"]},
      "graph_unavailable" => true
    }

    old_doc = document() |> Map.put("task_links", [%{"task_id" => removed, "criterion_id" => "crit-1"}]) |> Map.put("dependencies", [%{"task_id" => removed, "depends_on" => "github:owner/repo:2"}])
    baselines = put_in(baselines, ["older", "document"], old_doc)
    difference = Map.put(difference, "compared_ref", older)
    html = render(Map.put(snapshot(), "baselines", baselines), tab: "versions", difference: difference, read_only: true)
    assert Floki.attribute(find(html, ".assurance-version [phx-click=assurance-select-baseline]"), "phx-value-ref") == [@ref, older]
    assert Floki.attribute(find(html, ".assurance-difference [phx-click=select-task]"), "phx-value-id") == [removed, removed]
    assert html =~ "Current graph comparison unavailable; showing draft scope changes."
    assert length(find(html, ".assurance-difference li")) == 2
    assert find(html, "form") == []
  end

  test "comparison labels use current records and the exact saved version for removed tasks and dependencies" do
    task2 = "github:owner/repo:2"
    task3 = "github:owner/repo:3"
    node = fn id, identifier, title -> %{"id" => "task:" <> id, "task_id" => id, "identifier" => identifier, "title" => title} end
    current_nodes = [node.(@task, "GH-1", "Current reset flow"), node.(task2, "GH-2", "<script>New contract</script>"), node.(task3, "GH-33", "Current renamed task")]
    old_nodes = [node.(@task, "GH-1", "Original reset flow"), node.(task3, "GH-3", "Original removed task")]
    edge = fn id, from -> %{"id" => id, "type" => "depends_on", "source" => "task:" <> @task, "target" => "task:" <> from} end
    old_doc = document() |> Map.put("dependencies", [%{"task_id" => @task, "depends_on" => task3}])
    current_doc = document() |> Map.put("dependencies", [%{"task_id" => @task, "depends_on" => task2}])
    older = String.duplicate("b", 64)
    saved = %{"ref" => older, "document" => old_doc, "graph_snapshot" => %{"graph" => %{"nodes" => old_nodes, "edges" => [edge.("removed-edge", task3)]}}}
    unrelated = %{"ref" => @ref, "graph_snapshot" => %{"graph" => %{"nodes" => [node.(task3, "GH-300", "Wrong version")], "edges" => []}}}
    snap = snapshot() |> Map.put("draft", current_doc) |> Map.put("baselines", [unrelated, saved])
    board = %{tasks: [], workflow_graph: %{"nodes" => current_nodes, "edges" => [edge.("added-edge", task2), edge.("changed-edge", task2)]}}

    difference = %{
      "compared_ref" => older,
      "requirements" => %{"changed" => ["req-1"], "removed" => ["req-1"]},
      "task_links" => %{"changed" => [@task <> "/crit-1"]},
      "dependencies" => %{"added" => [@task <> "/" <> task2], "removed" => [@task <> "/" <> task3]},
      "graph" => %{
        "nodes" => %{"added" => ["task:" <> task2], "changed" => ["task:" <> @task], "removed" => ["task:" <> task3]},
        "edges" => %{"added" => ["added-edge"], "changed" => ["changed-edge"], "removed" => ["removed-edge"]}
      }
    }

    html = render(snap, tab: "versions", board: board, difference: difference)
    text = find(html, ".assurance-difference li") |> Floki.text()
    assert text =~ "Added dependency GH-2 → GH-1"
    assert text =~ "Changed dependency GH-2 → GH-1"
    assert text =~ "Removed dependency GH-3 → GH-1"
    assert text =~ "Changed task GH-1 · Current reset flow"
    assert text =~ "Removed task GH-3 · Original removed task"
    assert text =~ "coverage GH-1 → Reject expired tokens"
    assert text =~ "prerequisite annotation GH-3 → GH-1"
    assert text =~ "requirement Reset password"
    refute text =~ "Wrong version" or text =~ "Current renamed task" or text =~ "graph.edges"
    assert html =~ "&lt;script&gt;New contract&lt;/script&gt;"
    assert find(html, "script") == []
    assert "removed-edge" in Floki.attribute(find(html, ".assurance-difference li"), "title")
  end

  test "unknown diff IDs remain hints and never imply task identities or dependency endpoints" do
    difference = %{
      "graph" => %{"nodes" => %{"added" => ["task:" <> @task]}, "edges" => %{"removed" => ["pretend-edge"]}},
      "requirements" => %{"changed" => ["missing-requirement"]},
      "task_links" => %{"added" => [@task <> "/unknown-criterion"]},
      "dependencies" => %{"added" => [@task <> "/pretend-prerequisite"]},
      "other" => %{"changed" => [123]}
    }

    html = render(snapshot(), tab: "versions", difference: difference)
    text = find(html, ".assurance-difference li") |> Floki.text()
    assert text =~ "Unavailable task" and text =~ "Unavailable dependency" and text =~ "Unavailable requirement"
    assert text =~ "Unavailable coverage link" and text =~ "Unavailable prerequisite annotation" and text =~ "Unavailable item"
    refute text =~ "pretend-edge" or text =~ "pretend-prerequisite" or text =~ "github:"
    assert find(html, ".assurance-difference [phx-click=select-task]") == []
    assert "123" in Floki.attribute(find(html, ".assurance-difference li"), "title")
  end

  test "excluded quality requirements remain explicit and read-only with map-backed criterion status" do
    snap = snapshot() |> put_in(["draft", "requirements", Access.at(0), "exclusion"], "Deferred performance target")
    snap = put_in(snap, ["draft", "requirements", Access.at(0), "kind"], "nonfunctional")
    criterion = hd(hd(document()["requirements"])["criteria"])
    status = Map.merge(criterion, %{"status" => "covered", "issues" => []})
    projection = %{"criteria" => %{"crit-1" => status}, "observations_available" => true}
    html = render(snap, projection: projection, read_only: true)
    assert html =~ "Excluded" and html =~ "Deferred performance target" and html =~ "Quality"
    assert find(html, "form") == []
    refute html =~ "Current evidence passed"
    assert render(snap, projection: projection, read_only: true, gaps_only: true) |> find("[data-requirement-id]") == []
  end

  test "partial candidate records and structured evidence gaps stay visibly unverified" do
    removed = "github:owner/repo:removed"
    record = %{"id" => "partial-candidate", "baseline_ref" => @ref, "integrated_sha" => nil, "task_ids" => [removed]}
    snap = Map.put(snapshot(), "releases", %{"partial-candidate" => %{"record" => record}})

    status = %{
      "issues" => [%{"message" => "Artifact producer unavailable"}, %{"reason" => "Receipt expired"}, %{"check" => "runtime-smoke"}, %{}, nil],
      "missing_checks" => [],
      "missing_gates" => [],
      "missing_criteria" => []
    }

    projection = %{"observations_available" => true, "release_readiness" => %{"partial-candidate" => status}}
    html = render(snap, tab: "releases", projection: projection, read_only: true)
    assert html =~ "Unavailable" and html =~ "Unverified"
    assert html =~ "Artifact producer unavailable" and html =~ "Receipt expired" and html =~ "runtime-smoke"
    assert length(find(html, ".assurance-release li")) == 5
    assert Enum.count(find(html, ".assurance-release li"), &(Floki.text([&1]) == "Evidence gap")) == 2
    assert Floki.attribute(find(html, ".assurance-release [phx-click=select-task]"), "phx-value-id") == [removed]
    assert find(html, "form") == []
    refute html =~ "Artifact checks passed"
  end

  test "release candidates show computed gaps and no deployment action" do
    record = %{
      "id" => "candidate-1",
      "baseline_ref" => @ref,
      "integrated_sha" => String.duplicate("b", 40),
      "artifact_digest" => "sha256:" <> String.duplicate("c", 64),
      "target" => "staging",
      "configuration_ref" => "config-1",
      "task_ids" => [@task]
    }

    snap = Map.put(snapshot(), "releases", [%{"record" => record}])

    projection = %{
      "observations_available" => true,
      "release_readiness" => [
        %{
          "id" => "candidate-1",
          "build_ready" => false,
          "deployment_recorded" => false,
          "runtime_verified" => false,
          "issues" => ["missing_artifact_receipt"],
          "missing_checks" => ["integration"],
          "missing_gates" => ["runtime"]
        }
      ]
    }

    html = render(snap, tab: "releases", projection: projection)
    assert html =~ "missing artifact receipt" and html =~ "integration"
    assert html =~ "Deployment: not observed" and html =~ "Runtime: unverified"
    assert find(html, "[phx-submit=assurance-record-release]") != []
    refute find(html, "button") |> Floki.text() =~ "Deploy"
  end

  test "the existing application stylesheet includes isolated assurance styles" do
    assert {:ok, "text/css", css} = SymphonyElixirWeb.StaticAssets.fetch("/dashboard.css")
    assert css =~ ".assurance-workspace" and css =~ ".assurance-fields"
  end

  test "selected prerequisite annotations use source rationale, reviewed references and bounded pages" do
    project = "github:owner/repo"
    prerequisites = Enum.map(2..46, &(project <> ":#{&1}"))
    task_ids = [@task | prerequisites]
    tasks = Enum.map(task_ids, &%{id: &1, project: project, title: "Task " <> &1})
    nodes = Enum.map(task_ids, &%{"id" => "task:" <> &1, "task_id" => &1})
    edges = Enum.map(prerequisites, &%{"type" => "depends_on", "source" => "task:" <> @task, "target" => "task:" <> &1, "reason" => "Needs a reviewed contract"})
    board = %{tasks: tasks, workflow_graph: %{"version" => 1, "nodes" => nodes, "edges" => edges}}
    snap = put_in(snapshot(), ["draft", "project"], project)
    html = render(snap, board: board, selected_task_id: @task)
    assert length(find(html, "form[phx-submit=assurance-save-dependency]")) == 40
    assert html =~ "Needs a reviewed contract" and html =~ "of 45"
    assert Floki.attribute(find(html, "form[phx-submit=assurance-save-dependency] input[name=storage_revision]"), "value") |> Enum.all?(&(&1 == "7"))
    assert Floki.attribute(find(html, "form[phx-submit=assurance-save-dependency] select[name=reviewed_ref] option"), "value") |> Enum.member?(@ref)
    next = render(snap, board: board, selected_task_id: @task, page: 1)
    assert length(find(next, "form[phx-submit=assurance-save-dependency]")) == 5
    readonly = render(snap, board: board, selected_task_id: @task, read_only: true)
    assert find(readonly, "form[phx-submit=assurance-save-dependency]") == []
    assert readonly =~ "Required output: Not recorded"
  end

  defp render(snap, opts \\ []) do
    render_component(&AssuranceView.content/1, Keyword.merge([snapshot: snap, board: %{tasks: [%{id: @task, identifier: "GH-1", title: "Reset tokens"}]}], opts))
  end

  defp snapshot,
    do: %{
      "storage_revision" => 7,
      "draft" => document(),
      "reviewed_ref" => @ref,
      "baselines" => [%{"ref" => @ref, "reviewed_at" => "2026-10-04T01:00:00Z", "graph_snapshot" => %{}}],
      "evidence" => [],
      "releases" => []
    }

  defp document,
    do: %{
      "requirements" => [
        %{
          "id" => "req-1",
          "title" => "Reset password",
          "kind" => "functional",
          "exclusion" => nil,
          "criteria" => [%{"id" => "crit-1", "text" => "Reject expired tokens", "required_checks" => ["reset"]}]
        }
      ],
      "task_links" => [%{"task_id" => @task, "criterion_id" => "crit-1", "task_revision" => "task-v1", "subject" => nil}],
      "dependencies" => []
    }

  defp find(html, selector), do: html |> Floki.parse_fragment!() |> Floki.find(selector)
end
