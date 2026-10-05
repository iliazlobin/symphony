defmodule SymphonyElixirWeb.GraphNavigationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixirWeb.GraphNavigation

  test "graph bookmarks cannot consume task filters or arbitrary controls" do
    assert GraphNavigation.read(%{"q" => "board", "mode" => "paused", "graph_mode" => "focus", "graph_hops" => "2", "graph_query" => "lookup"}) == %{
             "mode" => "focus",
             "hops" => 2,
             "query" => "lookup"
           }

    assert GraphNavigation.read(%{"graph_mode" => "agents", "graph_hops" => "99", "graph_page" => "1junk", "graph_group" => %{}, "graph_query" => nil}) == %{}
    assert GraphNavigation.read(%{"graph_page" => -1, "graph_search_page" => "junk", "graph_direction" => "bad", "graph_group_by" => "secret"}) == %{}
  end

  test "bounded preferences round-trip and clearing removes a stale group" do
    options =
      GraphNavigation.update(%{"group" => "old", "gaps_only" => true}, %{
        "group" => "",
        "gaps_only" => "false",
        "page" => 1,
        "hops" => 1,
        "direction" => "upstream",
        "group_by" => "task_kind",
        "anchor" => "issue:1"
      })

    refute options["group"]
    refute options["gaps_only"]
    assert GraphNavigation.read(GraphNavigation.params(options)) == options
    assert options["anchor"] == "issue:1"
    assert GraphNavigation.read(%{"graph_anchor" => String.duplicate("x", 600)})["anchor"] == String.duplicate("x", 512)

    assert GraphNavigation.read(%{"graph_gaps_only" => "true", "graph_query" => String.duplicate("x", 200), "graph_search_page" => 2}) == %{
             "gaps_only" => true,
             "query" => String.duplicate("x", 160),
             "search_page" => 2
           }
  end
end
