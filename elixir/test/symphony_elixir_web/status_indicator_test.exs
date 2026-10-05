defmodule SymphonyElixirWeb.StatusIndicatorTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.StatusIndicator

  test "disclosure remains keyboard operable without hooks and escapes source text" do
    html = render_component(&StatusIndicator.indicator/1, %{id: "task-info", title: "Outcome", detail: "<script>unsafe</script>"})
    document = Floki.parse_fragment!(html)
    trigger = Floki.find(document, "button")
    detail = Floki.find(document, "[popover=auto]")
    assert Floki.attribute(trigger, "popovertarget") == Floki.attribute(detail, "id")
    assert Floki.attribute(trigger, "aria-describedby") == Floki.attribute(detail, "id")
    assert Floki.attribute(trigger, "aria-expanded") == []
    assert Floki.attribute(trigger, "aria-label") == ["Outcome: show details"]
    assert Floki.attribute(detail, "role") == ["tooltip"]
    assert Floki.text(detail) =~ "<script>unsafe</script>"
    assert Floki.find(document, "script") == []
    assert Floki.find(document, "[phx-click]") == []
  end

  test "warning labels stay visible while the explanation lives only in the popover" do
    html =
      render_component(&StatusIndicator.indicator/1, %{
        id: "task-warning",
        title: "Limit reached",
        label: "Attempts exhausted",
        detail: "Resolve the original failure before retrying.",
        tone: "warning"
      })

    document = Floki.parse_fragment!(html)
    assert Floki.text(Floki.find(document, "button")) == "Attempts exhausted"
    assert Floki.text(Floki.find(document, "[popover=auto]")) =~ "Resolve the original failure"
    assert Floki.attribute(Floki.find(document, "[phx-hook]"), "data-tone") == ["warning"]
  end
end
