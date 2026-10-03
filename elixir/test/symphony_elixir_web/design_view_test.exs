defmodule SymphonyElixirWeb.DesignViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.DesignView

  test "a new project starts with a brief and an accessible compact design outline" do
    html = render_component(&DesignView.content/1, project: "iliazlobin/sample", project_label: "Sample")

    assert Floki.attribute(find(html, "[data-design-project]"), "data-design-project") == ["iliazlobin/sample"]
    assert Floki.attribute(find(html, "[data-design-project]"), "aria-label") == ["Sample design workspace"]
    assert length(find(html, "[role=tab]")) == 5
    assert length(find(html, "[role=tabpanel]")) == 5
    assert Floki.attribute(find(html, "[role=tab][aria-selected=true]"), "aria-controls") == ["design-panel-brief"]
    assert find(html, "#design-panel-brief[hidden]") == []
    assert length(find(html, "[role=tabpanel][hidden]")) == 4
    assert Floki.text(find(html, "#design-panel-brief h3")) == "What are we designing?"
    assert html =~ "Publishing and task creation are separate steps"
    assert Floki.text(find(html, "[data-design-storage-label]")) == "Browser draft"
    refute html =~ "saved in this browser"
    assert find(html, "[data-design-example]") == []
    assert find(html, "form") == []

    for tab <- find(html, "[role=tab]") do
      [panel_id] = Floki.attribute([tab], "aria-controls")
      [tab_id] = Floki.attribute([tab], "id")
      assert Floki.attribute(find(html, "##{panel_id}"), "aria-labelledby") == [tab_id]
    end
  end

  test "requirements, data and architecture retain a labelled editable working outline" do
    html = render_component(&DesignView.content/1, project: "iliazlobin/sample")
    fields = find(html, "textarea[data-design-field]")

    assert length(fields) == 7
    assert Floki.text(find(html, "label")) =~ "Functional requirements"
    assert Floki.text(find(html, "label")) =~ "Quality requirements"
    assert Floki.text(find(html, "label")) =~ "Entities and relationships"
    assert Floki.text(find(html, "label")) =~ "Main flows"
    assert html =~ "unknown"
    assert html =~ "important failure path"

    for field <- fields do
      [id] = Floki.attribute([field], "id")
      [hint_id] = Floki.attribute([field], "aria-describedby")
      assert length(find(html, "label[for='#{id}']")) == 1
      assert length(find(html, "##{hint_id}")) == 1
      assert Floki.attribute([field], "maxlength") == ["12000"]
      assert Floki.text([field]) == ""
    end

    assert find(html, "[phx-click]") == []
    assert find(html, "input[type=submit]") == []
    assert length(find(html, "[data-design-prompt]")) == 7
  end

  test "the Events Concierge starter is explicitly illustrative and scoped to that project" do
    html = render_component(&DesignView.content/1, project: "github:iliazlobin/events-concierge")
    assert Floki.text(find(html, "[data-design-example]")) == "Add example"
    assert html =~ "illustrative Events Concierge assumptions"
    assert html =~ "Fills empty fields only"
    assert Floki.text(find(html, ".design-footnote")) =~ "not an approved design"

    for project <- ["iliazlobin/events-concierge-other", "iliazlobin/symphony", "other"] do
      html = render_component(&DesignView.content/1, project: project)
      assert find(html, "[data-design-example]") == []
    end
  end

  test "published design navigation allows only HTTPS Notion destinations" do
    url = "https://app.notion.com/p/3ebd865005a881acbbc1cc9799077ef4"
    html = render_component(&DesignView.content/1, project: "iliazlobin/symphony", notion_url: url)
    assert Floki.attribute(find(html, "a"), "href") == [url]
    assert Floki.attribute(find(html, "a"), "rel") == ["noopener noreferrer"]
    assert Floki.text(find(html, "a")) == "Published design ↗"

    for url <- [nil, "javascript:alert('x')", "http://app.notion.com/p/test", "https://evil.example/test"] do
      html = render_component(&DesignView.content/1, project: "iliazlobin/symphony", notion_url: url)
      assert find(html, "a") == []
    end

    for host <- ["www.notion.so", "notion.so"] do
      url = "https://#{host}/test"
      html = render_component(&DesignView.content/1, project: "iliazlobin/symphony", notion_url: url)
      assert Floki.attribute(find(html, "a"), "href") == [url]
    end
  end

  test "project names remain escaped and do not insert markup" do
    project = "<script>alert('x')</script>"
    html = render_component(&DesignView.content/1, project: project, project_label: project)
    assert html =~ "&lt;script&gt;"
    assert find(html, "script") == []
    assert Floki.attribute(find(html, "[data-design-project]"), "data-design-project") == [project]
    assert Floki.attribute(find(html, "[data-design-project]"), "aria-label") == ["#{project} design workspace"]
  end

  test "switching projects remounts browser-owned content without carrying old navigation or fields" do
    first = render_component(&DesignView.content/1, project: "iliazlobin/sample")
    again = render_component(&DesignView.content/1, project: "iliazlobin/sample")
    other = render_component(&DesignView.content/1, project: "iliazlobin/another")
    first_id = Floki.attribute(find(first, "[data-design-project]"), "id")

    assert first_id == Floki.attribute(find(again, "[data-design-project]"), "id")
    refute first_id == Floki.attribute(find(other, "[data-design-project]"), "id")
    assert [id] = first_id
    assert String.starts_with?(id, "design-workspace-")
    assert Floki.attribute(find(first, "[data-design-project]"), "phx-update") == ["ignore"]
  end

  defp find(html, selector), do: html |> Floki.parse_fragment!() |> Floki.find(selector)
end
