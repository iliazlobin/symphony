defmodule SymphonyElixirWeb.AssuranceWorkspaceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Assurance.Store
  alias SymphonyElixirWeb.{AssuranceWorkspace, BrowserAuth, TaskBoard}

  @project "github:example/workspace"
  @task @project <> ":1"

  setup do
    token = String.duplicate("workspace-test-operator", 3)
    original_token = System.get_env("SYMPHONY_CONTROL_TOKEN")
    System.put_env("SYMPHONY_CONTROL_TOKEN", token)

    configuration = %{
      tracker: %{
        kind: "github",
        provider: %{repo: "example/workspace", token: "test-token"},
        active_states: ["open"],
        terminal_states: ["closed"],
        required_labels: ["ready"]
      },
      control: %{enabled: false},
      observability: %{dashboard_enabled: false}
    }

    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(configuration) <> "\n---\nFixture")
    assert :ok = WorkflowStore.force_reload()
    {:ok, marker} = BrowserAuth.authenticate(Plug.Test.conn(:get, "http://localhost/"), token)
    auth = %{marker: marker, host: "localhost", peer_ip: {127, 0, 0, 1}, tracker_fingerprint: Orchestrator.tracker_fingerprint()}
    assert BrowserAuth.authorized?(auth)
    path = Path.join(System.tmp_dir!(), "assurance-workspace-#{System.unique_integer([:positive])}")
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(path)
    scope = fn -> Orchestrator.tracker_fingerprint() end
    store = start_supervised!({Store, name: nil, state_dir: root, project: @project, scope: scope})

    issue = %Issue{
      id: "1",
      identifier: "GH-1",
      title: "Exact subject",
      state: "open",
      description: "Depends on: none",
      labels: ["kind:feature"],
      dispatchable: true,
      native_ref: %{"repo" => "example/workspace"}
    }

    board = TaskBoard.project([issue], %{}, %{}, Config.settings!())

    on_exit(fn ->
      restore_env("SYMPHONY_CONTROL_TOKEN", original_token)
      File.rm_rf(root)
    end)

    context = %{project: @project, auth: auth, server: store, board: board, loading: false, read_only: false}
    %{context: context, board: board, auth: auth, store: store, root: root}
  end

  test "loads store records and refreshes observed badges without granting task or deployment authority", ctx do
    assert {:ok, empty, projection, board} = AssuranceWorkspace.load(ctx.board, @project, ctx.auth, %{}, true, ctx.store)
    assert empty["storage_revision"] == 0 and empty["draft"] == nil
    assert projection["tasks"][@task]["status"] == "unlinked"
    assert projection["execution_authority"] == false and projection["deployment_authority"] == false
    assert board.assurance == projection and board.assurance_evidence == [] and board.assurance_baselines == []
    assert [%{"id" => @task, "subject" => nil}] = board.assurance_observations["tasks"]

    saved = reviewed_plan(ctx.context)
    assert {:ok, ^saved, current, enriched} = AssuranceWorkspace.load(ctx.board, @project, ctx.auth, empty, true, ctx.store)
    assert current["counts"]["missing_subject"] == 1
    assert enriched.assurance_baselines == saved["baselines"]
    captured_nodes = hd(enriched.assurance_baselines)["graph_snapshot"]["graph"]["nodes"]
    assert Enum.filter(captured_nodes, &(&1["type"] == "task")) |> Enum.map(& &1["task_id"]) == [@task]
    assert {:ok, ^saved, ^current, _} = AssuranceWorkspace.load(ctx.board, @project, ctx.auth, saved, false, :missing_workspace_store)
    assert {:error, :assurance_storage_unavailable} = AssuranceWorkspace.load(ctx.board, @project, ctx.auth, saved, true, :missing_workspace_store)
    assert {:error, :unauthorized} = AssuranceWorkspace.load(ctx.board, @project, %{}, saved, true, ctx.store)
  end

  test "authentication, read-only history and malformed project or revision prevent every mutation", ctx do
    before = File.read(Path.join(ctx.root, "journal.json"))
    params = %{"storage_revision" => "0", "title" => "Bounded outcome"}

    for context <- [%{ctx.context | auth: %{}}, %{ctx.context | read_only: true}] do
      assert {:error, :unauthorized} = AssuranceWorkspace.mutate(context, "save-requirement", params)
    end

    assert {:error, :assurance_project_mismatch} = AssuranceWorkspace.mutate(%{ctx.context | project: nil}, "save-requirement", params)
    assert {:error, :invalid_assurance_revision} = AssuranceWorkspace.mutate(ctx.context, "save-requirement", Map.delete(params, "storage_revision"))
    assert {:error, :assurance_storage_unavailable} = AssuranceWorkspace.mutate(%{ctx.context | server: :missing_workspace_store}, "save-requirement", params)
    assert {:error, :invalid_assurance_action} = AssuranceWorkspace.mutate(ctx.context, "unknown-action", params)
    assert File.read(Path.join(ctx.root, "journal.json")) == before
    assert {:ok, saved} = AssuranceWorkspace.mutate(ctx.context, "save-requirement", params)
    bytes = File.read!(Path.join(ctx.root, "journal.json"))
    assert saved["storage_revision"] == 1
    assert {:error, :stale_assurance_revision} = AssuranceWorkspace.mutate(ctx.context, "save-requirement", Map.put(params, "title", "Stale replacement"))
    assert File.read!(Path.join(ctx.root, "journal.json")) == bytes
    System.put_env("SYMPHONY_CONTROL_TOKEN", String.duplicate("rotated-operator", 3))
    assert {:error, :unauthorized} = AssuranceWorkspace.mutate(ctx.context, "save-requirement", %{"storage_revision" => "1", "title" => "Rotated session"})
    assert File.read!(Path.join(ctx.root, "journal.json")) == bytes
  end

  test "baseline review cannot write while its graph or source is unavailable or still loading", ctx do
    before = File.read(Path.join(ctx.root, "journal.json"))

    for context <- [
          %{ctx.context | loading: true},
          %{ctx.context | board: %{ctx.board | source_error: "tracker unavailable"}},
          %{ctx.context | board: %{ctx.board | runtime_error: "native controls unavailable"}}
        ] do
      assert {:error, :assurance_graph_unavailable} = AssuranceWorkspace.mutate(context, "save-baseline", %{"storage_revision" => "0"})
      assert File.read(Path.join(ctx.root, "journal.json")) == before
    end

    assert {:error, :assurance_not_saved} = AssuranceWorkspace.mutate(ctx.context, "save-baseline", %{"storage_revision" => "0"})
    assert File.read(Path.join(ctx.root, "journal.json")) == before
  end

  test "a recorded release candidate remains blocked without integrated artifact and runtime receipts", ctx do
    saved = reviewed_plan(ctx.context)
    baseline = saved["reviewed"]["ref"]

    params = %{
      "storage_revision" => to_string(saved["storage_revision"]),
      "release_id" => "candidate-1",
      "baseline_ref" => baseline,
      "task_ids" => @task,
      "integrated_sha" => String.duplicate("a", 40),
      "artifact_digest" => "sha256:" <> String.duplicate("b", 64),
      "target" => "staging",
      "configuration_ref" => "config-1",
      "required_checks" => "ci:unit",
      "required_gates" => "security"
    }

    bytes = File.read!(Path.join(ctx.root, "journal.json"))
    assert {:error, :invalid_assurance_release} = AssuranceWorkspace.mutate(ctx.context, "record-release", Map.put(params, "integrated_sha", "main"))
    assert {:error, :unknown_assurance_evidence} = AssuranceWorkspace.mutate(ctx.context, "record-release", Map.put(params, "evidence_ids", "operator-claim"))
    assert File.read!(Path.join(ctx.root, "journal.json")) == bytes
    assert {:ok, candidate} = AssuranceWorkspace.mutate(ctx.context, "record-release", params)
    assert length(candidate["releases"]) == 1
    assert {:ok, _, projection, _} = AssuranceWorkspace.load(ctx.board, @project, ctx.auth, %{}, true, ctx.store)
    assert [readiness] = projection["release_readiness"]
    refute readiness["ready"] or readiness["build_ready"] or readiness["runtime_verified"] or readiness["deployment_recorded"]
    assert "missing_integrated_checks" in readiness["issues"]
    assert "missing_artifact_receipt" in readiness["issues"]
    assert "missing_deployment_receipt" in readiness["issues"]
    assert "missing_runtime_receipt" in readiness["issues"]
  end

  test "stale missing and future source times cannot review a saved plan or change its immutable history", ctx do
    saved = reviewed_plan(ctx.context)
    before = File.read!(Path.join(ctx.root, "journal.json"))
    params = %{"storage_revision" => to_string(saved["storage_revision"])}

    for timestamp <- [DateTime.utc_now() |> DateTime.add(-121) |> DateTime.to_iso8601(), nil, "invalid", "2099-01-01T00:00:00Z"] do
      context = %{ctx.context | board: %{ctx.board | generated_at: timestamp}}
      assert {:error, :assurance_graph_unavailable} = AssuranceWorkspace.mutate(context, "save-baseline", params)
      assert File.read!(Path.join(ctx.root, "journal.json")) == before
      assert {:ok, ^saved} = Store.read(@project, ctx.auth, ctx.store)
      assert {:ok, _, _, historical} = AssuranceWorkspace.load(context.board, @project, ctx.auth, saved, false, ctx.store)
      assert historical.assurance_baselines == saved["baselines"]
    end

    missing_time = %{ctx.context | board: Map.delete(ctx.board, :generated_at)}
    assert {:error, :assurance_graph_unavailable} = AssuranceWorkspace.mutate(missing_time, "save-baseline", params)
    assert File.read!(Path.join(ctx.root, "journal.json")) == before
    assert {:ok, ^saved} = AssuranceWorkspace.mutate(ctx.context, "save-baseline", params)
  end

  test "UI baseline review requires an explicit valid graph and preserves existing graph history", ctx do
    saved = reviewed_plan(ctx.context)
    before = File.read!(Path.join(ctx.root, "journal.json"))
    params = %{"storage_revision" => to_string(saved["storage_revision"])}

    for invalid <- [nil, [], "last-known graph", false] do
      context = %{ctx.context | board: %{ctx.board | workflow_graph: invalid}}
      assert {:error, :assurance_graph_unavailable} = AssuranceWorkspace.mutate(context, "save-baseline", params)
      assert File.read!(Path.join(ctx.root, "journal.json")) == before
      assert {:ok, ^saved} = Store.read(@project, ctx.auth, ctx.store)
    end

    missing = %{ctx.context | board: Map.delete(ctx.board, :workflow_graph)}
    assert {:error, :assurance_graph_unavailable} = AssuranceWorkspace.mutate(missing, "save-baseline", params)
    malformed = %{ctx.context | board: %{ctx.board | workflow_graph: %{}}}
    assert {:error, :invalid_assurance_graph} = AssuranceWorkspace.mutate(malformed, "save-baseline", params)
    assert File.read!(Path.join(ctx.root, "journal.json")) == before
    assert {:ok, ^saved} = AssuranceWorkspace.mutate(ctx.context, "save-baseline", params)
    assert is_map(saved["reviewed"]["graph_snapshot"])
  end

  defp reviewed_plan(context) do
    assert {:ok, requirement} = AssuranceWorkspace.mutate(context, "save-requirement", %{"storage_revision" => "0", "title" => "Reject expired tokens"})
    id = hd(requirement["draft"]["requirements"])["id"]

    assert {:ok, criterion} =
             AssuranceWorkspace.mutate(context, "save-criterion", %{
               "storage_revision" => "1",
               "requirement_id" => id,
               "text" => "Expired token cannot change the password",
               "required_checks" => "ci:unit"
             })

    criterion_id = hd(hd(criterion["draft"]["requirements"])["criteria"])["id"]
    assert {:ok, _linked} = AssuranceWorkspace.mutate(context, "link-task", %{"storage_revision" => "2", "task_id" => @task, "criterion_id" => criterion_id, "subject" => %{"revision" => "forged"}})
    assert {:ok, reviewed} = AssuranceWorkspace.mutate(context, "save-baseline", %{"storage_revision" => "3"})
    reviewed
  end
end
