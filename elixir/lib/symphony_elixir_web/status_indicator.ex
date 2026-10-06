defmodule SymphonyElixirWeb.StatusIndicator do
  @moduledoc "Compact task guidance with local hover, focus and tap disclosure."
  use Phoenix.Component

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:detail, :string, required: true)
  attr(:label, :string, default: nil)
  attr(:tone, :string, default: "neutral", values: ["neutral", "warning"])
  attr(:class, :string, default: nil)
  attr(:detail_class, :string, default: nil)
  attr(:rest, :global)

  @spec indicator(map()) :: Phoenix.LiveView.Rendered.t()
  def indicator(assigns) do
    ~H"""
    <span id={@id} class={["status-indicator", @class]} phx-hook="StatusIndicator" data-tone={@tone} {@rest}>
      <button type="button" class="status-indicator-trigger" data-indicator-trigger
        aria-label={"#{@title}: show details"} aria-describedby={@id <> "-detail"}
        aria-controls={@id <> "-detail"} popovertarget={@id <> "-detail"}>
        <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
          <circle cx="8" cy="8" r="6" />
          <path :if={@tone == "neutral"} d="M8 7v4M8 4.5v.5" />
          <path :if={@tone == "warning"} d="M8 4.5v4M8 11v.5" />
        </svg>
        <span :if={@label}>{@label}</span>
      </button>
      <span id={@id <> "-detail"} class={["status-indicator-detail", @detail_class]} data-indicator-detail popover="auto" role="tooltip">
        <strong>{@title}</strong><span>{@detail}</span>
      </span>
    </span>
    """
  end
end
