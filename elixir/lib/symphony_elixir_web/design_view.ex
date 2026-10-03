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
        <nav class="design-outline" role="tablist" aria-label="Design sections" aria-orientation="vertical">
          <button :for={section <- @sections} id={"design-tab-#{section.id}"} type="button" role="tab" data-design-section={section.id} aria-controls={"design-panel-#{section.id}"} aria-selected={to_string(section.id == "brief")} tabindex={if(section.id == "brief", do: "0", else: "-1")}>
            <span class="design-outline-title">{section.title}<span class="design-section-status" data-design-section-status={section.id} aria-label="Empty section">○</span></span><span class="design-outline-detail">{section.detail}</span>
          </button>
          <p class="design-outline-progress" data-design-progress>Start anywhere. Keep questions visible.</p>
        </nav>
        <div class="design-editor">
          <section id="design-panel-brief" class="design-panel" role="tabpanel" aria-labelledby="design-tab-brief" data-design-tab="brief">
            <div class="design-panel-heading"><div><h3>What are we designing?</h3><p>Start with the problem. Add detail when it helps a decision.</p></div><button type="button" class="design-agent-prompt" data-design-prompt="Help me clarify this project design brief. Ask one useful question at a time about the user, problem, outcome and scope.">Ask project agent ↗</button></div>
            <div class="design-field"><label for="design-field-brief">Problem and scope</label><p id="design-hint-brief">Who needs it? What should improve? What is outside this first version?</p><textarea id="design-field-brief" data-design-field="brief" rows="9" maxlength="12000" aria-describedby="design-hint-brief" placeholder="For [people], solve [problem]. Success looks like [outcome]. This version includes… and leaves out…"></textarea></div>
            <div class="design-starting-points"><span>Need a starting point?</span><button type="button" data-design-prompt="Help me brainstorm a small first version of this project. Offer three possible user problems to focus on, with one sentence each.">Explore an idea</button><button type="button" data-design-prompt="Help me organize an existing project design. Separate observed facts from assumptions and open questions, then suggest the smallest useful outline.">Organize what exists</button><button :if={@example_available} type="button" data-design-example>Add example</button></div>
            <p :if={@example_available} class="design-footnote">Example: illustrative Events Concierge assumptions. Fills empty fields only.</p>
            <p class="design-footnote">A working outline, not an approved design. Publishing and task creation are separate steps.</p>
          </section>
          <section id="design-panel-requirements" class="design-panel" role="tabpanel" aria-labelledby="design-tab-requirements" data-design-tab="requirements" hidden>
            <div class="design-panel-heading"><div><h3>Requirements</h3><p>Describe behavior first. Make quality goals measurable when possible.</p></div><button type="button" class="design-agent-prompt" data-design-prompt="Help me refine the functional and quality requirements for this design. Separate must-have behavior, measurable quality goals and unanswered questions. Do not invent traffic or reliability targets.">Ask project agent ↗</button></div>
            <div class="design-field"><label for="design-field-functional">Functional requirements</label><p id="design-hint-functional">What must a user or the system be able to do? Start with a few clear behaviors.</p><textarea id="design-field-functional" data-design-field="functional" rows="7" maxlength="12000" aria-describedby="design-hint-functional" placeholder="• A user can…&#10;• The system must…&#10;• Later: …"></textarea></div>
            <div class="design-field"><label for="design-field-quality">Quality requirements</label><p id="design-hint-quality">Response time, reliability, security, scale and cost. Record unknown targets as questions.</p><textarea id="design-field-quality" data-design-field="quality" rows="7" maxlength="12000" aria-describedby="design-hint-quality" placeholder="• Response time: …&#10;• Access and privacy: …&#10;• Expected usage: unknown; investigate…"></textarea></div>
          </section>
          <section id="design-panel-data" class="design-panel" role="tabpanel" aria-labelledby="design-tab-data" data-design-tab="data" hidden>
            <div class="design-panel-heading"><div><h3>Data</h3><p>Define the few entities and relationships that matter to the main flows.</p></div><button type="button" class="design-agent-prompt" data-design-prompt="Help me outline the core entities, their key fields and relationships for this design. Include ownership and important data rules. Keep it conceptual until a specific storage choice is justified.">Ask project agent ↗</button></div>
            <div class="design-field"><label for="design-field-entities">Entities and relationships</label><p id="design-hint-entities">Name each entity, its key fields, who owns it and how it relates to others. Add data rules or interfaces where useful.</p><textarea id="design-field-entities" data-design-field="entities" rows="12" maxlength="12000" aria-describedby="design-hint-entities" placeholder="Entity: …&#10;Key fields: …&#10;Relationships: one … has many …&#10;Rules: …"></textarea></div>
          </section>
          <section id="design-panel-architecture" class="design-panel" role="tabpanel" aria-labelledby="design-tab-architecture" data-design-tab="architecture" hidden>
            <div class="design-panel-heading"><div><h3>Architecture</h3><p>Start with big components. Trace the main cases through them.</p></div><button type="button" class="design-agent-prompt" data-design-prompt="Help me sketch the smallest architecture that meets this design's requirements. Describe component responsibilities and two main data flows. Introduce distributed services or low-level detail only where a requirement needs them.">Ask project agent ↗</button></div>
            <div class="design-field"><label for="design-field-components">Components</label><p id="design-hint-components">Responsibility, boundary and interfaces. Keep local and external systems distinct.</p><textarea id="design-field-components" data-design-field="components" rows="7" maxlength="12000" aria-describedby="design-hint-components" placeholder="• Web client: …&#10;• Backend: …&#10;• Data store: …&#10;• External system: …"></textarea></div>
            <div class="design-field"><label for="design-field-flows">Main flows</label><p id="design-hint-flows">Follow one user action through components and data. Note the important failure path.</p><textarea id="design-field-flows" data-design-field="flows" rows="8" maxlength="12000" aria-describedby="design-hint-flows" placeholder="1. User…&#10;2. Web client → Backend…&#10;3. Backend reads/writes…&#10;If this fails: …"></textarea></div>
          </section>
          <section id="design-panel-decisions" class="design-panel" role="tabpanel" aria-labelledby="design-tab-decisions" data-design-tab="decisions" hidden>
            <div class="design-panel-heading"><div><h3>Decisions and questions</h3><p>Capture what is still uncertain and how we will test it.</p></div><button type="button" class="design-agent-prompt" data-design-prompt="Review this working design for unanswered questions and unnecessary complexity. Suggest a few focused validation checks. Keep recommendations distinct from decisions already made.">Ask project agent ↗</button></div>
            <div class="design-field"><label for="design-field-decisions">Open questions, decisions and validation</label><p id="design-hint-decisions">Question → evidence needed. Decision → reason. Add deeper design only for a concrete risk.</p><textarea id="design-field-decisions" data-design-field="decisions" rows="12" maxlength="12000" aria-describedby="design-hint-decisions" placeholder="Open: …&#10;Decision: … because…&#10;Validate: …&#10;Detail needed: …"></textarea></div>
          </section>
        </div>
      </div>
    </section>
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
