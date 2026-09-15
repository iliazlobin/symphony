defmodule SymphonyElixirWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.Markdown

  test "renders Markdown structure, entities and literal code" do
    document =
      parse("""
      ## Outcome

      **Bold** and *emphasis* with ~~removed~~ text &amp; entities.

      - First
        - Nested
      - Second with `a < b && &amp;`

      3. Third
      4. Fourth

      > Quote

      ```elixir
      <script>&amp;</script>
      ```

      | Name | State |
      | --- | --- |
      | Build | Ready |

      ---

      Line one#{"  "}
      Line two
      """)

    assert text(document, "h2") == "Outcome"
    assert text(document, "strong") == "Bold"
    assert text(document, "em") == "emphasis"
    assert text(document, "del") == "removed"
    assert text(document, "p") =~ "text & entities"
    assert text(document, "ul ul li") == "Nested"
    assert text(document, "li code") == "a < b && &amp;"
    assert Floki.attribute(document, "ol", "start") == ["3"]
    assert text(document, "blockquote") == "Quote"
    assert text(document, "pre code") == "<script>&amp;</script>"
    assert text(document, "table th") == "NameState"
    assert text(document, "table td") == "BuildReady"
    assert length(Floki.find(document, "hr")) == 1
    assert length(Floki.find(document, "br")) == 1
    assert Floki.find(document, "script") == []
  end

  test "links open safely without replacing the board, and images remain text" do
    document =
      parse("""
      [Draft PR](https://github.com/example/repo/pull/7?a=1&amp;b=2)
      [Docs](http://example.com/docs)
      [Email](mailto:user@example.com)
      ![R&D <diagram>](https://example.com/tracker.png)
      """)

    assert Floki.attribute(document, "a", "href") == [
             "https://github.com/example/repo/pull/7?a=1&b=2",
             "http://example.com/docs",
             "mailto:user@example.com"
           ]

    assert Floki.attribute(document, "a", "target") == List.duplicate("_blank", 3)
    assert Floki.attribute(document, "a", "rel") == List.duplicate("noopener noreferrer", 3)
    assert text(document, "p") =~ "R&D <diagram>"
    assert Floki.find(document, "img, diagram") == []
  end

  test "issue content cannot inject scripts, HTML controls or LiveView attributes" do
    document =
      parse("""
      <script>alert(1)</script>
      <svg onload="alert(1)"><a href="javascript:alert(1)">svg</a></svg>
      <form action="/operator/session/logout"><input name="_csrf_token"></form>
      <iframe src="https://example.com"></iframe>
      <!-- hidden comment -->

      [Safe](https://example.com){:phx-click="confirm-command" data-phx-link="redirect" onclick="alert(1)"}

      ## Heading
      {: #board-dialog .spoof phx-hook="TaskBoard" style="position:fixed"}

      1. Item
      {:start="bad"}
      """)

    assert Floki.find(document, "script, svg, form, input, iframe, button") == []
    assert Floki.find(document, "[phx-click], [phx-hook], [data-phx-link], [onclick], [style], [id], [class]") == []
    assert text(document, "a") == "Safe"
    refute Floki.text(document) =~ "hidden comment"
    assert Floki.attribute(document, "ol", "start") == []

    for href <- [
          "javascript:alert%281%29",
          "javas&#99;ript:alert%281%29",
          "javascript&#58;alert%281%29",
          "java&#9;script:alert%281%29",
          "vbscript:run",
          "data:text/html;base64,abc",
          "//example.com",
          "/operator/session/logout",
          "../README.md",
          "https:",
          "mailto:",
          "https://example.com/&#10;bad",
          "https://example.com/&#92;bad"
        ] do
      rendered = parse("[Link](#{href})")
      assert Floki.find(rendered, "a") == [], href
      assert Floki.text(rendered) =~ "Link"
    end
  end

  test "missing descriptions have a fallback and incomplete Markdown remains readable" do
    for source <- [nil, "", " \n\t"] do
      assert text(parse(source), "p") == "No description available."
    end

    assert text(parse("```\nunfinished <code>"), "pre code") == "unfinished <code>"
  end

  defp parse(source), do: source |> Markdown.render() |> Phoenix.HTML.safe_to_string() |> Floki.parse_fragment!()
  defp text(document, selector), do: document |> Floki.find(selector) |> Floki.text() |> String.trim()
end
