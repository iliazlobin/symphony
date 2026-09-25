defmodule SymphonyElixir.LabelSyncTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LabelSync

  setup do
    tracker = %{kind: "github", required_labels: ["symphony", "ready / build"], provider: %{"repo" => "owner/repo", "token" => "fake-token"}}
    fingerprint = fingerprint(tracker)

    routing = %{
      "tracker_fingerprint" => fingerprint,
      "repository" => "owner/repo",
      "labels" => tracker.required_labels,
      "queued" => true,
      "revision" => 1,
      "status" => "pending",
      "error" => nil,
      "synced_at" => nil
    }

    issues = %{"7" => %{"routing" => routing}}
    snapshot = %{"enabled" => true, "instance_id" => "owner-1", "tracker_fingerprint" => fingerprint, "issues" => issues}
    control = %{enabled: true, state_path: "/private/tmp/label-sync-test-control.json"}
    context = %{tracker: tracker, control: control, snapshot: snapshot}
    source_state = %{context: context, acks: [], ack_mode: :normal, clock: 0}
    source = start_supervised!({Agent, fn -> source_state end}, id: :source)
    issue = issue("7")
    remote_state = %{issues: %{"7" => issue}, calls: [], mode: :normal, hook: nil, get_response: nil}
    remote = start_supervised!({Agent, fn -> remote_state end}, id: :remote)

    opts = [
      name: nil,
      interval_ms: :manual,
      context_fun: fn -> {:ok, Agent.get(source, & &1.context)} end,
      request_fun: request(remote),
      ack_fun: acknowledge(source),
      clock_fun: fn -> Agent.get(source, & &1.clock) end
    ]

    pid = start_supervised!({LabelSync, opts})
    %{pid: pid, source: source, remote: remote, opts: opts, routing: routing}
  end

  test "adds only missing owned labels, preserves content, and records a confirmed local intent", c do
    update_issue(c, &Map.put(&1, "labels", [%{"name" => "category:docs"}, %{"name" => "SYMPHONY"}]))
    assert :ok = LabelSync.sync(c.pid)
    assert [{"POST", "/repos/owner/repo/issues/7/labels", %{"labels" => ["ready / build"]}}] = writes(c)
    assert labels(c) == ["category:docs", "SYMPHONY", "ready / build"]
    assert remote_issue(c)["body"] == "Original issue description"
    assert remote_issue(c)["state"] == "open"
    assert routing(c)["status"] == "synced"
    assert [{"7", 1, _, :ok}] = acks(c)
    assert length(calls(c)) == 3
    assert :ok = LabelSync.sync(c.pid)
    assert length(calls(c)) == 3
  end

  test "removes only owned labels with encoded paths and accepts a concurrent missing label", c do
    update_routing(c, &%{&1 | "queued" => false})
    update_issue(c, &Map.put(&1, "labels", Enum.map(["category:docs", "SYMPHONY", "ready / build"], fn name -> %{"name" => name} end)))
    Agent.update(c.remote, &%{&1 | mode: :delete_missing})
    LabelSync.sync(c.pid)

    assert writes(c) == [
             {"DELETE", "/repos/owner/repo/issues/7/labels/SYMPHONY", nil},
             {"DELETE", "/repos/owner/repo/issues/7/labels/ready%20%2F%20build", nil}
           ]

    assert labels(c) == ["category:docs"]
    assert routing(c)["status"] == "synced"
  end

  test "checks synced intents periodically and repairs external routing drift", c do
    LabelSync.sync(c.pid)
    update_issue(c, &Map.put(&1, "labels", [%{"name" => "category:new"}]))
    before = calls(c)
    LabelSync.sync(c.pid)
    assert calls(c) == before
    advance(c, 60_001)
    LabelSync.sync(c.pid)
    assert labels(c) == ["category:new", "symphony", "ready / build"]
    assert length(writes(c)) == 2
    assert routing(c)["status"] == "synced"
  end

  test "unknown successful add is reconciled after restart without repeating the write", c do
    Agent.update(c.remote, &%{&1 | mode: :uncertain_applied})
    LabelSync.sync(c.pid)
    assert routing(c)["status"] == "pending"
    assert routing(c)["error"] == "github_unavailable"
    assert length(writes(c)) == 1
    LabelSync.sync(restart(c))
    assert routing(c)["status"] == "synced"
    assert length(writes(c)) == 1
  end

  test "failed delivery retries with bounded backoff and restart retains pending work", c do
    Agent.update(c.remote, &%{&1 | mode: :unavailable})
    LabelSync.sync(c.pid)
    first = calls(c)
    assert routing(c)["status"] == "pending"
    LabelSync.sync(c.pid)
    assert calls(c) == first
    advance(c, 15_000)
    LabelSync.sync(c.pid)
    assert length(writes(c)) == 2
    advance(c, 29_999)
    LabelSync.sync(c.pid)
    assert length(writes(c)) == 2
    advance(c, 1)
    LabelSync.sync(c.pid)
    assert length(writes(c)) == 3

    for _ <- 1..6 do
      advance(c, 300_000)
      LabelSync.sync(c.pid)
    end

    assert :sys.get_state(c.pid).due["7"].delay == 300_000
    Agent.update(c.remote, &%{&1 | mode: :normal})
    LabelSync.sync(restart(c))
    assert routing(c)["status"] == "synced"
  end

  test "uncertain partial removal is safely completed after restart", c do
    update_routing(c, &%{&1 | "queued" => false})
    update_issue(c, &Map.put(&1, "labels", Enum.map(["symphony", "ready / build", "human"], fn name -> %{"name" => name} end)))
    Agent.update(c.remote, &%{&1 | mode: :uncertain_applied})
    LabelSync.sync(c.pid)
    assert labels(c) == ["ready / build", "human"]
    assert routing(c)["status"] == "pending"
    Agent.update(c.remote, &%{&1 | mode: :normal})
    LabelSync.sync(restart(c))
    assert labels(c) == ["human"]
    assert length(writes(c)) == 2
    assert routing(c)["status"] == "synced"
  end

  test "a newer intent between read and write fences the stale write and acknowledgement", c do
    hook(c, "GET", fn -> update_routing(c, &%{&1 | "revision" => 2, "queued" => false}) end)
    LabelSync.sync(c.pid)
    assert writes(c) == []
    assert acks(c) == []
    LabelSync.sync(c.pid)
    assert [{"7", 2, _, :ok}] = acks(c)
    assert routing(c)["status"] == "synced"
  end

  test "newer local move during an in-flight write is preserved and converges on the next pass", c do
    hook(c, "POST", fn -> update_routing(c, &%{&1 | "revision" => 2, "queued" => false}) end)
    LabelSync.sync(c.pid)
    assert labels(c) == ["symphony", "ready / build"]
    assert acks(c) == []
    assert routing(c)["revision"] == 2
    assert routing(c)["status"] == "pending"
    LabelSync.sync(c.pid)
    assert labels(c) == []
    assert [{"7", 2, _, :ok}] = acks(c)
  end

  test "scope changes between requests or before an acknowledgement fail closed", c do
    hook(c, "GET", fn -> update_context(c, &put_in(&1, [:snapshot, "instance_id"], "owner-2")) end)
    LabelSync.sync(c.pid)
    assert writes(c) == []
    assert acks(c) == []
    LabelSync.sync(c.pid)
    assert routing(c)["status"] == "synced"

    update_routing(c, &%{&1 | "revision" => 2, "queued" => false, "status" => "pending"})
    hook(c, "DELETE", fn -> update_context(c, &put_in(&1, [:snapshot, "fault"], "storage unavailable")) end)
    LabelSync.sync(c.pid)
    assert length(writes(c)) == 2
    assert length(acks(c)) == 1
    assert routing(c)["status"] == "pending"
  end

  test "acknowledgement storage failure never loses a delivered pending intent", c do
    Agent.update(c.source, &%{&1 | ack_mode: :fail})
    LabelSync.sync(c.pid)
    assert routing(c)["status"] == "pending"
    assert length(writes(c)) == 1
    LabelSync.sync(c.pid)
    assert length(acks(c)) == 1
    Agent.update(c.source, &%{&1 | ack_mode: :normal})
    LabelSync.sync(restart(c))
    assert routing(c)["status"] == "synced"
    assert length(writes(c)) == 1
  end

  test "closed issues retain human lifecycle ownership while owned labels are mirrored", c do
    update_issue(c, &Map.put(&1, "state", "closed"))
    LabelSync.sync(c.pid)
    assert routing(c)["status"] == "synced"
    assert remote_issue(c)["state"] == "closed"
    update_routing(c, &%{&1 | "revision" => 2, "queued" => false, "status" => "pending"})
    LabelSync.sync(c.pid)
    assert labels(c) == []
    assert remote_issue(c)["state"] == "closed"
  end

  test "an empty owned-label set confirms local intent without any tracker mutation", c do
    update_context(c, fn context ->
      tracker = %{context.tracker | required_labels: []}
      fingerprint = fingerprint(tracker)
      routing = %{c.routing | "labels" => [], "tracker_fingerprint" => fingerprint}

      context
      |> Map.put(:tracker, tracker)
      |> put_in([:snapshot, "tracker_fingerprint"], fingerprint)
      |> put_in([:snapshot, "issues", "7", "routing"], routing)
    end)

    LabelSync.sync(c.pid)
    assert writes(c) == []
    assert routing(c)["status"] == "synced"
  end

  test "wrong issue identity, PRs, malformed labels and inaccessible issues never mutate", c do
    original = remote_issue(c)

    responses = [
      %{status: 200, body: %{original | "number" => 8}},
      %{status: 200, body: %{original | "html_url" => "https://github.com/other/repo/issues/7"}},
      %{status: 200, body: Map.put(original, "pull_request", %{})},
      %{status: 200, body: %{original | "state" => "unknown"}},
      %{status: 200, body: %{original | "labels" => [%{"name" => nil}]}},
      %{status: 200, body: %{original | "labels" => nil}},
      %{status: 200, body: nil},
      %{status: 404, body: %{}},
      %{status: 301, body: %{}},
      %{status: 503, body: %{}}
    ]

    Enum.each(responses, fn response ->
      Agent.update(c.remote, &%{&1 | get_response: response})
      LabelSync.sync(restart(c))
      assert routing(c)["status"] == "pending"
      assert is_binary(routing(c)["error"])
      assert writes(c) == []
    end)
  end

  test "write errors and nonconverged successful responses remain observable pending work", c do
    for mode <- [:status_500, :no_change] do
      Agent.update(c.remote, &%{&1 | mode: mode})
      LabelSync.sync(restart(c))
      assert routing(c)["status"] == "pending"
      assert routing(c)["error"] in ["github_labels_write_failed", "github_labels_not_converged"]
    end

    update_routing(c, &%{&1 | "queued" => false})
    update_issue(c, &Map.put(&1, "labels", [%{"name" => "symphony"}]))
    Agent.update(c.remote, &%{&1 | mode: :status_500})
    LabelSync.sync(restart(c))
    assert routing(c)["error"] == "github_labels_write_failed"
  end

  test "an external unrelated label change during delivery is preserved", c do
    hook(c, "GET", fn -> update_issue(c, &Map.put(&1, "labels", [%{"name" => "human-edit"}])) end)
    LabelSync.sync(c.pid)
    assert labels(c) == ["human-edit", "symphony", "ready / build"]
  end

  test "invalid or stale durable routing cannot cross repository, tracker or label boundaries", c do
    invalid = [
      nil,
      %{},
      %{c.routing | "tracker_fingerprint" => "old-config"},
      %{c.routing | "repository" => "other/repo"},
      %{c.routing | "revision" => 0},
      %{c.routing | "queued" => "true"},
      %{c.routing | "status" => "other"},
      %{c.routing | "labels" => ["unrelated"]}
    ]

    Enum.each(invalid, fn value ->
      update_routing(c, fn _ -> value end)
      LabelSync.sync(c.pid)
      assert calls(c) == []
      assert acks(c) == []
    end)

    update_context(c, &put_in(&1, [:snapshot, "issues"], %{"../7" => %{"routing" => c.routing}}))
    LabelSync.sync(c.pid)
    assert calls(c) == []
  end

  test "disabled, faulted or stale controller contexts perform no requests", c do
    original = Agent.get(c.source, & &1.context)

    invalid = [
      put_in(original, [:control, :enabled], false),
      put_in(original, [:snapshot, "enabled"], false),
      put_in(original, [:snapshot, "fault"], "disk failed"),
      put_in(original, [:snapshot, "error"], "unavailable"),
      put_in(original, [:snapshot, "tracker_fingerprint"], "old"),
      put_in(original, [:snapshot, "instance_id"], nil),
      put_in(original, [:snapshot, "issues"], nil)
    ]

    Enum.each(invalid, fn context ->
      update_context(c, fn _ -> context end)
      LabelSync.sync(c.pid)
      assert calls(c) == []
    end)

    update_context(c, fn _ -> original end)
    LabelSync.sync(c.pid)
    assert routing(c)["status"] == "synced"
  end

  test "bounded batches eventually reach all due intents without stalled issues starving others", c do
    update_context(c, fn context ->
      issues = Map.new(1..12, fn number -> {to_string(number), %{"routing" => c.routing}} end)
      put_in(context, [:snapshot, "issues"], issues)
    end)

    Agent.update(c.remote, fn remote ->
      %{remote | issues: Map.new(1..12, fn number -> {to_string(number), issue(to_string(number))} end)}
    end)

    LabelSync.sync(c.pid)
    assert length(acks(c)) == 5
    LabelSync.sync(c.pid)
    assert length(acks(c)) == 10
    LabelSync.sync(c.pid)
    assert length(acks(c)) == 12
  end

  test "scheduled service ticks use the same reconciliation and do not require a caller", c do
    stop_supervised!(LabelSync)
    opts = c.opts |> Keyword.put(:interval_ms, 60_000) |> Keyword.delete(:clock_fun)
    pid = start_supervised!({LabelSync, opts})
    send(pid, :tick)
    :sys.get_state(pid)
    assert routing(c)["status"] == "synced"
  end

  test "request and acknowledgement process failures retain retryable intent", c do
    for mode <- [:raise, :exit] do
      request = fn _, _, _, _, _ -> if mode == :raise, do: raise("failed"), else: exit(:failed) end
      LabelSync.sync(restart(c, request_fun: request))
      assert routing(c)["error"] == "github_unavailable"
    end

    for mode <- [:raise, :exit, :receipt] do
      Agent.update(c.source, &%{&1 | ack_mode: mode})
      pid = restart(c)
      LabelSync.sync(pid)
      assert Process.alive?(pid)
    end

    assert routing(c)["status"] == "synced"
  end

  test "unavailable or malformed context is disabled, including raised and exited providers", c do
    for context <- [fn -> :disabled end, fn -> {:ok, %{}} end, fn -> raise "unavailable" end, fn -> exit(:unavailable) end] do
      LabelSync.sync(restart(c, context_fun: context))
      assert calls(c) == []
    end
  end

  defp issue(id) do
    %{"number" => String.to_integer(id), "html_url" => "https://github.com/owner/repo/issues/#{id}", "state" => "open", "labels" => [], "body" => "Original issue description"}
  end

  defp request(remote) do
    fn method, path, _params, body, _settings ->
      {response, hook} =
        Agent.get_and_update(remote, fn state ->
          state = %{state | calls: state.calls ++ [{method, path, body}]}
          {response, next} = response(state, method, path, body)
          {hook, next} = take_hook(next, method)
          {{response, hook}, next}
        end)

      if hook, do: hook.()
      response
    end
  end

  defp response(state, "GET", path, _body) do
    id = List.last(String.split(path, "/"))
    response = state.get_response || %{status: 200, body: state.issues[id]}
    {{:ok, response}, state}
  end

  defp response(%{mode: :unavailable} = state, _method, _path, _body), do: {{:error, :github_unavailable}, state}
  defp response(%{mode: :status_500} = state, _method, _path, _body), do: {{:ok, %{status: 500, body: %{}}}, state}
  defp response(%{mode: :no_change} = state, _method, _path, _body), do: {{:ok, %{status: 200, body: []}}, state}

  defp response(state, method, path, body) do
    [_, "repos", "owner", "repo", "issues", id, "labels" | rest] = String.split(path, "/")
    issue = state.issues[id]
    current = Enum.map(issue["labels"], & &1["name"])
    labels = if method == "POST", do: Enum.uniq(current ++ body["labels"]), else: List.delete(current, URI.decode(hd(rest)))
    updated = Map.put(issue, "labels", Enum.map(labels, &%{"name" => &1}))
    next = put_in(state, [:issues, id], updated)

    result =
      cond do
        state.mode == :uncertain_applied -> {:error, :github_unavailable}
        method == "DELETE" and state.mode == :delete_missing -> {:ok, %{status: 404, body: %{}}}
        true -> {:ok, %{status: 200, body: updated["labels"]}}
      end

    {result, next}
  end

  defp take_hook(%{hook: {method, hook}} = state, method), do: {hook, %{state | hook: nil}}
  defp take_hook(state, _method), do: {nil, state}

  defp acknowledge(source) do
    fn id, revision, fingerprint, result ->
      mode = Agent.get(source, & &1.ack_mode)
      if mode == :raise, do: raise("storage failure")
      if mode == :exit, do: exit(:storage_failure)

      Agent.get_and_update(source, &acknowledge(&1, id, revision, fingerprint, result, mode))
    end
  end

  defp acknowledge(state, id, revision, fingerprint, result, mode) do
    state = %{state | acks: state.acks ++ [{id, revision, fingerprint, result}]}
    intent = get_in(state, [:context, :snapshot, "issues", id, "routing"])

    if mode == :fail or intent["revision"] != revision or intent["tracker_fingerprint"] != fingerprint do
      {{:error, :not_committed}, state}
    else
      status = if result == :ok, do: "synced", else: "pending"
      error = if result == :ok, do: nil, else: result |> elem(1) |> Atom.to_string()
      intent = Map.merge(intent, %{"status" => status, "error" => error})
      reply = if mode == :receipt, do: {:ok, %{}}, else: :ok
      {reply, put_in(state, [:context, :snapshot, "issues", id, "routing"], intent)}
    end
  end

  defp restart(c, overrides \\ []) do
    stop_supervised!(LabelSync)
    start_supervised!({LabelSync, Keyword.merge(c.opts, overrides)})
  end

  defp hook(c, method, fun), do: Agent.update(c.remote, &%{&1 | hook: {method, fun}})
  defp update_context(c, fun), do: Agent.update(c.source, &Map.update!(&1, :context, fun))
  defp update_routing(c, fun), do: update_context(c, &update_in(&1, [:snapshot, "issues", "7", "routing"], fun))
  defp update_issue(c, fun), do: Agent.update(c.remote, &update_in(&1, [:issues, "7"], fun))
  defp advance(c, amount), do: Agent.update(c.source, &%{&1 | clock: &1.clock + amount})
  defp routing(c), do: Agent.get(c.source, &get_in(&1, [:context, :snapshot, "issues", "7", "routing"]))
  defp remote_issue(c), do: Agent.get(c.remote, & &1.issues["7"])
  defp labels(c), do: Enum.map(remote_issue(c)["labels"], & &1["name"])
  defp calls(c), do: Agent.get(c.remote, & &1.calls)
  defp writes(c), do: Enum.reject(calls(c), &(elem(&1, 0) == "GET"))
  defp acks(c), do: Agent.get(c.source, & &1.acks)
  defp fingerprint(tracker), do: :crypto.hash(:sha256, :erlang.term_to_binary(tracker)) |> Base.url_encode64(padding: false)
end

defmodule SymphonyElixir.LabelSyncNativeTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.LabelSync

  test "native polling reads current configuration and owner snapshots without inventing label work" do
    request = fn _, _, _, _, _ -> flunk("No durable routing intent exists") end
    pid = start_supervised!({LabelSync, name: nil, interval_ms: :manual, request_fun: request})
    assert :ok = LabelSync.sync(pid)
    assert :sys.get_state(pid).context.() == :disabled

    root = Path.dirname(Workflow.workflow_file_path())

    config = %{
      tracker: %{kind: "github", active_states: ["open"], terminal_states: ["closed"], provider: %{repo: "owner/repo", token: "fake-token"}},
      workspace: %{root: root <> "/workspaces"},
      polling: %{interval_ms: 60_000},
      observability: %{dashboard_enabled: false},
      control: %{enabled: true, initial_mode: "paused", state_path: root <> "/control.json"}
    }

    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    assert :ok = WorkflowStore.force_reload()
    assert :ok = LabelSync.sync(pid)
    assert {:ok, %{tracker: %{kind: "github"}, snapshot: snapshot}} = :sys.get_state(pid).context.()
    assert is_map(snapshot)
  end
end
