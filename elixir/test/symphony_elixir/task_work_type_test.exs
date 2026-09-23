defmodule SymphonyElixir.TaskWorkTypeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TaskWorkType

  test "existing labels classify independently of routing, priority and label representation" do
    assert TaskWorkType.from_labels(nil) == "unclassified"
    assert TaskWorkType.from_labels(["ready", "priority:p1", %{}, nil]) == "unclassified"
    assert TaskWorkType.from_labels([%{"name" => " WORK:Infrastructure "}, "ready"]) == "infrastructure"

    for value <- ~w(application infrastructure deployment operations) do
      assert TaskWorkType.from_labels(["work:" <> value]) == value
    end
  end

  test "conflicting, duplicate and unknown work labels remain visibly invalid" do
    for labels <- [["work:application", "work:deployment"], ["work:application", "work:application"], ["work:future"], ["work:unclassified"], ["work:"]] do
      assert TaskWorkType.from_labels(labels) == "invalid"
    end

    assert TaskWorkType.label("invalid") == "Needs classification"
    refute "invalid" in TaskWorkType.values()
    assert {"Unclassified", "unclassified"} in TaskWorkType.options()
  end

  test "reclassification repairs conflicts and preserves unrelated labels exactly" do
    labels = ["Ready", "priority:p1", "Publish-approved", "WORK:application", "work:unknown"]
    assert TaskWorkType.update_labels(labels, "operations") == ["Ready", "priority:p1", "Publish-approved", "work:operations"]
    assert TaskWorkType.update_labels(labels, "unclassified") == ["Ready", "priority:p1", "Publish-approved"]
    assert_raise FunctionClauseError, fn -> TaskWorkType.update_labels(labels, "invalid") end
  end
end
