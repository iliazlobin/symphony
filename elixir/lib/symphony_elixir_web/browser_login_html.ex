defmodule SymphonyElixirWeb.BrowserLoginHTML do
  @moduledoc "Google browser sign-in without project data or client-side credentials."
  use Phoenix.Component

  alias SymphonyElixirWeb.StaticAssets

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns = assigns |> Map.put_new(:login_url, nil) |> Map.put_new(:continue, false)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Sign in · Symphony</title>
        <link rel="icon" type="image/png" sizes="128x128" href={StaticAssets.favicon_url()} />
        <link rel="stylesheet" href={StaticAssets.dashboard_css_url()} />
        <script :if={@continue} defer src={StaticAssets.browser_login_js_url()}></script>
      </head>
      <body>
        <main class="chat-shell">
          <section class="chat-empty chat-login" aria-labelledby="sign-in-title">
            <span class="chat-orbit" aria-hidden="true">∿</span>
            <h1 id="sign-in-title">{if @continue, do: "Opening your project…", else: "Sign in to Symphony"}</h1>
            <p>{if @continue, do: "Continuing with your Google session.", else: "Use your authorized Google account to view projects and manage work."}</p>
            <p :if={@error} class="board-warning" role="alert">{@error}</p>
            <a :if={@login_url} href={@login_url} class="button button-primary">Continue to Symphony</a>
            <form :if={is_nil(@login_url)} action={SymphonyElixirWeb.WorkspacePath.path("/auth/google")} method="post" class="chat-login-form" data-continue={@continue && "true"}>
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <input type="hidden" name="return_to" value="/" />
              <input :if={@continue} type="hidden" name="continue" value="1" />
              <button class="button button-primary">Sign in with Google</button>
            </form>
          </section>
        </main>
      </body>
    </html>
    """
  end
end
