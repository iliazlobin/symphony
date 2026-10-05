defmodule SymphonyElixirWeb.SpecificationView do
  @moduledoc "Structured specification editing with named, source-authoritative Mermaid diagrams."
  use Phoenix.Component

  alias SymphonyElixir.Specification.Document

  @sections [
    %{id: "brief", title: "Brief", detail: "Problem, people, scope", prompt: "Who needs this, and what should improve?"},
    %{id: "requirements", title: "Requirements", detail: "Behavior and quality", prompt: "Describe required behavior and measurable quality targets."},
    %{id: "data", title: "Data", detail: "Entities and relationships", prompt: "Name core entities, their fields and rules. Use an ER or class diagram where useful."},
    %{id: "architecture", title: "Architecture", detail: "Components and flows", prompt: "Describe boundaries and request flows, then show the connections in a diagram."},
    %{id: "decisions", title: "Decisions", detail: "Questions and validation", prompt: "Record the decision, its reason and how remaining questions will be tested."}
  ]

  attr(:project, :string, required: true)
  attr(:project_label, :string, default: nil)
  attr(:state, :map, default: %{})
  attr(:draft, :map, default: nil)
  attr(:section, :string, default: "brief")
  attr(:available, :boolean, default: true)
  attr(:read_only, :boolean, default: false)
  attr(:dirty, :boolean, default: false)
  attr(:notice, :string, default: nil)
  attr(:history, :boolean, default: false)
  attr(:viewed_ref, :string, default: nil)
  attr(:review_open, :boolean, default: false)
  attr(:idea_url, :string, default: nil)

  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    section = Enum.find(@sections, &(&1.id == assigns.section)) || hd(@sections)
    document = assigns.draft || assigns.state["draft"]
    content = if document, do: document["sections"][section.id], else: %{"items" => [], "diagrams" => []}

    assigns =
      assign(assigns,
        sections: @sections,
        selected: section,
        document: document,
        content: content,
        workspace_id: workspace_id(assigns.project),
        form_id: form_id(assigns, document, section.id),
        revision: Map.get(assigns.state, "storage_revision", 0),
        reviewed: assigns.state["reviewed"],
        versions: Map.get(assigns.state, "reviewed_versions", []),
        label: assigns.project_label || assigns.project,
        kinds: Document.kinds(section.id),
        editable: assigns.available and not assigns.history and not assigns.read_only,
        idea_url: local_url(assigns.idea_url),
        reviewable: is_map(assigns.state["draft"]) and Document.content?(assigns.state["draft"])
      )

    ~H"""
    <section id={@workspace_id} class="specification-workspace design-workspace" phx-hook="SpecificationWorkspace" data-specification-project={@project} aria-label={"#{@label} specification"}>
      <header class="design-toolbar">
        <div class="design-title"><h2>Design</h2><span class="design-draft-badge">Specification</span></div>
        <div class="design-toolbar-meta">
          <span role="status" aria-live="polite" data-spec-status>{if(@history, do: "Reviewed version · read-only", else: if(@read_only, do: "Read-only board", else: status(@available, @dirty, @state["draft"], @reviewed)))}</span>
          <.link :if={@idea_url} patch={@idea_url}>Open Idea</.link>
          <button :if={not @history} type="button" class="button button-small" phx-click="spec-reload" phx-value-project={@project}>Reload saved draft</button>
          <button :if={not @history} type="button" class="button button-small" phx-click="spec-review" phx-value-project={@project} phx-value-storage_revision={@revision} disabled={not @editable or @dirty or not @reviewable}>Review specification</button>
          <button :if={@history} type="button" class="button button-small" phx-click="spec-return-draft" phx-value-project={@project}>Return to draft</button>
        </div>
      </header>
      <p :if={@notice} class="board-notice" role="status">{@notice}</p>
      <details :if={@versions != []} id={@workspace_id <> "-history"} class="specification-history"><summary>Reviewed versions ({length(@versions)})</summary><ul><li :for={version <- @versions}><button type="button" class="button button-small" phx-click="spec-open-version" phx-value-project={@project} phx-value-ref={version["ref"]} aria-current={if(version["ref"] == @viewed_ref, do: "true", else: "false")}>{version["reviewed_at"]} · {String.slice(version["ref"], 0, 8)}</button></li></ul></details>
      <section :if={@review_open and not @history} class="specification-review" aria-label="Review specification"><h3>Review specification</h3><p>Save the current project draft as an immutable reviewed version. Later edits continue in the draft.</p><button type="button" class="button button-primary" phx-click="spec-confirm-review" phx-value-project={@project} phx-value-storage_revision={@revision} disabled={not @editable or @dirty or not @reviewable}>Save reviewed version</button><button type="button" class="button button-small" phx-click="spec-cancel-review" phx-value-project={@project}>Cancel</button></section>
      <div class="design-layout specification-layout">
        <nav class="design-outline" role="tablist" aria-label="Specification steps" aria-orientation="vertical">
          <button :for={{section, index} <- Enum.with_index(@sections, 1)} id={@workspace_id <> "-tab-" <> section.id} type="button" role="tab" aria-controls={@workspace_id <> "-panel"} aria-selected={to_string(section.id == @selected.id)} tabindex={if(section.id == @selected.id, do: "0", else: "-1")} phx-click="spec-section" phx-value-project={@project} phx-value-section={section.id}>
            <span class="design-step-number">{index}</span><span class="design-step-text"><span class="design-outline-title">{section.title}</span><span class="design-outline-detail">{section.detail}</span></span>
          </button>
        </nav>
        <section id={@workspace_id <> "-panel"} class="design-editor specification-editor" role="tabpanel" aria-labelledby={@workspace_id <> "-tab-" <> @selected.id}>
          <header class="design-panel-heading"><div><h3>{@selected.title}</h3><p>{@selected.prompt}</p></div></header>
          <form id={@form_id} phx-change="spec-edit" phx-submit="spec-save" class="specification-form">
            <input id={@form_id <> "-project"} type="hidden" name="project" value={@project} /><input id={@form_id <> "-document"} type="hidden" name="document_id" value={@document && @document["document_id"]} />
            <input id={@form_id <> "-section"} type="hidden" name="section" value={@selected.id} /><input id={@form_id <> "-revision"} type="hidden" name="storage_revision" value={@revision} />
            <fieldset disabled={not @editable}>
              <p :if={@content["items"] == [] and @content["diagrams"] == []} class="specification-empty">Start with a short statement. Add a diagram when it helps explain the design.</p>
              <article :for={item <- @content["items"]} id={@workspace_id <> "-item-" <> item["id"]} class="specification-item" data-spec-item-id={item["id"]}>
                <header><label class="specification-title"><span>Title</span><input id={@form_id <> "-item-" <> item["id"] <> "-title"} type="text" name={"items[#{item["id"]}][title]"} value={item["title"]} maxlength="256" placeholder="Name this part of the specification" /></label>
                  <label><span>Kind</span><select id={@form_id <> "-item-" <> item["id"] <> "-kind"} name={"items[#{item["id"]}][kind]"}><option :for={kind <- @kinds} value={kind} selected={kind == item["kind"]}>{kind_label(kind)}</option></select></label>
                  <button type="button" class="button button-small" phx-click="spec-remove-item" phx-value-project={@project} phx-value-section={@selected.id} phx-value-id={item["id"]} aria-label={"Remove " <> if(item["title"] == "", do: "item", else: item["title"])}>Remove</button>
                </header>
                <label><span>Details</span><textarea id={@form_id <> "-item-" <> item["id"] <> "-body"} name={"items[#{item["id"]}][body]"} rows="5" maxlength="24000" placeholder="Describe the behavior, fields, constraints or decision.">{item["body"]}</textarea></label>
              </article>
              <article :for={diagram <- @content["diagrams"]} id={@workspace_id <> "-diagram-" <> diagram["id"]} class="specification-diagram">
                <header><label class="specification-title"><span>Diagram name</span><input id={@form_id <> "-diagram-" <> diagram["id"] <> "-title"} type="text" name={"diagrams[#{diagram["id"]}][title]"} value={diagram["title"]} maxlength="256" placeholder="Name the diagram" /></label>
                  <button type="button" class="button button-small" phx-click="spec-remove-diagram" phx-value-project={@project} phx-value-section={@selected.id} phx-value-id={diagram["id"]} aria-label={"Remove " <> if(diagram["title"] == "", do: "diagram", else: diagram["title"])}>Remove</button>
                </header>
                <label><span>Mermaid source</span><textarea id={@form_id <> "-diagram-" <> diagram["id"] <> "-source"} name={"diagrams[#{diagram["id"]}][source]"} rows="7" maxlength="60000" spellcheck="false">{diagram["source"]}</textarea></label>
                <div id={@workspace_id <> "-render-" <> diagram["id"]} phx-hook="SpecificationDiagram" data-spec-renderer={SymphonyElixirWeb.StaticAssets.specification_diagram_js_url()}>
                  <pre hidden data-spec-mermaid data-spec-diagram-id={diagram["id"]}>{diagram["source"]}</pre>
                  <div id={@workspace_id <> "-preview-" <> diagram["id"]} data-spec-preview phx-update="ignore"></div>
                  <p data-spec-feedback role="status" aria-live="polite">Opening diagram preview…</p>
                </div>
              </article>
              <div class="specification-actions"><button type="button" class="button button-small" phx-click="spec-add-item" phx-value-project={@project} phx-value-section={@selected.id}>Add item</button><button type="button" class="button button-small" phx-click="spec-add-diagram" phx-value-project={@project} phx-value-section={@selected.id}>Add diagram</button><button type="submit" class="button button-primary" disabled={not @dirty}>Save specification</button></div>
            </fieldset>
          </form>
        </section>
      </div>
    </section>
    """
  end

  defp workspace_id(project), do: "specification-" <> (:crypto.hash(:sha256, project) |> Base.encode16(case: :lower) |> String.slice(0, 12))

  defp form_id(assigns, document, section) do
    document_id = if document, do: document["document_id"], else: "empty"
    version = if assigns.history, do: assigns.viewed_ref || "reviewed", else: "draft"
    workspace_id(assigns.project) <> "-form-" <> document_id <> "-" <> section <> "-" <> version
  end

  defp local_url(url) when is_binary(url) do
    local_path? = String.starts_with?(url, "/") and not String.starts_with?(url, "//")
    if local_path? and not String.contains?(url, ["\\", "\n", "\r"]), do: url
  end

  defp local_url(_), do: nil
  defp kind_label("nonfunctional"), do: "Non-functional"
  defp kind_label(kind), do: String.capitalize(kind)
  defp status(false, _, _, _), do: "Specification storage unavailable"
  defp status(true, true, _, _), do: "Unsaved changes"
  defp status(true, false, nil, _), do: "Start a specification"
  defp status(true, false, document, %{"ref" => ref}), do: if(Document.content_ref(document) == ref, do: "Reviewed version", else: "Draft · reviewed version retained")
  defp status(true, false, _, _), do: "Saved draft"
end
