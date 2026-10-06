defmodule SymphonyElixirWeb.SpecificationObjectViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixir.Specification.{Document, Object}
  alias SymphonyElixirWeb.SpecificationView
  @project "github:example/system"

  test "every object type exposes its own properties and nested rows without a type-changing control" do
    for section <- Document.sections(), kind <- Document.kinds(section) do
      {:ok, document} = Document.add(Document.new(@project), section, "items", kind)
      [item] = document["sections"][section]["items"]
      document = put_in(document, ["sections", section, "items", Access.at(0), "priority"], "must")
      document = if Object.row_fields(kind, "rows") != [], do: elem(Document.member(document, section, item["id"], "rows", "add"), 1), else: document
      html = render_component(&SpecificationView.content/1, attrs(document, section)) |> Floki.parse_document!()
      assert Floki.text(Floki.find(html, ".specification-object > summary")) =~ "Untitled"
      assert Floki.text(Floki.find(html, ".specification-object > summary")) =~ "Must"
      for field <- Object.fields(kind), do: assert(Floki.find(html, "[name$='[attributes][#{field.key}]']") != [])
      assert Floki.find(html, "select[name$='[kind]']") == []
    end
  end

  test "entities render compact typed fields and stable navigable object references" do
    {:ok, document} = Document.add(Document.new(@project), "data", "items", "entity")
    {:ok, document} = Document.add(document, "data", "items", "entity")
    [event, location] = document["sections"]["data"]["items"]
    document = put_in(document, ["sections", "data", "items", Access.at(0), "title"], "Event") |> put_in(["sections", "data", "items", Access.at(1), "title"], "Location")
    {:ok, document} = Document.member(document, "data", event["id"], "rows", "add")
    document = put_in(document, ["sections", "data", "items", Access.at(0), "rows", Access.at(0), "target"], location["id"])
    html = render_component(&SpecificationView.content/1, attrs(document, "data")) |> Floki.parse_document!()
    assert length(Floki.find(html, ".specification-object")) == 2
    assert Floki.text(Floki.find(html, ".spec-object-table thead")) =~ "FieldTypePresenceKeyReferencesMeaning / constraint"
    assert Floki.attribute(Floki.find(html, "[phx-click=spec-object]"), "phx-value-id") == [location["id"]]
    assert Floki.attribute(Floki.find(html, "[phx-click=spec-add-member]"), "phx-value-id") == [event["id"], event["id"], event["id"], location["id"], location["id"], location["id"]]
    ids = html |> Floki.find(".specification-form input, .specification-form select, .specification-form textarea") |> Floki.attribute("id")
    assert Enum.uniq(ids) == ids
    assert Floki.find(html, "[data-spec-search]") != []
    assert Floki.find(html, "input[name$='[kind]'][type=hidden]") != []
    assert Floki.find(html, "select[name$='[kind]']") == []
    assert Floki.text(Floki.find(html, ".spec-object-state")) == "DraftDraft"
    refute Floki.text(html) =~ "accepted task"
  end

  test "numeric targets and escaped source links remain ordinary accessible form controls" do
    {:ok, document} = Document.add(Document.new(@project), "requirements", "items", "nonfunctional")
    [item] = document["sections"]["requirements"]["items"]
    {:ok, document} = Document.member(document, "requirements", item["id"], "rows", "add")
    {:ok, document} = Document.member(document, "requirements", item["id"], "sources", "add")
    document = put_in(document, ["sections", "requirements", "items", Access.at(0), "rows", Access.at(0), "target"], 500)
    url = "https://example.com/source?revision=1&model=events"
    document = put_in(document, ["sections", "requirements", "items", Access.at(0), "sources", Access.at(0), "url"], url)
    document = put_in(document, ["sections", "requirements", "items", Access.at(0), "sources", Access.at(0), "label"], "<script>Source</script>")
    html = render_component(&SpecificationView.content/1, attrs(document, "requirements")) |> Floki.parse_document!()
    assert Floki.attribute(Floki.find(html, "input[type=number]"), "value") == ["500"]
    assert Floki.attribute(Floki.find(html, ".spec-object-source-links a"), "href") == [url]
    assert Floki.attribute(Floki.find(html, ".spec-object-source-links a"), "rel") == ["noopener noreferrer"]
    assert Floki.find(html, "script") == []
    unsafe = put_in(document, ["sections", "requirements", "items", Access.at(0), "sources", Access.at(0), "url"], "javascript:alert(1)")
    unsafe_html = render_component(&SpecificationView.content/1, attrs(unsafe, "requirements")) |> Floki.parse_document!()
    assert Floki.find(unsafe_html, ".spec-object-source-links a") == []
  end

  test "reviewed typed versions and read-only boards keep links but disable every write" do
    {:ok, document} = Document.add(Document.new(@project), "data", "items", "relationship")
    options = attrs(document, "data") ++ [history: true, viewed_ref: Document.content_ref(document)]
    html = render_component(&SpecificationView.content/1, options) |> Floki.parse_document!()
    assert Floki.find(html, ".specification-form fieldset[disabled]") != []
    assert Floki.find(html, ".specification-import") == []
    assert Floki.find(html, "[phx-click=spec-structure]") == []
    assert Floki.find(html, "select[name$='[cardinality]']") != []
    assert Floki.text(Floki.find(html, "[data-spec-status]")) == "Reviewed version · read-only"
    options = attrs(document, "data") ++ [read_only: true]
    read_only = render_component(&SpecificationView.content/1, options) |> Floki.parse_document!()
    assert Floki.find(read_only, ".specification-import fieldset[disabled]") != []
  end

  defp attrs(document, section), do: [project: @project, draft: document, state: %{"draft" => document, "storage_revision" => 3}, section: section]
end
