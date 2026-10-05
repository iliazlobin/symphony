defmodule SymphonyElixir.Chat.PRUpdatesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Chat.{PRUpdates, Store}
  alias SymphonyElixirWeb.{BoardCache, Endpoint, TaskBoard}

  defmodule Board do
    def load(_owner, timeout) do
      {parent, load} = Application.fetch_env!(:symphony_elixir, :pr_updates_test_load)
      send(parent, {:board_read, timeout})
      load.()
    end
  end

  setup do
    keys = [Endpoint, :chat_board_module, :pr_updates_test_load]
    old = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})

    on_exit(fn ->
      Enum.each(old, fn {key, value} ->
        if is_nil(value) do
          Application.delete_env(:symphony_elixir, key)
        else
          Application.put_env(:symphony_elixir, key, value)
        end
      end)
    end)

    endpoint_config = [server: false, secret_key_base: String.duplicate("c", 64), board_read_only: false]
    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    config = %{
      tracker: %{
        kind: "github",
        provider: %{repo: "example/repo", token: "unused-fixture"},
        active_states: ["open"],
        terminal_states: ["closed"]
      },
      chat: %{enabled: true}
    }

    configure(config)
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "chats")
    auth = %{tracker_fingerprint: Orchestrator.tracker_fingerprint()}

    store =
      start_supervised!(
        {Store,
         name: nil,
         settings: %{enabled: true, state_path: root, codex_home: root <> "/runtime", executable: "/usr/bin/false"},
         projects: fn -> [%{"id" => "github:example/repo"}] end,
         authorize: fn _ -> true end}
      )

    Application.put_env(:symphony_elixir, :chat_board_module, Board)
    {:ok, chat} = Store.ensure_conversation("github:example/repo", "github:example/repo:1", auth, store)
    issue = %Issue{id: "1", identifier: "GH-1", state: "open", title: "Issue", dispatchable: true, native_ref: %{"repo" => "example/repo"}}
    board = TaskBoard.project([issue], %{running: [], retrying: [], blocked: []}, %{"enabled" => false}, Config.settings!())

    pr = %{
      number: 7,
      title: "Change",
      url: "https://github.com/example/repo/pull/7",
      state: "open",
      checks: "success",
      review: "approved",
      head_sha: String.duplicate("a", 40)
    }

    board = %{board | tasks: Enum.map(board.tasks, &%{&1 | github_status: "available", pull_requests: [pr]})}

    Application.put_env(:symphony_elixir, :pr_updates_test_load, {self(), fn -> board end})
    updater = start_supervised!({PRUpdates, name: nil, store: store, interval_ms: :manual})
    %{config: config, board: board, store: store, updater: updater, auth: auth, chat: chat}
  end

  test "polling reuses fresh scoped evidence and refreshes stale, missing or invalid checked times", c do
    scope = BoardCache.scope(Orchestrator)
    assert :ok = BoardCache.put(scope, c.board)
    assert :ok = PRUpdates.sync(c.updater)
    refute_receive {:board_read, _}
    assert {:ok, chat} = Store.get("github:example/repo", c.chat["id"], c.auth, c.store)
    assert [%{"text" => text}] = chat["messages"]
    assert text =~ "CI: Success"

    for time <- ["2020-01-01T00:00:00Z", "bad-date", nil, "2099-01-01T00:00:00Z"] do
      BoardCache.put(scope, %{c.board | generated_at: time})
      assert :ok = PRUpdates.sync(c.updater)
      assert_receive {:board_read, 5_000}
      assert {:ok, ^chat} = Store.get("github:example/repo", c.chat["id"], c.auth, c.store)
    end

    BoardCache.put("other-scope", c.board)
    assert :ok = PRUpdates.sync(c.updater)
    assert_receive {:board_read, 5_000}
  end

  test "scope changes and failed reads leave previously recorded reports unchanged", c do
    assert :ok = PRUpdates.sync(c.updater)
    assert_receive {:board_read, _}
    assert {:ok, first} = Store.get("github:example/repo", c.chat["id"], c.auth, c.store)

    for reader <- [
          fn -> %{c.board | source_error: "Unavailable"} end,
          fn -> raise "Failed read" end,
          fn -> exit(:unavailable) end,
          fn ->
            configure(put_in(c.config, [:tracker, :provider, :token], "rotated-fixture"))
            c.board
          end
        ] do
      BoardCache.put("other-scope", c.board)
      Application.put_env(:symphony_elixir, :pr_updates_test_load, {self(), reader})
      assert :ok = PRUpdates.sync(c.updater)
      assert_receive {:board_read, _}
      assert {:ok, ^first} = Store.get("github:example/repo", c.chat["id"], c.auth, c.store)
    end
  end

  test "disabled chat, non-GitHub configuration, unavailable endpoint and untracked stores do not read", c do
    for config <- [put_in(c.config, [:chat, :enabled], false), %{chat: %{enabled: true}, tracker: %{kind: "memory"}}] do
      configure(config)
      assert :ok = PRUpdates.sync(c.updater)
      refute_receive {:board_read, _}
    end

    configure(c.config)
    stop_supervised!(Endpoint)
    assert :ok = PRUpdates.sync(c.updater)
    refute_receive {:board_read, _}
    stop_supervised!(Store)
    assert :ok = PRUpdates.sync(c.updater)
    refute_receive {:board_read, _}
  end

  test "scheduled ticks deliver reports without requiring an open browser", c do
    updater = start_supervised!({PRUpdates, name: nil, store: c.store, interval_ms: 10}, id: :scheduled)
    assert_receive {:board_read, 5_000}, 1_000
    assert :ok = PRUpdates.sync(updater)
    assert {:ok, chat} = Store.get("github:example/repo", c.chat["id"], c.auth, c.store)
    assert length(chat["messages"]) == 1
    stop_supervised!(:scheduled)
  end

  defp configure(config) do
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nTest")
    assert :ok = WorkflowStore.force_reload()
  end
end
