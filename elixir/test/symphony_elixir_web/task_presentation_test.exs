defmodule SymphonyElixirWeb.TaskPresentationTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.TaskPresentation

  test "the shared identity keeps safe resource references separate from task actions" do
    html = render_component(&TaskPresentation.identity/1, identifier: "GH-19", url: "https://github.com/example/project/issues/19", kind: "maintenance", priority: 1)
    tree = Floki.parse_fragment!(html)
    link = Floki.find(tree, ".task-reference[href]")
    assert Floki.attribute(link, "target") == ["_blank"]
    assert Floki.attribute(link, "rel") == ["noopener noreferrer"]
    assert Floki.attribute(link, "phx-click") == []
    assert Floki.text(Floki.find(tree, ".card-task-kind")) == "Maintenance"
    assert Floki.text(Floki.find(tree, ".priority[data-priority=P1]")) == "P1"

    unknown = render_component(&TaskPresentation.identity/1, identifier: "GH-20", url: "javascript:alert(1)", kind: "invalid", priority: nil)
    tree = Floki.parse_fragment!(unknown)
    assert Floki.find(tree, "a, .priority") == []
    assert Floki.text(Floki.find(tree, ".card-task-kind[data-task-kind=invalid]")) == "Needs classification"
    assert unknown =~ "GH-20"
  end

  test "dependency navigation carries the canonical task, full counts and filter context" do
    options = [
      task_id: "issue:19",
      identifier: "GH-19",
      upstream: 0,
      downstream: 4,
      filters: %{"q" => "schema", "priority" => "1"},
      session: "work:current"
    ]

    html = render_component(&TaskPresentation.dependencies/1, options)

    links = Floki.find(Floki.parse_fragment!(html), ".card-dependencies a")
    assert Enum.map(links, &Floki.text/1) == ["↑0", "↓4"]
    assert Floki.attribute(links, "data-board-view-task") == ["issue:19", "issue:19"]
    assert Floki.attribute(links, "aria-label") == ["0 prerequisites for GH-19; open graph", "4 dependent tasks for GH-19; open graph"]

    for href <- Floki.attribute(links, "href") do
      params = URI.decode_query(URI.parse(href).query)
      assert params["view"] == "graph"
      assert params["graph_mode"] == "focus"
      assert params["graph_anchor"] == "issue:19"
      assert params["chat_task"] == "issue:19"
      assert params["chat_session"] == "work:current"
      assert params["q"] == "schema"
      assert params["priority"] == "1"
    end
  end

  test "historical dependency links retain the reviewed version and live chat selection" do
    html =
      render_component(&TaskPresentation.dependencies/1,
        task_id: "issue:old",
        identifier: "GH-1",
        upstream: 3,
        downstream: 2,
        baseline_ref: "reviewed",
        live_task_id: "issue:live",
        session: "work:live"
      )

    links = Floki.find(Floki.parse_fragment!(html), ".card-dependencies a")
    assert Floki.attribute(links, "data-board-view-link") == []

    for href <- Floki.attribute(links, "href") do
      params = URI.decode_query(URI.parse(href).query)
      assert params["baseline"] == "reviewed"
      assert params["chat_task"] == "issue:live"
      assert params["chat_session"] == "work:live"
      assert params["graph_anchor"] == "issue:old"
    end
  end
end
