defmodule SymphonyElixirWeb.SpecificationObjectView do
  @moduledoc "Compact typed object cards with field tables, stable links and source references."
  use Phoenix.Component
  alias SymphonyElixir.Specification.Object

  attr(:item, :map, required: true)
  attr(:objects, :list, required: true)
  attr(:project, :string, required: true)
  attr(:section, :string, required: true)
  attr(:form_id, :string, required: true)
  attr(:workspace_id, :string, required: true)
  attr(:open, :boolean, default: false)

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    assigns = assign(assigns, base: "items[#{assigns.item["id"]}]", id: assigns.form_id <> "-item-" <> assigns.item["id"], fields: Object.fields(assigns.item["kind"]))

    ~H"""
    <details id={@workspace_id <> "-item-" <> @item["id"]} class="specification-object" data-spec-disclosure data-spec-item-id={@item["id"]} data-spec-search-text={@item["title"] <> " " <> @item["kind"] <> " " <> @item["body"]} open={@open or @item["title"] == ""}>
      <summary><span class="spec-object-kind">{label(@item["kind"])}</span><strong>{if(@item["title"] == "", do: "Untitled " <> label(@item["kind"]), else: @item["title"])}</strong><span class="spec-object-state" data-state={@item["state"]}>{label(@item["state"])}</span><small :if={@item["priority"] != "unspecified"}>{label(@item["priority"])}</small><small :if={@item["rows"] != []}>{length(@item["rows"])} {String.downcase(Object.row_label(@item["kind"]))}</small></summary>
      <div class="spec-object-editor">
        <header class="spec-object-heading">
          <label class="specification-title"><span>Name</span><input id={@id <> "-title"} name={@base <> "[title]"} value={@item["title"]} maxlength="256" /></label>
          <label><span>Design state</span><select id={@id <> "-state"} name={@base <> "[state]"}><option :for={state <- Object.states()} value={state} selected={state == @item["state"]}>{label(state)}</option></select></label>
          <label><span>Priority</span><select id={@id <> "-priority"} name={@base <> "[priority]"}><option :for={priority <- Object.priorities()} value={priority} selected={priority == @item["priority"]}>{label(priority)}</option></select></label>
          <input id={@id <> "-kind"} type="hidden" name={@base <> "[kind]"} value={@item["kind"]} />
          <button type="button" class="button button-small" phx-click="spec-remove-item" phx-value-project={@project} phx-value-section={@section} phx-value-id={@item["id"]} aria-label={"Remove " <> @item["title"]}>Remove</button>
        </header>
        <label class="spec-object-summary"><span>Summary</span><textarea id={@id <> "-body"} name={@base <> "[body]"} rows="2" maxlength="24000">{@item["body"]}</textarea></label>
        <div class="spec-object-properties">
          <.field :for={field <- @fields} field={field} value={@item["attributes"][field.key]} name={@base <> "[attributes][#{field.key}]"} id={@id <> "-attributes-" <> field.key} objects={@objects} project={@project} />
        </div>
        <.members :for={group <- ~w(rows links sources)} :if={Object.row_fields(@item["kind"], group) != []} item={@item} group={group} base={@base} id={@id} project={@project} section={@section} objects={@objects} />
        <details id={@id <> "-notes-disclosure"} class="spec-object-notes" data-spec-disclosure><summary>Notes {if(@item["notes"] != "", do: "· original content retained")}</summary><label><span>Supporting notes / original import</span><textarea id={@id <> "-notes"} name={@base <> "[notes]"} rows="4" maxlength="24000">{@item["notes"]}</textarea></label></details>
      </div>
    </details>
    """
  end

  attr(:item, :map, required: true)
  attr(:group, :string, required: true)
  attr(:base, :string, required: true)
  attr(:id, :string, required: true)
  attr(:project, :string, required: true)
  attr(:section, :string, required: true)
  attr(:objects, :list, required: true)

  @spec members(map()) :: Phoenix.LiveView.Rendered.t()
  def members(assigns) do
    title =
      case assigns.group do
        "rows" -> Object.row_label(assigns.item["kind"])
        "links" -> "Linked objects"
        "sources" -> "Sources"
      end

    assigns = assign(assigns, fields: Object.row_fields(assigns.item["kind"], assigns.group), title: title)

    ~H"""
    <section class={"spec-object-members spec-object-" <> @group} aria-label={@title}>
      <header :if={@group == "rows"}><h4>{@title}</h4><.add_member item={@item} group={@group} project={@project} section={@section} title={@title} /></header>
      <.member_table :if={@group == "rows"} item={@item} group={@group} base={@base} id={@id} project={@project} section={@section} objects={@objects} fields={@fields} title={@title} />
      <details :if={@group != "rows"} id={@id <> "-" <> @group <> "-disclosure"} data-spec-disclosure class="spec-object-meta"><summary>{@title} ({length(@item[@group])})</summary><header><.add_member item={@item} group={@group} project={@project} section={@section} title={@title} /></header><.member_table item={@item} group={@group} base={@base} id={@id} project={@project} section={@section} objects={@objects} fields={@fields} title={@title} /></details>
      <p :if={@group == "sources" and @item[@group] != []} class="spec-object-source-links"><a :for={source <- @item[@group]} :if={Object.safe_url?(source["url"])} href={source["url"]} target="_blank" rel="noopener noreferrer">{if(source["label"] == "", do: "Source", else: source["label"])} ↗</a></p>
    </section>
    """
  end

  attr(:item, :map, required: true)
  attr(:group, :string, required: true)
  attr(:project, :string, required: true)
  attr(:section, :string, required: true)
  attr(:title, :string, required: true)
  @spec add_member(map()) :: Phoenix.LiveView.Rendered.t()
  def add_member(assigns) do
    ~H"""
    <button type="button" class="button button-small" phx-click="spec-add-member" phx-value-project={@project} phx-value-section={@section} phx-value-id={@item["id"]} phx-value-group={@group} aria-label={"Add " <> String.downcase(@title) <> " to " <> @item["title"]}>+ Add</button>
    """
  end

  attr(:item, :map, required: true)
  attr(:group, :string, required: true)
  attr(:base, :string, required: true)
  attr(:id, :string, required: true)
  attr(:project, :string, required: true)
  attr(:section, :string, required: true)
  attr(:objects, :list, required: true)
  attr(:fields, :list, required: true)
  attr(:title, :string, required: true)
  @spec member_table(map()) :: Phoenix.LiveView.Rendered.t()
  def member_table(assigns) do
    ~H"""
      <div :if={@item[@group] != []} class="spec-object-table-scroll"><table class="spec-object-table"><thead><tr><th :for={field <- @fields}>{field.label}</th><th><span class="sr-only">Actions</span></th></tr></thead><tbody>
        <tr :for={row <- @item[@group]} data-spec-member-id={row["id"]}>
          <td :for={field <- @fields}><.field field={field} value={row[field.key]} name={@base <> "[#{@group}][#{row["id"]}][#{field.key}]"} id={@id <> "-" <> @group <> "-" <> row["id"] <> "-" <> field.key} objects={@objects} project={@project} compact /></td>
          <td><button type="button" class="button button-small spec-remove-member" phx-click="spec-remove-member" phx-value-project={@project} phx-value-section={@section} phx-value-id={@item["id"]} phx-value-group={@group} phx-value-row_id={row["id"]} aria-label={"Remove " <> @title <> " row"}>×</button></td>
        </tr>
      </tbody></table></div>
    """
  end

  attr(:field, :map, required: true)
  attr(:value, :any, required: true)
  attr(:name, :string, required: true)
  attr(:id, :string, required: true)
  attr(:objects, :list, required: true)
  attr(:project, :string, required: true)
  attr(:compact, :boolean, default: false)

  @spec field(map()) :: Phoenix.LiveView.Rendered.t()
  def field(assigns) do
    options = if assigns.field.type == :reference, do: Enum.filter(assigns.objects, &(assigns.field.kinds == :all or &1["kind"] in assigns.field.kinds)), else: []
    target = Enum.find(options, &(&1["id"] == assigns.value))
    assigns = assign(assigns, options: options, target: target)

    ~H"""
    <label class={if(@compact, do: "spec-table-field", else: "spec-property-field")}>
      <span class={if(@compact, do: "sr-only", else: nil)}>{@field.label}</span>
      <select :if={@field.type == :choice} id={@id} name={@name}><option :for={option <- @field.options} value={option} selected={option == @value}>{label(option)}</option></select>
      <select :if={@field.type == :reference} id={@id} name={@name}><option value="">—</option><option :for={object <- @options} value={object["id"]} selected={object["id"] == @value}>{object["title"]} · {label(object["kind"])}</option></select>
      <input :if={@field.type in [:url, :number] or (@field.type == :text and @field.limit <= 512)} id={@id} name={@name} value={@value} type={if(@field.type == :number, do: "number", else: if(@field.type == :url, do: "url", else: "text"))} step={if(@field.type == :number, do: "any")} maxlength={Map.get(@field, :limit)} title={if(is_binary(@value), do: @value)} />
      <textarea :if={@field.type == :text and @field.limit > 512} id={@id} name={@name} rows={if(@compact, do: "1", else: "2")} maxlength={@field.limit}>{@value}</textarea>
    </label>
    <button :if={@target} type="button" class="spec-object-link" phx-click="spec-object" phx-value-project={@project} phx-value-id={@target["id"]} aria-label={"Open " <> @target["title"]}>{@target["title"]} ↗</button>
    """
  end

  @spec label(String.t()) :: String.t()
  def label("nonfunctional"), do: "Non-functional"
  def label("unspecified"), do: "—"
  def label("none"), do: "—"
  def label(value), do: value |> String.replace("_", " ") |> String.capitalize()
end
