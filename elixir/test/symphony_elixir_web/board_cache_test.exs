defmodule SymphonyElixirWeb.BoardCacheTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.{BoardCache, Endpoint, TaskBoard}

  setup do
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])

    Application.put_env(:symphony_elixir, Endpoint,
      server: false,
      secret_key_base: String.duplicate("c", 64),
      board_read_only: false
    )

    start_supervised!({Endpoint, []})
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, previous_endpoint) end)

    clock = start_supervised!({Agent, fn -> 0 end})
    name = Module.concat(__MODULE__, "Cache#{System.unique_integer([:positive])}")
    cache = start_supervised!({BoardCache, name: name, clock: fn -> Agent.get(clock, & &1) end})
    board = TaskBoard.project([], %{running: [], retrying: [], blocked: []}, %{"enabled" => false}, Config.settings!())
    %{cache: cache, cache_name: name, clock: clock, board: board}
  end

  test "keeps a complete snapshot for reloads without renewing its checked time or expiry", ctx do
    scope = BoardCache.scope(self())
    assert is_binary(scope)
    assert :miss = BoardCache.get(scope, ctx.cache)
    assert :ok = BoardCache.put(scope, ctx.board, ctx.cache)
    assert {:ok, board} = BoardCache.get(scope, ctx.cache)
    assert board == ctx.board
    Agent.update(ctx.clock, fn _ -> 89_999 end)
    assert {:ok, ^board} = BoardCache.get(scope, ctx.cache)
    Agent.update(ctx.clock, fn _ -> 90_000 end)
    assert :miss = BoardCache.get(scope, ctx.cache)
    assert :sys.get_state(ctx.cache).entry == nil
  end

  test "keeps one scoped snapshot and rejects unscoped, incomplete, and oversized replacements", ctx do
    scope = BoardCache.scope(self())
    assert :ok = BoardCache.put(scope, ctx.board, ctx.cache)

    for invalid <- [
          %{ctx.board | source_error: "Tracker unavailable"},
          %{ctx.board | runtime_error: "Runtime unavailable"},
          %{ctx.board | tasks: nil},
          Map.put(ctx.board, :oversized, String.duplicate("x", 8_000_000)),
          %{}
        ] do
      assert :ok = BoardCache.put(scope, invalid, ctx.cache)
      assert {:ok, board} = BoardCache.get(scope, ctx.cache)
      assert board == ctx.board
    end

    assert :ok = BoardCache.put(nil, ctx.board, ctx.cache)
    assert :miss = BoardCache.get(nil, ctx.cache)
    assert :miss = BoardCache.get("another-source", ctx.cache)
    assert {:ok, _} = BoardCache.get(scope, ctx.cache)
    newer = %{ctx.board | generated_at: "2099-01-01T00:00:00Z"}
    assert :ok = BoardCache.put("another-source", newer, ctx.cache)
    assert :miss = BoardCache.get(scope, ctx.cache)
    assert {:ok, ^newer} = BoardCache.get("another-source", ctx.cache)
  end

  test "partial PR enrichment remains truthful and is eligible for fast reload", ctx do
    scope = BoardCache.scope(self())
    partial = %{ctx.board | enrichment_error: "PR evidence unavailable"}
    assert :ok = BoardCache.put(scope, partial, ctx.cache)
    assert {:ok, ^partial} = BoardCache.get(scope, ctx.cache)
  end

  test "cache restart forgets private snapshot and unavailability cannot break a page load", ctx do
    scope = BoardCache.scope(self())
    assert :ok = BoardCache.put(scope, ctx.board, ctx.cache)
    assert :ok = stop_supervised(BoardCache)
    assert :miss = BoardCache.get(scope, ctx.cache)
    assert :ok = BoardCache.put(scope, ctx.board, ctx.cache)
    cache = start_supervised!({BoardCache, name: ctx.cache_name})
    assert :miss = BoardCache.get(scope, cache)
    assert :ok = BoardCache.put(scope, ctx.board, cache)
    assert {:ok, _} = BoardCache.get(scope, cache)
    assert :miss = BoardCache.get(nil)
    assert :ok = BoardCache.put(nil, ctx.board)
  end

  test "scope fences tracker rules, endpoint sources and runtime owner identity", ctx do
    scope = BoardCache.scope(self())
    assert :ok = BoardCache.put(scope, ctx.board, ctx.cache)
    assert BoardCache.scope(self()) == scope
    runtime = start_supervised!({Task, fn -> receive do: (:finish -> :ok) end})
    refute BoardCache.scope(runtime) == scope

    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["ready"])
    changed = BoardCache.scope(self())
    refute changed == scope
    assert :miss = BoardCache.get(changed, ctx.cache)

    for {key, value} <- [board_loader: &TaskBoard.load/2, snapshot_loader: fn -> %{} end, board_read_only: true] do
      before_change = BoardCache.scope(self())
      configure_endpoint(key, value)
      refute BoardCache.scope(self()) == before_change
    end

    assert :ok = stop_supervised(Endpoint)
    assert BoardCache.scope(self()) == nil
    start_supervised!({Endpoint, []})
    refute BoardCache.scope(self()) == changed
  end

  test "scope rotates on resolved tracker and read-only controller credentials without exposing values" do
    environment = ~w(SYMPHONY_BOARD_CACHE_TEST_TOKEN GITHUB_TOKEN SYMPHONY_BOARD_API_URL SYMPHONY_BOARD_CONTROL_TOKEN)
    previous = Map.new(environment, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    config = %{
      tracker: %{
        kind: "github",
        provider: %{repo: "example/repo", token: "$SYMPHONY_BOARD_CACHE_TEST_TOKEN"},
        active_states: ["open"],
        terminal_states: ["closed"]
      }
    }

    System.put_env("SYMPHONY_BOARD_CACHE_TEST_TOKEN", "private-first-source-token")
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nTask")
    assert :ok = WorkflowStore.force_reload()
    scope = BoardCache.scope(self())
    refute scope =~ "private-first-source-token"
    assert byte_size(scope) == 43
    System.put_env("SYMPHONY_BOARD_CACHE_TEST_TOKEN", "private-second-source-token")
    refute BoardCache.scope(self()) == scope

    configure_endpoint(:board_read_only, true)

    for {key, value} <- [
          {"GITHUB_TOKEN", "fallback-token"},
          {"SYMPHONY_BOARD_API_URL", "http://127.0.0.1:8777"},
          {"SYMPHONY_BOARD_CONTROL_TOKEN", String.duplicate("controller-private", 3)}
        ] do
      before_change = BoardCache.scope(self())
      System.put_env(key, value)
      refute BoardCache.scope(self()) == before_change
    end
  end

  defp configure_endpoint(key, value) do
    config = Keyword.put(Application.get_env(:symphony_elixir, Endpoint), key, value)
    Application.put_env(:symphony_elixir, Endpoint, config)
    Endpoint.config_change([{Endpoint, config}], [])
  end
end
