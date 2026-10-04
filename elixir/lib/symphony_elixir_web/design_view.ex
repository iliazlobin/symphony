defmodule SymphonyElixirWeb.DesignView do
  @moduledoc "A project-scoped working outline; published designs remain in Notion."
  use Phoenix.Component

  @sections [
    %{id: "brief", title: "Brief", detail: "Problem, people, scope"},
    %{id: "requirements", title: "Requirements", detail: "Behavior and quality"},
    %{id: "data", title: "Data", detail: "Entities and relationships"},
    %{id: "architecture", title: "Architecture", detail: "Components and flows"},
    %{id: "decisions", title: "Decisions", detail: "Questions and validation"}
  ]

  attr(:project, :string, required: true)
  attr(:project_label, :string, default: nil)
  attr(:notion_url, :string, default: nil)

  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    assigns =
      assign(assigns,
        sections: @sections,
        workspace_id: workspace_id(assigns.project),
        label: assigns.project_label || assigns.project,
        published_url: published_url(assigns.notion_url),
        example_available: String.ends_with?(assigns.project, "/events-concierge")
      )

    ~H"""
    <section id={@workspace_id} class="design-workspace" phx-hook="DesignWorkspace" phx-update="ignore" data-design-durable="true" data-design-project={@project} data-design-editor-js={SymphonyElixirWeb.StaticAssets.design_editor_js_url()} data-design-editor-css={SymphonyElixirWeb.StaticAssets.design_editor_css_url()} data-design-editor-assets={SymphonyElixirWeb.StaticAssets.design_editor_asset_path()} aria-label={"#{@label} design workspace"}>
      <header class="design-toolbar">
        <div class="design-title"><h2>Design</h2><span class="design-draft-badge">Working draft</span></div>
        <div class="design-toolbar-meta"><span data-design-storage-label role="status" aria-live="polite">Opening saved design…</span><button type="button" class="button button-small" data-design-review>Review changes</button><a :if={@published_url} href={@published_url} target="_blank" rel="noopener noreferrer">Published design ↗</a></div>
      </header>
      <div class="design-recovery" data-design-recovery hidden role="status"><span data-design-recovery-message></span><button type="button" class="button button-small" data-design-use-saved>Open project draft</button><button type="button" class="button button-small" data-design-import>Save browser draft to project</button></div>
      <div class="design-layout">
        <aside class="design-guidance">
          <nav class="design-outline" role="tablist" aria-label="Design steps" aria-orientation="vertical">
            <button :for={{section, index} <- Enum.with_index(@sections, 1)} id={"design-tab-#{section.id}"} type="button" role="tab" data-design-section={section.id} aria-controls="design-canvas-panel" aria-selected={to_string(section.id == "brief")} tabindex={if(section.id == "brief", do: "0", else: "-1")}>
              <span class="design-step-number">{index}</span><span class="design-step-text"><span class="design-outline-title">{section.title}<span class="design-section-status" data-design-section-status={section.id} aria-label="Empty section">○</span></span><span class="design-outline-detail">{section.detail}</span></span>
            </button>
          </nav>
          <div class="design-step-guide"><p data-design-guide>Who is this for, and what problem should it solve?</p><button type="button" class="design-agent-prompt" data-design-feedback>Get feedback ↗</button><p class="design-outline-progress" data-design-progress>Start with a note or a sketch.</p></div>
          <div class="design-starting-points"><button :if={@example_available} type="button" data-design-example>Add example</button></div>
        </aside>
        <section id="design-canvas-panel" class="design-editor design-visual-editor" role="tabpanel" aria-labelledby="design-tab-brief">
          <header class="design-panel-heading"><div><h3 data-design-heading>Shape the idea</h3><p data-design-description>Write on the board. Connect ideas when it helps.</p></div><div class="design-heading-actions"><button type="button" class="button button-small" data-design-outline-toggle aria-expanded="false" aria-controls="design-item-outline">Outline</button><button type="button" class="design-agent-prompt" data-design-prompt="Help me brainstorm a small first version. Ask one useful clarifying question before suggesting components.">Brainstorm ↗</button></div></header>
          <div class="design-canvas-body"><div class="design-canvas-stage" data-design-canvas tabindex="0" aria-label="Design whiteboard"><p class="design-canvas-loading">Opening your whiteboard…</p></div><aside id="design-item-outline" class="design-item-outline" data-design-outline hidden aria-label="Structured design items"><header><strong>Outline</strong><button type="button" data-design-outline-toggle aria-label="Close outline">×</button></header><div data-design-items></div><div data-design-inspector></div></aside></div>
          <section class="design-review-panel" data-design-review-panel hidden role="region" aria-label="Review design changes"><header><h3>Review changes</h3><button type="button" class="button button-small" data-design-review-close aria-label="Close design review">Close ×</button></header><div class="design-review-body"><p data-design-review-description>Save this version as the design baseline. You can keep editing a new draft.</p><ul data-design-change-list></ul><div class="design-review-actions"><button type="button" class="button button-primary" data-design-confirm-review>Mark design reviewed</button><span data-design-review-label></span></div></div></section>
          <aside class="design-canvas-suggestions" data-canvas-suggestions aria-live="polite" hidden></aside>
          <p class="design-canvas-status" data-canvas-status role="status" aria-live="polite"></p>
        </section>
      </div>
      <div class="design-source-fields" hidden aria-hidden="true">
        <section :for={section <- @sections} data-design-tab={section.id}>
          <textarea :for={field <- section_fields(section.id)} id={"design-field-#{field}"} data-design-field={field} maxlength="12000" aria-label={field}></textarea>
        </section>
      </div>
    </section>
    """
  end

  defp section_fields("brief"), do: ["brief"]
  defp section_fields("requirements"), do: ["functional", "quality"]
  defp section_fields("data"), do: ["entities"]
  defp section_fields("architecture"), do: ["components", "flows"]
  defp section_fields("decisions"), do: ["decisions"]

  defp workspace_id(project) do
    hash = project |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower) |> String.slice(0, 12)
    "design-workspace-#{hash}"
  end

  defp published_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when host in ["app.notion.com", "www.notion.so", "notion.so"] -> url
      _ -> nil
    end
  end

  defp published_url(_url), do: nil
end
