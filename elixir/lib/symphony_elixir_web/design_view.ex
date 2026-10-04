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
    <section id={@workspace_id} class="design-workspace" phx-hook="DesignWorkspace" phx-update="ignore" data-design-project={@project} aria-label={"#{@label} design workspace"}>
      <header class="design-toolbar">
        <div class="design-title"><h2>Design</h2><span class="design-draft-badge">Working draft</span></div>
        <div class="design-toolbar-meta"><span data-design-storage-label role="status" aria-live="polite">Browser draft</span><a :if={@published_url} href={@published_url} target="_blank" rel="noopener noreferrer">Published design ↗</a></div>
      </header>
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
          <header class="design-panel-heading"><div><h3 data-design-heading>Shape the idea</h3><p data-design-description>Write on the board. Connect ideas when it helps.</p></div><button type="button" class="design-agent-prompt" data-design-prompt="Help me brainstorm a small first version. Ask one useful clarifying question before suggesting components.">Brainstorm ↗</button></header>
          <div class="design-canvas-tools" role="toolbar" aria-label="Whiteboard tools">
            <div class="design-canvas-tool-group">
              <button type="button" data-canvas-tool="select" title="Select and move" aria-label="Select and move" aria-pressed="true"><.tool_icon name="select" /></button>
              <button type="button" data-canvas-tool="pan" title="Pan" aria-label="Pan" aria-pressed="false"><.tool_icon name="pan" /></button>
              <button type="button" data-canvas-tool="note" title="Add note" aria-label="Add note" aria-pressed="false"><.tool_icon name="note" /><span>Note</span></button>
              <button type="button" data-canvas-tool="component" title="Add component" aria-label="Add component" aria-pressed="false"><.tool_icon name="component" /><span>Box</span></button>
              <button type="button" data-canvas-tool="entity" title="Add entity with fields" aria-label="Add entity" aria-pressed="false"><.tool_icon name="entity" /><span>Entity</span></button>
              <button type="button" data-canvas-tool="connect" title="Connect two cards" aria-label="Connect two cards" aria-pressed="false"><.tool_icon name="connect" /></button>
              <button type="button" data-canvas-tool="draw" title="Draw a sketch" aria-label="Draw a sketch" aria-pressed="false"><.tool_icon name="draw" /></button>
            </div>
            <div class="design-canvas-tool-group"><button type="button" data-canvas-action="undo" aria-label="Undo" title="Undo">↶</button><button type="button" data-canvas-action="redo" aria-label="Redo" title="Redo">↷</button></div>
            <div class="design-canvas-tool-group design-canvas-zoom"><button type="button" data-canvas-action="zoom-out" aria-label="Zoom out">−</button><span data-canvas-scale>100%</span><button type="button" data-canvas-action="zoom-in" aria-label="Zoom in">+</button><button type="button" data-canvas-action="fit">Fit</button></div>
          </div>
          <div class="design-canvas-body"><div class="design-canvas-stage" data-design-canvas tabindex="0" aria-label="Design whiteboard"><p class="design-canvas-loading">Opening your whiteboard…</p></div><aside class="design-canvas-selection" data-canvas-selection aria-label="Selected object" hidden></aside></div>
          <div class="design-canvas-suggestions" data-canvas-suggestions aria-live="polite" hidden></div>
          <footer class="design-canvas-footer"><span data-canvas-status role="status">Choose a tool, then click the board.</span><span>Drag to move · Scroll to pan · Ctrl/⌘ + scroll to zoom</span></footer>
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

  attr(:name, :string, required: true)

  defp tool_icon(assigns) do
    ~H"""
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path :if={@name == "select"} d="M5 3l14 9-7 1-3 7-4-17Z" />
      <path :if={@name == "pan"} d="M8 12V6a2 2 0 0 1 4 0v6-8a2 2 0 0 1 4 0v8-6a2 2 0 0 1 4 0v9c0 4-3 6-7 6-3 0-5-3-8-7a2 2 0 0 1 3-2l2 2" />
      <g :if={@name == "note"}><path d="M5 3h14v14l-4 4H5Z" /><path d="M15 21v-4h4M8 8h8M8 12h6" /></g>
      <rect :if={@name == "component"} x="3" y="5" width="18" height="14" rx="3" />
      <g :if={@name == "entity"}><rect x="3" y="3" width="18" height="18" rx="2" /><path d="M3 9h18M7 13h2M12 13h5M7 17h2M12 17h5" /></g>
      <path :if={@name == "connect"} d="M3 6h6v12h12m-5-4 5 4-5 4" />
      <path :if={@name == "draw"} d="m4 20 4-1L21 6l-3-3L5 16l-1 4Zm11-14 3 3" />
    </svg>
    """
  end

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
