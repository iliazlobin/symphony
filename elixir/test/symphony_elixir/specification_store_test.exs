defmodule SymphonyElixir.Specification.StoreTest do
  use ExUnit.Case, async: false

  import Bitwise
  alias SymphonyElixir.Specification.{Document, Persistence, Store}

  @project "github:example/design"

  setup do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "specification-store-#{System.unique_integer([:positive])}"))
    {:ok, scope} = Agent.start_link(fn -> "tracker-a" end)
    {:ok, auth} = Agent.start_link(fn -> true end)
    opts = [name: nil, state_dir: root, project: @project, scope: fn -> Agent.get(scope, & &1) end, authorize: fn token -> token == :operator and Agent.get(auth, & &1) end]
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, opts: opts, scope: scope, auth: auth, document: document()}
  end

  test "initial draft is empty and successful saves survive a new real owner", c do
    pid = start_supervised!({Store, c.opts})
    assert {:ok, %{"storage_revision" => 0, "draft" => nil, "reviewed" => nil, "review_count" => 0}} = Store.read(@project, :operator, pid)
    refute File.exists?(journal(c))
    assert {:ok, %{"storage_revision" => 1, "draft" => draft}} = Store.save(@project, 0, c.document, :operator, pid)
    assert draft == c.document
    assert band(File.stat!(c.root).mode, 0o777) == 0o700
    assert band(File.stat!(journal(c)).mode, 0o777) == 0o600
    assert File.ls!(c.root) |> Enum.sort() == [".owner.lock", "journal.json"]
    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:ok, %{"storage_revision" => 1, "draft" => ^draft}} = Store.read(@project, :operator, restarted)
  end

  test "two concurrent browser saves compare durable revision and only one wins", c do
    pid = start_supervised!({Store, c.opts})
    alternatives = [c.document, put_in(c.document, ["sections", "brief", "items", Access.at(0), "body"], "Second proposal")]
    results = alternatives |> Task.async_stream(&Store.save(@project, 0, &1, :operator, pid), max_concurrency: 2) |> Enum.map(fn {:ok, result} -> result end)
    assert Enum.count(results, &match?({:ok, %{"storage_revision" => 1}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_specification_revision})) == 1
    assert {:ok, saved} = Store.read(@project, :operator, pid)
    assert saved["draft"] in alternatives
    assert Jason.decode!(File.read!(journal(c)))["draft"] == saved["draft"]
    assert {:ok, ^saved} = Store.save(@project, 1, saved["draft"], :operator, pid)
    assert {:error, :stale_specification_revision} = Store.save(@project, "1", saved["draft"], :operator, pid)
  end

  test "review freezes an immutable content reference while later drafts and reviews remain editable", c do
    pid = start_supervised!({Store, c.opts})
    assert {:error, :specification_not_saved} = Store.review(@project, 0, :operator, pid)
    assert {:ok, %{"storage_revision" => 1}} = Store.save(@project, 0, c.document, :operator, pid)
    assert {:ok, %{"storage_revision" => 2, "reviewed" => baseline, "review_count" => 1}} = Store.review(@project, 1, :operator, pid)
    assert {:ok, frozen} = Store.reviewed(@project, baseline["ref"], :operator, pid)
    assert frozen["specification"] == c.document
    assert frozen["document_id"] == c.document["document_id"]
    assert {:ok, %{"storage_revision" => 2}} = Store.review(@project, 2, :operator, pid)
    assert {:error, :stale_specification_revision} = Store.review(@project, 1, :operator, pid)
    changed = c.document |> put_in(["sections", "brief", "items", Access.at(0), "body"], "An additional requirement")
    assert {:ok, %{"storage_revision" => 3, "reviewed" => ^baseline}} = Store.save(@project, 2, changed, :operator, pid)
    assert {:ok, ^frozen} = Store.reviewed(@project, baseline["ref"], :operator, pid)
    assert {:ok, %{"storage_revision" => 4, "reviewed" => next, "review_count" => 2, "reviewed_versions" => versions}} = Store.review(@project, 3, :operator, pid)
    assert length(versions) == 2 and Enum.all?(versions, &(not Map.has_key?(&1, "specification")))
    refute next["ref"] == baseline["ref"]
    assert {:error, :specification_review_not_found} = Store.reviewed(@project, "unknown", :operator, pid)
    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:ok, ^frozen} = Store.reviewed(@project, baseline["ref"], :operator, restarted)
    assert {:ok, %{"specification" => ^changed}} = Store.reviewed(@project, next["ref"], :operator, restarted)
  end

  test "source captures one immutable review and its current draft in the same owner operation", c do
    pid = start_supervised!({Store, c.opts})
    assert {:error, :specification_review_not_found} = Store.source(@project, "unknown", :operator, pid)
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    {:ok, reviewed} = Store.review(@project, 1, :operator, pid)
    ref = reviewed["reviewed"]["ref"]
    assert {:ok, %{"storage_revision" => 2, "draft" => original, "reviewed" => frozen}} = Store.source(@project, ref, :operator, pid)
    assert original == c.document and frozen["specification"] == c.document
    changed = altered(c.document, "body", "A later draft")
    requests = [fn -> Store.source(@project, ref, :operator, pid) end, fn -> Store.save(@project, 2, changed, :operator, pid) end]
    [{:ok, {:ok, captured}}, {:ok, {:ok, _}}] = Enum.to_list(Task.async_stream(requests, & &1.(), ordered: true))
    assert captured["reviewed"] == frozen
    assert {captured["storage_revision"], captured["draft"]} in [{2, c.document}, {3, changed}]
    assert {:ok, %{"storage_revision" => 3, "draft" => ^changed, "reviewed" => ^frozen}} = Store.source(@project, ref, :operator, pid)
    Agent.update(c.auth, fn _ -> false end)
    assert {:error, :unauthorized} = Store.source(@project, ref, :operator, pid)
  end

  test "authorization is fresh for all read and mutation operations", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    {:ok, saved} = Store.review(@project, 1, :operator, pid)
    bytes = File.read!(journal(c))
    Agent.update(c.auth, fn _ -> false end)
    assert {:error, :unauthorized} = Store.read(@project, :operator, pid)
    assert {:error, :unauthorized} = Store.save(@project, 2, c.document, :operator, pid)
    assert {:error, :unauthorized} = Store.review(@project, 2, :operator, pid)
    assert {:error, :unauthorized} = Store.reviewed(@project, saved["reviewed"]["ref"], :operator, pid)
    assert File.read!(journal(c)) == bytes
    Agent.update(c.auth, fn _ -> true end)
    assert {:ok, ^saved} = Store.read(@project, :operator, pid)
  end

  test "configuration scope changes fence old owners permanently and preserve the journal", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    bytes = File.read!(journal(c))
    Agent.update(c.scope, fn _ -> "tracker-b" end)
    assert {:error, :specification_scope_changed} = Store.read(@project, :operator, pid)
    Agent.update(c.scope, fn _ -> "tracker-a" end)
    assert {:error, :specification_scope_changed} = Store.save(@project, 1, c.document, :operator, pid)
    :ok = stop_supervised(Store)
    Agent.update(c.scope, fn _ -> "tracker-b" end)
    restarted = start_owner(c.opts)
    assert Process.alive?(restarted)
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, restarted)
    assert File.read!(journal(c)) == bytes
  end

  test "another owner is rejected and lock release after process death permits recovery", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    other = start_owner(c.opts)
    assert {:error, :specification_storage_locked} = Store.read(@project, :operator, other)
    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:ok, %{"storage_revision" => 1}} = Store.read(@project, :operator, restarted)
    assert {:error, :specification_storage_locked} = Store.read(@project, :operator, other)
  end

  test "losing the OS lock fails closed without writing", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    bytes = File.read!(journal(c))
    state = :sys.get_state(pid)
    true = Port.close(state.owner.lock)
    assert {:error, :specification_storage_unavailable} = Store.save(@project, 1, c.document, :operator, pid)
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, pid)
    assert File.read!(journal(c)) == bytes
  end

  test "external journal changes cannot be silently overwritten", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    foreign = File.read!(journal(c)) <> " "
    File.write!(journal(c), foreign)
    assert {:error, :specification_storage_unavailable} = Store.save(@project, 1, c.document, :operator, pid)
    assert File.read!(journal(c)) == foreign
  end

  test "replacing the lock path invalidates the retained owner before another write", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    bytes = File.read!(journal(c))
    lock = Path.join(c.root, ".owner.lock")
    File.rename!(lock, lock <> ".retained")
    File.write!(lock, "replacement")
    File.chmod!(lock, 0o600)
    assert {:error, :specification_storage_unavailable} = Store.save(@project, 1, c.document, :operator, pid)
    assert File.read!(journal(c)) == bytes
    assert File.read!(lock) == "replacement"
  end

  test "tampered review content is rejected on restart without replacing the evidence", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    {:ok, result} = Store.review(@project, 1, :operator, pid)
    :ok = stop_supervised(Store)
    record = Jason.decode!(File.read!(journal(c)))
    ref = result["reviewed"]["ref"]
    altered = put_in(record, ["reviews", ref, "specification", "sections", "brief", "items", Access.at(0), "body"], "Unreviewed substitution")
    bytes = Jason.encode!(altered)
    File.write!(journal(c), bytes)
    restarted = start_owner(c.opts)
    assert {:error, :specification_storage_unavailable} = Store.reviewed(@project, ref, :operator, restarted)
    assert File.read!(journal(c)) == bytes
  end

  test "symlinked roots and lock files are not followed or modified", c do
    retained = c.root <> "-original"
    File.mkdir_p!(retained)
    File.chmod!(retained, 0o700)
    on_exit(fn -> File.rm_rf(retained) end)
    File.ln_s!(retained, c.root)
    linked = start_owner(c.opts)
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, linked)
    assert File.ls!(retained) == []
    File.rm!(c.root)
    File.mkdir_p!(c.root)
    File.chmod!(c.root, 0o700)
    target = Path.join(c.root, "retained-lock")
    File.write!(target, "retained lock content")
    File.ln_s!(target, Path.join(c.root, ".owner.lock"))
    locked = start_owner(c.opts)
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, locked)
    assert File.read!(target) == "retained lock content"
    refute File.exists?(journal(c))
  end

  test "corrupt, symlinked, public and oversized journals are preserved on startup", c do
    File.mkdir_p!(c.root)
    File.chmod!(c.root, 0o700)
    File.write!(journal(c), "{corrupt")
    File.chmod!(journal(c), 0o600)
    corrupted = start_owner(c.opts)
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, corrupted)
    assert File.read!(journal(c)) == "{corrupt"
    File.rm!(journal(c))
    target = Path.join(c.root, "original")
    File.write!(target, "retained")
    File.ln_s!(target, journal(c))
    linked = start_owner(c.opts)
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, linked)
    assert File.read!(target) == "retained"
    File.rm!(journal(c))
    File.write!(journal(c), "public original")
    File.chmod!(journal(c), 0o644)
    public = start_owner(c.opts)
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, public)
    assert band(File.stat!(journal(c)).mode, 0o777) == 0o644
    File.chmod!(journal(c), 0o600)
    File.write!(journal(c), String.duplicate("x", 32_000_001))
    oversized = start_owner(c.opts)
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, oversized)
    assert File.stat!(journal(c)).size == 32_000_001
  end

  test "project, document and malformed specifications never overwrite the saved draft", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, saved} = Store.save(@project, 0, c.document, :operator, pid)
    bytes = File.read!(journal(c))
    assert {:error, :specification_project_mismatch} = Store.read("other", :operator, pid)
    assert {:error, :specification_document_mismatch} = Store.save(@project, 1, Map.put(c.document, "document_id", "Different"), :operator, pid)

    for document <- [nil, %{}, Map.put(c.document, "project", "other"), altered(c.document, "kind", "task"), altered(c.document, "body", String.duplicate("x", 24_001))] do
      assert {:error, :invalid_specification_document} = Store.save(@project, 1, document, :operator, pid)
    end

    assert {:ok, ^saved} = Store.read(@project, :operator, pid)
    assert File.read!(journal(c)) == bytes
  end

  test "blank saved specifications cannot be reviewed", c do
    pid = start_supervised!({Store, c.opts})
    blank = Document.new(@project)
    assert {:ok, saved} = Store.save(@project, 0, blank, :operator, pid)
    assert {:error, :specification_empty} = Store.review(@project, 1, :operator, pid)
    assert {:ok, ^saved} = Store.read(@project, :operator, pid)
    assert saved["reviewed_versions"] == []
  end

  test "disabled storage remains unavailable without touching the requested path", c do
    pid = start_owner(Keyword.put(c.opts, :enabled, false))
    assert Process.alive?(pid)
    assert {:error, :specification_storage_unavailable} = Store.save(@project, 0, c.document, :operator, pid)
    refute File.exists?(c.root)
    Persistence.close(nil)
  end

  test "specification owner never imports a native canvas journal", c do
    scope = Persistence.scope_ref(%{"project" => @project, "root" => c.root, "source" => "tracker-a"})
    {:ok, owner, native} = SymphonyElixir.Design.Persistence.open(c.root, @project, scope)

    scene = %{
      "version" => 2,
      "project" => @project,
      "document_id" => "Native1",
      "revision" => 0,
      "boards" => Map.new(Document.sections(), &{&1, %{"elements" => [], "appState" => %{"scrollX" => 0, "scrollY" => 0, "zoom" => %{"value" => 1}}}})
    }

    native = Map.put(native, "draft", scene)
    assert {:ok, _owner} = SymphonyElixir.Design.Persistence.put(owner, native)
    SymphonyElixir.Design.Persistence.close(owner)
    bytes = File.read!(journal(c))
    pid = start_supervised!({Store, c.opts})
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, pid)
    assert File.read!(journal(c)) == bytes
  end

  test "configured specifications work without chat state, credentials or an enabled controller", c do
    previous = SymphonyElixir.Workflow.workflow_file_path()
    File.mkdir_p!(c.root)
    path = Path.join(c.root, "WORKFLOW.md")
    control = Path.join(c.root, "control.json")
    File.write!(path, "---\ntracker:\n  kind: memory\n  project_slug: example/spec\ncontrol:\n  enabled: false\n  state_path: #{control}\nchat:\n  enabled: false\n---\nTest specification storage.\n")
    SymphonyElixir.Workflow.set_workflow_file_path(path)
    SymphonyElixir.WorkflowStore.force_reload()

    on_exit(fn ->
      SymphonyElixir.Workflow.set_workflow_file_path(previous)
      SymphonyElixir.WorkflowStore.force_reload()
    end)

    assert SymphonyElixir.Config.chat_settings().enabled == false
    pid = start_owner(name: nil, authorize: &(&1 == :operator))
    project = "memory:example/spec"
    document = Document.new(project)
    assert {:ok, %{"storage_revision" => 1}} = Store.save(project, 0, document, :operator, pid)
    assert File.exists?(Path.join(control <> ".specification", "journal.json"))
    refute File.exists?(control)
    refute File.exists?(Path.join(c.root, "design"))
    File.write!(path, String.replace(File.read!(path), "chat:\n  enabled: false", "chat:\n  enabled: false\n  state_path: unused-chat-path"))
    SymphonyElixir.WorkflowStore.force_reload()
    assert {:ok, %{"draft" => ^document}} = Store.read(project, :operator, pid)
  end

  test "typed conversion persists beside immutable legacy reviews and survives owner restart", c do
    owner = start_supervised!({Store, c.opts})
    assert {:ok, %{"storage_revision" => 1}} = Store.save(@project, 0, c.document, :operator, owner)
    assert {:ok, %{"storage_revision" => 2, "reviewed" => old}} = Store.review(@project, 1, :operator, owner)
    {:ok, structured} = Document.upgrade(c.document)
    assert {:error, :stale_specification_revision} = Store.save(@project, 1, structured, :operator, owner)
    assert {:ok, %{"storage_revision" => 3, "review_count" => 1}} = Store.save(@project, 2, structured, :operator, owner)
    assert {:ok, record} = Store.reviewed(@project, old["ref"], :operator, owner)
    assert record["specification"] == c.document
    assert Document.content_ref(record["specification"]) == old["ref"]
    assert {:ok, %{"storage_revision" => 4, "review_count" => 2}} = Store.review(@project, 3, :operator, owner)
    assert :ok = stop_supervised(Store)
    restarted = start_supervised!({Store, c.opts})
    assert {:ok, %{"draft" => ^structured, "storage_revision" => 4, "review_count" => 2}} = Store.read(@project, :operator, restarted)
    assert {:ok, ^record} = Store.reviewed(@project, old["ref"], :operator, restarted)
    assert {:error, :unauthorized} = Store.save(@project, 4, structured, :guest, restarted)
  end

  test "journal capacity failure keeps the draft and every immutable version without pruning", c do
    large = put_in(c.document, ["sections", "brief", "items"], Enum.map(1..37, fn n -> %{"id" => "goal#{n}", "kind" => "goal", "title" => "Goal", "body" => String.duplicate("x", 24_000)} end))
    assert Document.valid?(large, @project)
    variants = Enum.map(1..34, fn n -> put_in(large, ["sections", "brief", "items", Access.at(0), "title"], "Revision #{n}") end)

    records =
      Map.new(variants, fn doc ->
        ref = Document.content_ref(doc)
        {ref, %{"ref" => ref, "document_id" => doc["document_id"], "reviewed_at" => "2026-10-04T00:00:00Z", "specification" => doc}}
      end)

    scope = Persistence.scope_ref(%{"project" => @project, "root" => c.root, "source" => "tracker-a"})
    {:ok, owner, initial} = Persistence.open(c.root, @project, scope)
    retained = Map.merge(initial, %{"draft" => List.last(variants), "reviews" => records, "reviewed_ref" => Document.content_ref(List.last(variants)), "storage_revision" => 68})
    assert {:ok, owner} = Persistence.put(owner, retained)
    Persistence.close(owner)
    pid = start_supervised!({Store, c.opts})
    candidate = put_in(large, ["sections", "brief", "items", Access.at(0), "title"], "Revision 35")
    assert {:ok, saved} = Store.save(@project, 68, candidate, :operator, pid)
    bytes = File.read!(journal(c))
    assert {:error, :specification_storage_full} = Store.review(@project, 69, :operator, pid)
    assert {:ok, ^saved} = Store.read(@project, :operator, pid)
    assert File.read!(journal(c)) == bytes
    assert saved["review_count"] == 34
    for ref <- Map.keys(records), do: assert({:ok, %{"ref" => ^ref}} = Store.reviewed(@project, ref, :operator, pid))
  end

  test "default owner starts once and missing services return a bounded unavailable response" do
    assert {:error, {:already_started, pid}} = Store.start_link()
    assert Process.alive?(pid)
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, :missing_specification_owner)
  end

  test "provider exit is observed by the real owner before any further mutation", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    before = File.read!(journal(c))
    true = Port.command(:sys.get_state(pid).owner.lock, "x")
    await_fault(pid)
    assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, pid)
    assert File.read!(journal(c)) == before
  end

  test "scope and authorization callback faults fail closed without losing the draft", c do
    for callback <- [fn -> raise "authorization unavailable" end, fn -> throw(:authorization_unavailable) end] do
      pid = start_owner(Keyword.put(c.opts, :authorize, fn _ -> callback.() end))
      assert {:error, :unauthorized} = Store.read(@project, :operator, pid)
    end

    for callback <- [fn -> raise "scope unavailable" end, fn -> throw(:scope_unavailable) end] do
      pid = start_owner(Keyword.put(c.opts, :scope, callback))
      assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, pid)
    end

    refute File.exists?(journal(c))
  end

  test "a write failure preserves durable data and latches the owner unavailable", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    bytes = File.read!(journal(c))
    File.chmod!(c.root, 0o500)

    try do
      assert {:error, :specification_storage_unavailable} = Store.save(@project, 1, altered(c.document, "body", "Unsaved"), :operator, pid)
      assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, pid)
      assert File.read!(journal(c)) == bytes
    after
      File.chmod!(c.root, 0o700)
    end

    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:ok, %{"draft" => draft, "storage_revision" => 1}} = Store.read(@project, :operator, restarted)
    assert draft == c.document
  end

  test "malformed journal and review metadata stay retained and unavailable", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.document, :operator, pid)
    {:ok, saved} = Store.review(@project, 1, :operator, pid)
    original = Jason.decode!(File.read!(journal(c)))
    ref = saved["reviewed"]["ref"]
    :ok = stop_supervised(Store)

    invalid = [
      nil,
      %{},
      Map.put(original, "version", 2),
      put_in(original, ["reviews", ref], nil),
      put_in(original, ["reviews", ref, "reviewed_at"], "not-a-time"),
      put_in(original, ["reviews", ref, "reviewed_at"], nil)
    ]

    for record <- invalid do
      bytes = Jason.encode!(record)
      File.write!(journal(c), bytes)
      restarted = start_owner(c.opts)
      assert {:error, :specification_storage_unavailable} = Store.read(@project, :operator, restarted)
      assert File.read!(journal(c)) == bytes
    end
  end

  defp await_fault(pid, attempts \\ 100) do
    if is_nil(:sys.get_state(pid).fault) and attempts > 0 do
      Process.sleep(5)
      await_fault(pid, attempts - 1)
    else
      assert :sys.get_state(pid).fault == :specification_storage_unavailable
    end
  end

  defp start_owner(opts) do
    start_supervised!(%{id: make_ref(), start: {Store, :start_link, [opts]}})
  end

  defp journal(c), do: Path.join(c.root, "journal.json")
  defp altered(document, key, value), do: put_in(document, ["sections", "brief", "items", Access.at(0), key], value)

  defp document do
    Document.new(@project)
    |> Map.put("version", 1)
    |> Map.put("document_id", "Specification1")
    |> put_in(["sections", "brief", "items"], [%{"id" => "goal1", "kind" => "goal", "title" => "Useful discovery", "body" => "Find a relevant local event."}])
  end
end
