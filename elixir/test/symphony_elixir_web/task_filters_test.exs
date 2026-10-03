defmodule SymphonyElixirWeb.TaskFiltersTest do
  use ExUnit.Case, async: true
  alias SymphonyElixirWeb.TaskFilters

  @project "github:example/tasks"
  @other "github:example/other"

  test "classification, native execution lanes and attention remain independent" do
    assert ids(%{"status" => "work"}) == ["2", "6"]
    assert ids(%{"status" => "ready"}) == ["2"]
    assert ids(%{"status" => "in_progress"}) == ["3"]
    assert ids(%{"status" => "running"}) == ["3"]
    assert ids(%{"status" => "attention"}) == ["4", "6"]
    assert ids(%{"status" => "review,done"}) == ["4", "5"]
    assert ids(%{"kind" => "bug,security", "priority" => "P2"}) == ["2", "4"]
    assert ids(%{"kind" => "invalid", "priority" => "—"}) == ["6"]
    assert ids(%{"priority" => "—"}) == ["3", "6"]
    assert ids(%{"kind" => "operations"}) == ["3"]
  end

  test "current execution stage wins over a stale projected lane" do
    board = %{tasks: [task("1", %{stage: "running", lane: "work"}), task("2", %{stage: "ready", lane: "in_progress"})]}
    assert TaskFilters.visible_ids(board, %{"status" => "in_progress"}, nil) == [@project <> ":1"]
    assert TaskFilters.visible_ids(board, %{"status" => "work"}, nil) == [@project <> ":2"]
  end

  test "metadata values use OR within a filter and AND across filters without splitting labels" do
    labels = Jason.encode!(["label:bug, ui", "label:category:performance"])
    assert ids(%{"label" => labels}) == ["1", "5"]
    assert ids(%{"label" => labels, "assignee" => Jason.encode!(["assignee:bob"])}) == ["1"]
    assert ids(%{"label" => Jason.encode!(["__none__"])}) == ["3", "6"]
    assert ids(%{"label" => Jason.encode!(["__none__", "label:category:performance"])}) == ["1", "3", "5", "6"]
    assert ids(%{"assignee" => Jason.encode!(["__none__"])}) == ["3", "4", "6"]
    assert ids(%{"milestone" => Jason.encode!(["__none__"])}) == ["3", "4", "6"]
    assert ids(%{"milestone" => Jason.encode!(["milestone:#{@project}:7"])}) == ["1"]
    assert ids(%{"milestone" => Jason.encode!(["milestone:#{@other}:7"])}) == ["5"]
  end

  test "query matches the shipped card search fields, case-insensitively, without routing labels" do
    assert ids(%{"q" => "GH-3"}) == ["3"]
    assert ids(%{"q" => "LOGIN"}) == ["2"]
    assert ids(%{"q" => "security"}) == ["4"]
    assert ids(%{"q" => "Launch"}) == ["1"]
    assert ids(%{"q" => "@BOB"}) == ["1", "2"]
    assert ids(%{"q" => "category:performance"}) == ["1", "5"]
    assert ids(%{"q" => "symphony:ready"}) == []
    assert ids(%{"q" => "kind:feature"}) == []
  end

  test "project scope uses canonical task IDs and does not collide on issue numbers" do
    assert ids(%{"project" => @other}) == ["5"]
    assert ids(%{"project" => @project <> "," <> @other}) == ~w(1 2 3 4 5 6)
    assert ids(%{}, @project) == ~w(1 2 3 4 6)
    assert ids(%{"project" => @other}, @project) == []
    board = %{tasks: [task("1"), task("1"), task("1", %{project: @other, id: @other <> ":1"})]}
    assert TaskFilters.visible_ids(board, %{}, nil) == [@project <> ":1", @other <> ":1"]
  end

  test "invalid filter input never widens a requested selection or crashes" do
    for filters <- [
          %{"label" => "not JSON"},
          %{"label" => "null"},
          %{"label" => "{}"},
          %{"label" => "[7]"},
          %{"milestone" => "[\"milestone:missing:0\"]"},
          %{"assignee" => Jason.encode!(["assignee:"])},
          %{"label" => Jason.encode!(["assignee:bob"])},
          %{"assignee" => Jason.encode!(["label:backend"])},
          %{"label" => Jason.encode!(["label:KIND:feature"])},
          %{"label" => Jason.encode!(["label:Ready"])},
          %{"label" => Jason.encode!(["label:WORK:operations"])},
          %{"label" => Jason.encode!(["label:backend" <> <<0>>])},
          %{"label" => Jason.encode!(List.duplicate("label:backend", 21))},
          %{"label" => Jason.encode!(["label:" <> String.duplicate("x", 241)])},
          %{"q" => %{}},
          %{"q" => String.duplicate("x", 2_001)},
          %{"status" => ["work"]},
          %{"status" => "unknown"},
          %{"status" => "failed"},
          %{"priority" => "P0"},
          %{"kind" => "unknown"}
        ] do
      assert ids(filters) == [], inspect(filters)
    end

    assert ids(%{"label" => "[]"}) == ~w(1 2 3 4 5 6)
    assert ids(%{"label" => "", "status" => ""}) == ~w(1 2 3 4 5 6)
    board = %{tasks: [nil, %{}, %{id: "valid", labels: %{}, assignees: :bad, milestone: []}]}
    assert TaskFilters.visible_ids(board, %{}, nil) == ["valid"]
    assert TaskFilters.visible_ids(%{tasks: nil}, %{}, nil) == []
    assert TaskFilters.visible_ids(nil, %{}, nil) == []
    assert TaskFilters.visible_ids(%{tasks: [task("1", %{priority: 5})]}, %{"priority" => "P5"}, nil) == []
  end

  defp ids(filters, project \\ nil), do: fixtures() |> TaskFilters.visible_ids(filters, project) |> Enum.map(&List.last(String.split(&1, ":")))

  defp fixtures do
    %{
      tasks: [
        task("1", %{
          title: "Improve speed",
          priority: 1,
          labels: ["kind:feature", "category:performance", "bug, ui", "symphony:ready", "ready"],
          assignees: ["alice", "bob"],
          milestone: %{id: "7", title: "Launch"}
        }),
        task("2", %{
          title: "Fix login",
          stage: "ready",
          priority: 2,
          labels: ["kind:bug", "backend"],
          assignees: ["bob"],
          milestone: %{id: "8", title: "Beta"}
        }),
        task("3", %{stage: "running", labels: ["work:operations"]}),
        task("4", %{stage: "review", priority: 2, labels: ["kind:security", "auth"], attention: "Changes requested"}),
        task("5", %{
          project: @other,
          id: @other <> ":5",
          stage: "done",
          priority: 3,
          labels: ["kind:testing", "category:performance"],
          assignees: ["alice"],
          milestone: %{"id" => "7", "title" => "Release"}
        }),
        task("6", %{stage: "failed", lane: "work", priority: 0, labels: ["kind:feature", "kind:bug", "priority:P2", "RUNNING"], attention: "Failed"})
      ]
    }
  end

  defp task(id, fields \\ %{}) do
    Map.merge(
      %{
        id: @project <> ":" <> id,
        project: @project,
        identifier: "GH-" <> id,
        title: "Task " <> id,
        stage: "backlog",
        priority: nil,
        labels: [],
        assignees: [],
        milestone: nil,
        attention: nil
      },
      fields
    )
  end
end
