defmodule SymphonyElixir.Specification.ObjectTest do
  use ExUnit.Case, async: true
  alias Plug.Conn.Query
  alias SymphonyElixir.Specification.{Document, Object}
  alias SymphonyElixirWeb.SpecificationEditor
  @project "github:example/system"

  test "blank defaults do not claim content, but targets, references and meaningful rows do" do
    for section <- Document.sections(), kind <- Document.kinds(section) do
      item = Document.item(section, kind)
      refute Object.content?(item)
      assert Object.content?(Map.put(item, "title", "A design object"))

      if Object.row_fields(kind, "rows") != [] do
        refute Object.content?(Map.put(item, "rows", [Object.row("row", kind, "rows")]))
      end
    end

    item = Document.item("requirements", "nonfunctional")
    row = Object.row("target", "nonfunctional", "rows") |> Map.put("target", 0)
    assert Object.content?(Map.put(item, "rows", [row]))
    item = Document.item("data", "entity") |> put_in(["attributes", "owner"], "component")
    assert Object.content?(item)
    source = Object.row("source", "entity", "sources") |> Map.put("url", "https://example.com/model")
    assert Object.content?(Map.put(Document.item("data", "entity"), "sources", [source]))
  end

  test "each kind has a closed typed schema and bounded editable members" do
    document = Document.new(@project)
    assert document["version"] == 2

    for section <- Document.sections(), kind <- Document.kinds(section) do
      {:ok, draft} = Document.add(document, section, "items", kind)
      [item] = draft["sections"][section]["items"]
      assert item["kind"] == kind
      assert Document.valid?(draft, @project)

      for group <- ~w(rows links sources) do
        if Object.row_fields(kind, group) == [] do
          assert {:error, :invalid_specification_form} = Document.member(draft, section, item["id"], group, "add")
        else
          assert {:ok, with_row} = Document.member(draft, section, item["id"], group, "add")
          [row] = hd(with_row["sections"][section]["items"])[group]
          assert {:ok, ^draft} = Document.member(with_row, section, item["id"], group, "remove", row["id"])
          assert {:error, :invalid_specification_form} = Document.member(with_row, section, item["id"], group, "remove", "foreign")
        end
      end
    end

    assert Object.fields("unknown") == []
    refute Object.valid?(nil, %{})
    refute Object.valid?(Map.put(Document.item("data", "entity"), "unexpected", ""), %{})
    assert Object.row_fields("unknown", "rows") == []
    assert Object.row_fields("entity", "unknown") == []
    assert Object.row_label("goal") == "Items"
    assert Document.item("brief", "entity") == nil
    assert {:error, :invalid_specification_form} = Document.add(document, "data", "items", "functional")
    assert {:error, :invalid_specification_form} = Document.member(document, "unknown", "missing", "rows", "add")
    assert {:error, :invalid_specification_form} = Document.member(document, "data", "missing", "rows", "add")
  end

  test "stable references prevent deleting a target, foreign scope, wrong kinds and duplicate identities" do
    {:ok, document} = Document.add(Document.new(@project), "data", "items", "entity")
    {:ok, document} = Document.add(document, "data", "items", "relationship")
    [entity, relation] = document["sections"]["data"]["items"]
    document = put_in(document, ["sections", "data", "items", Access.at(1), "attributes", "from"], entity["id"])
    assert Document.valid?(document, @project)
    assert {:error, :invalid_specification_form} = Document.remove(document, "data", "items", entity["id"])
    refute Document.valid?(put_in(document, ["sections", "data", "items", Access.at(1), "attributes", "from"], "foreign-project"), @project)
    refute Document.valid?(put_in(document, ["sections", "data", "items", Access.at(0), "attributes", "owner"], relation["id"]), @project)
    {:ok, document} = Document.member(document, "data", entity["id"], "rows", "add")
    row = hd(hd(document["sections"]["data"]["items"])["rows"])
    duplicate = put_in(document, ["sections", "data", "items", Access.at(0), "rows"], [row, row])
    refute Document.valid?(duplicate, @project)

    for {group, action} <- [{"unknown", "add"}, {"rows", "unknown"}] do
      assert {:error, :invalid_specification_form} = Document.member(document, "data", entity["id"], group, action)
    end

    assert {:ok, without_relation} = Document.remove(document, "data", "items", relation["id"])
    assert {:ok, _} = Document.remove(without_relation, "data", "items", entity["id"])
  end

  test "nested browser forms normalize only valid framework markers and parse real numeric targets" do
    {:ok, document} = Document.add(Document.new(@project), "requirements", "items", "nonfunctional")
    [item] = document["sections"]["requirements"]["items"]
    {:ok, document} = Document.member(document, "requirements", item["id"], "rows", "add")
    item = hd(document["sections"]["requirements"]["items"])
    [row] = item["rows"]
    form = Object.form(item)
    form = put_in(form, ["rows", row["id"], "target"], "500")
    browser = form |> put_in(["attributes", "_unused_scope"], "") |> put_in(["rows", row["id"], "_unused_unit"], "") |> Map.put("_unused_notes", "") |> Query.encode() |> Query.decode()
    params = %{"project" => @project, "document_id" => document["document_id"], "section" => "requirements", "storage_revision" => "3", "items" => %{item["id"] => browser}}
    assert {:ok, saved} = SpecificationEditor.edit(document, %{"storage_revision" => 3}, params, "requirements")
    assert hd(hd(saved["sections"]["requirements"]["items"])["rows"])["target"] == 500
    refute Jason.encode!(saved) =~ "_unused_"

    for {value, expected} <- [{"", nil}, {"0.5", 0.5}, {"-1", -1}, {nil, nil}, {500, 500}] do
      values = put_in(form, ["rows", row["id"], "target"], value)
      assert {:ok, edited} = Object.edit(item, values)
      assert hd(edited["rows"])["target"] == expected
    end

    for target <- ["bad", "NaN", "Infinity", "1e999", "1000000000001", %{}] do
      bad = put_in(params, ["items", item["id"], "rows", row["id"], "target"], target)
      assert {:error, :invalid_specification_edit} = SpecificationEditor.edit(document, %{"storage_revision" => 3}, bad, "requirements")
    end

    for bad <- [
          Map.put(browser, "kind", "functional"),
          put_in(browser, ["attributes", "_unused_scope"], "malformed"),
          put_in(browser, ["rows", row["id"], "_unused_rogue"], ""),
          put_in(browser, ["attributes", "rogue"], ""),
          Map.delete(browser, "attributes"),
          Map.put(browser, "rows", %{"foreign" => %{}}),
          put_in(browser, ["rows", row["id"]], nil),
          Map.put(browser, "sources", "invalid"),
          Map.put(browser, "state", "accepted")
        ] do
      assert {:error, :invalid_specification_edit} = SpecificationEditor.edit(document, %{"storage_revision" => 3}, put_in(params, ["items", item["id"]], bad), "requirements")
    end

    assert Object.normalize(item, nil) == nil
    empty_members = Object.form(Document.item("requirements", "nonfunctional"))
    assert Object.normalize(item, Map.merge(empty_members, %{"rows" => nil, "links" => nil, "sources" => nil})) == empty_members
    assert {:error, :invalid_specification_form} = Document.edit(document, "requirements", %{"items" => %{}})
    assert {:error, :invalid_specification_form} = Document.edit(document, "requirements", %{"items" => %{item["id"] => nil}})
  end

  test "resource URLs, field choices, text and member sizes fail closed" do
    {:ok, document} = Document.add(Document.new(@project), "data", "items", "entity")
    [item] = document["sections"]["data"]["items"]
    {:ok, document} = Document.member(document, "data", item["id"], "sources", "add")
    assert Object.safe_url?("https://example.com/source?revision=1#model")
    assert Object.safe_url?("http://localhost:8778/")
    assert Object.safe_url?("http://[::1]:8778/model")

    for url <- [
          nil,
          1,
          "javascript:alert(1)",
          "//evil.example",
          "https://user:password@example.com",
          "https://example.com:invalid/",
          "https://example.com:65536/",
          "https://example.com/<invalid>",
          "https://example.com/\nlink",
          "https://example.com/\\link",
          <<255>>,
          String.duplicate("x", 4097)
        ] do
      refute Object.safe_url?(url)
      bad = put_in(document, ["sections", "data", "items", Access.at(0), "sources", Access.at(0), "url"], url)
      refute Document.valid?(bad, @project)
    end

    {:ok, document} = Document.member(document, "data", item["id"], "rows", "add")

    for {field, value} <- [{"type", "arbitrary"}, {"cardinality", "unknown"}, {"target", "missing"}, {"description", String.duplicate("x", 1025)}] do
      refute Document.valid?(put_in(document, ["sections", "data", "items", Access.at(0), "rows", Access.at(0), field], value), @project)
    end

    refute Document.valid?(put_in(document, ["sections", "data", "items", Access.at(0), "rows"], List.duplicate(hd(hd(document["sections"]["data"]["items"])["rows"]), 101)), @project)
  end

  test "conversion and import preserve the original text, IDs, diagrams and version-one reference" do
    old = Document.new(@project) |> Map.put("version", 1)
    {:ok, old} = Document.add(old, "data", "items")
    {:ok, old} = Document.add(old, "data", "diagrams")
    old = put_in(old, ["sections", "data", "items", Access.at(0), "body"], "Original source [model](https://example.com/models).")
    ref = Document.content_ref(old)
    assert {:ok, upgraded} = Document.upgrade(old)
    assert upgraded["document_id"] == old["document_id"]
    assert hd(upgraded["sections"]["data"]["items"])["notes"] == hd(old["sections"]["data"]["items"])["body"]
    assert {:ok, ^upgraded} = Document.import_objects(old, Jason.encode!(upgraded))
    assert {:ok, ^upgraded} = Document.upgrade(upgraded)
    assert Document.content_ref(old) == ref
    refute Document.content_ref(upgraded) == ref

    for bad <- [
          nil,
          "not json",
          Jason.encode!(%{}),
          String.duplicate("x", 1_000_001),
          Jason.encode!(Map.put(upgraded, "project", "another")),
          Jason.encode!(Map.put(upgraded, "document_id", "another")),
          Jason.encode!(put_in(upgraded, ["sections", "data", "items"], [])),
          Jason.encode!(put_in(upgraded, ["sections", "data", "items", Access.at(0), "notes"], "lost")),
          Jason.encode!(put_in(upgraded, ["sections", "data", "diagrams"], []))
        ] do
      assert {:error, :invalid_specification_import} = Document.import_objects(old, bad)
    end

    assert {:ok, ^upgraded} = Document.import_objects(upgraded, Jason.encode!(upgraded))
    assert {:error, :invalid_specification_form} = Document.upgrade(%{})
  end
end
