defmodule SymphonyElixirWeb.SpecificationEditorTest do
  use ExUnit.Case, async: true
  alias Plug.Conn.Query
  alias SymphonyElixir.Specification.Document
  alias SymphonyElixirWeb.SpecificationEditor, as: Editor

  test "edits keep stable identities and update only the owned section" do
    draft = legacy("project")
    {:ok, draft} = Editor.change(draft, "brief", "spec-add-item", nil)
    {:ok, draft} = Editor.change(draft, "brief", "spec-add-diagram", nil)
    [item] = draft["sections"]["brief"]["items"]
    [diagram] = draft["sections"]["brief"]["diagrams"]
    params = params(draft, "brief")

    params = %{
      params
      | "items" => %{item["id"] => %{"title" => "Goal", "body" => "Find an event", "kind" => "goal"}},
        "diagrams" => %{diagram["id"] => %{"title" => "Flow", "source" => "flowchart TD\nA --> B"}}
    }

    assert {:ok, updated} = Editor.edit(draft, %{"storage_revision" => 0}, params, "brief")
    assert hd(updated["sections"]["brief"]["items"])["id"] == item["id"]
    assert hd(updated["sections"]["brief"]["items"])["body"] == "Find an event"
    assert updated["sections"]["requirements"] == draft["sections"]["requirements"]
    assert {:ok, removed} = Editor.change(updated, "brief", "spec-remove-item", item["id"])
    assert {:ok, removed} = Editor.change(removed, "brief", "spec-remove-diagram", diagram["id"])
    assert removed["sections"]["brief"] == %{"items" => [], "diagrams" => []}
  end

  test "stale, foreign and substituted browser fields cannot retarget the draft" do
    draft = legacy("project")
    {:ok, draft} = Editor.change(draft, "requirements", "spec-add-item", nil)
    base = params(draft, "requirements")
    [item] = draft["sections"]["requirements"]["items"]

    for change <- [
          %{"storage_revision" => "1"},
          %{"document_id" => "another"},
          %{"project" => "foreign"},
          %{"section" => "data"},
          %{"items" => %{}},
          %{"items" => %{"foreign" => %{"title" => "", "body" => "", "kind" => "functional"}}},
          %{"items" => %{item["id"] => %{"title" => "", "body" => "", "kind" => "functional", "id" => "other"}}},
          %{"items" => %{item["id"] => %{"title" => "", "body" => "", "kind" => "goal"}}},
          %{"items" => []},
          %{"items" => %{item["id"] => "wrong"}}
        ] do
      assert {:error, :invalid_specification_edit} = Editor.edit(draft, %{"storage_revision" => 0}, Map.merge(base, change), "requirements")
    end

    assert {:error, :invalid_specification_edit} = Editor.edit(draft, %{"storage_revision" => 0}, base, "missing")

    for {section, action, id} <- [{"missing", "spec-add-item", nil}, {"brief", "unknown", nil}, {"brief", "spec-remove-item", "missing"}] do
      assert {:error, :invalid_specification_edit} = Editor.change(draft, section, action, id)
    end
  end

  test "empty sections and bounded revisions are accepted without forging items" do
    draft = legacy("project")
    assert {:ok, ^draft} = Editor.edit(draft, %{"storage_revision" => 0}, params(draft, "brief"), "brief")
    typed = Document.new("project")
    assert {:ok, ^typed} = Editor.edit(typed, %{"storage_revision" => 0}, params(typed, "brief"), "brief")
    assert {:error, :invalid_specification_edit} = Editor.edit(typed, %{"storage_revision" => 0}, Map.put(params(typed, "brief"), "items", []), "brief")
    assert Editor.revision(0) == 0
    assert Editor.revision("12") == 12
    for invalid <- [nil, -1, "-1", "1bad", [], 1.0], do: assert(is_nil(Editor.revision(invalid)))
  end

  test "typed field actions retain the parent and reject a substituted member identity" do
    {:ok, draft} = Editor.change(Document.new("project"), "data", "spec-add-item", nil, %{"kind" => "entity"})
    [item] = draft["sections"]["data"]["items"]
    options = %{"group" => "rows"}
    assert {:ok, with_field} = Editor.change(draft, "data", "spec-add-member", item["id"], options)
    [field] = hd(with_field["sections"]["data"]["items"])["rows"]
    assert {:error, :invalid_specification_edit} = Editor.change(with_field, "data", "spec-remove-member", item["id"], Map.put(options, "row_id", "foreign"))
    assert {:ok, ^draft} = Editor.change(with_field, "data", "spec-remove-member", item["id"], Map.put(options, "row_id", field["id"]))
  end

  test "decoded LiveView unused-input metadata does not become specification content" do
    draft = legacy("project")
    {:ok, draft} = Editor.change(draft, "brief", "spec-add-item", nil)
    {:ok, draft} = Editor.change(draft, "brief", "spec-add-diagram", nil)
    [item] = draft["sections"]["brief"]["items"]
    [diagram] = draft["sections"]["brief"]["diagrams"]

    base =
      params(draft, "brief")
      |> put_in(["items", item["id"], "title"], "Discovery scope")
      |> put_in(["diagrams", diagram["id"], "title"], "Discovery flow")
      |> put_in(["diagrams", diagram["id"], "source"], "flowchart TD\nA --> B")

    browser =
      base
      |> update_in(["items", item["id"]], &Map.merge(&1, %{"_unused_kind" => "", "_unused_title" => "", "_unused_body" => ""}))
      |> update_in(["diagrams", diagram["id"]], &Map.merge(&1, %{"_unused_title" => "", "_unused_source" => ""}))
      |> Map.put("_target", ["diagrams", diagram["id"], "source"])
      |> Query.encode()
      |> Query.decode()

    assert {:error, :invalid_specification_form} = Document.edit(draft, "brief", browser)
    assert {:ok, expected} = Editor.edit(draft, %{"storage_revision" => 0}, base, "brief")
    assert {:ok, ^expected} = Editor.edit(draft, %{"storage_revision" => 0}, browser, "brief")
    assert Document.valid?(expected, "project")
    refute Jason.encode!(expected) =~ "_unused_"
  end

  test "unused metadata cannot disguise unknown, malformed or incomplete fields" do
    draft = legacy("project")
    {:ok, draft} = Editor.change(draft, "brief", "spec-add-item", nil)
    {:ok, draft} = Editor.change(draft, "brief", "spec-add-diagram", nil)
    base = params(draft, "brief")
    [item] = draft["sections"]["brief"]["items"]
    [diagram] = draft["sections"]["brief"]["diagrams"]

    for {group, id, row} <- [
          {"items", item["id"], Map.put(base["items"][item["id"]], "_unused_source", "")},
          {"items", item["id"], Map.put(base["items"][item["id"]], "_unused_id", "")},
          {"items", item["id"], Map.put(base["items"][item["id"]], "unexpected", "")},
          {"items", item["id"], Map.put(base["items"][item["id"]], "_unused_body", "not-empty")},
          {"items", item["id"], Map.put(base["items"][item["id"]], "_unused_body", %{})},
          {"items", item["id"], base["items"][item["id"]] |> Map.delete("body") |> Map.put("_unused_body", "")},
          {"items", "foreign", Map.put(base["items"][item["id"]], "_unused_title", "")},
          {"diagrams", diagram["id"], Map.put(base["diagrams"][diagram["id"]], "_unused_body", "")},
          {"diagrams", diagram["id"], Map.put(base["diagrams"][diagram["id"]], "_unused_source", nil)},
          {"diagrams", diagram["id"], Map.put(base["diagrams"][diagram["id"]], "_unused_title", [])}
        ] do
      params = Map.put(base, group, %{id => row})
      assert {:error, :invalid_specification_edit} = Editor.edit(draft, %{"storage_revision" => 0}, params, "brief")
    end
  end

  defp params(draft, section) do
    values = fn items, keys -> Map.new(items, &{&1["id"], Map.take(&1, keys)}) end

    %{
      "project" => draft["project"],
      "document_id" => draft["document_id"],
      "section" => section,
      "storage_revision" => "0",
      "items" => if(draft["sections"][section]["items"] == [], do: nil, else: values.(draft["sections"][section]["items"], ~w(title kind body))),
      "diagrams" => if(draft["sections"][section]["diagrams"] == [], do: nil, else: values.(draft["sections"][section]["diagrams"], ~w(title source)))
    }
  end

  defp legacy(project), do: Document.new(project) |> Map.put("version", 1)
end
