defmodule SymphonyElixirWeb.StaticAssetsTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  alias SymphonyElixirWeb.{Endpoint, StaticAssets}
  @endpoint Endpoint

  setup do
    previous = Application.get_env(:symphony_elixir, Endpoint, [])
    Application.put_env(:symphony_elixir, Endpoint, server: false, secret_key_base: String.duplicate("c", 64))
    start_supervised!({Endpoint, []})
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, previous) end)
    :ok
  end

  test "all locally bundled editor chunks and fonts are embedded in the application" do
    paths = StaticAssets.design_editor_paths()
    assert length(paths) > 200
    assert Enum.any?(paths, &String.ends_with?(&1, ".woff2"))
    assert Enum.any?(paths, &String.ends_with?(&1, ".css"))
    assert Enum.any?(paths, &String.contains?(&1, "/chunks/"))

    Enum.each(paths, fn path ->
      assert {:ok, content_type, bytes} = StaticAssets.fetch(path)
      assert content_type in ["application/javascript", "text/css", "font/woff2", "text/plain"]
      assert byte_size(bytes) > 0
    end)

    assert {:ok, "application/javascript", _} = StaticAssets.fetch(StaticAssets.design_editor_js_url())
    assert {:ok, "text/css", _} = StaticAssets.fetch(StaticAssets.design_editor_css_url())
  end

  test "editor routes serve only generated allowlisted bytes" do
    javascript = StaticAssets.design_editor_js_url()
    font = Enum.find(StaticAssets.design_editor_paths(), &String.ends_with?(&1, ".woff2"))

    for path <- [javascript, font] do
      assert {:ok, _type, bytes} = StaticAssets.fetch(path)
      conn = get(build_conn(), path)
      assert response(conn, 200) == bytes
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["public, max-age=31536000"]
    end

    for path <- ["/design-editor/missing.js", "/design-editor/manifest.json", "/design-editor/package.json"] do
      assert response(get(build_conn(), path), 404) == "Not Found"
      assert StaticAssets.fetch(path) == :error
    end
  end
end
