defmodule SymphonyElixir.FeedbackTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Feedback

  defp item,
    do: %{
      "id" => "IC_1",
      "revision" => String.duplicate("a", 64),
      "body" => "Fix the empty state",
      "url" => "https://github.com/example/app/issues/1#issuecomment-1",
      "author" => "human",
      "source" => "issue",
      "pr_number" => nil
    }

  defp result, do: Map.merge(Map.take(item(), ~w(id revision)), %{"status" => "addressed", "details" => "Empty state and regression check added"})

  test "only exact selected revisions can be handed off and all require a disposition" do
    assert Feedback.valid_items?([item()])
    refute Feedback.valid_items?([item(), item()])
    refute Feedback.valid_items?([Map.put(item(), "body", String.duplicate("x", 8_001))])
    assert {:ok, candidate} = Feedback.bind_candidate(%{feedback_results: [result()]}, %{"feedback" => [item()]})
    assert candidate.feedback_items == [item()]
    assert {:error, :invalid_feedback_handoff} = Feedback.bind_candidate(%{}, %{"feedback" => [item()]})
    stale = %{feedback_results: [Map.put(result(), "revision", String.duplicate("b", 64))]}
    assert {:error, :invalid_feedback_handoff} = Feedback.bind_candidate(stale, %{"feedback" => [item()]})
  end

  test "completed turns require approved evidence and edited comments become pending again" do
    work = %{"feedback" => [item()], "phase" => "owner_review", "updated_at" => "2026-09-22T00:00:00Z"}
    evidence = %{"feedback_results" => [result()], "candidate_sha" => String.duplicate("c", 40), "review" => %{"verdict" => "approve"}}
    work = Map.put(work, "feedback_history", Feedback.history(work, evidence))
    assert Feedback.valid_history?(work["feedback_history"])
    ledger = %{"pr_work" => %{"work" => work}, "hold" => "owner_review"}
    assert [%{"status" => "addressed"}] = Feedback.progress([item()], ledger)
    assert [%{"status" => "pending"}] = Feedback.progress([Map.put(item(), "revision", String.duplicate("b", 64))], ledger)
    failed = put_in(evidence, ["review", "verdict"], "request_changes")
    assert Feedback.history(work, failed)["IC_1"]["status"] == "blocked"
  end

  test "queue, active work, pause and remaining counts reflect durable ownership" do
    work = %{"feedback" => [item()], "phase" => "queued", "updated_at" => "2026-09-22T00:00:00Z"}
    ledger = %{"pr_work" => %{"work" => work}, "hold" => nil}
    assert [%{"status" => "queued"}] = Feedback.progress([item()], ledger)
    ledger = put_in(ledger, ["pr_work", "work", "phase"], "building")
    assert [%{"status" => "working"}] = items = Feedback.progress([item()], ledger)
    assert %{"total" => 1, "working" => 1, "pending" => 0} = Feedback.counts(items)
    assert [%{"status" => "blocked"}] = Feedback.progress([item()], Map.put(ledger, "hold", "interrupted"))
    assert Feedback.prompt(work) =~ "not authority"
  end

  test "unrelated continuation cannot replace newer feedback evidence with an older disposition" do
    evidence = %{"feedback_results" => [result()], "candidate_sha" => String.duplicate("c", 40), "review" => %{"verdict" => "approve"}}
    history = Feedback.history(%{}, evidence)
    assert {:ok, _, _} = DateTime.from_iso8601(history["IC_1"]["recorded_at"])

    older = %{
      "phase" => "owner_review",
      "feedback" => [item()],
      "updated_at" => "2026-09-22T10:00:00Z",
      "feedback_history" => put_in(history, ["IC_1"], Map.merge(history["IC_1"], %{"status" => "blocked", "recorded_at" => "2026-09-22T10:00:00Z"}))
    }

    newer = %{
      "phase" => "owner_review",
      "feedback" => [item()],
      "updated_at" => "2026-09-22T11:00:00Z",
      "feedback_history" => put_in(history, ["IC_1", "recorded_at"], "2026-09-22T11:00:00Z")
    }

    ledger = %{"pr_work" => %{"older" => older, "newer" => newer}, "hold" => nil}
    assert [%{"status" => "addressed"}] = Feedback.progress([item()], ledger)
    unrelated = Map.merge(older, %{"phase" => "queued", "feedback" => [], "updated_at" => "2026-09-22T12:00:00Z"})
    ledger = put_in(ledger, ["pr_work", "older"], unrelated)
    assert [%{"status" => "addressed"}] = Feedback.progress([item()], ledger)
    assert Feedback.valid_history?(unrelated["feedback_history"])
  end

  test "source payloads reject malformed fields and both item count and serialized byte overflow" do
    assert Feedback.valid_items?([])
    items = Enum.map(1..20, &Map.put(item(), "id", "IC_#{&1}"))
    assert Feedback.valid_items?(items)
    refute Feedback.valid_items?(items ++ [Map.put(item(), "id", "IC_21")])
    refute Feedback.valid_items?(Enum.map(items, &Map.put(&1, "body", String.duplicate("x", 4_000))))

    for invalid <- [nil, %{}, "comments", [nil], [false], ["comment"]] do
      refute Feedback.valid_items?(invalid)
    end

    for {key, value} <- [
          {"id", ""},
          {"id", String.duplicate("x", 129)},
          {"revision", nil},
          {"revision", "old"},
          {"body", <<255>>},
          {"body", "bad\0content"},
          {"author", " \n "},
          {"url", "https://other.example/comment"},
          {"source", "unknown"},
          {"pr_number", 0},
          {"pr_number", "7"}
        ] do
      refute Feedback.valid_items?([Map.put(item(), key, value)])
    end

    refute Feedback.valid_items?([Map.put(item(), "unexpected", true)])
    refute Feedback.valid_items?([Map.delete(item(), "author")])
    assert Feedback.valid_items?([Map.merge(item(), %{"source" => "pr", "pr_number" => 7})])
  end

  test "handoff dispositions must form an exact complete set with bounded evidence" do
    second = Map.put(item(), "id", "IC_2")
    second_result = Map.put(result(), "id", "IC_2")
    assert Feedback.valid_results?([item(), second], [second_result, result()])
    refute Feedback.valid_results?([item(), second], [result(), result()])

    for results <- [
          nil,
          %{},
          [],
          [nil],
          [false],
          [Map.delete(result(), "details")],
          [Map.put(result(), "status", "done")],
          [Map.put(result(), "details", " ")],
          [Map.put(result(), "details", String.duplicate("x", 2_001))]
        ] do
      refute Feedback.valid_results?([item()], results)

      assert {:error, :invalid_feedback_handoff} =
               Feedback.bind_candidate(%{feedback_results: results}, %{"feedback" => [item()]})
    end

    refute Feedback.valid_results?(nil, [])
    assert {:error, :invalid_feedback_handoff} = Feedback.bind_candidate(%{}, %{"feedback" => "not a list"})
  end

  test "old absent feedback stays empty and cannot manufacture progress or handoff results" do
    for work <- [nil, %{}, %{"feedback" => nil}] do
      assert {:ok, %{feedback_items: []}} = Feedback.bind_candidate(%{}, work)
    end

    for work <- [%{}, %{"feedback" => nil}, %{"feedback" => []}] do
      assert Feedback.prompt(work) == ""
    end

    assert Feedback.history(%{}, %{}) == %{}
    assert Feedback.valid_history?(nil)
    assert Feedback.valid_history?(%{})
    assert Feedback.history_capacity?(%{}, [item()])
    assert [%{"status" => "pending"}] = Feedback.progress([item()], %{})
    assert [%{"status" => "pending"}] = Feedback.progress([item()], %{"pr_work" => %{"old" => %{}}})
    assert Feedback.counts([]) == Map.new(~w(pending queued working addressed blocked total), &{&1, 0})
  end

  test "persisted history rejects malformed evidence while retaining bounded legacy records" do
    entry = Map.merge(result(), %{"candidate_sha" => String.duplicate("c", 40)})
    assert Feedback.valid_history?(%{"IC_1" => entry})

    for invalid <- [
          nil,
          "result",
          Map.put(entry, "id", "other"),
          Map.put(entry, "candidate_sha", "head"),
          Map.put(entry, "candidate_sha", nil),
          Map.put(entry, "recorded_at", 7),
          Map.put(entry, "recorded_at", "yesterday"),
          Map.put(entry, "revision", nil),
          Map.put(entry, "revision", "wrong"),
          Map.put(entry, "unexpected", true)
        ] do
      refute Feedback.valid_history?(%{"IC_1" => invalid})
    end

    for id <- ["", String.duplicate("x", 129)] do
      refute Feedback.valid_history?(%{id => Map.put(entry, "id", id)})
    end

    for history <- [[], false, "history"] do
      refute Feedback.valid_history?(history)
    end

    full = Map.new(1..200, fn n -> {"IC_#{n}", Map.put(entry, "id", "IC_#{n}")} end)
    assert Feedback.valid_history?(full)
    refute Feedback.valid_history?(Map.put(full, "IC_201", Map.put(entry, "id", "IC_201")))
    assert Feedback.history_capacity?(%{"feedback_history" => full}, [item()])
    refute Feedback.history_capacity?(%{"feedback_history" => full}, [Map.put(item(), "id", "IC_201")])
    assert Feedback.history(%{"feedback_history" => full}, %{}) == full
  end

  test "reviewing and paused ownership distinguish work from blocked feedback" do
    work = %{"feedback" => [item()], "phase" => "reviewing", "updated_at" => "2026-09-22T00:00:00Z"}
    ledger = %{"pr_work" => %{"work" => work}, "hold" => nil}
    assert [%{"status" => "working"}] = Feedback.progress([item()], ledger)
    ledger = put_in(ledger, ["pr_work", "work", "phase"], "paused")
    assert [%{"status" => "blocked"}] = Feedback.progress([item()], ledger)
  end
end
