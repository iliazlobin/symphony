defmodule SymphonyElixir.BrowserSignInUITest do
  use SymphonyElixir.TestSupport

  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.{BrowserLoginHTML, ChatPanel, SettingsPanel}

  setup do
    previous_secret = System.get_env("SYMPHONY_TEST_GOOGLE_UI_SECRET")
    System.put_env("SYMPHONY_TEST_GOOGLE_UI_SECRET", "fixture-secret")
    on_exit(fn -> restore_env("SYMPHONY_TEST_GOOGLE_UI_SECRET", previous_secret) end)
    :ok
  end

  test "the standalone login keeps error text escaped and contains only the Google sign-in form" do
    html = render_component(&BrowserLoginHTML.render/1, %{csrf_token: "fixture-csrf", error: "<script>untrusted</script>"})
    document = Floki.parse_document!(html)
    assert html =~ "Sign in to Symphony"
    assert html =~ "&lt;script&gt;untrusted&lt;/script&gt;"
    assert Floki.find(document, "script") == []
    assert Floki.find(document, ~s(form[action="/auth/google"][method="post"])) != []
    assert Floki.attribute(document, ~s(input[name="return_to"]), "value") == ["/"]
    assert Floki.attribute(document, ~s(input[name="_csrf_token"]), "value") == ["fixture-csrf"]
    refute html =~ "operator_token"

    clean = render_component(&BrowserLoginHTML.render/1, %{csrf_token: "fixture-csrf", error: nil})
    assert Floki.find(Floki.parse_document!(clean), ~s([role="alert"])) == []
  end

  test "Google chat sign-in posts CSRF and a local return location without a token field" do
    configure("google")

    for {embedded, destination} <- [{true, "/?assistant=1"}, {false, "/chat"}] do
      html = chat_html(embedded)
      document = Floki.parse_document!(html)
      assert Floki.find(document, ~s(form[action="/auth/google"][method="post"])) != []
      assert Floki.attribute(document, ~s(input[name="_csrf_token"]), "value") == ["fixture-csrf"]
      assert Floki.attribute(document, ~s(input[name="return_to"]), "value") == [destination]
      assert html =~ "Sign in with Google"
      refute html =~ "Operator token"
      refute html =~ "Unlock chat"
      assert Floki.find(document, ~s(input[name="operator_token"])) == []
    end
  end

  test "Google settings permit sign-out even when project controls are read-only" do
    configure("google")
    html = settings_html()
    assert html =~ "Sign in with Google"
    assert html =~ ~s(action="/auth/google")
    assert html =~ ~s(value="/?panel=settings")
    refute html =~ "Operator token"
    refute html =~ ~s(action="/operator/session")

    signed_in = settings_html(authorized: true)
    assert signed_in =~ "Signed in to Symphony with Google."
    assert signed_in =~ "Sign out"
    assert signed_in =~ ~s(action="/operator/session/logout")
    refute signed_in =~ "Lock controls"

    read_only_session = settings_html(authorized: true, read_only: true)
    assert read_only_session =~ "Sign out"
    assert read_only_session =~ ~s(action="/operator/session/logout")

    preview = settings_html(read_only: true)
    refute preview =~ ~s(action="/auth/google")
    refute preview =~ ~s(action="/operator/session/logout")
  end

  test "both Settings providers submit the current scoped return location" do
    destination = "/projects/events-concierge/?view=design&priority=P1&chat_task=task&panel=settings"

    for {provider, action} <- [{"google", "/auth/google"}, {"local_token", "/operator/session"}] do
      configure(provider)
      document = settings_html(return_to: destination) |> Floki.parse_document!()
      assert Floki.attribute(document, "form[action='#{action}'] input[name='return_to']", "value") == [destination]
    end
  end

  test "the legacy local provider retains its token forms and labels" do
    configure("local_token")
    chat = chat_html(false)
    settings = settings_html()
    assert chat =~ "Unlock chat"
    assert chat =~ ~s(action="/operator/session")
    assert chat =~ ~s(name="operator_token")
    assert settings =~ "Unlock local controls"
    assert settings =~ ~s(name="operator_token")
    assert settings_html(authorized: true) =~ "Lock controls"
    refute chat =~ "Sign in with Google"
    refute settings =~ ~s(action="/auth/google")
  end

  defp configure(provider) do
    browser_auth = %{
      provider: provider,
      public_origin: "http://localhost:8778",
      client_id: "fixture-client.apps.googleusercontent.com",
      client_secret: "$SYMPHONY_TEST_GOOGLE_UI_SECRET",
      allowed_emails: ["owner@gmail.com"]
    }

    config = %{tracker: %{kind: "memory"}, browser_auth: browser_auth}
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nFixture")
    :ok = WorkflowStore.force_reload()
  end

  defp chat_html(embedded) do
    {:ok, socket} = ChatPanel.mount(%Phoenix.LiveView.Socket{})

    assigns =
      Map.merge(socket.assigns, %{
        embedded: embedded,
        loading: false,
        csrf_token: "fixture-csrf",
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      })

    render_component(&ChatPanel.render/1, assigns)
  end

  defp settings_html(overrides \\ []) do
    assigns = %{
      board: %{projects: []},
      read_only: false,
      authorized: false,
      tab: "connections",
      execution_status: "Paused",
      can_control: false,
      settings: %{},
      can_edit: false,
      settings_available: false,
      project_id: nil,
      loading: false,
      source_status: "Available",
      chat_health: "Available",
      csrf_token: "fixture-csrf",
      total_tokens: "0",
      runtime_duration: "0 min",
      rate_limits: "Not reported"
    }

    render_component(&SettingsPanel.content/1, Map.merge(assigns, Map.new(overrides)))
  end
end
