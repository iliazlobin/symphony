defmodule SymphonyElixirWeb.GraphProjectionTest do
  use ExUnit.Case, async: true
  Code.require_file("../fixtures/task_graph.exs", __DIR__)
  alias SymphonyElixirWeb.{GraphProjection, TaskGraphFixture}

  test "a thousand tasks and three thousand dependencies open as bounded milestone groups" do
    board = large_board()
    {index_us, index} = :timer.tc(fn -> GraphProjection.index(board) end)
    {project_us, projection} = :timer.tc(fn -> GraphProjection.project(index, nil) end)
    assert projection["options"]["mode"] == "overview"
    assert projection["total_tasks"] == 1_000
    assert projection["total_edges"] == 3_000
    assert length(projection["nodes"]) == 20
    assert length(projection["layout_nodes"]) == 20
    assert length(projection["edges"]) <= 300
    assert Enum.sum(Enum.map(projection["nodes"], & &1["task_count"])) == 1_000
    assert Enum.any?(projection["nodes"], & &1["graph_error"])

    IO.puts("graph fixture index=#{index_us}us projection=#{project_us}us (1000 tasks / 3000 dependencies)")
  end

  test "hub pages preserve focus, full counts and every reachable prerequisite" do
    index = GraphProjection.index(large_board())

    first =
      GraphProjection.project(index, "issue:1", %{"mode" => "focus", "direction" => "upstream"})

    assert length(first["nodes"]) == 80
    assert first["scope_nodes"] == 401
    assert first["omitted_nodes"] == 321
    assert first["selected"]["upstream_count"] == 400
    assert first["selected"]["waiting_count"] == 400
    assert first["pages"] == 6
    assert length(first["layout_nodes"]) == 80
    assert first["scope_edges"] == first["omitted_edges"] + length(first["edges"])

    pages =
      Enum.map(
        0..5,
        &GraphProjection.project(index, "issue:1", %{
          "mode" => "focus",
          "direction" => "upstream",
          "page" => &1
        })
      )

    assert Enum.all?(pages, fn page ->
             hd(page["nodes"])["id"] == "task:1" and length(page["nodes"]) <= 80 and
               length(page["edges"]) <= 300
           end)

    ids = pages |> Enum.flat_map(& &1["nodes"]) |> MapSet.new(& &1["id"])
    assert MapSet.size(ids) == 401

    assert GraphProjection.project(index, "issue:1", %{
             "mode" => "focus",
             "direction" => "upstream",
             "page" => "999"
           })["page"] == 5
  end

  test "scope direction and two-hop expansion handle a cycle without repeating cards" do
    nodes = Enum.map(1..6, &task/1)
    edges = [dep(2, 1), dep(3, 2), dep(4, 3), dep(5, 3), dep(5, 6), dep(6, 5)]
    index = GraphProjection.index(board(nodes, edges), ["issue:3"])

    upstream =
      GraphProjection.project(index, "issue:3", %{
        "mode" => "focus",
        "direction" => "upstream",
        "hops" => "1"
      })

    assert ids(upstream) == MapSet.new(~w(task:2 task:3))
    assert Enum.find(upstream["nodes"], &(&1["id"] == "task:2"))["visible"] == false

    two =
      GraphProjection.project(index, "issue:3", %{
        "mode" => "focus",
        "direction" => "upstream",
        "hops" => 2
      })

    assert ids(two) == MapSet.new(~w(task:1 task:2 task:3))

    downstream =
      GraphProjection.project(index, "issue:3", %{
        "mode" => "focus",
        "direction" => "downstream",
        "hops" => 2
      })

    assert ids(downstream) == MapSet.new(~w(task:3 task:4 task:5 task:6))
    cycle = GraphProjection.project(index, "task:5", %{"mode" => "focus", "hops" => 2})
    assert length(cycle["nodes"]) == MapSet.size(ids(cycle))
    assert Enum.find(cycle["nodes"], &(&1["id"] == "task:5"))["graph_error"] =~ "cycle"
  end

  test "ordinary selection keeps the anchored neighborhood, page and dependency arrows stable" do
    index = GraphProjection.index(large_board())
    options = %{"mode" => "focus", "anchor" => "issue:1", "direction" => "upstream"}
    first = GraphProjection.project(index, "issue:1", options)
    neighbor = Enum.find(first["nodes"], &(&1["task_id"] != "issue:1"))
    selected = GraphProjection.project(index, neighbor["task_id"], options)
    assert selected["selected"]["task_id"] == neighbor["task_id"]
    assert selected["nodes"] == first["nodes"]
    assert selected["layout_nodes"] == first["layout_nodes"]
    assert selected["edges"] == first["edges"]
    assert selected["options"] == first["options"]
    assert selected["omitted_nodes"] == 321
    assert selected["scope_edges"] == selected["omitted_edges"] + length(selected["edges"])

    reanchored = GraphProjection.project(index, neighbor["task_id"], Map.put(options, "anchor", neighbor["task_id"]))
    refute reanchored["nodes"] == first["nodes"]
    assert reanchored["options"]["anchor"] == neighbor["task_id"]
  end

  test "opening a group keeps its exact members without expanding a selected hub" do
    index = GraphProjection.index(large_board())
    group = Enum.find(GraphProjection.project(index, nil)["nodes"], &(&1["title"] == "Milestone 0"))
    options = %{"mode" => "tasks", "group" => group["group_id"], "anchor" => "issue:1"}
    opened = GraphProjection.project(index, "issue:1", options)
    assert length(opened["nodes"]) == 50
    assert Enum.count(opened["nodes"], &(get_in(&1, ["milestone", "id"]) == 0)) == 50
    refute MapSet.member?(ids(opened), "task:1")
    assert opened["layout_nodes"] == opened["nodes"]
    assert opened["selected"]["upstream_count"] == 400
    assert opened["pages"] == 1
    assert opened["omitted_edges"] > 0
    assert opened["scope_edges"] == opened["omitted_edges"] + length(opened["edges"])
    next = GraphProjection.project(index, "issue:20", options)
    assert next["nodes"] == opened["nodes"]
    assert next["edges"] == opened["edges"]
    assert next["selected"]["task_id"] == "issue:20"
  end

  test "large group pages remain exact and stable with an outside selected anchor" do
    members = Enum.map(2..161, &task(&1, %{"milestone" => %{"id" => 17, "title" => "Target"}}))
    index = GraphProjection.index(board([task(1) | members], Enum.map(2..161, &dep(&1, 1))))
    group = Enum.find(GraphProjection.project(index, nil)["nodes"], &(&1["title"] == "Target"))
    options = %{"mode" => "tasks", "group" => group["group_id"], "anchor" => "issue:1", "page" => 1}
    opened = GraphProjection.project(index, "issue:1", options)
    assert length(opened["nodes"]) == 80
    assert opened["scope_nodes"] == 160
    assert opened["pages"] == 2
    assert opened["page"] == 1
    refute MapSet.member?(ids(opened), "task:1")
    assert opened["scope_edges"] == 160
    assert opened["omitted_edges"] == 160
    assert opened["edges"] == []
    member = hd(opened["nodes"])
    selected = GraphProjection.project(index, member["task_id"], options)
    assert selected["nodes"] == opened["nodes"]
    assert selected["layout_nodes"] == opened["layout_nodes"]
    assert selected["options"] == opened["options"]
    assert selected["selected"]["id"] == member["id"]

    small = GraphProjection.index(board([task(1), hd(members)], [dep(2, 1)]))
    single = GraphProjection.project(small, "issue:1", options)
    assert ids(single) == MapSet.new(["task:2"])
    assert single["layout_nodes"] == single["nodes"]
    assert single["omitted_edges"] == 1
  end

  test "search covers undisplayed and filtered tasks with bounded accessible pages" do
    index = GraphProjection.index(large_board(), ["issue:1"])
    search = GraphProjection.search(index, "GH-1000")
    assert search.total == 1
    assert hd(search.results)["visible"] == false
    assert hd(search.results)["id"] == "task:1000"
    all = GraphProjection.search(index, "task", 1)
    assert all.total == 1_000
    assert length(all.results) == 8
    assert all.page == 1
    assert all.pages == 125
    assert GraphProjection.search(index, "not present").results == []
    assert GraphProjection.search(index, "").total == 0
    assert GraphProjection.search(index, "task", "invalid").page == 0
    assert GraphProjection.search(index, "task", 999).page == 124
    selected = GraphProjection.project(index, "issue:1000", %{"mode" => "focus"})
    assert ids(selected) == MapSet.new(["task:1000"])
  end

  test "dense pages cap arrows and prioritize exact direct reasons around the selected task" do
    nodes = Enum.map(1..80, &task/1)
    edges = for source <- 2..80, target <- 1..(source - 1), do: dep(source, target)
    index = GraphProjection.index(board(nodes, edges))
    projection = GraphProjection.project(index, "issue:80", %{"mode" => "tasks"})
    assert length(projection["nodes"]) == 80
    assert length(projection["edges"]) == 300
    assert projection["omitted_edges"] == length(edges) - 300
    assert Enum.count(projection["edges"], &(&1["source"] == "task:80")) == 79
    assert Enum.all?(projection["edges"], &(&1["reason"] == "Declared reason"))
  end

  test "exact identifiers and task IDs rank ahead of partial matches at scale" do
    source = large_board()
    nodes = Enum.map(source.workflow_graph["nodes"], &if(&1["id"] == "task:1", do: Map.put(&1, "priority", 100), else: Map.put(&1, "priority", 1)))
    source = put_in(source, [:workflow_graph, "nodes"], nodes)
    index = GraphProjection.index(source, ["issue:1000"])
    reordered = GraphProjection.index(put_in(source, [:workflow_graph, "nodes"], Enum.reverse(nodes)), ["issue:1000"])

    for query <- ["GH-1", " gh-1 ", "issue:1", "task:1"] do
      first = GraphProjection.search(index, query)
      assert first.total == 112
      assert hd(first.results)["task_id"] == "issue:1"
      assert hd(first.results)["visible"] == false
      assert first == GraphProjection.search(reordered, query)
      assert length(first.results) == 8

      partials = Enum.drop(first.results, 1)
      assert Enum.all?(partials, &(&1["priority"] == 1))
      assert Enum.map(partials, & &1["identifier"]) == Enum.sort(Enum.map(partials, & &1["identifier"]))
    end
  end

  test "group paging, kind grouping and reordered inputs are deterministic" do
    nodes =
      Enum.map(
        1..200,
        &task(&1, %{
          "milestone" => %{"id" => &1, "title" => "Milestone #{&1}"},
          "task_kind" => if(rem(&1, 2) == 0, do: "security", else: "delivery")
        })
      )

    original = GraphProjection.index(board(nodes, [dep(200, 1)]))
    reordered = GraphProjection.index(board(Enum.reverse(nodes), [dep(200, 1)]))
    first = GraphProjection.project(original, nil)
    assert first == GraphProjection.project(reordered, nil)
    assert length(first["nodes"]) == 80
    assert first["pages"] == 3
    group = hd(first["nodes"])["id"]
    opened = GraphProjection.project(original, nil, %{"mode" => "tasks", "group" => group})
    assert length(opened["nodes"]) == 1

    kinds =
      GraphProjection.project(original, nil, %{"mode" => "overview", "group_by" => "task_kind"})

    assert length(kinds["nodes"]) == 2
    assert length(kinds["edges"]) == 1
    assert hd(kinds["edges"])["count"] == 1

    assert GraphProjection.project(original, nil, %{"mode" => "tasks", "group" => "missing"})[
             "nodes"
           ] == []
  end

  test "gap filters use recorded coverage and keep dependencies as focus context" do
    coverage = %{
      "issue:1" => %{
        "criterion_count" => 2,
        "verified_count" => 2,
        "gap_count" => 0,
        "status" => "verified"
      },
      "issue:2" => %{
        "criterion_count" => 1,
        "verified_count" => 0,
        "gap_count" => 1,
        "status" => "stale"
      },
      "issue:3" => %{
        "criterion_count" => 0,
        "verified_count" => 0,
        "gap_count" => 0,
        "status" => "unlinked"
      }
    }

    source =
      board(Enum.map(1..4, &task/1), [dep(2, 1)]) |> Map.put(:assurance, %{"tasks" => coverage})

    index = GraphProjection.index(source)
    gaps = GraphProjection.project(index, nil, %{"gaps_only" => true, "query" => "Task"})
    assert ids(gaps) == MapSet.new(~w(task:2 task:3))
    assert gaps["search"].total == 4
    assert gaps["matching_tasks"] == 2
    overview = GraphProjection.project(index, nil, %{"mode" => "overview", "gaps_only" => "true"})
    assert Enum.sum(Enum.map(overview["nodes"], & &1["task_count"])) == 2
    assert overview["filtered_edges"] == 1
    assert overview["omitted_edges"] == 1
    focus = GraphProjection.project(index, "issue:2", %{"mode" => "focus", "gaps_only" => true})
    assert ids(focus) == MapSet.new(~w(task:1 task:2))
  end

  test "overview discloses dependencies crossing filters without invented group endpoints" do
    source = board(Enum.map(1..4, &task/1), [dep(1, 2), dep(3, 4)])
    index = GraphProjection.index(source, ["issue:1"])
    overview = GraphProjection.project(index, nil, %{"mode" => "overview"})
    assert overview["total_edges"] == 2
    assert overview["scope_edges"] == 1
    assert overview["filtered_edges"] == 1
    assert overview["omitted_edges"] == 1
    assert length(overview["nodes"]) == 1
    assert overview["edges"] == []

    prerequisite_only = GraphProjection.index(source, ["issue:2"]) |> GraphProjection.project(nil, %{"mode" => "overview"})
    assert prerequisite_only["filtered_edges"] == 1
    assert prerequisite_only["edges"] == []

    opened = GraphProjection.project(index, "issue:1", %{"mode" => "focus"})
    assert ids(opened) == MapSet.new(~w(task:1 task:2))
    assert length(opened["edges"]) == 1
    assert opened["omitted_edges"] == 0
  end

  test "unavailable graphs and unsupported options stay honest" do
    empty = GraphProjection.index(%{})

    projection =
      GraphProjection.project(empty, nil, %{
        "mode" => "focus",
        "direction" => "invalid",
        "hops" => 99,
        "page" => -1,
        "query" => [],
        "search_page" => -1
      })

    assert projection["available"] == false
    assert projection["nodes"] == []
    assert projection["options"]["hops"] == 2
    assert projection["options"]["direction"] == "both"
    assert projection["options"]["query"] == ""
    assert projection["page"] == 0
    optional = Map.put(dep(2, 1), "blocking", false)
    missing = task(3, %{"missing" => true, "dependency_error" => "Unavailable prerequisite"})

    index =
      GraphProjection.index(
        board([task(1, %{"identifier" => nil, "title" => nil}), task(2), missing], [
          optional,
          dep(2, 3)
        ])
      )

    result = GraphProjection.project(index, "issue:2")
    assert result["selected"]["waiting_count"] == 1

    assert Enum.find(result["nodes"], &(&1["id"] == "task:3"))["graph_error"] ==
             "Unavailable prerequisite"

    assert GraphProjection.project(index, nil, %{"hops" => "invalid"})["options"]["hops"] == 1
  end

  defp ids(projection), do: MapSet.new(projection["nodes"], & &1["id"])

  defp task(id, extra \\ %{}),
    do:
      Map.merge(
        %{
          "id" => "task:#{id}",
          "task_id" => "issue:#{id}",
          "type" => "task",
          "identifier" => "GH-#{id}",
          "title" => "Task #{id}",
          "lane" => "work",
          "task_kind" => "general",
          "milestone" => %{"id" => rem(id, 20), "title" => "Milestone #{rem(id, 20)}"}
        },
        extra
      )

  defp dep(source, target),
    do: %{
      "id" => "dep:#{source}:#{target}",
      "source" => "task:#{source}",
      "target" => "task:#{target}",
      "type" => "depends_on",
      "status" => "waiting",
      "reason" => "Declared reason"
    }

  defp board(nodes, edges),
    do: %{
      workflow_graph: %{
        "version" => 1,
        "nodes" => nodes,
        "edges" => edges,
        "policy" => "human_acceptance"
      }
    }

  defp large_board, do: TaskGraphFixture.board()
end
