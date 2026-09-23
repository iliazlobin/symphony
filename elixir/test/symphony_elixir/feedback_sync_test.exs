defmodule SymphonyElixir.FeedbackSyncTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.FeedbackSync
  alias SymphonyElixir.FeedbackSync.Journal

  setup do
    {:ok, tmp} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "feedback-sync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    tracker = %{kind: "github", provider: %{"repo" => "owner/repo", "token" => "fake-token"}}
    fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(tracker)) |> Base.url_encode64(padding: false)

    item = %{
      "id" => "COMMENT_1",
      "revision" => String.duplicate("a", 64),
      "url" => "https://github.com/owner/repo/issues/7#issuecomment-10",
      "body" => "Private text never mirrored",
      "author" => "human",
      "source" => "issue",
      "pr_number" => nil
    }

    work = %{"issue_id" => "7", "tracker_fingerprint" => fingerprint, "phase" => "queued", "feedback" => [item], "updated_at" => "2026-09-23T10:00:00Z"}
    ledger = %{"hold" => nil, "selected_work_id" => "work", "pr_work" => %{"work" => work}}
    snapshot = %{"enabled" => true, "instance_id" => "lock-1", "tracker_fingerprint" => fingerprint, "issues" => %{"7" => ledger}}
    context = %{tracker: tracker, control: %{enabled: true, state_path: root <> "/control.json"}, snapshot: snapshot}
    source = start_supervised!({Agent, fn -> context end}, id: :source)
    initial_remote = %{calls: [], comments: [], mode: :normal, hook: nil, viewer: 1}
    remote = start_supervised!({Agent, fn -> initial_remote end}, id: :remote)
    context_fun = fn -> {:ok, Agent.get(source, & &1)} end
    opts = [name: nil, interval_ms: :manual, context_fun: context_fun, request_fun: request(remote)]
    pid = start_supervised!({FeedbackSync, opts})
    on_exit(fn -> File.rm_rf(root) end)
    %{pid: pid, source: source, remote: remote, opts: opts, root: root, item: item}
  end

  test "selected feedback gets one private-body-free reply, coalesced updates and durable restart recovery", c do
    assert :ok = FeedbackSync.sync(c.pid)
    assert [{"POST", _, %{"body" => body}}] = writes(c)
    assert body =~ "1 queued"
    assert body =~ "[source](#{c.item["url"]})"
    refute body =~ c.item["body"]
    assert :ok = FeedbackSync.sync(c.pid)
    assert length(calls(c)) == 4

    update_work(c, &Map.put(&1, "phase", "building"))
    assert :ok = FeedbackSync.sync(c.pid)
    assert List.last(writes(c)) |> elem(2) |> Map.fetch!("body") =~ "👀 Working"
    assert Enum.count(writes(c), &(elem(&1, 0) == "POST")) == 1

    history = %{c.item["id"] => Map.take(c.item, ["id", "revision"]) |> Map.merge(%{"status" => "addressed", "details" => "Tested", "candidate_sha" => String.duplicate("b", 40)})}
    update_work(c, &Map.merge(&1, %{"phase" => "owner_review", "feedback_history" => history}))
    FeedbackSync.sync(c.pid)
    assert List.last(writes(c)) |> elem(2) |> Map.fetch!("body") =~ "✅ Addressed"
    before = calls(c)
    pid = restart(c)
    FeedbackSync.sync(pid)
    assert calls(c) == before
    assert {:ok, %{mode: mode}} = File.stat(c.root <> "/control.json.feedback/deliveries.json")
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "unknown successful POST is recovered after restart without another POST", c do
    Agent.update(c.remote, &%{&1 | mode: :unknown_stored})
    FeedbackSync.sync(c.pid)
    assert [%{"state" => "pending"}] = records(c)
    pid = restart(c)
    FeedbackSync.sync(pid)
    assert [%{"state" => "confirmed"}] = records(c)
    assert length(writes(c)) == 1
  end

  test "current selected work wins over a later publication timestamp on older work", c do
    Agent.update(c.source, fn context ->
      current = get_in(context, [:snapshot, "issues", "7", "pr_work", "work"])
      old_item = %{c.item | "revision" => String.duplicate("b", 64)}
      old = Map.merge(current, %{"updated_at" => "2027-01-01T00:00:00Z", "feedback" => [old_item]})
      put_in(context, [:snapshot, "issues", "7", "pr_work", "old"], old)
    end)

    FeedbackSync.sync(c.pid)
    assert [{"POST", _, %{"body" => body}}] = writes(c)
    assert body =~ "revision `aaaaaaaaaaaa`"
    refute body =~ "revision `bbbbbbbbbbbb`"
  end

  test "clearing selected feedback updates the existing reply but never creates an empty one", c do
    FeedbackSync.sync(c.pid)
    update_work(c, &Map.put(&1, "feedback", []))
    FeedbackSync.sync(c.pid)
    assert [{"POST", _, _}, {"PATCH", _, %{"body" => body}}] = writes(c)
    assert body =~ "No comments selected for the current work batch."
    assert body =~ "0 queued"
    before = calls(c)
    FeedbackSync.sync(c.pid)
    assert calls(c) == before
  end

  test "unknown missing POST never blindly reposts, including after restart and backoff", c do
    Agent.update(c.remote, &%{&1 | mode: :unknown_missing})
    FeedbackSync.sync(c.pid)
    before = calls(c)
    FeedbackSync.sync(c.pid)
    assert calls(c) == before

    for _ <- 1..2 do
      pid = restart(c)
      FeedbackSync.sync(pid)
      assert [%{"state" => "pending"}] = records(c)
    end

    assert length(writes(c)) == 1
  end

  test "duplicate host markers hold updates without picking an arbitrary comment", c do
    FeedbackSync.sync(c.pid)

    Agent.update(c.remote, fn remote ->
      [comment] = remote.comments
      %{remote | comments: [comment, %{comment | "id" => 12, "html_url" => "https://github.com/owner/repo/issues/7#issuecomment-12"}]}
    end)

    update_work(c, &Map.put(&1, "phase", "building"))
    FeedbackSync.sync(c.pid)
    assert length(writes(c)) == 1
  end

  test "only viewer-authored marker can be recovered; issue identity is checked before creation", c do
    FeedbackSync.sync(c.pid)
    Agent.update(c.remote, fn remote -> %{remote | viewer: 2} end)
    update_work(c, &Map.put(&1, "phase", "building"))
    FeedbackSync.sync(c.pid)
    assert length(writes(c)) == 1
  end

  test "control lifetime changing during read fences writes even at the same tracker and path", c do
    Agent.update(c.remote, fn remote ->
      %{remote | hook: fn -> Agent.update(c.source, &put_in(&1, [:snapshot, "instance_id"], "lock-2")) end}
    end)

    FeedbackSync.sync(c.pid)
    assert writes(c) == []
  end

  test "current feedback progress changing during read fences stale status", c do
    Agent.update(c.remote, &%{&1 | hook: fn -> update_work(c, fn work -> Map.put(work, "phase", "building") end) end})
    FeedbackSync.sync(c.pid)
    assert writes(c) == []
  end

  test "foreign tracker work and unsafe source URLs do not cause requests", c do
    update_work(c, &Map.put(&1, "tracker_fingerprint", "foreign"))
    FeedbackSync.sync(c.pid)
    assert calls(c) == []
    fingerprint = Agent.get(c.source, & &1.snapshot["tracker_fingerprint"])
    update_work(c, fn work -> work |> Map.put("tracker_fingerprint", fingerprint) |> Map.put("feedback", [%{c.item | "url" => "https://github.com/other/repo/issues/7#issuecomment-10"}]) end)
    FeedbackSync.sync(c.pid)
    assert calls(c) == []
    Agent.update(c.source, &put_in(&1, [:control, :enabled], false))
    FeedbackSync.sync(c.pid)
    assert calls(c) == []
  end

  test "blocked and PR review sources update the existing issue reply", c do
    items = [
      %{c.item | "source" => "pr", "pr_number" => 8, "url" => "https://github.com/owner/repo/pull/8#issuecomment-10"},
      %{c.item | "id" => "REVIEW_2", "source" => "review", "pr_number" => 8, "url" => "https://github.com/owner/repo/pull/8#discussion_r20"}
    ]

    update_work(c, &Map.merge(&1, %{"phase" => "paused", "feedback" => items}))
    FeedbackSync.sync(c.pid)
    assert [{"POST", _, %{"body" => body}}] = writes(c)
    assert body =~ "❗ 2 blocked"
    assert body =~ "❗ Blocked"
    assert body =~ "pull/8#discussion_r20"
  end

  test "a failed PATCH is recovered with a safe idempotent update", c do
    FeedbackSync.sync(c.pid)
    Agent.update(c.remote, &%{&1 | mode: :failed_patch})
    update_work(c, &Map.put(&1, "phase", "building"))
    FeedbackSync.sync(c.pid)
    Agent.update(c.remote, &%{&1 | mode: :normal})
    pid = restart(c)
    FeedbackSync.sync(pid)
    assert Enum.count(writes(c), &(elem(&1, 0) == "POST")) == 1
    assert Enum.count(writes(c), &(elem(&1, 0) == "PATCH")) == 2
    assert [%{"state" => "confirmed"}] = records(c)
  end

  test "journal refuses symlinks, concurrent owners, malformed records and unsafe writes", c do
    path = c.root <> "/journal"
    {:ok, journal} = Journal.open(path)
    assert Journal.owned?(journal)
    refute Journal.owned?(%{})
    assert Task.async(fn -> Journal.owned?(journal) end) |> Task.await() == false
    assert {:error, _} = Journal.open(path)
    key = String.duplicate("a", 64)
    assert {:error, _} = Journal.put(journal, key, %{"state" => "confirmed", "comment_id" => -1, "hash" => key})
    assert {:error, _} = Journal.put(journal, "bad", %{"state" => "pending", "comment_id" => nil, "hash" => nil})
    File.ln_s!(c.root <> "/outside", path <> "/deliveries.json")
    assert {:error, _} = Journal.put(journal, key, %{"state" => "pending", "comment_id" => nil, "hash" => nil})
    Journal.close(journal)
    assert {:error, _} = Journal.open(path)
    File.rm!(path <> "/deliveries.json")
    File.write!(path <> "/deliveries.json", "broken")
    assert {:error, _} = Journal.open(path)
    File.ln_s!(path, c.root <> "/linked")
    assert {:error, _} = Journal.open(c.root <> "/linked")
    assert {:error, _} = Journal.open("relative")
    assert {:error, _} = Journal.open(nil)
    File.write!(path <> "/deliveries.json", Jason.encode!(%{"version" => 1, "records" => []}))
    assert {:error, _} = Journal.open(path)
    File.write!(path <> "/deliveries.json", Jason.encode!(%{"version" => 1, "records" => %{key => false}}))
    assert {:error, _} = Journal.open(path)
  end

  test "journal lock loss during remote read prevents subsequent GitHub writes", c do
    # First render establishes the journal without making an external write.
    update_work(c, &Map.put(&1, "feedback", []))
    FeedbackSync.sync(c.pid)
    lock = :sys.get_state(c.pid).journal.lock
    update_work(c, &Map.put(&1, "feedback", [c.item]))
    Agent.update(c.remote, &%{&1 | hook: fn -> Port.close(lock) end})
    FeedbackSync.sync(c.pid)
    assert writes(c) == []
    refute File.exists?(c.root <> "/control.json.feedback/deliveries.json")

    {:ok, journal} = Journal.open(c.root <> "/lost-lock")
    Port.close(journal.lock)
    pending = %{"state" => "pending", "comment_id" => nil, "hash" => nil}
    assert {:error, _} = Journal.put(journal, String.duplicate("a", 64), pending)
  end

  test "native lifetime change after journaling leaves a recoverable intent without posting", c do
    context = fn ->
      current = Agent.get(c.source, & &1)
      path = c.root <> "/control.json.feedback/deliveries.json"
      current = if File.exists?(path), do: put_in(current, [:snapshot, "instance_id"], "changed"), else: current
      {:ok, current}
    end

    stop_supervised!(FeedbackSync)
    pid = start_supervised!({FeedbackSync, Keyword.put(c.opts, :context_fun, context)})
    FeedbackSync.sync(pid)
    assert writes(c) == []
    assert [%{"state" => "pending"}] = records(c)
  end

  test "periodic polling, lock exit and graceful stop retain replay safety", c do
    send(c.pid, :tick)
    FeedbackSync.sync(c.pid)
    assert length(writes(c)) == 1
    lock = :sys.get_state(c.pid).journal.lock
    send(c.pid, {lock, {:exit_status, 1}})
    send(c.pid, {lock, {:exit_status, 1}})
    FeedbackSync.sync(c.pid)
    assert length(writes(c)) == 1
    GenServer.stop(c.pid, :normal)
    refute Process.alive?(c.pid)
  end

  test "invalid context and unavailable journal fail closed", c do
    original = :sys.get_state(c.pid).context

    for callback <- [fn -> raise "Unavailable" end, fn -> exit(:unavailable) end] do
      :sys.replace_state(c.pid, &%{&1 | context: callback})
      FeedbackSync.sync(c.pid)
      assert writes(c) == []
    end

    :sys.replace_state(c.pid, &%{&1 | context: original})
    File.write!(c.root <> "/control.json.feedback", "invalid journal root")
    FeedbackSync.sync(c.pid)
    assert :sys.get_state(c.pid).journal == nil
    assert writes(c) == []
  end

  test "pending feedback and malformed remote identity cannot fabricate delivery", c do
    update_work(c, &Map.put(&1, "phase", "owner_review"))
    Agent.update(c.remote, &%{&1 | viewer: "malformed"})
    FeedbackSync.sync(c.pid)
    assert writes(c) == []
    Agent.update(c.remote, &%{&1 | viewer: 1, mode: :wrong_issue})
    FeedbackSync.sync(restart(c))
    assert writes(c) == []
    Agent.update(c.remote, &%{&1 | mode: :normal})
    FeedbackSync.sync(restart(c))
    assert [{"POST", _, %{"body" => body}}] = writes(c)
    assert body =~ "Pending"
  end

  test "truncated comment inventory blocks creation", c do
    Agent.update(c.remote, &%{&1 | comments: List.duplicate(%{"user" => %{"id" => 99}, "body" => "human"}, 100)})
    FeedbackSync.sync(c.pid)
    assert length(calls(c)) == 11
    assert writes(c) == []
  end

  test "scope change before comment inventory and persistence failure after POST remain safe", c do
    original = c.opts[:request_fun]

    changed = fn method, path, params, body, settings ->
      result = original.(method, path, params, body, settings)
      if path == "/user", do: Agent.update(c.source, &put_in(&1, [:snapshot, "instance_id"], "reopened"))
      result
    end

    stop_supervised!(FeedbackSync)
    pid = start_supervised!({FeedbackSync, Keyword.put(c.opts, :request_fun, changed)})
    FeedbackSync.sync(pid)
    assert writes(c) == []

    failed = fn method, path, params, body, settings ->
      result = original.(method, path, params, body, settings)

      if method == "POST" do
        file = c.root <> "/control.json.feedback/deliveries.json"
        File.rename!(file, file <> ".saved")
        File.mkdir!(file)
      end

      result
    end

    stop_supervised!(FeedbackSync)
    pid = start_supervised!({FeedbackSync, Keyword.put(c.opts, :request_fun, failed)})
    FeedbackSync.sync(pid)
    assert length(writes(c)) == 1
    FeedbackSync.sync(pid)
    assert length(writes(c)) == 1
  end

  defp restart(c) do
    stop_supervised!(FeedbackSync)
    start_supervised!({FeedbackSync, c.opts})
  end

  defp update_work(c, fun), do: Agent.update(c.source, &update_in(&1, [:snapshot, "issues", "7", "pr_work", "work"], fun))
  defp calls(c), do: Agent.get(c.remote, &Enum.reverse(&1.calls))
  defp writes(c), do: Enum.filter(calls(c), &(elem(&1, 0) in ["POST", "PATCH"]))
  defp records(c), do: (c.root <> "/control.json.feedback/deliveries.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("records") |> Map.values()

  defp request(remote) do
    fn method, path, _params, body, _settings ->
      Agent.get_and_update(remote, fn state ->
        next = %{state | calls: [{method, path, body} | state.calls]}
        fake_reply(method, path, body, next)
      end)
    end
  end

  defp fake_reply("GET", "/user", _body, state), do: {{:ok, %{status: 200, body: %{"id" => state.viewer}}}, state}

  defp fake_reply("GET", "/repos/owner/repo/issues/7/comments", _body, state) do
    if state.hook, do: state.hook.()
    {{:ok, %{status: 200, body: state.comments}}, state}
  end

  defp fake_reply("GET", "/repos/owner/repo/issues/7", _body, state) do
    number = if state.mode == :wrong_issue, do: 8, else: 7
    {{:ok, %{status: 200, body: %{"number" => number, "html_url" => "https://github.com/owner/repo/issues/7"}}}, state}
  end

  defp fake_reply("POST", "/repos/owner/repo/issues/7/comments", body, state) do
    comment = %{"id" => 11, "user" => %{"id" => state.viewer}, "body" => body["body"], "html_url" => "https://github.com/owner/repo/issues/7#issuecomment-11"}
    next = if state.mode == :unknown_missing, do: state, else: %{state | comments: [comment]}
    response = if state.mode in [:unknown_missing, :unknown_stored], do: {:error, :timeout}, else: {:ok, %{status: 201, body: comment}}
    {response, next}
  end

  defp fake_reply("PATCH", "/repos/owner/repo/issues/comments/11", _body, %{mode: :failed_patch} = state), do: {{:error, :timeout}, state}

  defp fake_reply("PATCH", "/repos/owner/repo/issues/comments/11", body, state) do
    comments = Enum.map(state.comments, &Map.put(&1, "body", body["body"]))
    {{:ok, %{status: 200, body: hd(comments)}}, %{state | comments: comments}}
  end
end
