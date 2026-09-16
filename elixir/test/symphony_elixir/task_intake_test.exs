defmodule SymphonyElixirWeb.TaskIntakeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Chat.Store
  alias SymphonyElixir.GitHub.Admission
  alias SymphonyElixirWeb.{Endpoint, TaskIntake}

  defmodule TestTools do
    def call("symphony_propose_action", args, context) do
      send(context.auth.test_pid, {:prepared, args})

      case context.auth[:prepare_result] do
        :error ->
          {:error, :board_unavailable}

        :malformed ->
          {:ok, %{}}

        _ ->
          {:ok,
           %{
             "proposal" => %{
               "action" => args["action"],
               "args" => Map.delete(args, "action"),
               "project_id" => context.project_id,
               "tracker_fingerprint" => context.tracker_fingerprint,
               "expected_updated_at" => context.auth[:updated_at],
               "created_at" => "2026-09-16T01:00:00Z"
             },
             "widgets" => [%{"type" => "proposal", "title" => "Review task change"}]
           }}
      end
    end

    def confirm(proposal, context) do
      send(context.auth.test_pid, {:confirmed, proposal, self()})

      case context.auth[:result] do
        :wait -> receive do: (:finish -> {:ok, %{"summary" => "Task created"}})
        :unknown -> {:error, :write_outcome_unknown}
        _ -> {:ok, %{"summary" => "Task created", "url" => "https://github.com/test/one/issues/12"}}
      end
    end

    def reconcile(proposal, context) do
      send(context.auth.test_pid, {:reconciled, proposal})
      {:ok, %{"summary" => "Existing task found", "url" => "https://github.com/test/one/issues/12"}}
    end
  end

  defmodule Adapter do
    def list_actions(project, auth), do: Store.list_actions(project, auth, __MODULE__)
    def get_action(project, id, auth), do: Store.get_action(project, id, auth, __MODULE__)
    def prepare_action(project, id, args, revision, auth), do: Store.prepare_action(project, id, args, revision, auth, __MODULE__)
    def decide_action_record(project, id, decision, auth), do: Store.decide_action_record(project, id, decision, auth, __MODULE__)
  end

  setup do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "task-intake-#{System.unique_integer([:positive])}"))
    settings = %{enabled: false, state_path: root, max_concurrent: 2}
    projects = fn -> [%{"id" => "github:test/one"}, %{"id" => "github:test/two"}] end
    authorize = fn auth -> auth[:allowed] == true end
    opts = [name: Adapter, settings: settings, projects: projects, authorize: authorize, tools: TestTools]
    server = start_supervised!({Store, opts})
    prior = Application.get_env(:symphony_elixir, Endpoint)
    Application.put_env(:symphony_elixir, Endpoint, Keyword.merge(prior || [], server: false, secret_key_base: String.duplicate("i", 64), chat_store: Adapter, board_read_only: false))

    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, prior)
      File.rm_rf(root)
    end)

    %{
      project: "github:test/one",
      auth: %{allowed: true, tracker_fingerprint: "scope", test_pid: self()},
      root: root,
      opts: opts,
      server: server,
      id: String.duplicate("a", 32),
      args: %{"action" => "create_task", "title" => "A task", "body" => "## Outcome\nDone\n\nDepends on: none"}
    }
  end

  test "disabled chat keeps deterministic action previews durable without model access", c do
    assert {:ok, record} = TaskIntake.prepare(c.project, c.id, c.args, nil, c.auth)
    assert record["kind"] == "board_action"
    assert [%{"status" => "pending"}] = record["proposals"]
    assert File.exists?(Path.join(c.root, c.id <> ".json"))
    assert {:ok, [^record]} = TaskIntake.list(c.project, c.auth)
    assert {:ok, ^record} = TaskIntake.get(c.project, c.id, c.auth)
    assert {:error, :chat_not_configured} = Store.list(c.project, c.auth, c.server)
    assert {:ok, %{enabled: false, healthy: false}} = Store.health(c.auth, c.server)
    assert {:error, :chat_not_configured} = Store.create(c.project, "Chat", c.auth, c.server)

    for operation <- [:get, :archive, :stop] do
      assert {:error, :chat_not_found} = apply(Store, operation, [c.project, c.id, c.auth, c.server])
    end

    assert {:error, :chat_not_found} = Store.rename(c.project, c.id, "Hide", c.auth, c.server)
    assert {:error, :chat_not_found} = Store.send_message(c.project, c.id, "Model", "client", c.auth, c.server)
    assert {:error, :chat_not_found} = Store.decide(c.project, c.id, hd(record["proposals"])["id"], "confirm", c.auth, c.server)
    refute Map.has_key?(record, "submission")
  end

  test "disabling inference preserves saved conversations but hides all chat-only operations", c do
    :sys.replace_state(c.server, fn state -> put_in(state, [:settings, :enabled], true) end)
    assert {:ok, chat} = Store.create(c.project, "Existing chat", c.auth, c.server)
    restart(c)
    assert File.exists?(Path.join(c.root, chat["id"] <> ".json"))
    assert {:error, :chat_not_configured} = Store.list(c.project, c.auth, Adapter)

    for operation <- [:get, :archive, :stop] do
      assert {:error, :chat_not_configured} = apply(Store, operation, [c.project, chat["id"], c.auth, Adapter])
    end

    assert {:error, :chat_not_configured} = Store.rename(c.project, chat["id"], "Hidden", c.auth, Adapter)
    assert {:error, :chat_not_configured} = Store.send_message(c.project, chat["id"], "Hello", "client", c.auth, Adapter)
    assert {:error, :chat_not_configured} = Store.decide(c.project, chat["id"], c.id, "confirm", c.auth, Adapter)
    assert {:error, :chat_not_found} = TaskIntake.get(c.project, chat["id"], c.auth)
    assert {:ok, []} = TaskIntake.list(c.project, c.auth)
  end

  test "exact submission replay survives restart and changed content cannot reuse its identity", c do
    assert {:ok, record} = TaskIntake.prepare(c.project, c.id, c.args, nil, c.auth)
    assert_receive {:prepared, _}
    assert {:ok, ^record} = TaskIntake.prepare(c.project, c.id, c.args, nil, c.auth)
    refute_receive {:prepared, _}
    restart(c)
    assert {:ok, ^record} = TaskIntake.prepare(c.project, c.id, c.args, nil, c.auth)
    assert {:error, :submission_id_conflict} = TaskIntake.prepare(c.project, c.id, Map.put(c.args, "title", "Different"), nil, c.auth)
    assert {:error, :chat_not_found} = TaskIntake.prepare("github:test/two", c.id, c.args, nil, c.auth)
    assert {:error, :chat_not_found} = TaskIntake.get(c.project, c.id, %{c.auth | tracker_fingerprint: "new"})
    assert {:ok, []} = TaskIntake.list(c.project, %{c.auth | tracker_fingerprint: "new"})
    assert {:error, :unauthorized} = TaskIntake.prepare(c.project, c.id, c.args, nil, %{})
    assert {:error, :unauthorized} = TaskIntake.decide(c.project, c.id, "confirm", %{})
    assert {:error, :unauthorized} = Store.prepare_action(c.project, c.id, c.args, nil, %{})
    assert {:error, :project_not_found} = TaskIntake.list("github:unknown/project", c.auth)
    refute_receive {:confirmed, _, _}
  end

  test "an interrupted confirmed action only reconciles after restart and never repeats the write", c do
    {:ok, _} = TaskIntake.prepare(c.project, c.id, c.args, nil, c.auth)
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "chat:" <> c.id)
    assert {:error, :invalid_decision} = TaskIntake.decide(c.project, c.id, "reconcile", c.auth)
    assert {:error, :invalid_decision} = TaskIntake.decide(c.project, c.id, "other", c.auth)
    assert {:ok, executing} = TaskIntake.decide(c.project, c.id, "confirm", Map.put(c.auth, :result, :wait))
    assert hd(executing["proposals"])["status"] == "executing"
    assert_receive {:confirmed, proposal, _worker}
    persisted = Jason.decode!(File.read!(Path.join(c.root, c.id <> ".json")))
    assert hd(persisted["proposals"])["status"] == "executing"
    assert {:error, :chat_busy} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    restart(c)
    assert {:ok, recovered} = TaskIntake.get(c.project, c.id, c.auth)
    assert hd(recovered["proposals"])["status"] == "unknown"
    assert {:ok, _} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    assert_receive {:reconciled, ^proposal}
    completed = wait_for(c, "completed")
    assert hd(completed["proposals"])["receipt"]["summary"] == "Existing task found"
    assert {:ok, ^completed} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    refute_receive {:confirmed, _, _}
  end

  test "uncertain HTTP outcomes remain saved and cancelled previews never write", c do
    {:ok, _} = TaskIntake.prepare(c.project, c.id, c.args, nil, c.auth)
    assert {:ok, _} = TaskIntake.decide(c.project, c.id, "confirm", Map.put(c.auth, :result, :unknown))
    assert_receive {:confirmed, _, _}
    unknown = wait_for(c, "unknown")
    restart(c)
    assert {:ok, ^unknown} = TaskIntake.get(c.project, c.id, c.auth)
    assert {:ok, ^unknown} = TaskIntake.prepare(c.project, c.id, c.args, nil, c.auth)
    assert {:ok, _} = TaskIntake.decide(c.project, c.id, "reconcile", c.auth)
    assert_receive {:reconciled, _}
    wait_for(c, "completed")
    other = String.duplicate("b", 32)
    assert {:ok, _} = TaskIntake.prepare(c.project, other, c.args, nil, c.auth)
    assert {:ok, cancelled} = TaskIntake.decide(c.project, other, "cancel", c.auth)
    assert hd(cancelled["proposals"])["status"] == "cancelled"
    refute_receive {:confirmed, _, _}
  end

  test "edits require the original visible revision and reject stale preparation without a journal write", c do
    args = %{"action" => "edit_task", "task_id" => "github:test/one:12", "title" => "Changed"}
    assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, c.id, args, nil, c.auth)
    assert {:error, :task_changed} = TaskIntake.prepare(c.project, c.id, args, "old", Map.put(c.auth, :updated_at, "new"))
    refute File.exists?(Path.join(c.root, c.id <> ".json"))
    assert {:ok, record} = TaskIntake.prepare(c.project, c.id, args, "current", Map.put(c.auth, :updated_at, "current"))
    assert hd(record["proposals"])["expected_updated_at"] == "current"
    assert {:ok, ^record} = TaskIntake.prepare(c.project, c.id, args, "current", Map.put(c.auth, :updated_at, "changed-again"))
  end

  test "bounded form actions validate dependency syntax and reject privileged or malformed fields", c do
    for args <- [nil, %{}, %{"action" => "resume"}, Map.put(c.args, "priority", 1), %{"action" => "create_task", "body" => nil}] do
      assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, c.id, args, nil, c.auth)
    end

    assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, "not-an-id", c.args, nil, c.auth)
    assert {:error, :invalid_submission} = TaskIntake.prepare(c.project, c.id, c.args, 5, c.auth)
    assert {:error, {:invalid_dependency_declaration, explanation}} = TaskIntake.prepare(c.project, c.id, Map.put(c.args, "body", "Missing dependencies"), nil, c.auth)
    assert TaskIntake.error_message({:invalid_dependency_declaration, explanation}) =~ "Depends on"
    assert {:ok, ["12", "34"]} = Admission.validate_declaration("Intent\nDepends on: #12, #34")
    assert {:error, _} = Admission.validate_declaration(nil)

    for {action, body} <- [{"edit_task", "Depends on: none"}, {"feedback", "A comment"}, {"queue_task", nil}, {"unqueue_task", nil}] do
      args = %{"action" => action, "task_id" => "GH-12"}
      args = if body, do: Map.put(args, "body", body), else: args
      assert {:ok, _} = TaskIntake.prepare(c.project, new_id(), args, "current", Map.put(c.auth, :updated_at, "current"))
    end
  end

  test "storage and read-only guards prevent proposals or confirmed writes", c do
    Endpoint.config_change([{Endpoint, Keyword.put(Application.get_env(:symphony_elixir, Endpoint), :board_read_only, true)}], [])
    assert {:error, :read_only} = TaskIntake.prepare(c.project, c.id, c.args, nil, c.auth)
    assert {:error, :read_only} = TaskIntake.list(c.project, c.auth)
    assert TaskIntake.error_message(:read_only) =~ "read-only"
    assert TaskIntake.error_message(:task_changed) =~ "changed"
    assert TaskIntake.error_message("Unavailable") == "Unavailable"
    refute_receive {:prepared, _}
    Endpoint.config_change([{Endpoint, Keyword.put(Application.get_env(:symphony_elixir, Endpoint), :board_read_only, false)}], [])
    {:ok, _} = TaskIntake.prepare(c.project, c.id, c.args, nil, c.auth)
    path = Path.join(c.root, c.id <> ".json")
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, :chat_storage_unavailable} = TaskIntake.decide(c.project, c.id, "confirm", c.auth)
    assert {:error, :chat_storage_unavailable} = TaskIntake.list(c.project, c.auth)
    refute_receive {:confirmed, _, _}
  end

  test "preparation failures and journal capacity preserve prior records", c do
    assert {:error, :board_unavailable} = TaskIntake.prepare(c.project, c.id, c.args, nil, Map.put(c.auth, :prepare_result, :error))
    assert {:error, :invalid_proposal} = TaskIntake.prepare(c.project, c.id, c.args, nil, Map.put(c.auth, :prepare_result, :malformed))
    assert {:ok, []} = TaskIntake.list(c.project, c.auth)
    :sys.replace_state(c.server, fn state -> %{state | chats: Map.new(1..500, fn n -> {n, %{}} end)} end)
    assert {:error, :action_history_full} = TaskIntake.prepare(c.project, c.id, c.args, nil, c.auth)
  end

  defp restart(c) do
    stop_supervised!(Store)
    start_supervised!({Store, c.opts})
  end

  defp wait_for(c, status, attempts \\ 100)
  defp wait_for(_c, _status, 0), do: flunk("Action did not settle")

  defp wait_for(c, status, attempts) do
    {:ok, record} = TaskIntake.get(c.project, c.id, c.auth)

    if hd(record["proposals"])["status"] == status do
      record
    else
      Process.sleep(10)
      wait_for(c, status, attempts - 1)
    end
  end

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
