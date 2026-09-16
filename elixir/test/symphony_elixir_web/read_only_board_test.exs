defmodule SymphonyElixirWeb.ReadOnlyBoardTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixirWeb.ReadOnlyBoard

  defmodule UnavailableGitHub do
    def fetch_issues_by_states(["open", "closed"]), do: {:error, :unavailable}
  end

  setup do
    previous = Map.new(["SYMPHONY_BOARD_API_URL", "SYMPHONY_BOARD_CONTROL_TOKEN", "GITHUB_TOKEN"], &{&1, System.get_env(&1)})
    System.delete_env("GITHUB_TOKEN")
    System.put_env("SYMPHONY_BOARD_API_URL", "http://127.0.0.1:9876")
    System.put_env("SYMPHONY_BOARD_CONTROL_TOKEN", String.duplicate("t", 40))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> if value, do: System.put_env(key, value), else: System.delete_env(key) end)
    end)

    :ok
  end

  test "reads live tracker and controller independently without constructing execution authority" do
    owner = self()

    requester = fn url, token, timeout ->
      send(owner, {:get, url, token, timeout})
      {:ok, if(String.ends_with?(url, "/state"), do: runtime(), else: control())}
    end

    issue = %SymphonyElixir.Tracker.Issue{
      id: "6",
      identifier: "GH-6",
      title: "Pilot",
      state: "open",
      dispatchable: true,
      description: "Depends on: none",
      labels: ["ready"],
      native_ref: %{"repo" => "example/repo"}
    }

    board = ReadOnlyBoard.load_with(settings(), 500, fn ["open", "closed"] -> {:ok, [issue]} end, requester)
    assert board.read_only
    assert board.source_error == nil
    assert board.runtime_error == nil
    assert board.data_mode == "Live GitHub"
    assert board.runtime.codex_totals.total_tokens == 123
    assert hd(board.tasks).stage == "review"
    assert Enum.any?(board.context_links, &(&1.url == "https://github.com/example/repo/pulls"))
    assert_receive {:get, "http://127.0.0.1:9876/api/v1/state", _, 500}
    assert_receive {:get, "http://127.0.0.1:9876/api/v1/control", _, 500}
    refute_receive {:get, _, _, _}
  end

  test "missing or malformed runtime is unknown and cannot become a successful idle snapshot" do
    for body <- [%{}, %{"running" => [], "retrying" => [], "blocked" => ["invalid"], "codex_totals" => %{}}] do
      board = ReadOnlyBoard.load_with(settings(), 500, fn _ -> {:ok, []} end, fn _, _, _ -> {:ok, body} end)
      assert board.runtime.error.code == "controller_unavailable"
      assert board.runtime_error =~ "unknown"
      refute Map.has_key?(board.runtime, :running)
    end
  end

  test "runtime entries use an explicit key allowlist without converting untrusted keys to atoms" do
    data = runtime() |> Map.put("running", [%{"issue_id" => "8", "issue_identifier" => "GH-8", "last_message" => "Inspecting", "unknown_runtime_key_never_atomized" => "discard"}])
    data = data |> Map.put("retrying", [%{"issue_id" => "9", "issue_identifier" => "GH-9", "error" => "Retry pending"}])
    data = data |> Map.put("blocked", [%{"issue_id" => "10", "issue_identifier" => "GH-10", "error" => "Answer needed"}])
    requester = fn url, _, _ -> {:ok, if(String.ends_with?(url, "/state"), do: data, else: control())} end
    board = ReadOnlyBoard.load_with(settings(), 500, fn _ -> {:ok, []} end, requester)
    assert hd(board.runtime.running).last_message == "Inspecting"
    refute Map.has_key?(hd(board.runtime.running), "unknown_runtime_key_never_atomized")
    assert hd(board.runtime.retrying).error == "Retry pending"
    assert hd(board.runtime.blocked).error == "Answer needed"
    assert Enum.find(board.tasks, &(&1.issue_id == "8")).source_missing
  end

  test "invalid destinations cannot receive the controller credential" do
    for url <- ["https://example.com", "http://localhost:8777", "http://127.0.0.1:8777/wrong", "http://u:p@127.0.0.1:8777"] do
      System.put_env("SYMPHONY_BOARD_API_URL", url)
      board = ReadOnlyBoard.load_with(settings(), 50, fn _ -> {:ok, []} end, fn _, _, _ -> flunk("credential egress") end)
      assert board.runtime_error =~ "unknown"
    end

    assert ReadOnlyBoard.snapshot().error.code == "controller_unavailable"
  end

  test "source scope, timeouts and failures remain explicit and sanitize exception details" do
    sources = [
      fn _ -> {:ok, [%SymphonyElixir.Tracker.Issue{id: "1", native_ref: %{"repo" => "foreign/repo"}}]} end,
      fn _ -> raise "private value" end,
      fn _ -> throw("private value") end,
      fn _ -> Process.sleep(10_000) end
    ]

    for source <- sources do
      board =
        ReadOnlyBoard.load_with(settings(), 25, source, fn url, _, _ ->
          {:ok, if(String.ends_with?(url, "/state"), do: runtime(), else: control())}
        end)

      assert board.source_error
      refute board.source_error =~ "private"
    end
  end

  test "control failure is separate from successful runtime reads" do
    for response <- [{:error, :unavailable}, {:ok, Map.put(control(), "fault", "disk")}] do
      requester = fn url, _, _ -> if String.ends_with?(url, "/state"), do: {:ok, runtime()}, else: response end
      board = ReadOnlyBoard.load_with(settings(), 100, fn _ -> {:ok, []} end, requester)
      refute board.runtime[:error]
      assert board.runtime_error
    end

    requester = fn url, _, _ ->
      {:ok, if(String.ends_with?(url, "/state"), do: runtime(), else: %{"enabled" => false})}
    end

    board = ReadOnlyBoard.load_with(settings(), 100, fn _ -> {:ok, []} end, requester)
    assert board.runtime_error == nil
    assert board.control == %{"enabled" => false}
  end

  test "snapshot makes an actual bounded GET and rejects redirects and malformed responses" do
    for {status, body} <- [{200, Jason.encode!(runtime())}, {302, ""}, {200, "not json"}] do
      {port, server} = serve(status, body)
      System.put_env("SYMPHONY_BOARD_API_URL", "http://127.0.0.1:#{port}")
      result = ReadOnlyBoard.snapshot()
      if status == 200 and String.starts_with?(body, "{"), do: assert(result.running == []), else: assert(result[:error])
      assert Task.await(server) =~ "GET /api/v1/state HTTP/1.1"
    end
  end

  test "public loader fails explicitly without starting a controller or acquiring a ledger" do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, UnavailableGitHub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :github_client_module)
    end)

    provider = %{repo: "example/repo", token: "fixture-token"}
    tracker = %{kind: "github", provider: provider, active_states: ["open"], terminal_states: ["closed"]}
    config = %{tracker: tracker, control: %{enabled: false}}
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nRead-only test")
    assert :ok = WorkflowStore.force_reload()
    System.put_env("SYMPHONY_BOARD_API_URL", "invalid")
    board = ReadOnlyBoard.load(:no_controller_exists, 100)
    assert board.read_only
    assert board.source_error
    assert board.runtime_error
  end

  defp serve(status, body) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.send(socket, "HTTP/1.1 #{status} Test\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}")
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        request
      end)

    {port, task}
  end

  defp runtime, do: %{"running" => [], "retrying" => [], "blocked" => [], "codex_totals" => %{"total_tokens" => 123}}
  defp control, do: %{"enabled" => true, "mode" => "running", "issues" => %{"6" => %{"hold" => "owner_review", "handoff" => %{}}}}

  defp settings do
    %{
      tracker: %{
        kind: "github",
        provider: %{"repo" => "example/repo", "api_url" => "https://github.example.test/api/v3"},
        active_states: ["open"],
        terminal_states: ["closed"],
        required_labels: ["ready"]
      },
      control: %{enabled: true}
    }
  end
end
