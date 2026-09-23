defmodule SymphonyElixirWeb.TaskReworkTest do
  use ExUnit.Case, async: true
  alias SymphonyElixirWeb.TaskRework
  @id String.duplicate("a", 32)
  @sha String.duplicate("b", 40)
  defp task, do: %{stage: "review", tracker_state: "open", issue_id: "11", ledger: %{}, pull_requests: []}

  test "corrections create separate work; closed issues and blank requests cannot silently queue" do
    assert {:ok, command} = TaskRework.prepare(task(), %{"instruction" => "Correct the README", "work_id" => "new"}, 3, @id, @sha)
    assert command["base_sha"] == @sha
    assert command["expected_revision"] == 3
    assert command["feedback"] == []
    assert {:error, :corrections_required} = TaskRework.prepare(task(), %{"instruction" => "", "work_id" => "new"}, 3, @id, @sha)
    assert {:error, :reopen_issue_required} = TaskRework.prepare(%{task() | tracker_state: "closed"}, %{}, 3, @id, @sha)
  end

  test "continuation binds the exact existing head and merged PR work cannot be reused" do
    work = %{"id" => @id, "head_sha" => @sha, "phase" => "owner_review", "updated_at" => "now", "publication" => %{"pr_number" => 14, "status" => "ready"}}
    task = %{task() | ledger: %{"pr_work" => %{@id => work}}, pull_requests: [%{number: 14, state: "OPEN"}]}
    assert [%{id: @id}] = TaskRework.options(task)
    assert {:ok, command} = TaskRework.prepare(task, %{"instruction" => "Fix checks", "work_id" => @id}, 3, @id, @sha)
    assert command["expected_head_sha"] == @sha
    assert TaskRework.options(%{task | pull_requests: [%{number: 14, state: "MERGED"}]}) == []
    assert {:error, :pr_work_not_found} = TaskRework.prepare(task, %{"instruction" => "Fix checks", "work_id" => "unknown"}, 3, @id, @sha)
  end

  test "selected comments retain the displayed exact revision and strip presentation fields" do
    first = feedback("comment-1")
    second = feedback("comment-2") |> Map.put("revision", String.duplicate("d", 64))
    displayed = Map.put(task(), :feedback, %{items: [Map.put(first, "status", "addressed"), second], status: "partial"})
    params = %{"instruction" => "  Verify the corrected behavior.  ", "work_id" => "new", "feedback_ids" => [second["id"]]}

    assert {:ok, command} = TaskRework.prepare(displayed, params, 4, @id, @sha)
    assert command["feedback"] == [second]
    assert command["instruction"] == "Verify the corrected behavior."
    assert command["issue_id"] == "11"
    assert command["command_id"] == @id
    assert command["expected_revision"] == 4

    edited = Map.put(first, "revision", String.duplicate("e", 64))
    displayed = put_in(displayed, [:feedback, :items], [Map.put(edited, "status", "pending")])
    assert {:ok, command} = TaskRework.prepare(displayed, %{params | "feedback_ids" => [first["id"]]}, 5, @id, @sha)
    assert command["feedback"] == [edited]
    refute command["feedback"] == [first]
  end

  test "blank corrections can use selected feedback once but cannot silently submit an empty task" do
    item = feedback("comment-1")
    displayed = Map.put(task(), :feedback, %{items: [item]})
    params = %{"instruction" => " \n\t ", "work_id" => "new", "feedback_ids" => [item["id"], item["id"]]}

    assert {:ok, command} = TaskRework.prepare(displayed, params, 3, @id, @sha)
    assert command["feedback"] == [item]
    assert command["instruction"] =~ "Address the selected human feedback"
    assert {:error, :corrections_required} = TaskRework.prepare(displayed, %{params | "feedback_ids" => []}, 3, @id, @sha)

    for instruction <- [nil, 4, %{}, [], String.duplicate("é", 4_001)] do
      assert {:error, :corrections_required} =
               TaskRework.prepare(displayed, %{params | "instruction" => instruction}, 3, @id, @sha)
    end
  end

  test "unknown, malformed and oversized selections cannot replace the displayed feedback" do
    item = feedback("comment-1")
    displayed = Map.put(task(), :feedback, %{items: [item]})
    params = %{"instruction" => "Apply corrections", "work_id" => "new", "feedback_ids" => []}

    for ids <- [["missing"], [item["id"], "missing"], [nil], [1], [%{"id" => item["id"]}]] do
      assert {:error, :feedback_changed} = TaskRework.prepare(displayed, %{params | "feedback_ids" => ids}, 3, @id, @sha)
    end

    for ids <- [nil, "comment-1", %{}, List.duplicate(item["id"], 21)] do
      assert {:error, :invalid_feedback} = TaskRework.prepare(displayed, %{params | "feedback_ids" => ids}, 3, @id, @sha)
    end

    for invalid <- [Map.put(item, "body", String.duplicate("x", 8_001)), Map.put(item, "revision", "old")] do
      malformed = put_in(displayed, [:feedback, :items], [invalid])

      assert {:error, :feedback_changed} =
               TaskRework.prepare(malformed, %{params | "feedback_ids" => [item["id"]]}, 3, @id, @sha)
    end

    duplicated_source = put_in(displayed, [:feedback, :items], [item, item])

    assert {:error, :feedback_changed} =
             TaskRework.prepare(duplicated_source, %{params | "feedback_ids" => [item["id"]]}, 3, @id, @sha)
  end

  test "only review tasks with an open tracker issue and valid baseline can be prepared" do
    params = %{"instruction" => "Correct behavior", "work_id" => "new"}

    for stage <- ["backlog", "ready", "running", "done"] do
      assert {:error, :task_not_in_review} = TaskRework.prepare(%{task() | stage: stage}, params, 3, @id, @sha)
    end

    for state <- [nil, "closed"] do
      assert {:error, :reopen_issue_required} =
               TaskRework.prepare(%{task() | tracker_state: state}, params, 3, @id, @sha)
    end

    for base <- [nil, "main", String.duplicate("f", 39)] do
      assert {:error, :invalid_command} = TaskRework.prepare(task(), params, 3, @id, base)
    end

    assert {:ok, _} = TaskRework.prepare(%{task() | tracker_state: "OPEN"}, params, 3, @id, @sha)
  end

  test "unpublished and published sessions are sorted and stale open observations cannot reopen merged work" do
    unpublished = work(@id, "2026-09-23T11:00:00Z", nil)
    published_id = String.duplicate("c", 32)
    receipt = %{"pr_number" => 14, "status" => "ready"}
    published = work(published_id, "2026-09-23T10:00:00Z", receipt)
    displayed = %{task() | ledger: %{"pr_work" => %{@id => unpublished, published_id => published}}}

    assert [%{id: @id, label: "Continue session aaaaaaaa"}, %{id: ^published_id, label: "Continue PR #14"}] =
             TaskRework.options(displayed)

    params = %{"instruction" => "Continue corrections", "work_id" => @id}
    assert {:ok, command} = TaskRework.prepare(displayed, params, 3, @id, @sha)
    assert command["action"] == "continue_pr_work"
    assert command["expected_head_sha"] == @sha

    stale = %{displayed | pull_requests: [%{number: 14, state: "OPEN"}]}
    stale = put_in(stale, [:ledger, "pr_work", published_id, "publication", "status"], "merged")
    assert [%{id: @id}] = TaskRework.options(stale)

    assert {:error, :pr_work_not_found} =
             TaskRework.prepare(stale, %{params | "work_id" => published_id}, 3, @id, @sha)

    for state <- ["CLOSED", "MERGED"] do
      assert [%{id: @id}] = TaskRework.options(%{displayed | pull_requests: [%{number: 14, state: state}]})
    end

    paused = put_in(stale, [:ledger, "pr_work", @id, "phase"], "paused")
    assert TaskRework.options(paused) == []
  end

  defp feedback(id) do
    %{
      "id" => id,
      "revision" => String.duplicate("c", 64),
      "body" => "Correct this behavior",
      "author" => "reviewer",
      "url" => "https://github.com/example/repo/issues/11#issuecomment-1",
      "source" => "issue",
      "pr_number" => nil
    }
  end

  defp work(id, updated, receipt) do
    %{"id" => id, "head_sha" => @sha, "phase" => "owner_review", "updated_at" => updated, "publication" => receipt}
  end
end
