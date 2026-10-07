defmodule SymphonyElixir.Specification.DocumentTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Specification.Document
  @project "github:example/system"

  test "new documents and inserted items have stable independent identities and no reviewed content" do
    document = legacy(@project)
    assert Document.valid?(document, @project)
    refute Document.content?(document)
    refute legacy(@project)["document_id"] == document["document_id"]
    assert Document.sections() == ~w(brief requirements data architecture decisions)
    assert Document.kinds("unknown") == [] and Document.item("unknown") == nil

    for section <- Document.sections() do
      {:ok, added} = Document.add(document, section, "items")
      [item] = added["sections"][section]["items"]
      assert item["kind"] == hd(Document.kinds(section))
      refute Document.content?(added)
      assert {:ok, ^document} = Document.remove(added, section, "items", item["id"])
    end

    {:ok, diagrams} = Document.add(document, "data", "diagrams")
    [diagram] = diagrams["sections"]["data"]["diagrams"]
    assert Document.content?(diagrams)
    assert diagram["source"] =~ "flowchart TD"
    assert {:ok, ^document} = Document.remove(diagrams, "data", "diagrams", diagram["id"])
  end

  test "editing preserves identities and other sections while rejecting unknown, partial or invalid rows" do
    {:ok, document} = Document.add(legacy(@project), "requirements", "items")
    {:ok, document} = Document.add(document, "requirements", "diagrams")
    [item] = document["sections"]["requirements"]["items"]
    [diagram] = document["sections"]["requirements"]["diagrams"]

    params = %{
      "items" => %{item["id"] => %{"title" => "Fast discovery", "kind" => "nonfunctional", "body" => "p95 < 500ms"}},
      "diagrams" => %{diagram["id"] => %{"title" => "Read path", "source" => "sequenceDiagram\n  Web->>API: search"}}
    }

    assert {:ok, edited} = Document.edit(document, "requirements", params)
    assert edited["document_id"] == document["document_id"]
    assert edited["sections"]["brief"] == document["sections"]["brief"]
    assert hd(edited["sections"]["requirements"]["items"])["id"] == item["id"]
    assert Document.content?(edited)

    invalid = [
      nil,
      %{},
      put_in(params, ["items", "unknown"], %{}),
      put_in(params, ["items", item["id"]], %{"title" => "Missing details"}),
      put_in(params, ["items", item["id"], "kind"], "component")
    ]

    for bad <- invalid do
      assert {:error, :invalid_specification_form} = Document.edit(document, "requirements", bad)
    end

    for {section, type, id} <- [{"unknown", "items", item["id"]}, {"requirements", "bad", item["id"]}, {"requirements", "items", "missing"}] do
      assert {:error, :invalid_specification_form} = Document.remove(document, section, type, id)
    end

    assert {:error, :invalid_specification_form} = Document.add(document, "unknown", "items")
    assert {:error, :invalid_specification_form} = Document.add(document, "brief", "bad")
    assert {:error, :invalid_specification_form} = Document.edit(%{}, "brief", %{})
  end

  test "strict bounded structure rejects duplicate identities, foreign fields, invalid kinds and excessive text" do
    document = legacy(@project)
    item = %{"id" => "goal1", "kind" => "goal", "title" => "Goal", "body" => "Useful output"}
    document = put_in(document, ["sections", "brief", "items"], [item])
    diagram = %{"id" => "diagram1", "title" => "Flow", "source" => "flowchart TD\n  A --> B"}
    assert Document.valid?(document, @project)

    invalid = [
      nil,
      %{},
      Map.put(document, "version", 2),
      Map.put(document, "extra", true),
      Map.put(document, "project", "other"),
      Map.put(document, "document_id", <<255>>),
      Map.put(document, "document_id", "bad:id"),
      put_in(document, ["sections", "brief"], nil),
      put_in(document, ["sections", "brief", "items"], %{}),
      put_in(document, ["sections", "brief", "items"], [item, item]),
      put_in(document, ["sections", "data", "diagrams"], [Map.put(diagram, "id", item["id"])]),
      put_in(document, ["sections", "brief", "items"], Enum.map(1..201, &Map.put(item, "id", "goal#{&1}"))),
      put_in(document, ["sections", "data", "diagrams"], Enum.map(1..31, &Map.put(diagram, "id", "diagram#{&1}"))),
      put_in(document, ["sections", "brief", "items"], [Map.put(item, "body", <<255>>)]),
      put_in(document, ["sections", "brief", "items"], [Map.put(item, "title", String.duplicate("😀", 129))]),
      put_in(document, ["sections", "brief", "items"], [Map.put(item, "body", String.duplicate("x", 24_001))]),
      put_in(document, ["sections", "data", "diagrams"], [Map.put(diagram, "source", String.duplicate("x", 60_001))]),
      put_in(document, ["sections", "brief", "items"], Enum.map(1..45, &Map.merge(item, %{"id" => "goal#{&1}", "body" => String.duplicate("x", 24_000)})))
    ]

    for value <- invalid, do: refute(Document.valid?(value, @project))
    boundary = put_in(document, ["sections", "brief", "items"], [Map.put(item, "title", String.duplicate("😀", 128))])
    assert Document.valid?(boundary, @project)
    blank = put_in(document, ["sections", "data", "diagrams"], [Map.put(diagram, "source", " ")]) |> put_in(["sections", "brief", "items"], [])
    refute Document.content?(blank)
    assert {:error, :invalid_specification_form} = Document.add(put_in(document, ["sections", "data", "diagrams"], Enum.map(1..30, &Map.put(diagram, "id", "diagram#{&1}"))), "data", "diagrams")
  end

  test "content references ignore map ordering but include source, stable identity and semantic order" do
    document = legacy(@project)
    reordered = Map.new(Enum.reverse(Map.to_list(document)))
    assert Document.content_ref(document) == Document.content_ref(reordered)
    {:ok, with_diagram} = Document.add(document, "architecture", "diagrams")
    refute Document.content_ref(document) == Document.content_ref(with_diagram)
    refute Document.content_ref(document) == Document.content_ref(Map.put(document, "document_id", "Another"))
  end

  defp legacy(project), do: Document.new(project) |> Map.put("version", 1)
end
