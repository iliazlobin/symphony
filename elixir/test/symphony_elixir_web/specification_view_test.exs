defmodule SymphonyElixirWeb.SpecificationViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixir.Specification.Document
  alias SymphonyElixirWeb.SpecificationView
  @project "github:example/system"

  test "new specifications retain the five-step vertical flow and use distinct project identities" do
    html = view_html()
    assert length(find(html, "[role=tab]")) == 5
    assert Floki.attribute(find(html, "[role=tablist]"), "aria-orientation") == ["vertical"]
    assert Floki.attribute(find(html, "[data-specification-project]"), "phx-hook") == ["SpecificationWorkspace"]
    assert Floki.attribute(find(html, "[role=tab][aria-selected=true]"), "tabindex") == ["0"]
    assert Floki.attribute(find(html, "[role=tab][aria-selected=false]"), "tabindex") == ["-1", "-1", "-1", "-1"]
    assert Floki.attribute(find(html, "[role=tabpanel]"), "aria-labelledby") == Floki.attribute(find(html, "[role=tab][aria-selected=true]"), "id")
    assert Floki.text(find(html, "[data-spec-status]")) == "Start a specification"
    assert find(html, "[phx-click=spec-review][disabled]") != []
    assert find(html, "[data-design-editor-js]") == []
    assert find(html, "[phx-click=spec-reload]") != []
    other = view_html(project: "github:example/other")
    refute Floki.attribute(find(html, "[data-specification-project]"), "id") == Floki.attribute(find(other, "[data-specification-project]"), "id")
    assert Floki.text(find(view_html(section: "unknown"), "[role=tab][aria-selected=true]")) =~ "Brief"
  end

  test "functional and nonfunctional requirements edit stable rows with exact CAS form context" do
    {:ok, document} = Document.add(Document.new(@project), "requirements", "items")
    [item] = document["sections"]["requirements"]["items"]
    html = view_html(section: "requirements", draft: document, state: %{"storage_revision" => 7, "draft" => document}, dirty: true)
    assert Floki.attribute(find(html, "form"), "phx-change") == ["spec-edit"]
    assert Floki.attribute(find(html, "form"), "phx-submit") == ["spec-save"]
    assert Floki.attribute(find(html, "input[name=storage_revision]"), "value") == ["7"]
    assert Floki.attribute(find(html, "input[name=document_id]"), "value") == [document["document_id"]]
    assert Floki.attribute(find(html, "select"), "name") == ["items[#{item["id"]}][kind]"]
    assert Floki.attribute(find(html, "option"), "value") == ~w(functional nonfunctional)
    assert Floki.text(find(html, "[data-spec-status]")) == "Unsaved changes"
    assert find(html, "[phx-click=spec-review][disabled]") != []
    assert find(html, "button[type=submit][disabled]") == []
  end

  test "criteria and coverage stay compact, source focused and separate from candidate verification" do
    document =
      put_in(Document.new(@project), ["sections", "requirements", "items"], [
        %{
          "id" => "search",
          "kind" => "functional",
          "title" => "Relevant search",
          "body" => "Filter results",
          "criteria" => [%{"id" => "relevance", "statement" => "Only matching places", "method" => "test"}]
        }
      ])

    ref = Document.content_ref(document)
    state = %{"storage_revision" => 2, "draft" => document, "reviewed" => %{"ref" => ref}}
    link = %{task_id: @project <> ":1", title: "GH-1", stage: "ready", status: "linked", candidate: %{"status" => "ready"}}
    coverage = %{"search" => %{status: "linked", criteria_count: 1, links: [link]}}
    html = view_html(section: "requirements", draft: document, state: state, coverage: coverage, focus_item: "search", task_url: "/?view=kanban&task=one")
    assert find(html, "[data-spec-focused=true]") != []
    assert Floki.text(find(html, "[data-spec-coverage]")) =~ "1 criterion linked"
    assert Floki.text(find(html, "[data-spec-coverage]")) =~ "criteria unverified"
    assert find(html, "[phx-click=spec-prepare-task][disabled]") == []
    assert find(html, ".specification-criterion textarea") != []
    assert Floki.text(find(html, ".specification-criterion select")) =~ "Analysis"
    assert find(html, "a[href='/\?view=kanban&task=one']") != []

    for status <- ~w(missing changed pending unknown incomplete) do
      coverage = %{"search" => %{status: status, criteria_count: 1, links: []}}
      rendered = view_html(section: "requirements", draft: document, state: state, coverage: coverage)
      refute Floki.text(find(rendered, "[data-spec-coverage]")) =~ "criterion linked"
    end

    for candidate <- [nil, %{"status" => "stale"}, %{"status" => "changes_requested"}], stage <- ~w(running backlog) do
      coverage = %{"search" => %{status: "linked", criteria_count: 2, links: [%{link | candidate: candidate, stage: stage}]}}
      rendered = view_html(section: "requirements", draft: document, state: state, coverage: coverage)

      assert Floki.text(find(rendered, "[data-spec-coverage]")) =~ "2 criteria linked"
    end

    pending = %{link | task_id: nil, stage: nil, status: "pending", candidate: nil} |> Map.put(:preview_id, "preview")
    coverage = %{"search" => %{status: "pending", criteria_count: 1, links: [pending]}}
    assert view_html(section: "requirements", draft: document, state: state, coverage: coverage) =~ "Open preview"

    changed = %{link | status: "changed"}
    coverage = %{"search" => %{status: "changed", criteria_count: 1, links: [changed]}}
    assert view_html(section: "requirements", draft: document, state: state, coverage: coverage) =~ "Compare task scope"
  end

  test "Mermaid source is escaped, retained and hooked into one isolated SVG preview" do
    {:ok, document} = Document.add(Document.new(@project), "data", "diagrams")
    source = "erDiagram\n  EVENT ||--o{ SAVED_CHOICE : saved\n<script>bad()</script>"
    document = put_in(document, ["sections", "data", "diagrams", Access.at(0), "source"], source)
    html = view_html(section: "data", draft: document)
    assert find(html, "script") == []
    assert Floki.text(find(html, "[data-spec-mermaid]")) == source
    assert length(find(html, "[phx-hook=SpecificationDiagram]")) == 1
    assert Floki.attribute(find(html, "[data-spec-preview]"), "phx-update") == ["ignore"]
    assert Floki.attribute(find(html, "[data-spec-feedback]"), "aria-live") == ["polite"]
    assert [url] = Floki.attribute(find(html, "[data-spec-renderer]"), "data-spec-renderer")
    assert url =~ "/specification/diagram-"
    assert length(find(html, "textarea[name$='[source]']")) == 1
  end

  test "every form control has stable identity within its document and a distinct section or history context" do
    {:ok, document} = Document.add(Document.new(@project), "brief", "items")
    {:ok, document} = Document.add(document, "brief", "diagrams")
    {:ok, document} = Document.add(document, "data", "items")
    html = view_html(draft: document, state: %{"draft" => document, "storage_revision" => 1})
    controls = find(html, "form input, form select, form textarea")
    ids = Floki.attribute(controls, "id")
    [form_id] = Floki.attribute(find(html, "form"), "id")
    assert length(controls) == 9
    assert length(ids) == length(controls)
    assert length(Enum.uniq(ids)) == length(ids)
    assert Enum.all?(ids, &String.starts_with?(&1, form_id <> "-"))

    changed = put_in(document, ["sections", "brief", "items", Access.at(0), "title"], "A changed title")
    updated = view_html(draft: changed, state: %{"draft" => document, "storage_revision" => 2}, dirty: true)
    assert Floki.attribute(find(updated, "form"), "id") == [form_id]
    assert Floki.attribute(find(updated, "form input, form select, form textarea"), "id") == ids
    assert Floki.attribute(find(updated, "input[name$='[title]']"), "value") == ["A changed title", ""]
    assert Floki.attribute(find(updated, "input[name=storage_revision]"), "value") == ["2"]

    contexts = [
      [draft: document, section: "data"],
      [draft: Map.put(document, "document_id", "spec-replacement")],
      [draft: document, project: "github:example/other"],
      [draft: document, history: true, viewed_ref: String.duplicate("a", 64)],
      [draft: document, history: true, viewed_ref: String.duplicate("b", 64)]
    ]

    context_ids =
      Enum.map(contexts, fn attrs ->
        rendered = view_html(attrs)
        [id] = Floki.attribute(find(rendered, "form"), "id")
        refute id == form_id
        assert MapSet.disjoint?(MapSet.new(ids), MapSet.new(Floki.attribute(find(rendered, "form input, form select, form textarea"), "id")))
        id
      end)

    assert length(Enum.uniq(context_ids)) == length(context_ids)
  end

  test "reviewed history renders read-only without exposing draft replacement or execution controls" do
    {:ok, document} = Document.add(Document.new(@project), "brief", "items")
    document = put_in(document, ["sections", "brief", "items", Access.at(0), "body"], "Reviewed brief")
    ref = Document.content_ref(document)
    record = %{"ref" => ref, "document_id" => document["document_id"], "reviewed_at" => "2026-10-04T00:00:00Z"}
    state = %{"draft" => document, "storage_revision" => 2, "reviewed" => record, "reviewed_versions" => [record]}
    html = view_html(state: state, draft: document, history: true, viewed_ref: ref)
    assert Floki.text(find(html, "[data-spec-status]")) == "Reviewed version · read-only"
    assert find(html, "fieldset[disabled]") != []
    assert find(html, "[phx-click=spec-review]") == []
    assert find(html, "[phx-click=spec-return-draft]") != []
    assert Floki.attribute(find(html, "[phx-click=spec-open-version]"), "phx-value-ref") == [ref]
    assert Floki.attribute(find(html, "[phx-click=spec-open-version]"), "aria-current") == ["true"]
    [workspace_id] = Floki.attribute(find(html, "[data-specification-project]"), "id")
    assert Floki.attribute(find(html, ".specification-history"), "id") == [workspace_id <> "-history"]
    assert Floki.attribute(find(view_html(state: state, section: "data"), ".specification-history"), "id") == [workspace_id <> "-history"]
    refute Floki.attribute(find(view_html(state: state, project: "github:example/another"), ".specification-history"), "id") == [workspace_id <> "-history"]
    refute html =~ "queue_task"
    assert Floki.text(find(view_html(state: state), "[data-spec-status]")) == "Reviewed version"
    altered = put_in(document, ["sections", "brief", "items", Access.at(0), "body"], "A later draft")
    assert Floki.text(find(view_html(state: %{state | "draft" => altered}), "[data-spec-status]")) == "Draft · reviewed version retained"
    assert find(view_html(state: %{state | "reviewed" => nil}, review_open: true), "[phx-click=spec-confirm-review]") != []
  end

  test "unavailable storage visibly disables edits and ordinary project strings remain escaped" do
    html = view_html(project_label: "<script>System</script>", available: false, notice: "Retained <draft>")
    assert find(html, "script") == []
    assert find(html, "fieldset[disabled]") != []
    assert Floki.text(find(html, "[data-spec-status]")) == "Specification storage unavailable"
    assert html =~ "Retained &lt;draft&gt;"
    assert Floki.attribute(find(html, "[data-specification-project]"), "aria-label") == ["<script>System</script> specification"]
    assert Floki.text(find(view_html(state: %{"draft" => Document.new(@project)}), "[data-spec-status]")) == "Saved draft"
    assert find(view_html(idea_url: "/?project=system&view=idea"), "a") != []
    for url <- [nil, "//evil.example/path", "javascript:alert(1)", "/\\evil", "/\nheader"], do: assert(find(view_html(idea_url: url), "a") == [])
  end

  test "read-only boards disable specification writes without claiming storage is unavailable" do
    {:ok, document} = Document.add(Document.new(@project), "brief", "items")
    document = put_in(document, ["sections", "brief", "items", Access.at(0), "body"], "Saved draft")
    html = view_html(state: %{"draft" => document}, read_only: true, review_open: true)
    assert Floki.text(find(html, "[data-spec-status]")) == "Read-only board"
    assert find(html, "fieldset[disabled]") != []
    assert find(html, "[phx-click=spec-review][disabled]") != []
    assert find(html, "[phx-click=spec-confirm-review][disabled]") != []
  end

  defp view_html(attrs \\ []), do: render_component(&SpecificationView.content/1, Keyword.merge([project: @project, project_label: "System"], attrs))
  defp find(html, selector), do: html |> Floki.parse_fragment!() |> Floki.find(selector)
end
