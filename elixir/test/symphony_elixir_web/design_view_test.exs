defmodule SymphonyElixirWeb.DesignViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.DesignView

  test "Idea retains five vertical steps and one accessible whiteboard" do
    html = render_component(&DesignView.content/1, project: "iliazlobin/sample", project_label: "Sample")
    assert Floki.text(find(html, "h2")) == "Idea"
    assert Floki.attribute(find(html, "[data-design-project]"), "aria-label") == ["Sample idea workspace"]
    assert Floki.attribute(find(html, "[data-design-project]"), "phx-hook") == ["DesignWorkspace"]
    assert Floki.attribute(find(html, "[data-design-project]"), "data-design-durable") == ["true"]
    assert length(find(html, "[role=tab]")) == 5
    assert Floki.attribute(find(html, "[role=tablist]"), "aria-orientation") == ["vertical"]
    assert length(find(html, "[role=tabpanel]")) == 1
    assert Floki.attribute(find(html, "[role=tabpanel]"), "aria-labelledby") == ["design-tab-brief"]
    assert length(find(html, "[data-design-canvas]")) == 1
    assert Floki.attribute(find(html, "[data-design-canvas]"), "tabindex") == ["0"]
    assert Floki.text(find(html, "[data-design-storage-label]")) == "Opening saved idea…"
    refute html =~ "saved in this browser"
    assert find(html, "form") == []

    for tab <- find(html, "[role=tab]") do
      assert Floki.attribute([tab], "aria-controls") == ["design-canvas-panel"]
    end
  end

  test "existing draft fields are retained outside the visual workspace with focused editing tools" do
    html = render_component(&DesignView.content/1, project: "iliazlobin/sample")
    assert length(find(html, ".design-source-fields[hidden] textarea[data-design-field]")) == 7
    assert find(html, ".design-editor textarea") == []
    assert find(html, "[data-canvas-tool]") == []
    assert find(html, "[data-canvas-action]") == []
    assert [url] = Floki.attribute(find(html, "[data-design-editor-js]"), "data-design-editor-js")
    assert url =~ "/design-editor/"
    assert [css] = Floki.attribute(find(html, "[data-design-editor-css]"), "data-design-editor-css")
    assert css =~ ".css"
    assert length(find(html, "[data-design-feedback]")) == 1
    assert length(find(html, "[data-canvas-suggestions][hidden]")) == 1
    assert find(html, "[phx-click]") == []
  end

  test "the Events Concierge starter is explicitly illustrative and scoped to that project" do
    html = render_component(&DesignView.content/1, project: "github:iliazlobin/events-concierge")
    assert Floki.text(find(html, "[data-design-example]")) == "Add example"

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
    assert Floki.text(find(html, "a")) == "Project design notes ↗"

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
    assert Floki.attribute(find(html, "[data-design-project]"), "aria-label") == ["#{project} idea workspace"]
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
