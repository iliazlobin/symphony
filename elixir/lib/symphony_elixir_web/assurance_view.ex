defmodule SymphonyElixirWeb.AssuranceView do
  @moduledoc "Compact criteria, reviewed versions and release evidence within the existing board dialog."
  use Phoenix.Component

  alias SymphonyElixir.Assurance.Contract
  alias SymphonyElixirWeb.AssuranceActions

  attr(:snapshot, :map, default: %{})
  attr(:projection, :map, default: %{})
  attr(:board, :map, default: %{})
  attr(:tab, :string, default: "requirements")
  attr(:baseline_ref, :any, default: nil)
  attr(:selected_task_id, :any, default: nil)
  attr(:difference, :map, default: %{})
  attr(:read_only, :boolean, default: false)
  attr(:error, :any, default: nil)
  attr(:gaps_only, :boolean, default: false)
  attr(:page, :integer, default: 0)

  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    assigns = prepare(assigns)

    ~H"""
    <section id="assurance-workspace" class="assurance-workspace" aria-label="Scope and release assurance" data-baseline={@baseline_ref || "draft"}>
      <nav class="assurance-tabs" aria-label="Assurance views">
        <button :for={{key, label} <- [{"requirements", "Requirements"}, {"versions", "Versions"}, {"releases", "Releases"}]} type="button"
          class={["button button-small", @tab == key && "button-primary"]} phx-click="assurance-tab" phx-value-tab={key} aria-current={if @tab == key, do: "page"}>{label}</button>
      </nav>
      <p :if={@error} class="assurance-error" role="alert">{if is_binary(@error), do: @error, else: AssuranceActions.error_message(@error)}</p>
      <p :if={@baseline_ref} class="assurance-notice">Reviewed version <code title={@baseline_ref}>{short(@baseline_ref)}</code> · read-only.
        <button type="button" class="button button-small" phx-click="assurance-select-baseline" phx-value-ref="">Return to draft</button>
      </p>
      <p :if={@selected_task} class="assurance-task-context">Selected task: <button type="button" phx-click="select-task" phx-value-id={@selected_task.id} class="assurance-task-link">{@selected_task[:identifier] || @selected_task.id} · {@selected_task[:title]}</button></p>

      <%= case @tab do %>
        <% "versions" -> %>
          <p class="muted">Reviewed scope versions are immutable. Compare their requirements and links; tasks keep the same IDs.</p>
          <form :if={@editable?} phx-submit="assurance-save-baseline" class="assurance-inline-form">
            <input type="hidden" name="storage_revision" value={@revision} />
            <button class="button button-primary" phx-disable-with="Saving…" disabled={!Contract.reviewable?(@document)}>Save reviewed baseline</button>
            <span class="muted">Review the included criteria and check names before saving.</span>
          </form>
          <p :if={@baselines == []} class="muted">No reviewed baseline yet. Add observable criteria and required checks in Requirements.</p>
          <div :for={baseline <- Enum.slice(@baselines, max(@page, 0) * 40, 40)} class="assurance-version">
            <div><code title={baseline["ref"]}>{short(baseline["ref"])}</code><span class="muted">{baseline["reviewed_at"]}</span></div>
            <div class="assurance-inline-form">
              <button type="button" class="button button-small" phx-click="assurance-select-baseline" phx-value-ref={baseline["ref"]}>Read version</button>
              <button type="button" class="button button-small" phx-click="assurance-compare" phx-value-ref={baseline["ref"]}>Compare to draft</button>
              <button :if={baseline["graph_snapshot"]} type="button" class="button button-small" phx-click="assurance-view-baseline" phx-value-ref={baseline["ref"]}>Show graph</button>
            </div>
          </div>
          <.pages page={@page} count={length(@baselines)} />
          <section :if={@difference != %{}} class="assurance-difference" aria-label="Version changes">
            <h3>Changes compared with draft</h3>
            <p :if={@difference["graph_unavailable"] == true} class="muted">Current graph comparison unavailable; showing draft scope changes.</p>
            <p :if={@changes == []} class="muted">No changes in requirements or links.</p>
            <ul><li :for={change <- Enum.slice(@changes, max(@page, 0) * 40, 40)}><span class="assurance-state">{change.change}</span> {change.kind} <code>{change.id}</code>
              <button :if={change.task_id} type="button" class="assurance-task-link" phx-click="select-task" phx-value-id={change.task_id}>Open task</button>
            </li></ul>
            <.pages page={@page} count={length(@changes)} />
          </section>
        <% "releases" -> %>
          <p class="muted">Release records bind reviewed scope to an integrated commit, immutable artifact and target. Readiness is computed from observed evidence.</p>
          <details :if={@editable? && @current_baseline} class="assurance-editor"><summary>Record a release</summary>
            <form phx-submit="assurance-record-release" class="assurance-form">
              <input type="hidden" name="storage_revision" value={@revision} /><input type="hidden" name="baseline_ref" value={@current_baseline} />
              <label>Release ID<input name="release_id" required maxlength="256" placeholder="release-1" /></label>
              <fieldset class="assurance-receipt-selection"><legend>Included linked tasks</legend><label :for={id <- Enum.uniq(Enum.map(@document["task_links"], & &1["task_id"]))}><input type="checkbox" name="task_ids[]" value={id} checked />{task_label(@board, id)}</label><p :if={@document["task_links"] == []} class="muted">Link tasks to criteria before recording a release.</p></fieldset>
              <label>Integrated commit SHA<input name="integrated_sha" required pattern="[a-f0-9]{40}" maxlength="40" spellcheck="false" /></label>
              <label>Artifact digest<input name="artifact_digest" required pattern="sha256:[a-f0-9]{64}" maxlength="71" placeholder="sha256:…" spellcheck="false" /></label>
              <div class="assurance-fields"><label>Target<input name="target" required maxlength="256" placeholder="staging" /></label><label>Configuration reference<input name="configuration_ref" required maxlength="512" placeholder="Reviewed configuration revision" /></label></div>
              <label>Required artifact checks<textarea name="required_checks" rows="2" required placeholder="One exact check name per line" /></label>
              <label>Required runtime gates<textarea name="required_gates" rows="2" required placeholder="One exact gate name per line" /></label>
              <fieldset :if={@release_receipts != []} class="assurance-receipt-selection"><legend>Current observed receipts</legend><label :for={receipt <- @release_receipts}><input type="checkbox" name="evidence_ids[]" value={receipt["id"]} />{receipt["release_id"]} · {receipt["check"]} · {receipt["result"]}<code>{get_in(receipt, ["subject", "revision"])}</code></label><p class="muted">Select only receipts observed for the release ID above. Readiness still checks their exact subject.</p></fieldset>
              <p class="muted">This immutable record captures a candidate and its selected evidence. Use a new release ID for another candidate. Deployment and runtime verification require observed receipts for this exact subject.</p>
              <button class="button button-primary" phx-disable-with="Saving…">Save release record</button>
            </form>
          </details>
          <p :if={!@current_baseline} class="muted">Save a reviewed baseline before recording a release.</p>
          <p :if={@releases == []} class="muted">No release records yet.</p>
          <article :for={entry <- Enum.slice(@releases, max(@page, 0) * 40, 40)} class="assurance-release">
            <% release = entry["record"] || entry %><% status = release_status(@projection, release["id"]) %>
            <header><h3>{release["id"]}</h3><span class="assurance-state">{release_label(status)}</span></header>
            <dl class="assurance-facts"><div><dt>Scope</dt><dd><code title={release["baseline_ref"]}>{short(release["baseline_ref"])}</code></dd></div><div><dt>Commit</dt><dd><code title={release["integrated_sha"]}>{short(release["integrated_sha"])}</code></dd></div><div><dt>Artifact</dt><dd><code>{release["artifact_digest"]}</code></dd></div><div><dt>Target</dt><dd>{release["target"]} · {release["configuration_ref"]}</dd></div></dl>
            <p class="muted">{release_detail(status)}</p>
            <ul :if={issues(status) != []}><li :for={issue <- issues(status)}>{issue}</li></ul>
            <div class="assurance-inline-form"><button :for={id <- release["task_ids"] || []} type="button" class="assurance-task-link" phx-click="select-task" phx-value-id={id}>{task_label(@board, id)}</button></div>
          </article>
          <.pages page={@page} count={length(@releases)} />
          <.receipts snapshot={@snapshot} board={@board} />
        <% _ -> %>
          <div class="assurance-toolbar"><p class="muted">Each requirement needs observable criteria, linked tasks and current evidence.</p><button type="button" class="button button-small" phx-click="assurance-gaps" phx-value-only={to_string(!@gaps_only)} aria-pressed={to_string(@gaps_only)}>{if @gaps_only, do: "Show all", else: "Show gaps"}</button></div>
          <.dependency_annotations rows={@dependency_rows} baselines={@baselines} board={@board} revision={@revision} editable={@editable?} page={@page} />
          <details :if={@editable?} class="assurance-editor"><summary>Add requirement</summary><.requirement_form revision={@revision} requirement={%{}} /></details>
          <p :if={@rows == []} class="muted">{if @gaps_only && @document["requirements"] != [], do: "No gaps in the selected view. This does not establish release readiness.", else: "No requirements in this view yet."}</p>
          <article :for={row <- Enum.slice(@rows, max(@page, 0) * 40, 40)} class="assurance-requirement" data-requirement-id={row.requirement["id"]}>
            <header><div><h3>{row.requirement["title"]}</h3><span class="muted">{row.requirement["id"]} · {if row.requirement["kind"] == "nonfunctional", do: "Quality", else: "Behavior"}</span></div><span class="assurance-state">{if row.requirement["exclusion"], do: "Excluded", else: if(row.gap?, do: "Needs evidence", else: "Criteria covered")}</span></header>
            <p :if={row.requirement["exclusion"]} class="muted">Exclusion: {row.requirement["exclusion"]}</p>
            <details :if={@editable?} class="assurance-editor"><summary>Edit requirement</summary><.requirement_form revision={@revision} requirement={row.requirement} /><button type="button" class="button button-small" phx-click="assurance-remove-requirement" phx-value-id={row.requirement["id"]} phx-value-storage_revision={@revision}>Remove from draft</button></details>
            <p :if={row.criteria == [] && !row.requirement["exclusion"]} class="muted">Missing observable criterion and required checks.</p>
            <div :for={criterion <- row.criteria} class="assurance-criterion" data-criterion-id={criterion.item["id"]}>
              <p>{criterion.item["text"]}</p><span class="assurance-state">{criterion.label}</span>
              <p class="muted">Required checks: {if criterion.item["required_checks"] == [], do: "Not specified", else: Enum.join(criterion.item["required_checks"], ", ")}</p>
              <p :if={criterion.issues != []} class="assurance-gap">{Enum.join(criterion.issues, " · ")}</p>
              <div :for={link <- criterion.links} class="assurance-linked-task"><button type="button" class="assurance-task-link" phx-click="select-task" phx-value-id={link["task_id"]}>{task_label(@board, link["task_id"])}</button><span class="muted">{if link["subject"], do: "Candidate " <> short(link["subject"]["revision"]), else: "No candidate evidence yet"}</span><button :if={@editable?} type="button" class="button button-small" phx-click="assurance-unlink-task" phx-value-task_id={link["task_id"]} phx-value-criterion_id={criterion.item["id"]} phx-value-storage_revision={@revision}>Unlink</button></div>
              <form :if={@editable? && @selected_task && !row.requirement["exclusion"]} phx-submit="assurance-link-task" class="assurance-inline-form"><input type="hidden" name="storage_revision" value={@revision} /><input type="hidden" name="task_id" value={@selected_task.id} /><input type="hidden" name="criterion_id" value={criterion.item["id"]} /><button class="button button-small">Link selected task · current revision</button></form>
              <details :if={@editable?} class="assurance-editor"><summary>Edit criterion</summary><.criterion_form revision={@revision} requirement_id={row.requirement["id"]} criterion={criterion.item} /><button type="button" class="button button-small" phx-click="assurance-remove-criterion" phx-value-id={criterion.item["id"]} phx-value-requirement_id={row.requirement["id"]} phx-value-storage_revision={@revision}>Remove criterion</button></details>
            </div>
            <details :if={@editable? && !row.requirement["exclusion"]} class="assurance-editor"><summary>Add criterion</summary><.criterion_form revision={@revision} requirement_id={row.requirement["id"]} criterion={%{}} /></details>
          </article>
          <.pages page={@page} count={length(@rows)} />
          <.receipts snapshot={@snapshot} board={@board} />
      <% end %>
    </section>
    """
  end

  attr(:rows, :list, required: true)
  attr(:baselines, :list, required: true)
  attr(:board, :map, required: true)
  attr(:revision, :integer, required: true)
  attr(:editable, :boolean, required: true)
  attr(:page, :integer, required: true)
  @spec dependency_annotations(map()) :: Phoenix.LiveView.Rendered.t()
  def dependency_annotations(assigns) do
    ~H"""
    <details :if={@rows != []} class="assurance-editor assurance-dependencies">
      <summary>Selected task prerequisites · {length(@rows)}</summary>
      <p class="muted">Task sources declare prerequisites. These annotations record the required output and rationale for scope review.</p>
      <article :for={row <- Enum.slice(@rows, max(@page, 0) * 40, 40)} data-dependency-task={row.task_id} data-dependency-prerequisite={row.depends_on}>
        <p><button type="button" class="assurance-task-link" phx-click="select-task" phx-value-id={row.depends_on}>{task_label(@board, row.depends_on)}</button><span :if={!row.declared?} class="assurance-state">Source relation removed</span></p>
        <p :if={!row.controlled?} class="assurance-gap">Prerequisite unavailable in this project's current board.</p>
        <form :if={@editable && row.declared? && row.controlled?} phx-submit="assurance-save-dependency" class="assurance-form">
          <input type="hidden" name="storage_revision" value={@revision} /><input type="hidden" name="task_id" value={row.task_id} /><input type="hidden" name="depends_on" value={row.depends_on} />
          <label>Why this prerequisite is needed<textarea name="reason" rows="2" required maxlength="4000">{row.reason}</textarea></label>
          <label>Required output<textarea name="output" rows="2" required maxlength="4000" placeholder="Reviewed API contract at the agreed revision">{row.output}</textarea></label>
          <label>Review reference <span class="muted">optional</span><select name="reviewed_ref"><option value="">Not linked to a reviewed version</option><option :for={baseline <- @baselines} value={baseline["ref"]} selected={row.reviewed_ref == baseline["ref"]}>{short(baseline["ref"])} · {baseline["reviewed_at"]}</option></select></label>
          <button class="button button-small" phx-disable-with="Saving…">Save prerequisite annotation</button>
        </form>
        <div :if={!@editable || !row.declared? || !row.controlled?}><p>{row.reason}</p><p class="muted">Required output: {if row.output == "", do: "Not recorded", else: row.output}</p><p :if={row.reviewed_ref} class="muted">Review reference <code>{short(row.reviewed_ref)}</code></p></div>
        <button :if={@editable && row.controlled? && row.annotated?} type="button" class="button button-small" phx-click="assurance-remove-dependency" phx-value-task_id={row.task_id} phx-value-depends_on={row.depends_on} phx-value-storage_revision={@revision}>Remove annotation</button>
      </article>
      <.pages page={@page} count={length(@rows)} />
    </details>
    """
  end

  attr(:revision, :integer, required: true)
  attr(:requirement, :map, required: true)
  @spec requirement_form(map()) :: Phoenix.LiveView.Rendered.t()
  def requirement_form(assigns) do
    ~H"""
    <form phx-submit="assurance-save-requirement" class="assurance-form"><input type="hidden" name="storage_revision" value={@revision} /><input type="hidden" name="requirement_id" value={@requirement["id"] || ""} />
      <label>Required outcome<input name="title" value={@requirement["title"] || ""} required maxlength="512" placeholder="User can reset a password" /></label>
      <label>Kind<select name="kind"><option value="functional" selected={@requirement["kind"] != "nonfunctional"}>Behavior</option><option value="nonfunctional" selected={@requirement["kind"] == "nonfunctional"}>Quality, safety or performance</option></select></label>
      <label>Exclusion reason <span class="muted">optional</span><input name="exclusion" value={@requirement["exclusion"] || ""} maxlength="4000" placeholder="Leave blank when included" /></label><button class="button button-primary" phx-disable-with="Saving…">Save requirement</button>
    </form>
    """
  end

  attr(:revision, :integer, required: true)
  attr(:requirement_id, :string, required: true)
  attr(:criterion, :map, required: true)
  @spec criterion_form(map()) :: Phoenix.LiveView.Rendered.t()
  def criterion_form(assigns) do
    ~H"""
    <form phx-submit="assurance-save-criterion" class="assurance-form"><input type="hidden" name="storage_revision" value={@revision} /><input type="hidden" name="requirement_id" value={@requirement_id} /><input type="hidden" name="criterion_id" value={@criterion["id"] || ""} />
      <label>Observable success criterion<textarea name="text" required rows="3" maxlength="4000" placeholder="Given an expired reset token, the request is rejected and the password is unchanged.">{@criterion["text"] || ""}</textarea></label>
      <label>Required check names<textarea name="required_checks" required rows="2" placeholder="One exact automated check name per line">{Enum.join(@criterion["required_checks"] || [], "\n")}</textarea></label><button class="button button-primary" phx-disable-with="Saving…">Save criterion</button>
    </form>
    """
  end

  attr(:page, :integer, required: true)
  attr(:count, :integer, required: true)
  @spec pages(map()) :: Phoenix.LiveView.Rendered.t()
  def pages(assigns) do
    ~H"""
    <div :if={@count > 40} class="assurance-inline-form"><button type="button" class="button button-small" phx-click="assurance-page" phx-value-page={max(@page - 1, 0)} disabled={@page <= 0}>Previous</button><span>{min(@page * 40 + 1, @count)}–{min((@page + 1) * 40, @count)} of {@count}</span><button type="button" class="button button-small" phx-click="assurance-page" phx-value-page={@page + 1} disabled={(@page + 1) * 40 >= @count}>Next</button></div>
    """
  end

  attr(:snapshot, :map, required: true)
  attr(:board, :map, required: true)
  @spec receipts(map()) :: Phoenix.LiveView.Rendered.t()
  def receipts(assigns) do
    evidence = records(assigns.snapshot["evidence"]) ++ (get_in(assigns.board, [:assurance_observations, "evidence"]) || [])
    assigns = assign(assigns, :receipts, Enum.uniq_by(evidence, & &1["id"]) |> Enum.take(40))

    ~H"""
    <details :if={@receipts != []} class="assurance-editor assurance-receipts"><summary>Evidence receipts</summary><article :for={receipt <- @receipts}><strong>{receipt["check"]} · {receipt["result"]}</strong><p class="muted">{if receipt["origin"] in ["manual", "imported"], do: "Declaration · unverified", else: "Observed by " <> (receipt["producer"] || "unknown producer")} · {receipt["observed_at"]}</p><p><code>{get_in(receipt, ["subject", "revision"])}</code><span> {get_in(receipt, ["subject", "environment"])}</span></p><p class="muted">Run {receipt["run_id"]} · {receipt["origin"]}</p></article></details>
    """
  end

  defp document(%{"document" => doc}), do: document(doc)
  defp document(%{"requirements" => _} = doc), do: doc
  defp document(_), do: %{"requirements" => [], "task_links" => [], "dependencies" => []}
  defp records(value) when is_map(value), do: value |> Map.values() |> Enum.sort_by(&(&1["reviewed_at"] || &1["created_at"] || &1["id"] || ""), :desc)
  defp records(value) when is_list(value), do: value
  defp records(_), do: []

  defp prepare(assigns) do
    document = selected_document(assigns)
    rows = requirement_rows(document, assigns.projection, document(assigns.snapshot["draft"]))
    rows = if assigns.gaps_only, do: Enum.filter(rows, & &1.gap?), else: rows

    assign(assigns,
      document: document,
      rows: rows,
      editable?: not assigns.read_only and is_nil(assigns.baseline_ref),
      revision: assigns.snapshot["storage_revision"] || 0,
      selected_task: selected_task(assigns),
      baselines: records(assigns.snapshot["baselines"]),
      releases: records(assigns.snapshot["releases"]),
      release_receipts: release_receipts(assigns.board),
      changes: changes(assigns.difference, assigns.board),
      current_baseline: current_baseline(assigns.snapshot),
      dependency_rows: dependency_rows(assigns.board, document, assigns.selected_task_id)
    )
  end

  defp selected_document(%{baseline_ref: nil} = assigns), do: document(assigns.snapshot["draft"])

  defp selected_document(assigns) do
    selected = assigns.snapshot["selected_baseline"] || Enum.find(records(assigns.snapshot["baselines"]), &(&1["ref"] == assigns.baseline_ref))
    document(selected)
  end

  defp selected_task(assigns), do: Enum.find(assigns.board[:tasks] || [], &(&1[:id] == assigns.selected_task_id))
  defp current_baseline(snapshot), do: snapshot["reviewed_ref"] || get_in(snapshot, ["reviewed", "ref"])
  defp release_receipts(board), do: Enum.filter(get_in(board, [:assurance_observations, "evidence"]) || [], &(&1["origin"] in ~w(native github) and not is_nil(&1["release_id"])))

  defp requirement_rows(document, projection, current_document) do
    Enum.map(document["requirements"], &requirement_row(&1, document, projection, current_document))
  end

  defp dependency_rows(_board, _document, nil), do: []

  defp dependency_rows(board, document, selected) do
    graph = board[:workflow_graph] || %{}
    ids = Map.new(graph["nodes"] || [], &{&1["id"], &1["task_id"]})
    annotations = Enum.filter(document["dependencies"], &(&1["task_id"] == selected)) |> Map.new(&{&1["depends_on"], &1})
    declared = Enum.filter(graph["edges"] || [], &(&1["type"] == "depends_on" and ids[&1["source"]] == selected)) |> Map.new(&{ids[&1["target"]], &1})
    project = document["project"] || graph["project_id"]
    (Map.keys(annotations) ++ Map.keys(declared)) |> Enum.uniq() |> Enum.sort() |> Enum.map(&dependency_row(&1, selected, annotations[&1], declared[&1], board, project))
  end

  defp dependency_row(id, selected, annotation, edge, board, project) do
    values = annotation || edge || %{}
    controlled = Enum.all?([selected, id], fn task_id -> Enum.any?(board[:tasks] || [], &(&1[:id] == task_id and &1[:project] == project)) end)

    %{
      task_id: selected,
      depends_on: id,
      reason: values["reason"] || "",
      output: values["output"] || "",
      reviewed_ref: values["reviewed_ref"],
      declared?: not is_nil(edge),
      annotated?: not is_nil(annotation),
      controlled?: controlled
    }
  end

  defp requirement_row(requirement, document, projection, current_document) do
    criteria = Enum.map(requirement["criteria"], &criterion_row(&1, requirement, document, projection, current_document))
    %{requirement: requirement, criteria: criteria, gap?: is_nil(requirement["exclusion"]) and (criteria == [] or Enum.any?(criteria, & &1.gap?))}
  end

  defp criterion_row(criterion, requirement, document, projection, current_document) do
    links = criterion_links(document, criterion["id"])
    current_links = criterion_links(current_document, criterion["id"])
    status = if links == current_links, do: criterion_status(projection, criterion["id"]), else: %{}
    verified? = verified?(status, criterion)
    gap? = is_nil(requirement["exclusion"]) and (links == [] or criterion["required_checks"] == [] or not verified?)
    issues = criterion_issues(status, links, criterion)
    label = criterion_label(requirement, verified?)
    %{item: criterion, links: links, issues: issues, label: label, gap?: gap?}
  end

  defp criterion_links(document, id), do: Enum.filter(document["task_links"], &(&1["criterion_id"] == id))
  defp criterion_label(%{"exclusion" => reason}, _verified) when is_binary(reason), do: "Excluded"
  defp criterion_label(_requirement, true), do: "Current evidence passed"
  defp criterion_label(_requirement, _verified), do: "Unverified"

  defp criterion_status(projection, id), do: if(projection["observations_available"] == true, do: find_status(projection["criteria"], id), else: %{})
  defp release_status(projection, id), do: if(projection["observations_available"] == true, do: find_status(projection["release_readiness"], id), else: %{})
  defp find_status(items, id) when is_list(items), do: Enum.find(items, &((&1["id"] || &1[:id] || &1["criterion_id"]) == id)) || %{}
  defp find_status(items, id) when is_map(items), do: items[id] || %{}
  defp find_status(_, _), do: %{}
  defp verified?(status, criterion), do: status["status"] == "covered" and status["issues"] == [] and status["text"] == criterion["text"] and status["required_checks"] == criterion["required_checks"]

  defp criterion_issues(status, links, criterion) do
    own = if(links == [], do: ["No linked task"], else: []) ++ if(criterion["required_checks"] == [], do: ["No required checks"], else: [])
    Enum.uniq(own ++ issues(status) ++ if(status == %{} && own == [], do: ["Current observed evidence unavailable"], else: []))
  end

  defp issues(status), do: Enum.flat_map(~w(issues missing_checks missing_gates missing_criteria), fn key -> Enum.map(status[key] || [], &issue_label/1) end)
  defp issue_label(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp issue_label(value) when is_map(value), do: value["message"] || value["reason"] || value["check"] || "Evidence gap"
  defp issue_label(_), do: "Evidence gap"
  defp release_label(status), do: if(status["runtime_verified"] == true, do: "Runtime verified", else: if(status["build_ready"] == true, do: "Artifact checks passed", else: "Unverified"))

  defp release_detail(status),
    do:
      if(status == %{},
        do: "Current release observations are unavailable.",
        else: "Deployment: #{if status["deployment_recorded"] == true, do: "observed", else: "not observed"} · Runtime: #{if status["runtime_verified"] == true, do: "verified", else: "unverified"}"
      )

  defp task_label(board, id) do
    case Enum.find(board[:tasks] || [], &(&1[:id] == id)) do
      nil -> id
      task -> (task[:identifier] || id) <> " · " <> (task[:title] || "")
    end
  end

  defp short(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp short(_), do: "Unavailable"

  defp changes(difference, board, prefix \\ "") do
    difference |> Enum.flat_map(&change_group(&1, board, prefix)) |> Enum.sort_by(&{&1.kind, &1.change, &1.id})
  end

  defp change_group({kind, value}, board, prefix) when is_map(value) do
    name = prefix <> to_string(kind)

    if Enum.any?(~w(added removed changed), &Map.has_key?(value, &1)),
      do: Enum.flat_map(~w(added removed changed), &change_rows(value, &1, name, board)),
      else: changes(value, board, name <> ".")
  end

  defp change_group(_, _, _), do: []
  defp change_rows(value, change, name, board), do: Enum.map(value[change] || [], &change_row(&1, change, name, board))
  defp change_row(id, change, name, board), do: %{kind: name, change: change, id: if(is_binary(id), do: id, else: inspect(id)), task_id: change_task(name, id, board)}

  defp change_task("graph.nodes", "task:" <> id, _board), do: id

  defp change_task(kind, id, board) when kind in ["task_links", "dependencies"] and is_binary(id) do
    case Enum.find(board[:tasks] || [], &String.starts_with?(id, &1.id <> "/")) do
      nil -> if kind == "task_links", do: id |> String.split("/") |> Enum.drop(-1) |> Enum.join("/"), else: nil
      task -> task.id
    end
  end

  defp change_task(_kind, _id, _board), do: nil
end
