defmodule SymphonyElixir.PRWorkTest do
  use ExUnit.Case
  alias SymphonyElixir.{ControlLedger, PRWork}

  @work String.duplicate("a", 32)
  @other String.duplicate("b", 32)
  @base String.duplicate("a", 40)
  @head String.duplicate("b", 40)
  @context %{tracker_fingerprint: "configured-tracker", base_sha: @base, repository: "owner/repo"}

  defmodule HTTPAdapter do
    import ExUnit.Assertions

    def run(request) do
      assert request.url.host == "api.github.com"
      assert request.url.path == "/repos/owner/repo/pulls/18"
      assert request.options[:retry] == false
      assert request.options[:redirect] == false
      assert Req.Request.get_header(request, "authorization") == ["Bearer fixture"]
      {request, Process.get(:pr_work_http_response)}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-pr-work-#{System.unique_integer([:positive])}") |> Path.expand()
    File.mkdir_p!(root)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    budgets = %{max_attempts: 8, max_total_runtime_ms: 60_000, max_total_tokens: 1_000}
    settings = Map.merge(budgets, %{state_path: root <> "/control.json", initial_mode: "running"})
    {:ok, ledger} = ControlLedger.open(settings, root <> "/workspaces")

    on_exit(fn ->
      ControlLedger.close(ledger)
      File.rm_rf!(root)
    end)

    %{ledger: ledger, root: root}
  end

  test "two PR work identities retain separate threads, exact reviews and shared issue budgets", c do
    create = create()
    assert {:ok, ledger, %{"work_id" => @work}, false} = ControlLedger.command(c.ledger, create, 5, @context)
    assert {:ok, ^ledger, _, true} = ControlLedger.command(ledger, create, 5, @context)
    reused_id = %{create | "issue_id" => "8", "command_id" => "cross-issue", "expected_revision" => 1}
    assert {:error, :pr_work_exists} = ControlLedger.command(ledger, reused_id, 5, @context)
    assert {:error, :command_id_conflict} = ControlLedger.command(ledger, %{create | "instruction" => "different scope"}, 5, @context)
    assert {:error, :pr_work_pending} = ControlLedger.command(ledger, create(@other, 1), 5, @context)
    assert {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    assert {:error, :not_admitted} = ControlLedger.reserve(ledger, "7")
    assert get_in(ledger.data, ["issues", "7", "active", "work_id"]) == @work
    assert {:ok, ledger} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"builder_thread_id" => "builder-A"})
    assert {:ok, ledger} = ControlLedger.tokens(ledger, "7", run, 120)
    assert {:error, :stale_run} = ControlLedger.tokens(ledger, "7", "stale", 900)
    assert {:ok, ledger} = ControlLedger.finish(ledger, "7", run, "owner_review", evidence(run))
    assert {:error, :pr_work_continuation_required} = ControlLedger.command(ledger, cmd("retry", 1), 5, @context)
    assert {:error, :not_admitted} = ControlLedger.reserve(ledger, "7")
    assert {:error, :pr_head_changed} = ControlLedger.command(ledger, continue(1, nil), 5, @context)
    assert {:ok, ledger, _, false} = ControlLedger.command(ledger, continue(1, @head), 5, @context)
    assert {:ok, ledger, run2, _} = ControlLedger.reserve(ledger, "7")
    assert ControlLedger.selected_work(ledger, "7")["builder_thread_id"] == "builder-A"
    assert {:error, :stale_run} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"builder_thread_id" => "builder-A"})
    assert {:error, :builder_thread_changed} = ControlLedger.checkpoint_pr_work(ledger, "7", run2, @work, %{"builder_thread_id" => "builder-B"})
    assert {:ok, ledger} = ControlLedger.finish(ledger, "7", run2, "owner_review", evidence(run2, @work, @head))
    assert {:ok, ledger, _, false} = ControlLedger.command(ledger, create(@other, 2), 5, @context)
    assert ledger.data["issues"]["7"]["hold"] == nil
    assert {:ok, ledger, run3, _} = ControlLedger.reserve(ledger, "7")
    assert ControlLedger.selected_work(ledger, "7")["id"] == @other
    assert ControlLedger.selected_work(ledger, "7")["builder_thread_id"] == nil
    assert {:ok, ledger} = ControlLedger.checkpoint_pr_work(ledger, "7", run3, @other, %{"builder_thread_id" => "builder-B"})
    assert {:ok, ledger} = ControlLedger.tokens(ledger, "7", run3, 90)
    assert {:ok, ledger} = ControlLedger.finish(ledger, "7", run3, "owner_review", %{evidence(run3, @other) | "builder_session_id" => "builder-B-turn"})
    issue = ledger.data["issues"]["7"]
    assert issue["tokens"] == 210
    assert issue["attempts"] == 3
    assert issue["pr_work"][@work]["builder_thread_id"] == "builder-A"
    assert issue["pr_work"][@other]["builder_thread_id"] == "builder-B"
    assert issue["pr_work"][@work]["branch"] != issue["pr_work"][@other]["branch"]
    assert {:ok, ledger, false} = ControlLedger.record_pr_publication(ledger, publication(run2) |> Map.put("expected_head_sha", @head), @context)
    assert ledger.data["issues"]["7"]["pr_work"][@work]["published_head_sha"] == @head
    assert ledger.data["issues"]["7"]["pr_work"][@other]["published_head_sha"] == nil
    assert ledger.data["issues"]["7"]["handoff"]["work_id"] == @other
    assert PRWork.valid_issue?("7", issue)
    ControlLedger.close(ledger)
    assert {:ok, reopened} = ControlLedger.open(ledger.settings, c.root <> "/workspaces")
    assert reopened.data["issues"] == ledger.data["issues"]
    ControlLedger.close(reopened)
  end

  test "restart pauses the exact PR work and keeps the builder identity and consumed budget", c do
    {:ok, ledger, _, _} = ControlLedger.command(c.ledger, create(), 5, @context)
    {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    {:ok, ledger} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"builder_thread_id" => "builder-A"})
    {:ok, ledger} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"working_head_sha" => @head})
    {:ok, ledger} = ControlLedger.tokens(ledger, "7", run, 17)
    ControlLedger.close(ledger)
    assert {:ok, reopened} = ControlLedger.open(ledger.settings, c.root <> "/workspaces")
    issue = reopened.data["issues"]["7"]
    assert reopened.data["mode"] == "paused"
    assert issue["hold"] == "interrupted"
    assert issue["active"] == nil
    assert issue["tokens"] == 17
    assert issue["attempts"] == 1
    assert PRWork.selected(issue)["phase"] == "paused"
    assert PRWork.selected(issue)["builder_thread_id"] == "builder-A"
    assert PRWork.selected(issue)["working_head_sha"] == @head
    assert PRWork.selected(issue)["head_sha"] == nil
    assert {:error, :not_admitted} = ControlLedger.reserve(reopened, "7")
    assert {:ok, reopened, _, _} = ControlLedger.command(reopened, cmd("retry", 1), 5, @context)
    assert {:ok, reopened, _, _} = ControlLedger.command(reopened, Map.put(cmd("resume", 2), "issue_id", nil), 5, @context)
    assert {:ok, reopened, _, _} = ControlLedger.reserve(reopened, "7")
    ControlLedger.close(reopened)
  end

  test "cancelled queued work accepts a scoped continuation without clearing its hold", c do
    {:ok, ledger, _, _} = ControlLedger.command(c.ledger, create(), 5, @context)
    {:ok, ledger, _, _} = ControlLedger.command(ledger, cmd("cancel", 1), 5, @context)
    assert ControlLedger.selected_work(ledger, "7")["phase"] == "paused"
    assert {:ok, ledger, _, _} = ControlLedger.command(ledger, continue(2, nil), 5, @context)
    assert ledger.data["issues"]["7"]["hold"] == "cancelled"
    assert {:error, :not_admitted} = ControlLedger.reserve(ledger, "7")
    assert {:ok, ledger, _, _} = ControlLedger.command(ledger, cmd("retry", 3), 5, @context)
    assert {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    assert {:ok, ledger} = ControlLedger.hold(ledger, "7", "cancelled")
    assert {:error, :stale_run} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"builder_thread_id" => "late"})
    assert {:ok, ledger} = ControlLedger.finish(ledger, "7", run)
    assert ControlLedger.selected_work(ledger, "7")["phase"] == "paused"
    assert {:error, :stale_run} = ControlLedger.finish(ledger, "7", run)
    assert {:ok, ledger, _, _} = ControlLedger.command(ledger, cmd("retry", 4), 5, @context)
    assert {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    assert {:ok, ledger} = ControlLedger.finish(ledger, "7", run)
    assert ControlLedger.selected_work(ledger, "7")["phase"] == "queued"
  end

  test "new PR work preserves non-review holds and the original legacy handoff", c do
    legacy = %{"candidate_sha" => @head, "run_id" => "legacy-run", "branch" => "codex/gh-7"}
    {:ok, ledger} = ControlLedger.hold(c.ledger, "7", "owner_review")
    ledger = put_in(ledger.data["issues"]["7"]["handoff"], legacy)
    {:ok, ledger, _, _} = ControlLedger.command(ledger, create(), 5, @context)
    assert ledger.data["issues"]["7"]["legacy_handoff"] == legacy
    assert ledger.data["issues"]["7"]["hold"] == nil
    {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    {:ok, ledger} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"builder_thread_id" => "builder-A"})
    {:ok, ledger} = ControlLedger.finish(ledger, "7", run, "owner_review", evidence(run))

    for hold <- ~w(cancelled interrupted token_budget runtime_budget) do
      {:ok, held} = ControlLedger.hold(ledger, "7", hold)
      {:ok, next, _, _} = ControlLedger.command(held, create(@other, 1), 5, @context)
      assert next.data["issues"]["7"]["hold"] == hold
      assert next.data["issues"]["7"]["legacy_handoff"] == legacy
      assert {:error, :not_admitted} = ControlLedger.reserve(next, "7")
    end

    ControlLedger.close(ledger)
    {:ok, reopened} = ControlLedger.open(ledger.settings, c.root <> "/workspaces")
    assert reopened.data["issues"]["7"]["legacy_handoff"] == legacy
    ControlLedger.close(reopened)
  end

  test "exact candidate and publication fences preserve issue ownership and prior evidence", c do
    {ledger, run} = reviewed(c.ledger)
    receipt = publication(run)
    assert {:ok, ledger, false} = ControlLedger.record_pr_publication(ledger, receipt, @context)
    assert {:ok, ^ledger, true} = ControlLedger.record_pr_publication(ledger, receipt, @context)
    work = ControlLedger.selected_work(ledger, "7")
    assert work["head_sha"] == @head
    assert work["published_head_sha"] == @head
    assert work["publication"] == receipt
    assert ledger.data["issues"]["7"]["hold"] == "owner_review"
    assert PRWork.valid_issue?("7", ledger.data["issues"]["7"])
    assert {:error, :pr_head_changed} = ControlLedger.record_pr_publication(ledger, %{receipt | "candidate_sha" => @base}, @context)
    foreign = %{@context | tracker_fingerprint: "different"}
    assert {:error, :tracker_changed} = ControlLedger.record_pr_publication(ledger, receipt, foreign)
    other_pr = %{receipt | "pr_number" => 19, "pr_url" => "https://github.com/owner/repo/pull/19"}
    assert {:error, :pr_identity_changed} = ControlLedger.record_pr_publication(ledger, other_pr, @context)
    assert {:error, :invalid_publication} = ControlLedger.record_pr_publication(ledger, Map.put(receipt, "extra", "injected"), @context)
    merged = Map.merge(receipt, %{"status" => "merged", "merge_sha" => @base})
    assert {:ok, ledger, false} = ControlLedger.record_pr_publication(ledger, merged, @context)
    assert {:error, :pr_already_merged} = ControlLedger.record_pr_publication(ledger, receipt, @context)
    assert {:error, :pr_already_merged} = PRWork.verify_remote(ControlLedger.selected_work(ledger, "7"), tracker())
    assert {:ok, ledger} = ControlLedger.hold(ledger, "7", "cancelled")
    assert {:error, :pr_work_pending} = ControlLedger.record_pr_publication(ledger, merged, @context)
  end

  test "untrusted candidate, thread and command fields cannot alter ownership", c do
    {:ok, ledger, _, _} = ControlLedger.command(c.ledger, create(), 5, @context)
    assert {:error, :pr_work_exists} = ControlLedger.command(ledger, create(@work, 1), 5, @context)
    assert {:error, :invalid_command} = ControlLedger.command(ledger, Map.put(create(@other, 1), "workspace_key", "outside"), 5, @context)
    assert {:error, :invalid_command} = ControlLedger.command(ledger, %{create(@other, 1) | "instruction" => " "}, 5, @context)
    assert {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    assert {:error, :issue_running} = ControlLedger.command(ledger, create(@other, 1), 5, @context)
    assert {:error, :invalid_checkpoint} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"phase" => "reviewing"})
    assert {:error, :invalid_checkpoint} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{})
    assert {:error, :invalid_checkpoint} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"working_head_sha" => "invalid"})
    assert {:error, :stale_run} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @other, %{"builder_thread_id" => "builder-A"})
    assert {:ok, ledger} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"builder_thread_id" => "builder-A"})
    assert {:ok, ledger} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"phase" => "reviewing"})
    assert {:ok, same_usage} = ControlLedger.tokens(ledger, "7", run, 0, %{"thread_id" => "unrelated"})
    assert ControlLedger.selected_work(same_usage, "7")["builder_usage"] == ControlLedger.selected_work(ledger, "7")["builder_usage"]
    assert {:error, :invalid_pr_handoff} = ControlLedger.finish(ledger, "7", run, "owner_review", [])

    for field <- ~w(work_id run_id expected_head_sha base_sha branch candidate_sha builder_session_id review) do
      assert {:error, :invalid_pr_handoff} = ControlLedger.finish(ledger, "7", run, "owner_review", Map.put(evidence(run), field, "wrong"))
    end

    assert {:ok, ledger} = ControlLedger.finish(ledger, "7", run, "owner_review", evidence(run))
    foreign = %{@context | tracker_fingerprint: "changed"}
    changed_base = %{@context | base_sha: @head}
    assert {:error, :tracker_changed} = ControlLedger.command(ledger, continue(1, @head), 5, foreign)
    assert {:error, :approved_baseline_changed} = ControlLedger.command(ledger, continue(1, @head), 5, changed_base)
    assert {:error, :pr_work_not_found} = ControlLedger.command(ledger, Map.put(continue(1, @head), "work_id", @other), 5, @context)
    assert {:error, :tracker_changed} = ControlLedger.command(ledger, create(@other, 1), 5, foreign)
    unauthorized_base = %{create(@other, 1) | "base_sha" => @head}
    assert {:error, :approved_baseline_changed} = ControlLedger.command(ledger, unauthorized_base, 5, @context)
  end

  test "budget exhaustion and failed storage do not create or checkpoint another work", c do
    {ledger, _run} = reviewed(c.ledger)
    exhausted = put_in(ledger.data["issues"]["7"]["tokens"], 1_000)
    assert {:error, :budget_exhausted} = ControlLedger.command(exhausted, create(@other, 1), 5, @context)
    assert {:error, :budget_exhausted} = ControlLedger.command(exhausted, continue(1, @head), 5, @context)
    {:ok, ledger, _, _} = ControlLedger.command(ledger, continue(1, @head), 5, @context)
    {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    retained = File.read!(ledger.path)
    File.rename!(ledger.path, ledger.path <> ".saved")
    File.mkdir!(ledger.path)
    assert {:error, {:control_persistence, _}} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"builder_thread_id" => "builder-A"})
    assert File.read!(ledger.path <> ".saved") == retained
  end

  test "published PR continuation reads fresh remote identity, head and base", c do
    {ledger, run} = reviewed(c.ledger)
    {:ok, ledger, _} = ControlLedger.record_pr_publication(ledger, publication(run), @context)
    work = ControlLedger.selected_work(ledger, "7")

    pr = %{
      "number" => 18,
      "html_url" => "https://github.com/owner/repo/pull/18",
      "state" => "open",
      "merged" => false,
      "head" => %{"sha" => @head, "ref" => work["branch"], "repo" => %{"full_name" => "owner/repo"}},
      "base" => %{"sha" => @base, "repo" => %{"full_name" => "owner/repo"}}
    }

    previous = Application.get_env(:symphony_elixir, :pr_work_github_request)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :pr_work_github_request, previous)
      else
        Application.delete_env(:symphony_elixir, :pr_work_github_request)
      end
    end)

    stub = fn value ->
      request = fn "GET", "/repos/owner/repo/pulls/18", %{}, nil, _ -> value end
      Application.put_env(:symphony_elixir, :pr_work_github_request, request)
    end

    stub.({:ok, %{status: 200, body: pr}})
    assert :ok = PRWork.verify_remote(work, tracker())
    stub.({:ok, %{status: 200, body: put_in(pr["head"]["sha"], @base)}})
    assert {:error, :pr_head_changed} = PRWork.verify_remote(work, tracker())
    stub.({:ok, %{status: 200, body: put_in(pr["base"]["sha"], @head)}})
    assert {:error, :approved_baseline_changed} = PRWork.verify_remote(work, tracker())
    stub.({:error, :disconnected})
    assert {:error, :pr_evidence_unavailable} = PRWork.verify_remote(work, tracker())

    for malformed <- [nil, [], "not a PR"] do
      stub.({:ok, %{status: 200, body: malformed}})
      assert {:error, :pr_evidence_unavailable} = PRWork.verify_remote(work, tracker())
    end

    stub.({:ok, %{status: 200, body: Map.put(pr, "head", "malformed")}})
    assert {:error, :pr_head_changed} = PRWork.verify_remote(work, tracker())
    assert {:error, :unsupported_tracker_scope} = PRWork.verify_remote(work, %{tracker() | kind: "linear"})
    assert :ok = PRWork.verify_remote(nil, tracker())
    assert :ok = PRWork.verify_remote(%{"published_head_sha" => nil}, tracker())
  end

  test "corrupted retained PR bindings fail closed on load", c do
    {ledger, run} = reviewed(c.ledger)
    {:ok, ledger, _} = ControlLedger.record_pr_publication(ledger, publication(run), @context)
    ControlLedger.close(ledger)

    for corrupt <- [
          put_in(ledger.data["issues"]["7"]["selected_work_id"], @other),
          put_in(ledger.data["issues"]["7"]["pr_work"][@work]["workspace_key"], "../other"),
          put_in(ledger.data["issues"]["7"]["pr_work"][@work]["handoff"], "not an object"),
          put_in(ledger.data["issues"]["7"]["pr_work"][@work]["handoff"]["review"], false),
          put_in(ledger.data["issues"]["7"]["pr_work"][@work]["handoff"]["expected_head_sha"], "invalid"),
          update_in(ledger.data["issues"]["7"]["pr_work"][@work]["handoff"], &Map.delete(&1, "expected_head_sha")),
          put_in(ledger.data["issues"]["7"]["legacy_handoff"], %{"work_id" => @work}),
          put_in(ledger.data["issues"]["7"]["pr_work"][@work]["publication"]["candidate_sha"], @base),
          put_in(ledger.data["issues"]["7"]["pr_work"][@work]["publication"]["pr_url"], "https://foreign.invalid/18"),
          put_in(ledger.data["issues"]["7"]["pr_work"][@work]["publication"], nil),
          put_in(ledger.data["issues"]["7"]["pr_work"][@work], false),
          put_in(ledger.data["issues"]["7"]["pr_work"], [])
        ] do
      File.write!(ledger.path, Jason.encode!(corrupt.data))
      assert {:error, :invalid_control_state} = ControlLedger.open(ledger.settings, c.root <> "/workspaces")
    end
  end

  test "missing review evidence cannot acknowledge publication and exhausted work capacity stays bounded", c do
    {ledger, run} = reviewed(c.ledger)
    issue = ledger.data["issues"]["7"]
    missing_review = put_in(issue["pr_work"][@work]["handoff"], nil)
    assert {:error, :pr_head_changed} = PRWork.publication(missing_review, publication(run), @context)
    assert {:error, :tracker_changed} = PRWork.transition(issue, create(@other, 1), %{})
    assert {:error, :pr_work_not_found} = PRWork.publication(%{}, publication(run), @context)
    works = Map.new(1..20, fn n -> {Integer.to_string(n), issue["pr_work"][@work]} end)
    assert {:error, :pr_work_limit} = PRWork.transition(Map.put(issue, "pr_work", works), create(@other, 1), @context)
  end

  test "real HTTP adapter uses one bounded authenticated read and returns transport errors without retry", c do
    {ledger, run} = reviewed(c.ledger)
    {:ok, ledger, _} = ControlLedger.record_pr_publication(ledger, publication(run), @context)
    work = ControlLedger.selected_work(ledger, "7")
    defaults = Req.default_options()
    on_exit(fn -> Req.default_options(defaults) end)

    Req.default_options(adapter: HTTPAdapter)
    Process.put(:pr_work_http_response, Req.Response.new(status: 503, body: %{}))

    assert {:error, :pr_evidence_unavailable} = PRWork.verify_remote(work, tracker())
    Process.put(:pr_work_http_response, %Req.TransportError{reason: :timeout})
    assert {:error, :pr_evidence_unavailable} = PRWork.verify_remote(work, tracker())
  end

  test "feedback history capacity rejects a new comment before work is queued but permits another revision", c do
    {ledger, _run} = reviewed(c.ledger)

    item = %{
      "id" => "IC_201",
      "revision" => String.duplicate("c", 64),
      "body" => "Correct the remaining check",
      "author" => "reviewer",
      "url" => "https://github.com/owner/repo/issues/7#issuecomment-201",
      "source" => "issue",
      "pr_number" => nil
    }

    history =
      Map.new(1..200, fn n ->
        id = "IC_#{n}"

        {id,
         %{"id" => id, "revision" => String.duplicate("d", 64), "status" => "addressed", "details" => "Verified in the candidate", "candidate_sha" => @head, "recorded_at" => "2026-09-22T10:00:00Z"}}
      end)

    ledger = put_in(ledger.data["issues"]["7"]["pr_work"][@work]["feedback_history"], history)
    before_issue = ledger.data["issues"]["7"]
    command = Map.put(continue(1, @head), "feedback", [item])
    assert {:error, :feedback_history_full} = ControlLedger.command(ledger, command, 5, @context)
    assert ledger.data["issues"]["7"] == before_issue
    assert {:error, :not_admitted} = ControlLedger.reserve(ledger, "7")

    changed_revision = Map.put(item, "id", "IC_1")
    assert {:ok, next, _, false} = ControlLedger.command(ledger, %{command | "feedback" => [changed_revision]}, 5, @context)
    assert ControlLedger.selected_work(next, "7")["feedback"] == [changed_revision]
    assert map_size(ControlLedger.selected_work(next, "7")["feedback_history"]) == 200
    assert next.data["issues"]["7"]["attempts"] == before_issue["attempts"]
    assert next.data["issues"]["7"]["tokens"] == before_issue["tokens"]
  end

  test "missing or corrupt retained handoff cannot authorize publication", c do
    {ledger, run} = reviewed(c.ledger)
    issue = ledger.data["issues"]["7"]
    receipt = publication(run)

    for handoff <- [nil, [], "approved"] do
      corrupted = put_in(issue, ["pr_work", @work, "handoff"], handoff)
      refute PRWork.valid_issue?("7", corrupted)
      assert {:error, :pr_head_changed} = PRWork.publication(corrupted, receipt, @context)
      assert corrupted["pr_work"][@work]["publication"] == nil
      assert corrupted["pr_work"][@work]["published_head_sha"] == nil
    end

    assert ledger.data["issues"]["7"] == issue
  end

  test "continuation fences old goals and unsupported work never reaches dispatch", c do
    command = Map.put(create(), "purpose", "deployment")
    refute PRWork.valid_command?(command)
    assert {:error, :unsupported_work_purpose} = PRWork.transition(%{}, command, @context)
    {ledger, _run} = reviewed(c.ledger)
    assert ControlLedger.selected_work(ledger, "7")["goal_revision"] == 1
    assert {:ok, ledger, _, false} = ControlLedger.command(ledger, continue(1, @head), 5, @context)
    assert ControlLedger.selected_work(ledger, "7")["goal_revision"] == 2
    assert PRWork.valid_issue?("7", ledger.data["issues"]["7"])
    assert {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    stale = evidence(run, @work, @head) |> Map.put("goal_revision", 1)
    assert {:error, :invalid_pr_handoff} = ControlLedger.finish(ledger, "7", run, "owner_review", stale)
    assert {:ok, ledger} = ControlLedger.finish(ledger, "7", run, "owner_review", evidence(run, @work, @head))
    stale_review = put_in(ledger.data["issues"]["7"], ["pr_work", @work, "handoff", "goal_revision"], 1)
    refute PRWork.valid_issue?("7", stale_review)
    assert {:error, :pr_head_changed} = PRWork.publication(stale_review, publication(run) |> Map.put("expected_head_sha", @head), @context)
    refute PRWork.valid_issue?("7", put_in(ledger.data["issues"]["7"], ["pr_work", @work, "handoff", "goal_revision"], 3))
    refute PRWork.valid_issue?("7", put_in(ledger.data["issues"]["7"], ["pr_work", @work, "purpose"], "deployment"))
    refute PRWork.dispatchable?(put_in(ledger.data["issues"]["7"], ["pr_work", @work, "purpose"], "deployment"))
  end

  defp create(work \\ @work, revision \\ 0), do: Map.merge(cmd("create_pr_work", revision), %{"work_id" => work, "instruction" => "Implement the scoped PR", "base_sha" => @base})
  defp continue(revision, head), do: Map.merge(cmd("continue_pr_work", revision), %{"work_id" => @work, "instruction" => "Address the review findings", "expected_head_sha" => head})
  defp cmd(action, revision), do: %{"action" => action, "issue_id" => "7", "expected_revision" => revision, "command_id" => "#{action}-#{revision}"}
  defp tracker, do: %{kind: "github", provider: %{"repo" => "owner/repo", "token" => "fixture"}}

  defp evidence(run, work \\ @work, previous \\ nil) do
    %{
      "run_id" => run,
      "work_id" => work,
      "expected_head_sha" => previous,
      "goal_revision" => if(previous, do: 2, else: 1),
      "candidate_sha" => @head,
      "base_sha" => @base,
      "branch" => "codex/gh-7-#{work}",
      "builder_session_id" => "builder-A-turn",
      "reviewer_session_id" => "reviewer-turn",
      "review" => %{"candidate_sha" => @head, "verdict" => "approve", "findings" => []}
    }
  end

  defp publication(run),
    do:
      evidence(run)
      |> Map.take(~w(run_id work_id expected_head_sha candidate_sha base_sha branch))
      |> Map.merge(%{"issue_id" => "7", "pr_number" => 18, "pr_url" => "https://github.com/owner/repo/pull/18", "status" => "draft_pr"})

  defp reviewed(ledger) do
    {:ok, ledger, _, _} = ControlLedger.command(ledger, create(), 5, @context)
    {:ok, ledger, run, _} = ControlLedger.reserve(ledger, "7")
    {:ok, ledger} = ControlLedger.checkpoint_pr_work(ledger, "7", run, @work, %{"builder_thread_id" => "builder-A"})
    {:ok, ledger} = ControlLedger.finish(ledger, "7", run, "owner_review", evidence(run))
    {ledger, run}
  end
end
