defmodule SymphonyElixir.CandidatePipelineEdgeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CandidatePipeline, PathSafety}

  setup do
    {:ok, root} =
      PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony-candidate-edge-#{System.unique_integer([:positive])}"))

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    workspace = Path.join(root, "GH-7")
    File.mkdir_p!(workspace)

    for args <- [
          ["init", "-b", "codex/gh-7"],
          ["config", "user.name", "Fixture"],
          ["config", "user.email", "fixture@example.invalid"]
        ] do
      {_, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    File.write!(Path.join(workspace, "source"), "fixture\n")
    {_, 0} = System.cmd("git", ["add", "source"], cd: workspace)
    {_, 0} = System.cmd("git", ["commit", "-m", "fixture"], cd: workspace)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    sha = String.trim(sha)
    handoff_path = Path.join(workspace, ".symphony/handoff.json")
    File.mkdir_p!(Path.dirname(handoff_path))
    handoff = %{candidate_sha: sha, branch: "codex/gh-7", summary: "Fixture", checks: [], limitations: []}
    File.write!(handoff_path, Jason.encode!(handoff))
    %{root: root, workspace: workspace, sha: sha, handoff: handoff, handoff_path: handoff_path}
  end

  test "check evidence preserves passed, failed and unavailable outcomes", context do
    checks =
      Enum.map(["passed", "failed", "not_run"], fn result ->
        %{name: "fixture #{result}", result: result, details: "Observed outcome"}
      end)

    File.write!(context.handoff_path, Jason.encode!(%{context.handoff | checks: checks, limitations: ["Service checks unavailable"]}))
    assert {:ok, candidate} = CandidatePipeline.read_candidate(context.workspace)
    assert Enum.map(candidate.checks, & &1["result"]) == ["passed", "failed", "not_run"]
    assert candidate.limitations == ["Service checks unavailable"]

    for check <- [
          %{name: "", result: "passed", details: ""},
          %{name: "unit", result: "green", details: ""},
          %{name: "unit", result: "passed", details: nil},
          %{name: "unit", result: "passed"}
        ] do
      File.write!(context.handoff_path, Jason.encode!(%{context.handoff | checks: [check]}))
      assert {:error, :invalid_candidate_handoff} = CandidatePipeline.read_candidate(context.workspace)
    end
  end

  test "malformed and oversized handoffs never become candidate evidence", context do
    for contents <- [
          "null",
          "[]",
          "{",
          Jason.encode!(%{context.handoff | summary: " "}),
          Jason.encode!(%{context.handoff | limitations: [42]}),
          Jason.encode!(%{context.handoff | checks: nil}),
          Jason.encode!(%{context.handoff | candidate_sha: String.upcase(context.sha)}),
          Jason.encode!(%{context.handoff | summary: String.duplicate("x", 65_537)})
        ] do
      File.write!(context.handoff_path, contents)
      assert {:error, _reason} = CandidatePipeline.read_candidate(context.workspace)
    end
  end

  test "review accepts actionable findings but rejects malformed or empty finding evidence", %{sha: sha} do
    finding = %{severity: "high", path: "source", line: nil, description: "Needs correction"}
    review = %{candidate_sha: sha, verdict: "request_changes", summary: "Finding remains", findings: [finding]}
    assert {:ok, _} = review(review, sha)
    assert {:ok, _} = review(%{review | verdict: "blocked"}, sha)

    for invalid <- [
          "free text",
          %{finding | severity: "warning"},
          %{finding | path: nil},
          %{finding | line: 0},
          %{finding | line: -1},
          %{finding | line: "1"},
          %{finding | description: " "}
        ] do
      assert {:error, :invalid_review_result} = review(%{review | findings: [invalid]}, sha)
    end

    assert {:error, :invalid_review_result} = review(%{review | findings: nil}, sha)
    assert {:error, :invalid_review_result} = review(%{review | verdict: "approved"}, sha)
    assert {:error, :invalid_review_result} = review(%{review | summary: ""}, sha)
    assert {:error, :invalid_review_result} = CandidatePipeline.review_result(%{final_messages: ["not JSON"]}, sha)
  end

  test "missing pinned commit stops before the builder is launched", context do
    configure(context.root, "false", String.duplicate("f", 40))
    assert {:error, :approved_baseline_unavailable} = CandidatePipeline.run(context.workspace, issue(), [run_id: "missing-baseline"], fn _ -> flunk("Builder launched") end)
  end

  test "Git and process guardian failures propagate without success evidence", context do
    non_repository = Path.join(context.root, "not-a-repository")
    File.mkdir_p!(non_repository)
    assert {:error, {:candidate_git_failed, _status, _output}} = CandidatePipeline.verify_revision(non_repository, context.sha)
    previous = System.get_env("PATH")

    try do
      System.put_env("PATH", Path.join(context.root, "no-executables"))
      assert {:error, :process_guardian_python_not_found} = CandidatePipeline.verify_revision(context.workspace, context.sha)
    after
      restore_env("PATH", previous)
    end
  end

  test "redirected object stores are rejected before host Git reads them", context do
    objects = Path.join(context.workspace, ".git/objects")
    redirected = Path.join(context.root, "redirected-objects")
    File.rename!(objects, redirected)
    File.ln_s!(redirected, objects)
    assert {:error, {:candidate_git_failed, 78, output}} = CandidatePipeline.read_candidate(context.workspace)
    assert output =~ "Unsafe worker Git metadata"
  end

  test "same-size clean filters cannot execute during host candidate or hook validation", context do
    marker = Path.join(context.root, "filter-executed")
    File.write!(Path.join(context.workspace, ".gitattributes"), "source filter=canary\n")
    {_, 0} = System.cmd("git", ["add", ".gitattributes"], cd: context.workspace)
    {_, 0} = System.cmd("git", ["commit", "-m", "fixture attributes"], cd: context.workspace)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: context.workspace)
    sha = String.trim(sha)
    {_, 0} = System.cmd("git", ["config", "filter.canary.clean", "touch '#{marker}'; cat"], cd: context.workspace)
    File.write!(Path.join(context.workspace, "source"), "changed\n")
    assert byte_size(File.read!(Path.join(context.workspace, "source"))) == byte_size("fixture\n")
    assert {:error, {:candidate_git_failed, 78, _}} = CandidatePipeline.verify_revision(context.workspace, sha)
    refute File.exists?(marker)

    configure(context.root, "false", sha, hook_before_run: "git status --porcelain")
    assert {:error, {:workspace_hook_failed, "before_run", 78, _}} = Workspace.run_before_run_hook(context.workspace, issue())
    refute File.exists?(marker)
  end

  test "config includes are rejected without reading their target or emitting values", context do
    external = Path.join(context.root, "external-config")
    File.write!(external, "this is invalid config with PRIVATE-CANARY\n")
    {_, 0} = System.cmd("git", ["config", "include.path", external], cd: context.workspace)
    assert {:error, {:candidate_git_failed, 78, output}} = CandidatePipeline.verify_revision(context.workspace, context.sha)
    assert output =~ "Unsafe worker Git metadata"
    refute output =~ "PRIVATE-CANARY"
    refute output =~ external
  end

  test "gitlinks are unsupported before candidate validation or host hooks", context do
    {_, 0} = System.cmd("git", ["update-index", "--add", "--cacheinfo", "160000,#{context.sha},child"], cd: context.workspace)
    assert {:error, {:candidate_git_failed, 78, _}} = CandidatePipeline.verify_revision(context.workspace, context.sha)

    configure(context.root, "false", context.sha, hook_before_run: "git status --porcelain")
    assert {:error, {:workspace_hook_failed, "before_run", 78, _}} = Workspace.run_before_run_hook(context.workspace, issue())
  end

  test "untracked nested Git metadata is unsupported", context do
    nested = Path.join(context.workspace, "child/.git")
    File.mkdir_p!(nested)
    assert {:error, {:candidate_git_failed, 78, _}} = CandidatePipeline.verify_revision(context.workspace, context.sha)
    File.rmdir!(nested)
    File.write!(nested, "gitdir: ../../.git\n")
    assert {:error, {:candidate_git_failed, 78, _}} = CandidatePipeline.verify_revision(context.workspace, context.sha)
    File.rm!(nested)
    File.mkdir!(Path.join(context.workspace, "child/.GiT"))
    assert {:error, {:candidate_git_failed, 78, _}} = CandidatePipeline.verify_revision(context.workspace, context.sha)
  end

  test "Git directory files and symlinks cannot redirect host validation", context do
    gitdir = Path.join(context.workspace, ".git")
    retained = Path.join(context.root, "retained-git")
    File.rename!(gitdir, retained)
    File.ln_s!(retained, gitdir)
    assert {:error, {:candidate_git_failed, 78, _}} = CandidatePipeline.verify_revision(context.workspace, context.sha)
    File.rm!(gitdir)
    File.write!(gitdir, "gitdir: #{retained}\n")
    assert {:error, {:candidate_git_failed, 78, _}} = CandidatePipeline.verify_revision(context.workspace, context.sha)
  end

  test "hardlinked metadata and alternate object stores are refused", context do
    config = Path.join(context.workspace, ".git/config")
    link = Path.join(context.root, "linked-config")
    File.ln!(config, link)
    assert {:error, {:candidate_git_failed, 78, _}} = CandidatePipeline.verify_revision(context.workspace, context.sha)
    File.rm!(link)
    alternate = Path.join(context.workspace, ".git/objects/info/alternates")
    File.write!(alternate, Path.join(context.root, "other-objects") <> "\n")
    assert {:error, {:candidate_git_failed, 78, _}} = CandidatePipeline.verify_revision(context.workspace, context.sha)
  end

  defp review(value, sha), do: CandidatePipeline.review_result(%{final_messages: [Jason.encode!(value)]}, sha)

  defp configure(root, command, base_sha, overrides \\ []) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, [workspace_root: root, tracker_kind: "memory", codex_command: command] ++ overrides)
    section = "\ncontrol:\n  enabled: true\n  state_path: #{root}/control.json\n  base_sha: #{base_sha}\n---\n"
    File.write!(path, File.read!(path) |> String.replace("\n---\n", section, global: false))
    WorkflowStore.force_reload()
  end

  defp issue, do: %Issue{id: "7", identifier: "GH-7", title: "Fixture", description: "Preserve behavior", state: "open", labels: []}
end
