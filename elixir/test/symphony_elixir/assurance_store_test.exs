defmodule SymphonyElixir.Assurance.StoreTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Assurance.{Contract, GraphSnapshot, Projection, Store}
  alias SymphonyElixir.Design.Persistence

  @project "github:example/coverage"
  @task @project <> ":1"
  @sha String.duplicate("a", 40)
  @digest "sha256:" <> String.duplicate("b", 64)

  setup do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "assurance-#{System.unique_integer([:positive])}"))
    {:ok, scope} = Agent.start_link(fn -> "scope" end)
    {:ok, auth} = Agent.start_link(fn -> true end)

    opts = [
      name: nil,
      state_dir: root,
      project: @project,
      scope: fn -> Agent.get(scope, & &1) end,
      authorize: fn token -> token == :operator and Agent.get(auth, & &1) end,
      verify_evidence: fn project, record -> project == @project and record["producer"] == "pinned-native" end
    ]

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, opts: opts, scope: scope, auth: auth}
  end

  test "private owner saves, freezes a baseline and recovers it after restart", c do
    pid = start_supervised!({Store, c.opts})
    assert {:ok, %{"storage_revision" => 0, "draft" => nil}} = Store.read(@project, :operator, pid)
    assert {:ok, %{"storage_revision" => 1}} = Store.save(@project, 0, doc(), :operator, pid)
    assert {:ok, %{"storage_revision" => 2, "reviewed" => base}} = Store.baseline(@project, 1, :operator, pid)
    assert {:ok, %{"storage_revision" => 2}} = Store.baseline(@project, 2, :operator, pid)
    changed = put_in(doc(), ["requirements", Access.at(0), "criteria", Access.at(0), "text"], "Requests finish within 100ms")
    assert {:ok, %{"storage_revision" => 3}} = Store.save(@project, 2, changed, :operator, pid)
    assert {:ok, ^base} = Store.reviewed(@project, base["ref"], :operator, pid)
    assert {:ok, %{"requirements" => %{"changed" => ["REQ-1"]}}} = Store.diff(@project, base["ref"], :operator, pid)
    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:ok, ^base} = Store.reviewed(@project, base["ref"], :operator, restarted)
    assert {:ok, %{"draft" => ^changed, "storage_revision" => 3}} = Store.read(@project, :operator, restarted)
    assert Bitwise.band(File.stat!(Path.join(c.root, "journal.json")).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(c.root).mode, 0o777) == 0o700
  end

  test "empty plans and current evidence remain unreviewed until explicit baseline acceptance", c do
    assert {:error, {:already_started, default}} = Store.start_link()
    assert Process.alive?(default)
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, Contract.document(@project), :operator, pid)
    assert {:error, :assurance_plan_incomplete} = Store.baseline(@project, 1, :operator, pid)
    {:ok, _} = Store.save(@project, 1, doc(), :operator, pid)
    assert {:ok, %{"counts" => %{"covered" => 0, "unreviewed" => 1}}} = Store.projection(@project, observations([evidence()]), :operator, pid)
    assert {:error, :assurance_baseline_not_found} = Store.reviewed(@project, "missing", :operator, pid)
    assert {:error, :assurance_baseline_not_found} = Store.diff(@project, "missing", :operator, pid)
  end

  test "competing drafts and stale baselines cannot overwrite current revisions", c do
    pid = start_supervised!({Store, c.opts})
    results = [doc(), put_in(doc(), ["requirements", Access.at(0), "title"], "Second proposal")] |> Task.async_stream(&Store.save(@project, 0, &1, :operator, pid)) |> Enum.map(fn {:ok, v} -> v end)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_assurance_revision})) == 1
    assert {:error, :stale_assurance_revision} = Store.baseline(@project, 0, :operator, pid)
    assert {:ok, saved} = Store.read(@project, :operator, pid)
    assert {:ok, ^saved} = Store.save(@project, 1, saved["draft"], :operator, pid)
  end

  test "incomplete drafts and explicit exclusions preserve plan review boundaries", c do
    pid = start_supervised!({Store, c.opts})
    assert {:error, :assurance_not_saved} = Store.baseline(@project, 0, :operator, pid)
    incomplete = put_in(doc(), ["requirements", Access.at(0), "criteria", Access.at(0), "required_checks"], [])
    assert {:ok, _} = Store.save(@project, 0, incomplete, :operator, pid)
    assert {:error, :assurance_plan_incomplete} = Store.baseline(@project, 1, :operator, pid)
    excluded = put_in(incomplete, ["requirements", Access.at(0), "exclusion"], "Deferred until the next release")
    assert {:ok, _} = Store.save(@project, 1, excluded, :operator, pid)
    assert {:ok, _} = Store.baseline(@project, 2, :operator, pid)
    assert {:ok, %{"counts" => %{"excluded" => 1}}} = Store.projection(@project, observations(), :operator, pid)
  end

  test "authorization, project and changed scope fence every operation", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    bytes = File.read!(Path.join(c.root, "journal.json"))
    assert {:error, :assurance_project_mismatch} = Store.read("github:other/repo", :operator, pid)
    Agent.update(c.auth, fn _ -> false end)
    assert {:error, :unauthorized} = Store.save(@project, 1, doc(), :operator, pid)
    assert {:error, :unauthorized} = Store.evidence(@project, 1, evidence(), :operator, pid)
    assert {:error, :unauthorized} = Store.reviewed(@project, Contract.ref(doc()), :operator, pid)
    Agent.update(c.auth, fn _ -> true end)
    Agent.update(c.scope, fn _ -> "changed-tracker" end)
    assert {:error, :assurance_scope_changed} = Store.read(@project, :operator, pid)
    assert File.read!(Path.join(c.root, "journal.json")) == bytes
  end

  test "same-root ownership, journal tampering and project binding fail closed", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    second = start_owner(c.opts)
    assert {:error, :assurance_storage_unavailable} = Store.read(@project, :operator, second)
    path = Path.join(c.root, "journal.json")
    File.write!(path, "{tampered")
    assert {:error, :assurance_storage_unavailable} = Store.read(@project, :operator, pid)
    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:error, :assurance_storage_unavailable} = Store.read(@project, :operator, restarted)
    assert File.read!(path) == "{tampered"
  end

  test "disabled storage, missing owners and faulting authority never create a journal", c do
    disabled = start_owner(Keyword.put(c.opts, :enabled, false))
    assert {:error, :assurance_storage_unavailable} = Store.read(@project, :operator, disabled)
    assert {:error, :assurance_storage_unavailable} = Store.read(@project, :operator, :missing_assurance_owner)
    failing_auth = start_owner(Keyword.put(c.opts, :authorize, fn _ -> raise "identity unavailable" end))
    assert {:error, :unauthorized} = Store.read(@project, :operator, failing_auth)
    failing_scope = start_owner(Keyword.put(c.opts, :scope, fn -> throw(:scope_unavailable) end))
    assert {:error, :assurance_storage_unavailable} = Store.read(@project, :operator, failing_scope)
    refute File.exists?(Path.join(c.root, "journal.json"))
  end

  test "provider exit and unwritable storage stop further mutations without losing saved records", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    before = File.read!(Path.join(c.root, "journal.json"))
    send(pid, :unrelated_message)
    assert {:ok, _} = Store.read(@project, :operator, pid)
    true = Port.command(:sys.get_state(pid).owner.lock, "x")
    await_fault(pid)
    assert {:error, :assurance_storage_unavailable} = Store.save(@project, 1, doc(), :operator, pid)
    assert File.read!(Path.join(c.root, "journal.json")) == before
    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    changed = put_in(doc(), ["requirements", Access.at(0), "title"], "Unsaved change")
    File.chmod!(c.root, 0o500)

    try do
      assert {:error, :assurance_storage_unavailable} = Store.save(@project, 1, changed, :operator, restarted)
      assert File.read!(Path.join(c.root, "journal.json")) == before
    after
      File.chmod!(c.root, 0o700)
    end
  end

  test "malformed nested records and out-of-project links never replace a draft", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, saved} = Store.save(@project, 0, doc(), :operator, pid)

    invalid = [
      nil,
      %{},
      Map.put(doc(), "extra", true),
      Map.put(doc(), "requirements", [1]),
      put_in(doc(), ["task_links", Access.at(0), "task_id"], "github:other/repo:1"),
      put_in(doc(), ["task_links", Access.at(0), "criterion_id"], "missing"),
      put_in(doc(), ["requirements", Access.at(0), "criteria"], [criterion(), criterion()]),
      Map.put(doc(), "task_links", List.duplicate(hd(doc()["task_links"]), 10_001))
    ]

    for value <- invalid, do: assert({:error, :invalid_assurance_document} = Store.save(@project, 1, value, :operator, pid))
    assert {:ok, ^saved} = Store.read(@project, :operator, pid)
    for value <- [nil, 1, %{}], do: refute(Contract.valid?(value, @project, "scope"))
    refute Contract.valid_evidence?(Map.put(evidence(), "observed_at", nil))
    refute Contract.valid_subject?(Map.put(subject("artifact"), "artifact_digest", "mutable:latest"))
    refute Contract.valid_release?(nil)
  end

  test "a thousand linked task identities remain representable with bounded schemas", c do
    pid = start_supervised!({Store, c.opts})
    links = Enum.map(1..1_000, fn n -> %{hd(doc()["task_links"]) | "task_id" => @project <> ":#{n}"} end)
    large = Map.put(doc(), "task_links", links)
    assert {:ok, _} = Store.save(@project, 0, large, :operator, pid)
    assert {:ok, %{"reviewed" => base}} = Store.baseline(@project, 1, :operator, pid)
    assert length(base["document"]["task_links"]) == 1_000
    assert {:ok, %{"stale_task_ids" => stale}} = Store.projection(@project, observations(), :operator, pid)
    assert length(stale) == 999
  end

  test "a thousand distinct criterion subjects retain exact coverage and isolate a stale task" do
    records =
      Enum.map(1..1_000, fn n ->
        criterion_id = "AC-#{n}"
        task_id = @project <> ":#{n}"
        candidate = Map.put(subject("pr"), "pr_number", n)
        requirement = %{"id" => "REQ-#{n}", "title" => "Observable scope #{n}", "kind" => "functional", "exclusion" => nil, "criteria" => [%{criterion() | "id" => criterion_id}]}
        link = %{"task_id" => task_id, "criterion_id" => criterion_id, "task_revision" => "task-v1", "subject" => candidate}
        task = %{"id" => task_id, "revision" => "task-v1", "subject" => candidate}
        proof = evidence() |> Map.merge(%{"id" => "proof-#{n}", "criterion_id" => criterion_id, "subject" => candidate})
        {requirement, link, task, proof}
      end)

    document = Contract.document(@project) |> Map.merge(%{"requirements" => Enum.map(records, &elem(&1, 0)), "task_links" => Enum.map(records, &elem(&1, 1))})
    ref = Contract.ref(document)
    base = %{"ref" => ref, "reviewed_at" => timestamp(), "document" => document, "graph_snapshot" => nil}
    journal = Contract.empty(@project, "scope") |> Map.merge(%{"draft" => document, "reviewed_ref" => ref, "baselines" => %{ref => base}})
    observed = %{"tasks" => Enum.map(records, &elem(&1, 2)), "evidence" => Enum.map(records, &elem(&1, 3))}
    assert Contract.valid?(journal, @project, "scope")
    assert %{"counts" => %{"covered" => 1_000}, "unlinked_task_ids" => []} = Projection.build(journal, observed)
    stale = put_in(observed, ["tasks", Access.at(999), "revision"], "task-v2")
    assert %{"counts" => %{"covered" => 999, "stale" => 1}, "stale_task_ids" => [@project <> ":1000"]} = Projection.build(journal, stale)
  end

  test "coverage distinguishes uncovered, stale revisions, missing evidence and native passes", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    {:ok, _} = Store.baseline(@project, 1, :operator, pid)
    assert {:ok, %{"counts" => %{"missing_checks" => 1}}} = Store.projection(@project, observations(), :operator, pid)
    native = observations([evidence()])
    assert {:ok, %{"counts" => %{"covered" => 1}, "execution_authority" => false, "deployment_authority" => false}} = Store.projection(@project, native, :operator, pid)
    stale = put_in(native, ["tasks", Access.at(0), "revision"], "task-v2")
    assert {:ok, %{"counts" => %{"stale" => 1}, "stale_task_ids" => [@task]}} = Store.projection(@project, stale, :operator, pid)
    advanced = put_in(native, ["tasks", Access.at(0), "subject", "revision"], String.duplicate("c", 40))
    assert {:ok, %{"counts" => %{"stale" => 1}}} = Store.projection(@project, advanced, :operator, pid)
    assert {:ok, %{"observations_available" => false, "counts" => %{"covered" => 0}}} = Store.projection(@project, %{}, :operator, pid)
    uncovered = Map.put(doc(), "task_links", [])
    {:ok, _} = Store.save(@project, 2, uncovered, :operator, pid)
    assert {:ok, %{"counts" => %{"uncovered" => 1}, "unlinked_task_ids" => [@task]}} = Store.projection(@project, native, :operator, pid)
  end

  test "manual, imported, skipped, failed and old observations cannot satisfy checks", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    {:ok, _} = Store.baseline(@project, 1, :operator, pid)
    assert {:ok, %{"storage_revision" => 3, "evidence" => [manual]}} = Store.evidence(@project, 2, evidence(), :operator, pid)
    assert manual["origin"] == "manual"
    assert {:ok, %{"counts" => %{"covered" => 0}}} = Store.projection(@project, observations(), :operator, pid)

    for record <- [
          Map.put(evidence(), "origin", "manual"),
          Map.put(evidence(), "origin", "imported"),
          Map.put(evidence(), "result", "skipped"),
          Map.put(evidence(), "result", "failed"),
          Map.put(evidence(), "observed_at", "2020-01-01T00:00:00Z")
        ] do
      assert {:ok, %{"counts" => %{"covered" => 0}}} = Store.projection(@project, observations([record]), :operator, pid)
    end

    assert {:error, :assurance_evidence_not_observable} = Store.observe(@project, 3, Map.put(evidence(), "producer", "forged"), :operator, pid)
    foreign = put_in(evidence(), ["subject", "repository"], "other/repo")
    assert {:error, :assurance_evidence_scope_mismatch} = Store.observe(@project, 3, foreign, :operator, pid)
  end

  test "every linked task subject must have all required criterion checks", c do
    pid = start_supervised!({Store, c.opts})
    second = hd(doc()["task_links"]) |> Map.merge(%{"task_id" => @project <> ":2", "subject" => put_in(subject("pr"), ["pr_number"], 8)})
    linked = Map.put(doc(), "task_links", doc()["task_links"] ++ [second])
    {:ok, _} = Store.save(@project, 0, linked, :operator, pid)
    {:ok, _} = Store.baseline(@project, 1, :operator, pid)
    second_task = %{"id" => second["task_id"], "revision" => second["task_revision"], "subject" => second["subject"]}
    observed = observations([evidence()]) |> Map.update!("tasks", &(&1 ++ [second_task]))
    assert {:ok, %{"counts" => %{"covered" => 0, "missing_checks" => 1}}} = Store.projection(@project, observed, :operator, pid)
    second_evidence = evidence() |> Map.merge(%{"id" => "evidence-2", "subject" => second["subject"], "run_id" => "native-run-2"})
    both = Map.update!(observed, "evidence", &(&1 ++ [second_evidence]))
    assert {:ok, %{"counts" => %{"covered" => 1}}} = Store.projection(@project, both, :operator, pid)
  end

  test "changed task coverage and dependency annotations require another reviewed baseline", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    {:ok, _} = Store.baseline(@project, 1, :operator, pid)
    second = hd(doc()["task_links"]) |> Map.merge(%{"task_id" => @project <> ":2", "subject" => put_in(subject("pr"), ["pr_number"], 8)})
    relinked = Map.put(doc(), "task_links", [second])
    {:ok, _} = Store.save(@project, 2, relinked, :operator, pid)
    proof = evidence() |> Map.merge(%{"id" => "second-check", "subject" => second["subject"]})
    observed = %{"tasks" => [%{"id" => second["task_id"], "revision" => second["task_revision"], "subject" => second["subject"]}], "evidence" => [proof]}
    assert {:ok, %{"counts" => %{"covered" => 0, "unreviewed" => 1}}} = Store.projection(@project, observed, :operator, pid)
    {:ok, %{"reviewed" => baseline}} = Store.baseline(@project, 3, :operator, pid)
    assert {:ok, %{"counts" => %{"covered" => 1}}} = Store.projection(@project, observed, :operator, pid)
    annotation = %{"task_id" => second["task_id"], "depends_on" => @task, "reason" => "Reuse the reviewed schema", "output" => "Validated request schema", "reviewed_ref" => baseline["ref"]}
    changed = Map.put(relinked, "dependencies", [annotation])
    {:ok, _} = Store.save(@project, 4, changed, :operator, pid)
    assert {:ok, %{"counts" => %{"covered" => 0, "unreviewed" => 1}}} = Store.projection(@project, observed, :operator, pid)
    {:ok, _} = Store.baseline(@project, 5, :operator, pid)
    assert {:ok, %{"counts" => %{"covered" => 1}}} = Store.projection(@project, observed, :operator, pid)
  end

  test "native receipt import is immutable, idempotent and verifier-bound", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    record = evidence()
    assert {:ok, %{"storage_revision" => 2}} = Store.observe(@project, 1, record, :operator, pid)
    assert {:ok, %{"storage_revision" => 2}} = Store.observe(@project, 2, record, :operator, pid)
    assert {:error, :assurance_record_conflict} = Store.observe(@project, 2, Map.put(record, "result", "failed"), :operator, pid)
    assert {:ok, %{"evidence" => [^record]}} = Store.read(@project, :operator, pid)
  end

  test "a passed check cannot mask a fresh failed or pending rerun for its exact subject", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    {:ok, _} = Store.baseline(@project, 1, :operator, pid)

    for outcome <- ~w(failed pending skipped) do
      rerun = evidence() |> Map.merge(%{"id" => "rerun-#{outcome}", "run_id" => "rerun-#{outcome}", "result" => outcome})
      observed = observations([evidence(), rerun])
      assert {:ok, %{"counts" => %{"covered" => 0, "missing_checks" => 1}}} = Store.projection(@project, observed, :operator, pid)
    end
  end

  test "graph baselines sanitize work details, survive restart and diff task metadata", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    graph = graph()
    assert {:ok, %{"reviewed" => frozen}} = Store.baseline_graph(@project, 1, graph, :operator, pid)
    assert length(frozen["graph_snapshot"]["graph"]["nodes"]) == 2
    refute Jason.encode!(frozen) =~ "PRIVATE INSTRUCTION"
    changed = update_in(graph, ["nodes"], fn nodes -> Enum.map(nodes, fn node -> if node["type"] == "task", do: Map.put(node, "title", "Revised title"), else: node end) end)
    assert {:ok, %{"reviewed" => next}} = Store.baseline_graph(@project, 2, changed, :operator, pid)
    refute next["ref"] == frozen["ref"]
    assert {:ok, %{"graph" => %{"nodes" => %{"changed" => ["task:" <> @task]}}}} = Store.diff(@project, frozen["ref"], :operator, pid)
    assert {:ok, ^frozen} = Store.reviewed(@project, frozen["ref"], :operator, pid)
    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:ok, ^frozen} = Store.reviewed(@project, frozen["ref"], :operator, restarted)
    assert {:error, :invalid_assurance_graph} = GraphSnapshot.capture(Map.put(graph, "project_id", "another"), @project)
    assert {:error, :invalid_assurance_graph} = GraphSnapshot.capture(put_in(graph, ["warnings"], [<<255>>]), @project)
    assert {:error, :invalid_assurance_graph} = GraphSnapshot.capture(Map.put(graph, "nodes", List.duplicate(nil, 50_002)), @project)
    assert {:error, :invalid_assurance_graph} = GraphSnapshot.capture(nil, @project)
  end

  test "historical graphs retain dependency cycles and bounded metadata while stripping embedded work artifacts" do
    original = graph()
    task = Enum.find(original["nodes"], &(&1["type"] == "task"))

    other =
      task
      |> Map.merge(%{
        "id" => "task:" <> @project <> ":2",
        "task_id" => @project <> ":2",
        "issue_id" => "2",
        "identifier" => "GH-2",
        "missing" => true,
        "milestone" => %{"id" => 9, "title" => "MVP", "state" => "open", "url" => nil}
      })

    edge = %{
      "id" => "dependency-1",
      "type" => "depends_on",
      "source" => task["id"],
      "target" => other["id"],
      "kind" => "delivery",
      "blocking" => true,
      "reason" => nil,
      "status" => "missing",
      "satisfaction" => "human_acceptance",
      "evidence" => %{},
      "instruction" => "PRIVATE INSTRUCTION"
    }

    graph = original |> Map.put("nodes", original["nodes"] ++ [other]) |> Map.put("edges", [edge])
    assert {:ok, snapshot} = GraphSnapshot.capture(graph, @project)
    assert GraphSnapshot.valid?(snapshot, @project)
    refute Jason.encode!(snapshot) =~ "PRIVATE INSTRUCTION"
    assert %{"edges" => %{"added" => ["dependency-1"]}} = GraphSnapshot.diff(nil, snapshot)
    assert %{"edges" => %{"removed" => ["dependency-1"]}} = GraphSnapshot.diff(snapshot, nil)
    cycle = %{edge | "target" => task["id"], "status" => "cycle", "evidence" => %{"accepted_at" => timestamp(), "candidate_sha" => @sha}}
    assert {:ok, _} = GraphSnapshot.capture(Map.put(graph, "edges", [cycle]), @project)
    corrupt = put_in(graph, ["edges", Access.at(0), "evidence"], %{"candidate_sha" => "forged"})
    assert {:error, :invalid_assurance_graph} = GraphSnapshot.capture(corrupt, @project)
    refute GraphSnapshot.valid?(Map.put(snapshot, "content_ref", String.duplicate("c", 64)), @project)
    refute GraphSnapshot.valid?(Map.put(snapshot, "captured_at", nil), @project)
    unknown = put_in(snapshot, ["graph", "nodes", Access.at(1), "type"], "unknown")
    refute GraphSnapshot.valid?(unknown, @project)
  end

  test "release readiness requires exact integrated SHA artifact target and all mandatory receipts", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    {:ok, %{"reviewed" => base}} = Store.baseline(@project, 1, :operator, pid)
    security = evidence() |> Map.merge(%{"id" => "security-receipt", "criterion_id" => nil, "release_id" => "release-1", "check" => "security", "subject" => subject("artifact")})
    health = evidence() |> Map.merge(%{"id" => "health-receipt", "criterion_id" => nil, "release_id" => "release-1", "check" => "health", "subject" => subject("runtime")})
    receipts = release_receipts() ++ [security, health]

    revision =
      Enum.reduce(receipts, 2, fn receipt, rev ->
        {:ok, result} = Store.observe(@project, rev, receipt, :operator, pid)
        result["storage_revision"]
      end)

    record = release_record(base["ref"], Enum.map(receipts, & &1["id"])) |> Map.put("required_gates", ~w(artifact deployment runtime security health))
    assert {:ok, %{"storage_revision" => release_revision}} = Store.release(@project, revision, record, :operator, pid)
    assert {:ok, %{"storage_revision" => ^release_revision}} = Store.release(@project, release_revision, record, :operator, pid)
    assert {:error, :assurance_record_conflict} = Store.release(@project, release_revision, Map.put(record, "target", "other"), :operator, pid)
    {:ok, projection} = Store.projection(@project, observations(receipts), :operator, pid)
    assert [%{"ready" => true, "deployment_authority" => false}] = projection["release_readiness"]
    rerun = hd(receipts) |> Map.merge(%{"id" => "release-rerun", "run_id" => "release-rerun", "result" => "pending"})
    {:ok, blocked} = Store.projection(@project, observations(receipts ++ [rerun]), :operator, pid)
    assert [%{"ready" => false, "build_ready" => false}] = blocked["release_readiness"]

    for {field, replacement} <- [
          {"revision", String.duplicate("c", 40)},
          {"artifact_digest", "sha256:" <> String.duplicate("c", 64)},
          {"environment", "wrong-target"},
          {"configuration_ref", "wrong-config"}
        ] do
      mismatched = Enum.map(receipts, fn receipt -> if receipt["subject"]["kind"] == "runtime", do: put_in(receipt, ["subject", field], replacement), else: receipt end)
      {:ok, projection} = Store.projection(@project, observations(mismatched), :operator, pid)
      assert [%{"ready" => false, "runtime_verified" => false}] = projection["release_readiness"]
    end

    skipped = Enum.map(receipts, &Map.put(&1, "result", "skipped"))
    {:ok, projection} = Store.projection(@project, observations(skipped), :operator, pid)
    assert [%{"ready" => false, "build_ready" => false}] = projection["release_readiness"]
    assert {:ok, %{"release_readiness" => [%{"ready" => false}]}} = Store.projection(@project, observations(), :operator, pid)
    changed = put_in(doc(), ["requirements", Access.at(0), "title"], "New scope")
    {:ok, _} = Store.save(@project, release_revision, changed, :operator, pid)
    {:ok, projection} = Store.projection(@project, observations(receipts), :operator, pid)
    assert [%{"ready" => false, "issues" => issues}] = projection["release_readiness"]
    assert "unreviewed_changes" in issues
  end

  test "unknown release baselines and evidence identities cannot create a candidate", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, doc(), :operator, pid)
    {:ok, %{"reviewed" => base}} = Store.baseline(@project, 1, :operator, pid)
    assert {:error, :invalid_assurance_release} = Store.release(@project, 2, %{}, :operator, pid)
    missing = release_record(String.duplicate("f", 64), [])
    assert {:error, :assurance_baseline_not_found} = Store.release(@project, 2, missing, :operator, pid)
    record = release_record(base["ref"], ["missing-receipt"])
    assert {:error, :assurance_evidence_not_found} = Store.release(@project, 2, record, :operator, pid)
    assert {:ok, %{"releases" => [], "storage_revision" => 2}} = Store.read(@project, :operator, pid)
  end

  test "a full bounded evidence ledger retains its prior records when another declaration cannot fit", c do
    binding = scope_binding(c)

    records =
      Map.new(1..10_000, fn n ->
        record = evidence() |> Map.merge(%{"id" => "record-#{n}", "origin" => "manual"})
        {record["id"], record}
      end)

    journal = Contract.empty(@project, binding) |> Map.merge(%{"draft" => doc(), "evidence" => records, "storage_revision" => 10_000})
    write_journal(c, journal)
    pid = start_supervised!({Store, c.opts})
    extra = evidence() |> Map.put("id", "overflow")
    assert {:error, :assurance_storage_full} = Store.evidence(@project, 10_000, extra, :operator, pid)
    assert {:ok, retained} = Store.read(@project, :operator, pid)
    assert retained["storage_revision"] == 10_000
    assert length(retained["evidence"]) == 10_000
    assert Jason.decode!(File.read!(Path.join(c.root, "journal.json")))["evidence"] == records
  end

  test "journal byte capacity preserves reviewed history and the saved draft without pruning", c do
    documents = Enum.map(1..5, &large_document/1)

    baselines =
      Map.new(Enum.take(documents, 4), fn document ->
        ref = Contract.ref(document)
        {ref, %{"ref" => ref, "reviewed_at" => timestamp(), "document" => document, "graph_snapshot" => nil}}
      end)

    reviewed = Contract.ref(Enum.at(documents, 3))
    journal = Contract.empty(@project, scope_binding(c)) |> Map.merge(%{"draft" => List.last(documents), "baselines" => baselines, "reviewed_ref" => reviewed, "storage_revision" => 9})
    bytes = write_journal(c, journal)
    assert byte_size(bytes) < 32_000_000
    pid = start_supervised!({Store, c.opts})
    assert {:error, :assurance_storage_full} = Store.baseline(@project, 9, :operator, pid)
    assert {:ok, retained} = Store.read(@project, :operator, pid)
    assert retained["storage_revision"] == 9
    assert length(retained["baselines"]) == 4
    assert retained["reviewed"]["ref"] == reviewed
    assert File.read!(Path.join(c.root, "journal.json")) == bytes
  end

  test "PR passing checks cannot stand in for integrated-source evidence" do
    doc = doc()
    base = %{"ref" => Contract.ref(doc), "document" => doc, "reviewed_at" => timestamp(), "graph_snapshot" => nil}
    receipts = release_receipts() |> Enum.map(fn value -> if value["check"] == "unit", do: Map.put(value, "subject", subject("pr")), else: value end)
    record = release_record(base["ref"], Enum.map(receipts, & &1["id"]))

    journal =
      Contract.empty(@project, "scope")
      |> Map.merge(%{
        "draft" => doc,
        "reviewed_ref" => base["ref"],
        "baselines" => %{base["ref"] => base},
        "evidence" => Map.new(receipts, &{&1["id"], &1}),
        "releases" => %{"release-1" => %{"id" => "release-1", "record" => record}}
      })

    result = Projection.build(journal, observations(receipts))
    assert [%{"ready" => false, "issues" => issues}] = result["release_readiness"]
    assert "missing_integrated_checks" in issues
    assert "missing_integrated_criteria" in issues
  end

  test "integrated evidence cannot hide an in-scope criterion with no linked delivery task" do
    document = doc()
    second = %{criterion() | "id" => "AC-2"}
    document = put_in(document, ["requirements", Access.at(0), "criteria"], [criterion(), second])
    base = %{"ref" => Contract.ref(document), "document" => document, "reviewed_at" => timestamp(), "graph_snapshot" => nil}
    proof = hd(release_receipts()) |> Map.merge(%{"id" => "release-second", "criterion_id" => "AC-2"})
    receipts = release_receipts() ++ [proof]
    record = release_record(base["ref"], Enum.map(receipts, & &1["id"]))

    journal =
      Contract.empty(@project, "scope")
      |> Map.merge(%{
        "draft" => document,
        "reviewed_ref" => base["ref"],
        "baselines" => %{base["ref"] => base},
        "evidence" => Map.new(receipts, &{&1["id"], &1}),
        "releases" => %{"release-1" => %{"id" => "release-1", "record" => record}}
      })

    result = Projection.build(journal, observations(receipts))
    assert [%{"ready" => false, "missing_criteria" => ["AC-2"]}] = result["release_readiness"]
  end

  defp start_owner(opts), do: start_supervised!(%{id: make_ref(), start: {Store, :start_link, [opts]}})
  defp scope_binding(c), do: Persistence.scope_ref(%{"project" => @project, "root" => c.root, "source" => "scope"})

  defp write_journal(c, journal) do
    assert Contract.valid?(journal, @project, journal["scope"])
    bytes = Jason.encode!(journal)
    File.mkdir_p!(c.root)
    File.chmod!(c.root, 0o700)
    File.write!(Path.join(c.root, "journal.json"), bytes)
    File.chmod!(Path.join(c.root, "journal.json"), 0o600)
    bytes
  end

  defp large_document(version) do
    requirements =
      Enum.map(1..20, fn r ->
        criteria = Enum.map(1..100, fn n -> %{criterion() | "id" => "AC-#{r}-#{n}", "text" => String.duplicate("x", 3_000)} end)
        %{"id" => "REQ-#{r}", "title" => "Observable scope #{version}", "kind" => "nonfunctional", "exclusion" => nil, "criteria" => criteria}
      end)

    Contract.document(@project) |> Map.put("requirements", requirements)
  end

  defp await_fault(pid, attempts \\ 100) do
    if :sys.get_state(pid).fault == nil and attempts > 0 do
      Process.sleep(5)
      await_fault(pid, attempts - 1)
    else
      assert :sys.get_state(pid).fault == :assurance_storage_unavailable
    end
  end

  defp criterion, do: %{"id" => "AC-1", "text" => "A request completes successfully", "required_checks" => ["unit"]}

  defp doc do
    Contract.document(@project)
    |> Map.merge(%{
      "requirements" => [%{"id" => "REQ-1", "title" => "Requests", "kind" => "functional", "exclusion" => nil, "criteria" => [criterion()]}],
      "task_links" => [%{"task_id" => @task, "criterion_id" => "AC-1", "task_revision" => "task-v1", "subject" => subject("pr")}]
    })
  end

  defp subject(kind) do
    %{
      "kind" => kind,
      "repository" => "example/coverage",
      "revision" => @sha,
      "artifact_digest" => if(kind in ~w(artifact runtime), do: @digest),
      "environment" => if(kind == "runtime", do: "production"),
      "configuration_ref" => if(kind == "runtime", do: "config-v1"),
      "pr_number" => if(kind == "pr", do: 7)
    }
  end

  defp evidence,
    do: %{
      "id" => "evidence-1",
      "criterion_id" => "AC-1",
      "release_id" => nil,
      "check" => "unit",
      "subject" => subject("pr"),
      "producer" => "pinned-native",
      "run_id" => "native-run-1",
      "result" => "passed",
      "observed_at" => timestamp(),
      "origin" => "native"
    }

  defp observations(evidence \\ []), do: %{"tasks" => [%{"id" => @task, "revision" => "task-v1", "subject" => subject("pr")}], "evidence" => evidence}

  defp release_receipts do
    Enum.map([{"unit", "source"}, {"artifact", "artifact"}, {"deployment", "runtime"}, {"runtime", "runtime"}], fn {check, kind} ->
      evidence() |> Map.merge(%{"id" => "release-#{check}", "criterion_id" => if(check == "unit", do: "AC-1"), "release_id" => "release-1", "check" => check, "subject" => subject(kind)})
    end)
  end

  defp release_record(ref, evidence_ids),
    do: %{
      "id" => "release-1",
      "baseline_ref" => ref,
      "task_ids" => [@task],
      "integrated_sha" => @sha,
      "artifact_digest" => @digest,
      "target" => "production",
      "configuration_ref" => "config-v1",
      "required_checks" => ["unit"],
      "required_gates" => ["artifact", "deployment", "runtime"],
      "evidence_ids" => evidence_ids
    }

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp graph do
    node = %{
      "id" => "task:" <> @task,
      "type" => "task",
      "task_id" => @task,
      "issue_id" => "1",
      "identifier" => "GH-1",
      "title" => "Request work",
      "lane" => "Backlog",
      "stage" => "backlog",
      "execution_status" => "idle",
      "task_kind" => "general",
      "priority" => 1,
      "milestone" => nil,
      "tags" => [],
      "dependency_error" => nil,
      "url" => "https://github.com/example/coverage/issues/1",
      "missing" => false,
      "cycle" => false,
      "upstream_count" => 0,
      "upstream_known" => 0,
      "upstream_unknown" => 0,
      "downstream_count" => 0,
      "downstream_known" => 0,
      "downstream_unknown" => 0
    }

    %{
      "version" => 1,
      "project_id" => @project,
      "policy" => "human_acceptance",
      "nodes" => [%{"id" => "project:" <> @project, "type" => "project", "name" => @project}, node, %{"id" => "work:1", "type" => "work", "title" => "PRIVATE INSTRUCTION"}],
      "edges" => [],
      "warnings" => []
    }
  end
end
