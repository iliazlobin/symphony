defmodule SymphonyElixir.Design.StoreTest do
  use ExUnit.Case, async: false

  import Bitwise
  alias SymphonyElixir.Design.{Persistence, Store}

  @project "github:example/design"

  setup do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "design-store-#{System.unique_integer([:positive])}"))
    {:ok, scope} = Agent.start_link(fn -> "tracker-a" end)
    {:ok, auth} = Agent.start_link(fn -> true end)
    opts = [name: nil, state_dir: root, project: @project, scope: fn -> Agent.get(scope, & &1) end, authorize: fn token -> token == :operator and Agent.get(auth, & &1) end]
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, opts: opts, scope: scope, auth: auth, scene: scene()}
  end

  test "initial draft is empty and successful saves survive a new real owner", c do
    pid = start_supervised!({Store, c.opts})
    assert {:ok, %{"storage_revision" => 0, "draft" => nil, "reviewed" => nil, "review_count" => 0}} = Store.read(@project, :operator, pid)
    refute File.exists?(journal(c))
    assert {:ok, %{"storage_revision" => 1, "draft" => draft}} = Store.save(@project, 0, c.scene, :operator, pid)
    assert draft == c.scene
    assert band(File.stat!(c.root).mode, 0o777) == 0o700
    assert band(File.stat!(journal(c)).mode, 0o777) == 0o600
    assert File.ls!(c.root) |> Enum.sort() == [".owner.lock", "journal.json"]
    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:ok, %{"storage_revision" => 1, "draft" => ^draft}} = Store.read(@project, :operator, restarted)
  end

  test "two concurrent browser saves compare durable revision and only one wins", c do
    pid = start_supervised!({Store, c.opts})
    alternatives = [c.scene, put_in(c.scene, ["boards", "brief", "elements", Access.at(0), "text"], "Second proposal")]
    results = alternatives |> Task.async_stream(&Store.save(@project, 0, &1, :operator, pid), max_concurrency: 2) |> Enum.map(fn {:ok, result} -> result end)
    assert Enum.count(results, &match?({:ok, %{"storage_revision" => 1}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_design_revision})) == 1
    assert {:ok, saved} = Store.read(@project, :operator, pid)
    assert saved["draft"] in alternatives
    assert Jason.decode!(File.read!(journal(c)))["draft"] == saved["draft"]
    assert {:ok, ^saved} = Store.save(@project, 1, saved["draft"], :operator, pid)
    assert {:error, :stale_design_revision} = Store.save(@project, "1", saved["draft"], :operator, pid)
  end

  test "review freezes an immutable content reference while later drafts and reviews remain editable", c do
    pid = start_supervised!({Store, c.opts})
    assert {:error, :design_not_saved} = Store.review(@project, 0, :operator, pid)
    assert {:ok, %{"storage_revision" => 1}} = Store.save(@project, 0, c.scene, :operator, pid)
    assert {:ok, %{"storage_revision" => 2, "reviewed" => baseline, "review_count" => 1}} = Store.review(@project, 1, :operator, pid)
    assert {:ok, frozen} = Store.reviewed(@project, baseline["ref"], :operator, pid)
    assert frozen["scene"] == c.scene
    assert frozen["document_id"] == c.scene["document_id"]
    assert {:ok, %{"storage_revision" => 2}} = Store.review(@project, 2, :operator, pid)
    assert {:error, :stale_design_revision} = Store.review(@project, 1, :operator, pid)
    changed = c.scene |> Map.put("revision", 1) |> put_in(["boards", "brief", "elements", Access.at(0), "text"], "An additional requirement")
    assert {:ok, %{"storage_revision" => 3, "reviewed" => ^baseline}} = Store.save(@project, 2, changed, :operator, pid)
    assert {:ok, ^frozen} = Store.reviewed(@project, baseline["ref"], :operator, pid)
    assert {:ok, %{"storage_revision" => 4, "reviewed" => next, "review_count" => 2}} = Store.review(@project, 3, :operator, pid)
    refute next["ref"] == baseline["ref"]
    assert {:error, :design_review_not_found} = Store.reviewed(@project, "unknown", :operator, pid)
    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:ok, ^frozen} = Store.reviewed(@project, baseline["ref"], :operator, restarted)
    assert {:ok, %{"scene" => ^changed}} = Store.reviewed(@project, next["ref"], :operator, restarted)
  end

  test "camera and native editing counters do not create new reviewed content", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    {:ok, first} = Store.review(@project, 1, :operator, pid)

    changed =
      c.scene
      |> Map.put("revision", 45)
      |> put_in(["boards", "brief", "appState"], %{"scrollX" => 56, "scrollY" => -78, "zoom" => %{"value" => 0.8}})
      |> update_in(["boards", "brief", "elements", Access.at(0)], &Map.merge(&1, %{"version" => 90, "versionNonce" => 34, "updated" => 78, "index" => "a1"}))

    assert Persistence.content_ref(changed) == first["reviewed"]["ref"]
    {:ok, _} = Store.save(@project, 2, changed, :operator, pid)
    assert {:ok, %{"storage_revision" => 3, "review_count" => 1, "reviewed" => reviewed}} = Store.review(@project, 3, :operator, pid)
    assert reviewed == first["reviewed"]
    assert {:ok, %{"scene" => original}} = Store.reviewed(@project, reviewed["ref"], :operator, pid)
    assert original == c.scene
    styled = put_in(changed, ["boards", "brief", "elements", Access.at(0), "strokeColor"], "#f00")
    refute Persistence.content_ref(styled) == reviewed["ref"]
  end

  test "source captures one immutable review and its current draft in the same owner operation", c do
    pid = start_supervised!({Store, c.opts})
    assert {:error, :design_review_not_found} = Store.source(@project, "unknown", :operator, pid)
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    {:ok, reviewed} = Store.review(@project, 1, :operator, pid)
    ref = reviewed["reviewed"]["ref"]
    assert {:ok, %{"storage_revision" => 2, "draft" => original, "reviewed" => frozen}} = Store.source(@project, ref, :operator, pid)
    assert original == c.scene and frozen["scene"] == c.scene
    changed = altered(c.scene, "text", "A later draft")
    requests = [fn -> Store.source(@project, ref, :operator, pid) end, fn -> Store.save(@project, 2, changed, :operator, pid) end]
    [{:ok, {:ok, captured}}, {:ok, {:ok, _}}] = Enum.to_list(Task.async_stream(requests, & &1.(), ordered: true))
    assert captured["reviewed"] == frozen
    assert {captured["storage_revision"], captured["draft"]} in [{2, c.scene}, {3, changed}]
    assert {:ok, %{"storage_revision" => 3, "draft" => ^changed, "reviewed" => ^frozen}} = Store.source(@project, ref, :operator, pid)
    Agent.update(c.auth, fn _ -> false end)
    assert {:error, :unauthorized} = Store.source(@project, ref, :operator, pid)
  end

  test "backend admission follows the editor camera, text and semantic-tag contract", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, saved} = Store.save(@project, 0, c.scene, :operator, pid)
    bytes = File.read!(journal(c))

    invalid = [
      put_in(c.scene, ["boards", "brief", "appState"], %{}),
      altered(c.scene, "font", ""),
      altered(c.scene, "font", "abc"),
      altered(c.scene, "fontSize", 0),
      altered(c.scene, "lineHeight", 0),
      altered(c.scene, "strokeWidth", 9_007_199_254_740_992),
      altered(c.scene, "originalText", String.duplicate("😀", 6_001)),
      altered(c.scene, "customData", false),
      altered(c.scene, "customData", %{"symphony" => nil}),
      altered(c.scene, "customData", %{"symphony" => %{"id" => "Invalid:id", "role" => "body"}}),
      altered(c.scene, "customData", %{"symphony" => %{"id" => "Node1", "role" => "unknown"}}),
      altered(c.scene, "customData", %{"symphony" => %{"id" => "Node1", "role" => "node", "kind" => "note"}}),
      altered(c.scene, "customData", %{"symphony" => %{"id" => "Node1", "role" => "node", "kind" => "unknown"}}),
      altered(c.scene, "customData", %{"symphony" => %{"id" => "note-functional", "role" => "node", "kind" => "note", "field" => "functional"}}),
      altered(c.scene, "points", %{}),
      altered(c.scene, "pressures", [2]),
      altered(c.scene, "fixedSegments", [%{"index" => 0}])
    ]

    for candidate <- invalid do
      assert {:error, :invalid_design_scene} = Store.save(@project, 1, candidate, :operator, pid)
      assert File.read!(journal(c)) == bytes
    end

    assert {:ok, ^saved} = Store.read(@project, :operator, pid)
    text = hd(c.scene["boards"]["brief"]["elements"])
    tagged = Map.put(text, "customData", %{"symphony" => %{"id" => "Node1", "role" => "body"}})
    duplicate = put_in(c.scene, ["boards", "brief", "elements"], [tagged, Map.put(tagged, "id", "text2")])
    assert {:error, :invalid_design_scene} = Store.save(@project, 1, duplicate, :operator, pid)
    legitimate = tagged |> Map.put("font", " 20px Arial") |> Map.put("originalText", String.duplicate("😀", 6_000))
    valid = put_in(c.scene, ["boards", "brief", "elements"], [legitimate, Map.put(tagged, "id", "text2") |> Map.put("isDeleted", true)])
    assert {:ok, _} = Store.save(@project, 1, valid, :operator, pid)
  end

  test "more than twenty small reviews remain available without history pruning", c do
    pid = start_supervised!({Store, c.opts})

    refs =
      Enum.reduce(1..22, [], fn i, refs ->
        scene = put_in(c.scene, ["boards", "brief", "elements", Access.at(0), "text"], "Iteration #{i}")
        {:ok, _} = Store.save(@project, (i - 1) * 2, scene, :operator, pid)
        {:ok, result} = Store.review(@project, i * 2 - 1, :operator, pid)
        assert result["review_count"] == i
        [result["reviewed"]["ref"] | refs]
      end)

    for ref <- refs, do: assert({:ok, %{"ref" => ^ref}} = Store.reviewed(@project, ref, :operator, pid))
  end

  test "project and document identity mismatches cannot overwrite the saved draft", c do
    pid = start_supervised!({Store, c.opts})
    assert {:error, :design_project_mismatch} = Store.read("github:other/project", :operator, pid)
    assert {:error, :invalid_design_scene} = Store.save(@project, 0, Map.put(c.scene, "project", "other"), :operator, pid)
    {:ok, before} = Store.save(@project, 0, c.scene, :operator, pid)
    bytes = File.read!(journal(c))
    assert {:error, :design_document_mismatch} = Store.save(@project, 1, Map.put(c.scene, "document_id", "DifferentDocument"), :operator, pid)
    assert {:ok, ^before} = Store.read(@project, :operator, pid)
    assert File.read!(journal(c)) == bytes
  end

  test "authorization is fresh for all read and mutation operations", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    {:ok, saved} = Store.review(@project, 1, :operator, pid)
    bytes = File.read!(journal(c))
    Agent.update(c.auth, fn _ -> false end)
    assert {:error, :unauthorized} = Store.read(@project, :operator, pid)
    assert {:error, :unauthorized} = Store.save(@project, 2, c.scene, :operator, pid)
    assert {:error, :unauthorized} = Store.review(@project, 2, :operator, pid)
    assert {:error, :unauthorized} = Store.reviewed(@project, saved["reviewed"]["ref"], :operator, pid)
    assert File.read!(journal(c)) == bytes
    Agent.update(c.auth, fn _ -> true end)
    assert {:ok, ^saved} = Store.read(@project, :operator, pid)
  end

  test "configuration scope changes fence old owners permanently and preserve the journal", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    bytes = File.read!(journal(c))
    Agent.update(c.scope, fn _ -> "tracker-b" end)
    assert {:error, :design_scope_changed} = Store.read(@project, :operator, pid)
    Agent.update(c.scope, fn _ -> "tracker-a" end)
    assert {:error, :design_scope_changed} = Store.save(@project, 1, c.scene, :operator, pid)
    :ok = stop_supervised(Store)
    Agent.update(c.scope, fn _ -> "tracker-b" end)
    restarted = start_owner(c.opts)
    assert Process.alive?(restarted)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, restarted)
    assert File.read!(journal(c)) == bytes
  end

  test "another owner is rejected and lock release after process death permits recovery", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    other = start_owner(c.opts)
    assert {:error, :design_storage_locked} = Store.read(@project, :operator, other)
    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:ok, %{"storage_revision" => 1}} = Store.read(@project, :operator, restarted)
    assert {:error, :design_storage_locked} = Store.read(@project, :operator, other)
  end

  test "losing the OS lock fails closed without writing", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    bytes = File.read!(journal(c))
    state = :sys.get_state(pid)
    true = Port.close(state.owner.lock)
    assert {:error, :design_storage_unavailable} = Store.save(@project, 1, c.scene, :operator, pid)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, pid)
    assert File.read!(journal(c)) == bytes
  end

  test "external journal changes cannot be silently overwritten", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    foreign = File.read!(journal(c)) <> " "
    File.write!(journal(c), foreign)
    assert {:error, :design_storage_unavailable} = Store.save(@project, 1, c.scene, :operator, pid)
    assert File.read!(journal(c)) == foreign
  end

  test "replacing the lock path invalidates the retained owner before another write", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    bytes = File.read!(journal(c))
    lock = Path.join(c.root, ".owner.lock")
    File.rename!(lock, lock <> ".retained")
    File.write!(lock, "replacement")
    File.chmod!(lock, 0o600)
    assert {:error, :design_storage_unavailable} = Store.save(@project, 1, c.scene, :operator, pid)
    assert File.read!(journal(c)) == bytes
    assert File.read!(lock) == "replacement"
  end

  test "tampered review content is rejected on restart without replacing the evidence", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    {:ok, result} = Store.review(@project, 1, :operator, pid)
    :ok = stop_supervised(Store)
    record = Jason.decode!(File.read!(journal(c)))
    ref = result["reviewed"]["ref"]
    altered = put_in(record, ["reviews", ref, "scene", "boards", "brief", "elements", Access.at(0), "text"], "Unreviewed substitution")
    bytes = Jason.encode!(altered)
    File.write!(journal(c), bytes)
    restarted = start_owner(c.opts)
    assert {:error, :design_storage_unavailable} = Store.reviewed(@project, ref, :operator, restarted)
    assert File.read!(journal(c)) == bytes
  end

  test "symlinked roots and lock files are not followed or modified", c do
    retained = c.root <> "-original"
    File.mkdir_p!(retained)
    File.chmod!(retained, 0o700)
    on_exit(fn -> File.rm_rf(retained) end)
    File.ln_s!(retained, c.root)
    linked = start_owner(c.opts)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, linked)
    assert File.ls!(retained) == []
    File.rm!(c.root)
    File.mkdir_p!(c.root)
    File.chmod!(c.root, 0o700)
    target = Path.join(c.root, "retained-lock")
    File.write!(target, "retained lock content")
    File.ln_s!(target, Path.join(c.root, ".owner.lock"))
    locked = start_owner(c.opts)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, locked)
    assert File.read!(target) == "retained lock content"
    refute File.exists?(journal(c))
  end

  test "unavailable or disabled storage does not prevent the owner process starting", c do
    File.write!(c.root, "retained original")
    pid = start_supervised!({Store, c.opts})
    assert Process.alive?(pid)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, pid)
    assert File.read!(c.root) == "retained original"
    disabled_root = c.root <> "-disabled"
    disabled = start_owner(Keyword.merge(c.opts, state_dir: disabled_root, enabled: false))
    assert {:error, :design_storage_unavailable} = Store.save(@project, 0, c.scene, :operator, disabled)
    refute File.exists?(disabled_root)
  end

  test "corrupt, symlinked, public and oversized journals are preserved on startup", c do
    File.mkdir_p!(c.root)
    File.chmod!(c.root, 0o700)
    File.write!(journal(c), "{corrupt")
    File.chmod!(journal(c), 0o600)
    corrupted = start_owner(c.opts)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, corrupted)
    assert File.read!(journal(c)) == "{corrupt"
    File.rm!(journal(c))
    target = Path.join(c.root, "original")
    File.write!(target, "retained")
    File.ln_s!(target, journal(c))
    linked = start_owner(c.opts)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, linked)
    assert File.read!(target) == "retained"
    File.rm!(journal(c))
    File.write!(journal(c), "public original")
    File.chmod!(journal(c), 0o644)
    public = start_owner(c.opts)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, public)
    assert band(File.stat!(journal(c)).mode, 0o777) == 0o644
    File.chmod!(journal(c), 0o600)
    File.write!(journal(c), String.duplicate("x", 32_000_001))
    oversized = start_owner(c.opts)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, oversized)
    assert File.stat!(journal(c)).size == 32_000_001
  end

  test "bounded native scenes reject restore hazards and dangling bindings without replacing saved content", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, saved} = Store.save(@project, 0, c.scene, :operator, pid)
    bytes = File.read!(journal(c))
    element = hd(c.scene["boards"]["brief"]["elements"])

    invalid = [
      Map.put(c.scene, "version", 3),
      Map.delete(c.scene, "document_id"),
      Map.put(c.scene, "extra", "authority"),
      put_in(c.scene, ["boards", "brief", "appState", "zoom"], %{"value" => 0}),
      put_in(c.scene, ["boards", "brief", "elements"], List.duplicate(element, 501)),
      put_in(c.scene, ["boards", "brief", "elements"], [element, element]),
      altered(c.scene, "type", "image"),
      altered(c.scene, "type", "embeddable"),
      altered(c.scene, "type", "iframe"),
      altered(c.scene, "link", %{"unexpected" => true}),
      altered(c.scene, "font", %{}),
      altered(c.scene, "containerId", "absent"),
      altered(c.scene, "startBinding", %{"elementId" => "absent"}),
      altered(c.scene, "boundElements", [%{"id" => "absent", "type" => "text"}]),
      altered(c.scene, "type", "arrow"),
      altered(c.scene, "originalText", String.duplicate("x", 12_001)),
      altered(c.scene, "customData", %{"large" => String.duplicate("x", 4_000_001)})
    ]

    for scene <- invalid do
      assert {:error, :invalid_design_scene} = Store.save(@project, 1, scene, :operator, pid)
      assert File.read!(journal(c)) == bytes
    end

    assert {:ok, ^saved} = Store.read(@project, :operator, pid)
  end

  test "native bindings, tombstones, strokes and opaque styles survive review exactly", c do
    box = %{
      "id" => "box",
      "type" => "rectangle",
      "x" => 0,
      "y" => 0,
      "width" => 250,
      "height" => 200,
      "angle" => 0,
      "isDeleted" => true,
      "boundElements" => [%{"id" => "text", "type" => "text"}, %{"id" => "arrow", "type" => "arrow"}],
      "customData" => %{"symphony" => %{"id" => "note-brief", "role" => "node", "kind" => "note", "field" => "brief"}, "user" => "retained"}
    }

    text = hd(c.scene["boards"]["brief"]["elements"]) |> Map.put("containerId", "box") |> Map.put("originalText", "Full native text\nwith no truncation")
    arrow = Map.merge(box, %{"id" => "arrow", "type" => "arrow", "points" => [[0, 0], [20, 20]], "startBinding" => %{"elementId" => "box", "gap" => 4}, "boundElements" => [], "customData" => nil})
    stroke = Map.merge(box, %{"id" => "stroke", "type" => "freedraw", "points" => [[0, 0]], "pressures" => [], "simulatePressure" => true, "boundElements" => []})
    scene = put_in(c.scene, ["boards", "brief", "elements"], [box, text, arrow, stroke])
    assert Persistence.valid_scene?(scene, @project)
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, scene, :operator, pid)
    {:ok, result} = Store.review(@project, 1, :operator, pid)
    assert {:ok, %{"scene" => ^scene}} = Store.reviewed(@project, result["reviewed"]["ref"], :operator, pid)
  end

  test "journal capacity failure keeps every reviewed snapshot and current draft available", c do
    pid = start_supervised!({Store, c.opts})
    large = altered(c.scene, "customData", %{"retained" => String.duplicate("x", 3_550_000)})

    result =
      Enum.reduce_while(1..12, nil, fn i, _ ->
        {:ok, before} = Store.read(@project, :operator, pid)
        scene = altered(large, "text", "Revision #{i}")

        case Store.save(@project, before["storage_revision"], scene, :operator, pid) do
          {:ok, draft} ->
            bytes = File.read!(journal(c))

            case Store.review(@project, draft["storage_revision"], :operator, pid) do
              {:ok, _} ->
                {:cont, nil}

              {:error, :design_storage_full} ->
                assert File.read!(journal(c)) == bytes
                assert {:ok, ^draft} = Store.read(@project, :operator, pid)
                assert draft["review_count"] >= 7
                {:halt, draft}
            end

          other ->
            flunk("Unexpected save result #{inspect(other)}")
        end
      end)

    assert is_map(result)
    journal = Jason.decode!(File.read!(journal(c)))
    for ref <- Map.keys(journal["reviews"]), do: assert({:ok, %{"ref" => ^ref}} = Store.reviewed(@project, ref, :operator, pid))
    assert File.stat!(journal(c)).size <= 32_000_000
  end

  test "default owner starts once and missing services return a bounded unavailable response" do
    assert {:error, {:already_started, pid}} = Store.start_link()
    assert Process.alive?(pid)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, :missing_design_owner)
  end

  test "provider exit is observed by the real owner before any further mutation", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    before = File.read!(journal(c))
    true = Port.command(:sys.get_state(pid).owner.lock, "x")
    await_fault(pid)
    assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, pid)
    assert File.read!(journal(c)) == before
  end

  test "scope and authorization callback faults fail closed without losing the draft", c do
    for callback <- [fn -> raise "authorization unavailable" end, fn -> throw(:authorization_unavailable) end] do
      pid = start_owner(Keyword.put(c.opts, :authorize, fn _ -> callback.() end))
      assert {:error, :unauthorized} = Store.read(@project, :operator, pid)
    end

    for callback <- [fn -> raise "scope unavailable" end, fn -> throw(:scope_unavailable) end] do
      pid = start_owner(Keyword.put(c.opts, :scope, callback))
      assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, pid)
    end

    refute File.exists?(journal(c))
  end

  test "a write failure preserves durable data and latches the owner unavailable", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
    bytes = File.read!(journal(c))
    File.chmod!(c.root, 0o500)

    try do
      assert {:error, :design_storage_unavailable} = Store.save(@project, 1, altered(c.scene, "text", "Unsaved"), :operator, pid)
      assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, pid)
      assert File.read!(journal(c)) == bytes
    after
      File.chmod!(c.root, 0o700)
    end

    :ok = stop_supervised(Store)
    restarted = start_owner(c.opts)
    assert {:ok, %{"draft" => draft, "storage_revision" => 1}} = Store.read(@project, :operator, restarted)
    assert draft == c.scene
  end

  test "storage refuses invalid roots and failed serialization without replacing a journal", c do
    on_exit(fn -> File.rm_rf(c.root <> "-invalid") end)

    for root <- [nil, "relative/design", c.root <> "/../redirect", c.root <> "-invalid/" <> <<255>>] do
      assert {:error, :design_storage_unavailable} = Persistence.open(root, @project, "scope")
    end

    assert {:ok, owner, initial} = Persistence.open(c.root, @project, "scope")
    assert {:ok, owner} = Persistence.put(owner, initial)
    bytes = File.read!(journal(c))
    assert {:error, :design_storage_unavailable} = Persistence.put(owner, %{"invalid" => <<255>>})
    assert File.read!(journal(c)) == bytes
    Persistence.close(owner)
  end

  test "missing and failed lock runtimes leave no usable owner", c do
    with_path("/definitely-no-executables", fn ->
      assert {:error, :design_storage_unavailable} = Persistence.open(c.root, @project, "scope")
    end)

    bin = fake_runtime(c, "#!/definitely/no/interpreter\n")

    with_path(bin, fn ->
      assert {:error, :design_storage_unavailable} = Persistence.open(c.root, @project, "scope")
    end)

    assert {:ok, owner, _} = Persistence.open(c.root, @project, "scope")
    Persistence.close(owner)
  end

  test "a stalled readiness handshake times out and releases its process", c do
    bin = fake_runtime(c, "#!/bin/sh\nwhile read line; do :; done\n")
    started = System.monotonic_time(:millisecond)

    with_path(bin, fn ->
      assert {:error, :design_storage_unavailable} = Persistence.open(c.root, @project, "scope")
    end)

    assert System.monotonic_time(:millisecond) - started < 10_000
    assert {:ok, owner, _} = Persistence.open(c.root, @project, "scope")
    Persistence.close(owner)
  end

  test "a readiness message without a private lock file is rejected", c do
    bin = fake_runtime(c, "#!/bin/sh\nprintf 'READY\\n'\nwhile read line; do :; done\n")

    with_path(bin, fn ->
      assert {:error, :design_storage_unavailable} = Persistence.open(c.root, @project, "scope")
    end)

    refute File.exists?(journal(c))
  end

  test "malformed journal and review metadata stay retained and unavailable", c do
    pid = start_supervised!({Store, c.opts})
    {:ok, _} = Store.save(@project, 0, c.scene, :operator, pid)
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
      assert {:error, :design_storage_unavailable} = Store.read(@project, :operator, restarted)
      assert File.read!(journal(c)) == bytes
    end
  end

  test "native styles, nullable retained bindings and valid semantic connectors round trip", c do
    node = %{
      "id" => "node",
      "type" => "rectangle",
      "x" => 0,
      "y" => 0,
      "width" => 80,
      "height" => 60,
      "angle" => 0,
      "groupIds" => ["group"],
      "roundness" => %{"type" => 3, "value" => 4},
      "customData" => %{"symphony" => %{"id" => "note-brief", "role" => "node", "kind" => "note", "field" => "brief"}},
      "boundElementIds" => ["arrow"],
      "boundElements" => nil
    }

    edge =
      Map.merge(node, %{
        "id" => "arrow",
        "type" => "arrow",
        "points" => [],
        "startBinding" => nil,
        "endBinding" => nil,
        "roundness" => nil,
        "boundElements" => nil,
        "boundElementIds" => nil,
        "fixedSegments" => nil,
        "customData" => %{"symphony" => %{"id" => "Edge1", "role" => "edge"}}
      })

    full = put_in(c.scene, ["boards", "brief", "elements"], [node, edge])
    pid = start_supervised!({Store, c.opts})
    assert {:ok, saved} = Store.save(@project, 0, full, :operator, pid)
    assert saved["draft"] == full
    invalid = [put_in(c.scene, ["boards", "brief", "elements"], [nil]), altered(c.scene, "fixedSegments", "bad"), altered(c.scene, "groupIds", [false])]
    nested = Enum.reduce(1..35, "leaf", fn _, child -> %{"nested" => child} end)
    for scene <- [altered(c.scene, "customData", nested) | invalid], do: assert({:error, :invalid_design_scene} = Store.save(@project, 1, scene, :operator, pid))
  end

  defp await_fault(pid, attempts \\ 100) do
    if is_nil(:sys.get_state(pid).fault) and attempts > 0 do
      Process.sleep(5)
      await_fault(pid, attempts - 1)
    else
      assert :sys.get_state(pid).fault == :design_storage_unavailable
    end
  end

  defp fake_runtime(c, source) do
    bin = Path.join(c.root, "lock-runtime")
    File.mkdir_p!(bin)
    File.chmod!(c.root, 0o700)
    File.write!(Path.join(bin, "python3"), source)
    File.chmod!(Path.join(bin, "python3"), 0o700)
    bin
  end

  defp with_path(path, callback) do
    previous = System.get_env("PATH")
    System.put_env("PATH", path)

    try do
      callback.()
    after
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
    end
  end

  defp start_owner(opts) do
    start_supervised!(%{id: make_ref(), start: {Store, :start_link, [opts]}})
  end

  defp journal(c), do: Path.join(c.root, "journal.json")
  defp altered(scene, key, value), do: put_in(scene, ["boards", "brief", "elements", Access.at(0), key], value)

  defp scene do
    boards = Map.new(~w(brief requirements data architecture decisions), &{&1, %{"elements" => [], "appState" => %{"scrollX" => 0, "scrollY" => 0, "zoom" => %{"value" => 1}}}})

    %{"version" => 2, "project" => @project, "document_id" => "Document1", "revision" => 0, "boards" => boards}
    |> put_in(["boards", "brief", "elements"], [
      %{"id" => "text", "type" => "text", "x" => 15, "y" => 20, "width" => 200, "height" => 80, "angle" => 0, "text" => "Problem and scope", "originalText" => "Problem and scope"}
    ])
  end
end
