defmodule SymphonyElixir.ProjectDirectoryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Config.Schema, ProjectDirectory, Workflow}
  alias SymphonyElixir.Config.Schema.Server

  defp link(url \\ "http://localhost:8779/") do
    %{"id" => "github:iliazlobin/symphony", "label" => "Symphony", "url" => url}
  end

  test "directory accepts explicit HTTPS or loopback project origins" do
    assert ProjectDirectory.valid?([])

    for url <- ["http://localhost:8779/", "http://127.0.0.1:8779", "http://[::1]:8779/", "https://symphony.example.com/"] do
      assert ProjectDirectory.valid?([link(url)])
      assert Server.changeset(%Server{}, %{"project_links" => [link(url)]}).valid?
    end
  end

  test "rejects credentials, paths, unsafe schemes and unbounded or ambiguous entries" do
    for url <- [
          "http://[",
          "https://example.com|",
          "javascript:alert(1)",
          "//example.com",
          "http://example.com/",
          "http://localhost:0/",
          "http://localhost:65536/",
          "http://owner:secret@localhost:8779/",
          "http://localhost:8779/?token=x",
          "http://localhost:8779/#fragment",
          "http://localhost:8779/settings",
          " http://localhost:8779/",
          "http://localhost:8779/\n",
          "http://localhost\\@example.com:8779/",
          String.duplicate("x", 513)
        ] do
      refute ProjectDirectory.valid?([link(url)])
      refute Server.changeset(%Server{}, %{"project_links" => [link(url)]}).valid?
    end

    for entry <- [
          nil,
          %{},
          Map.put(link(), "id", "other"),
          Map.put(link(), "label", " "),
          Map.put(link(), "label", String.duplicate("x", 81)),
          Map.put(link(), "url", 1),
          Map.put(link(), "id", String.duplicate("x", 201)),
          Map.put(link(), "token", "forbidden")
        ] do
      refute ProjectDirectory.valid?([entry])
    end

    refute ProjectDirectory.valid?(nil)
    refute ProjectDirectory.valid?([link(), link("http://localhost:8780/")])
    refute ProjectDirectory.valid?([link(), Map.put(link(), "id", "github:example/other")])
    refute ProjectDirectory.valid?(List.duplicate(link(), 21))
  end

  test "self-management workflow parses with isolated identity and retained intake storage" do
    path = Path.expand("../../../WORKFLOW.md", __DIR__)
    assert {:ok, workflow} = Workflow.load(path)
    assert {:ok, settings} = Schema.parse(workflow.config)
    assert settings.tracker.provider["repo"] == "iliazlobin/symphony"
    assert settings.control.initial_mode == "paused"
    assert settings.control.max_total_tokens == 1_000_000
    assert settings.server.session_cookie == "_symphony_self_key"
    assert settings.chat.enabled
    assert settings.chat.state_path == "$SYMPHONY_CHAT_STATE"
    assert settings.browser_auth["provider"] == "google"
    assert settings.browser_auth["allowed_emails"] == []
  end

  test "cookie keys are explicit and legacy installations retain their key" do
    assert %Server{}.session_cookie == "_symphony_elixir_key"
    assert Server.changeset(%Server{}, %{"session_cookie" => "_symphony_self_key"}).valid?

    for key <- ["", nil, "bad; cookie", String.duplicate("x", 100), "../cookie"] do
      refute Server.changeset(%Server{}, %{"session_cookie" => key}).valid?
    end
  end
end
