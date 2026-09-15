defmodule SymphonyElixirWeb.Markdown do
  @moduledoc "Renders task Markdown with a fixed set of inert HTML elements."

  alias Phoenix.HTML

  @tags ~w(p h1 h2 h3 h4 h5 h6 ul ol li blockquote pre code strong em del table thead tbody tr th td a img br hr)

  @spec render(String.t() | nil) :: {:safe, iodata()}
  def render(markdown) do
    source = if is_nil(markdown) || String.trim(markdown) == "", do: "No description available.", else: markdown
    {_status, nodes, _messages} = EarmarkParser.as_ast(source, gfm_tables: true)
    {:safe, Enum.map(nodes, &render_node/1)}
  end

  defp render_node(text) when is_binary(text), do: text |> HtmlEntities.decode() |> escaped()
  defp render_node({:comment, _, _, _}), do: []

  defp render_node({tag, attrs, children, meta}) do
    if meta[:verbatim] || tag not in @tags do
      Enum.map(children, &render_node/1)
    else
      render_element(tag, attrs, children)
    end
  end

  defp render_element("a", attrs, children) do
    href = attrs |> attribute("href") |> HtmlEntities.decode()

    if safe_link?(href) do
      element("a", [href: href, target: "_blank", rel: "noopener noreferrer"], children)
    else
      Enum.map(children, &render_node/1)
    end
  end

  defp render_element("img", attrs, _), do: render_node(attribute(attrs, "alt"))
  defp render_element("code", _, children), do: ["<code>", Enum.map(children, &escaped/1), "</code>"]

  defp render_element("ol", attrs, children) do
    start = attribute(attrs, "start")
    attrs = if Regex.match?(~r/\A[0-9]{1,9}\z/, start), do: [start: start], else: []
    element("ol", attrs, children)
  end

  defp render_element(tag, _, _) when tag in ["br", "hr"], do: ["<", tag, ">"]
  defp render_element(tag, _, children), do: element(tag, [], children)

  # Never forward issue-supplied HTML/IAL attributes into the LiveView DOM.
  defp element(tag, attrs, children) do
    {:safe, attrs} = HTML.attributes_escape(attrs)
    ["<", tag, attrs, ">", Enum.map(children, &render_node/1), "</", tag, ">"]
  end

  defp attribute(attrs, name), do: attrs |> List.keyfind(name, 0, {name, ""}) |> elem(1)

  defp escaped(text) do
    {:safe, value} = HTML.html_escape(text)
    value
  end

  defp safe_link?(href) do
    uri = URI.parse(href)

    valid_destination =
      (uri.scheme in ["http", "https"] && is_binary(uri.host) && uri.host != "") ||
        (uri.scheme == "mailto" && is_binary(uri.path) && uri.path != "")

    valid_destination && !Regex.match?(~r/[\x00-\x20\x7f\\]/, href)
  end
end
