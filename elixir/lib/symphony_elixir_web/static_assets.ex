defmodule SymphonyElixirWeb.StaticAssets do
  @moduledoc false

  @dashboard_css_path Path.expand("../../priv/static/dashboard.css", __DIR__)
  @dashboard_js_path Path.expand("../../priv/static/dashboard.js", __DIR__)
  @design_canvas_js_path Path.expand("../../priv/static/design-canvas.js", __DIR__)
  @design_canvas_css_path Path.expand("../../priv/static/design-canvas.css", __DIR__)
  @browser_login_js_path Path.expand("../../priv/static/browser-login.js", __DIR__)
  @favicon_path Path.expand("../../priv/static/favicon.png", __DIR__)
  @phoenix_html_js_path Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @phoenix_js_path Application.app_dir(:phoenix, "priv/static/phoenix.js")
  @phoenix_live_view_js_path Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.js")
  @design_editor_path Path.expand("../../priv/static/design-editor", __DIR__)
  @design_editor_manifest_path Path.join(@design_editor_path, "manifest.json")

  @external_resource @dashboard_css_path
  @external_resource @dashboard_js_path
  @external_resource @design_canvas_js_path
  @external_resource @design_canvas_css_path
  @external_resource @browser_login_js_path
  @external_resource @favicon_path
  @external_resource @phoenix_html_js_path
  @external_resource @phoenix_js_path
  @external_resource @phoenix_live_view_js_path
  @external_resource @design_editor_manifest_path

  @design_editor_manifest_bytes File.read!(@design_editor_manifest_path)
  @design_editor_manifest Jason.decode!(@design_editor_manifest_bytes)
  @design_editor_digest :crypto.hash(:sha256, @design_editor_manifest_bytes)
                        |> Base.encode16(case: :lower)
                        |> binary_part(0, 12)
  @design_editor_base "/design-editor/#{@design_editor_digest}/"

  for {source, expected_digest} <- @design_editor_manifest["sources"] do
    source_path = Path.expand("../../assets/#{source}", __DIR__)
    @external_resource source_path
    actual_digest = source_path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    if actual_digest != expected_digest do
      raise "Design editor assets are stale; run npm ci --ignore-scripts && npm run build in elixir/assets."
    end
  end

  @design_editor_assets Map.new(@design_editor_manifest["assets"], fn {asset, details} ->
                          asset_path = Path.join(@design_editor_path, asset)
                          bytes = File.read!(asset_path)
                          actual_digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

                          if actual_digest != details["sha256"] do
                            raise "Generated design editor asset changed: #{asset}"
                          end

                          {@design_editor_base <> asset, {details["type"], bytes}}
                        end)

  for asset <- Map.keys(@design_editor_manifest["assets"]) do
    @external_resource Path.join(@design_editor_path, asset)
  end

  @dashboard_css File.read!(@dashboard_css_path) <> "\n" <> File.read!(@design_canvas_css_path)
  @dashboard_css_digest :crypto.hash(:sha256, @dashboard_css)
                        |> Base.encode16(case: :lower)
                        |> binary_part(0, 12)
  @dashboard_js File.read!(@design_canvas_js_path) <> "\n" <> File.read!(@dashboard_js_path)
  @dashboard_js_digest :crypto.hash(:sha256, @dashboard_js) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  @browser_login_js File.read!(@browser_login_js_path)
  @browser_login_js_digest :crypto.hash(:sha256, @browser_login_js) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  @favicon File.read!(@favicon_path)
  @favicon_digest :crypto.hash(:sha256, @favicon)
                  |> Base.encode16(case: :lower)
                  |> binary_part(0, 12)
  @phoenix_html_js File.read!(@phoenix_html_js_path)
  @phoenix_js File.read!(@phoenix_js_path)
  @phoenix_live_view_js File.read!(@phoenix_live_view_js_path)

  @assets Map.merge(@design_editor_assets, %{
            "/dashboard.js" => {"application/javascript", @dashboard_js},
            "/browser-login.js" => {"application/javascript", @browser_login_js},
            "/dashboard.css" => {"text/css", @dashboard_css},
            "/favicon.png" => {"image/png", @favicon},
            "/vendor/phoenix_html/phoenix_html.js" => {"application/javascript", @phoenix_html_js},
            "/vendor/phoenix/phoenix.js" => {"application/javascript", @phoenix_js},
            "/vendor/phoenix_live_view/phoenix_live_view.js" => {"application/javascript", @phoenix_live_view_js}
          })

  @spec design_editor_js_url() :: String.t()
  def design_editor_js_url, do: SymphonyElixirWeb.WorkspacePath.path(@design_editor_base <> @design_editor_manifest["entry"]["js"])

  @spec design_editor_css_url() :: String.t()
  def design_editor_css_url, do: SymphonyElixirWeb.WorkspacePath.path(@design_editor_base <> @design_editor_manifest["entry"]["css"])

  @spec design_editor_asset_path() :: String.t()
  def design_editor_asset_path, do: SymphonyElixirWeb.WorkspacePath.path(@design_editor_base)

  @spec design_editor_paths() :: [String.t()]
  def design_editor_paths, do: @design_editor_assets |> Map.keys() |> Enum.sort()

  @spec dashboard_css_url() :: String.t()
  def dashboard_css_url, do: SymphonyElixirWeb.WorkspacePath.path("/dashboard.css?v=#{@dashboard_css_digest}")

  @spec dashboard_js_url() :: String.t()
  def dashboard_js_url, do: SymphonyElixirWeb.WorkspacePath.path("/dashboard.js?v=#{@dashboard_js_digest}")

  @spec browser_login_js_url() :: String.t()
  def browser_login_js_url, do: SymphonyElixirWeb.WorkspacePath.path("/browser-login.js?v=#{@browser_login_js_digest}")

  @spec favicon_url() :: String.t()
  def favicon_url, do: SymphonyElixirWeb.WorkspacePath.path("/favicon.png?v=#{@favicon_digest}")

  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | :error
  def fetch(path) when is_binary(path) do
    case Map.fetch(@assets, path) do
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      :error -> :error
    end
  end
end
